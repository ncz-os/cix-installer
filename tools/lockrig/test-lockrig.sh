#!/usr/bin/env bash
# tools/lockrig/test-lockrig.sh -- offline self-test of the rig (no hosts touched).
# Checks: shell syntax of every script, python syntax of the lib, lease.sh
# acquire/refuse/release/expire semantics, hosts.tsv parse, and report.sh
# consolidation on synthetic data. CI-friendly: exit 0 on success.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
bad(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
have(){ grep -qF -- "$2" "$1" 2>/dev/null; }

echo "== syntax =="
for f in "$HERE/lockrig" "$HERE/lease.sh" "$HERE/report.sh" "$HERE/test-lockrig.sh" \
         "$HERE/agent/run_host.sh" "$HERE/agent/headless.sh" "$HERE/agent/preflight.sh"; do
  if bash -n "$f" 2>/dev/null; then ok "bash -n $(basename "$f")"; else bad "bash -n $(basename "$f")"; bash -n "$f"; fi
done
for p in "$HERE"/agent/lib/*.py; do
  if python3 -m py_compile "$p" 2>/dev/null; then ok "py_compile $(basename "$p")"; else bad "py_compile $(basename "$p")"; fi
done

echo "== hosts.example.tsv =="
n=$(awk -F'\t' '!/^#/ && NF>=9' "$HERE/hosts.example.tsv" | wc -l | tr -d ' ')
[ "$n" -ge 6 ] && ok "hosts.example.tsv has $n host rows" || bad "hosts.example.tsv only $n rows"
awk -F'\t' '!/^#/ && NF>=9 { if ($8!="0" && $8!="1") { print "bad attended: "$0; exit 1 } if ($9!="0" && $9!="1") { print "bad headless: "$0; exit 1 } }' "$HERE/hosts.example.tsv" \
  && ok "attended/headless flags are 0/1" || bad "attended/headless flags malformed"
awk -F'\t' '!/^#/ && NF>=9 && $2 !~ /^192\.0\.2\./ { print "non-documentation address: "$1; exit 1 }' "$HERE/hosts.example.tsv" \
  && ok "example inventory uses documentation addresses only" || bad "example inventory carries a real address"

echo "== lease semantics =="
TMP="$(mktemp -d)"; export LOCKRIG_LEASE_DIR="$TMP" LOCKRIG_LEASE_DIRS=""
"$HERE/lease.sh" acquire rigtest --owner alice --purpose "selftest" --ttl 60 >/dev/null 2>&1 && ok "alice acquired rigtest" || bad "alice acquire"
"$HERE/lease.sh" acquire rigtest --owner bob --purpose "selftest" >/dev/null 2>&1; rc=$?
[ "$rc" = 3 ] && ok "bob REFUSED while alice holds (rc=3)" || bad "bob not refused (rc=$rc)"
"$HERE/lease.sh" acquire rigtest --owner alice --purpose "refresh" >/dev/null 2>&1 && ok "same owner re-acquire (idempotent)" || bad "same owner re-acquire"
"$HERE/lease.sh" release rigtest --owner bob >/dev/null 2>&1; rc=$?
[ "$rc" = 3 ] && ok "bob cannot release alice's lease" || bad "bob release not refused (rc=$rc)"
"$HERE/lease.sh" release rigtest --owner alice >/dev/null 2>&1 && ok "alice released" || bad "alice release"
"$HERE/lease.sh" acquire rigtest --owner bob --purpose "now free" >/dev/null 2>&1 && ok "bob acquires after release" || bad "bob acquire after release"
# expiry takeover
"$HERE/lease.sh" release rigtest --owner bob >/dev/null 2>&1
"$HERE/lease.sh" acquire rigtest --owner carol --purpose "short" --ttl 1 >/dev/null 2>&1
sleep 2
"$HERE/lease.sh" acquire rigtest --owner dave --purpose "takeover" >/dev/null 2>&1 && ok "expired lease taken over" || bad "expired takeover"
"$HERE/lease.sh" reap >/dev/null 2>&1; "$HERE/lease.sh" release rigtest --owner dave >/dev/null 2>&1
rm -rf "$TMP"; unset LOCKRIG_LEASE_DIR LOCKRIG_LEASE_DIRS

echo "== lease semantics across two lease directories =="
L1="$(mktemp -d)"; L2="$(mktemp -d)"; LX="$(mktemp -d)"
export LOCKRIG_LEASE_DIR="$L1" LOCKRIG_LEASE_DIRS="$L2"
"$HERE/lease.sh" acquire rigtest --owner alice --purpose "two dirs" --ttl 60 >/dev/null 2>&1 \
  && [ -f "$L1/rigtest.lease" ] && [ -f "$L2/rigtest.lease" ] && cmp -s "$L1/rigtest.lease" "$L2/rigtest.lease" \
  && ok "acquire writes the same lease to both directories" || bad "acquire did not write both copies"
rm -f "$L1/rigtest.lease"   # only the second directory still holds alice's lease
"$HERE/lease.sh" acquire rigtest --owner bob --purpose "x" >/dev/null 2>&1; rc=$?
[ "$rc" = 3 ] && ok "a live lease only in the second directory refuses another owner" || bad "second-directory lease ignored (rc=$rc)"
out="$("$HERE/lease.sh" status rigtest)"
case "$out" in "rigtest HELD owner=alice"*) ok "status reads the second directory";; *) bad "status: $out";; esac
"$HERE/lease.sh" release rigtest --owner bob >/dev/null 2>&1; rc=$?
[ "$rc" = 3 ] && [ -f "$L2/rigtest.lease" ] && ok "release by another owner is refused and keeps the copy" || bad "foreign release (rc=$rc)"
"$HERE/lease.sh" acquire rigtest --owner alice --purpose "refresh" >/dev/null 2>&1
"$HERE/lease.sh" release rigtest --owner alice >/dev/null 2>&1 && [ ! -e "$L1/rigtest.lease" ] && [ ! -e "$L2/rigtest.lease" ] \
  && ok "release removes the lease from both directories" || bad "release left a copy behind"
# a copy written by hand in the second directory by another owner blocks release of the first
printf 'HOST=rigtest\nOWNER=carol\nPURPOSE=x\nACQUIRED_EPOCH=%s\nTTL=600\n' "$(date +%s)" > "$L2/rigtest.lease"
printf 'HOST=rigtest\nOWNER=dave\nPURPOSE=y\nACQUIRED_EPOCH=%s\nTTL=600\n' "$(date +%s)" > "$L1/rigtest.lease"
out="$("$HERE/lease.sh" status rigtest)"
case "$out" in "rigtest CONFLICT"*) ok "different live owners are reported as a conflict";; *) bad "conflict not reported: $out";; esac
"$HERE/lease.sh" release rigtest --owner dave >/dev/null 2>&1; rc=$?
[ "$rc" = 3 ] && [ -f "$L1/rigtest.lease" ] && ok "release refuses while any copy has another owner, nothing removed" || bad "partial release (rc=$rc)"
rm -f "$L1/rigtest.lease" "$L2/rigtest.lease"
printf 'HOST=old\nOWNER=erin\nPURPOSE=x\nACQUIRED_EPOCH=1\nTTL=1\n' > "$L2/old.lease"
"$HERE/lease.sh" acquire live1 --owner frank --purpose "x" --ttl 60 >/dev/null 2>&1
out="$("$HERE/lease.sh" status)"
echo "$out" | grep -q '^old EXPIRED' && echo "$out" | grep -q '^live1 HELD' && ok "status lists hosts from both directories" || bad "status all: $out"
"$HERE/lease.sh" reap >/dev/null 2>&1
[ ! -e "$L2/old.lease" ] && [ -f "$L1/live1.lease" ] && [ -f "$L2/live1.lease" ] && ok "reap drops expired leases in every directory, keeps live ones" || bad "reap"
"$HERE/lease.sh" release live1 --owner frank >/dev/null 2>&1
# the config file names the additional directory when the variable is unset
unset LOCKRIG_LEASE_DIRS
mkdir -p "$LX/cfg/ncz"; printf '# extra\n%s\n%s\n' "$L2" "$L1" > "$LX/cfg/ncz/lease-dirs"
XDG_CONFIG_HOME="$LX/cfg" "$HERE/lease.sh" acquire cfgtest --owner gina --purpose "x" --ttl 60 >/dev/null 2>&1 \
  && [ -f "$L1/cfgtest.lease" ] && [ -f "$L2/cfgtest.lease" ] && ok "lease-dirs config file adds the second directory" || bad "config file not honoured"
XDG_CONFIG_HOME="$LX/cfg" "$HERE/lease.sh" release cfgtest --owner gina >/dev/null 2>&1
[ ! -e "$L2/cfgtest.lease" ] && ok "config-file release removes both copies" || bad "config-file release"
# an empty variable disables the config file
LOCKRIG_LEASE_DIRS="" XDG_CONFIG_HOME="$LX/cfg" "$HERE/lease.sh" acquire one --owner hal --purpose "x" --ttl 60 >/dev/null 2>&1
[ -f "$L1/one.lease" ] && [ ! -e "$L2/one.lease" ] && ok "LOCKRIG_LEASE_DIRS= (empty) uses only the primary" || bad "empty variable did not override the config"
rm -rf "$L1" "$L2" "$LX"; unset LOCKRIG_LEASE_DIR

echo "== report consolidation =="
RO="$(mktemp -d)"
mkdir -p "$RO/h1" "$RO/h2"
printf 'PREFLIGHT\tPASS\tok\nT1\tPASS\tlocked\nT3\tFAIL\tstatic\nTH\tSKIP\tnone\n' > "$RO/h1/cases.tsv"
printf 'PREFLIGHT\tPASS\tok\nT1\tPASS\tlocked\nT3\tPASS\tanimated\n' > "$RO/h2/cases.tsv"
echo '{"host":"h1","mode":"live","summary":{"pass":2,"fail":1,"skip":1}}' > "$RO/h1/result.json"
echo '{"host":"h2","mode":"live","summary":{"pass":3,"fail":0,"skip":0}}' > "$RO/h2/result.json"
"$HERE/report.sh" --out "$RO" --hosts h1,h2 >/dev/null 2>&1
[ -s "$RO/matrix.md" ] && have "$RO/matrix.md" "FAIL 1" && ok "matrix.md totals" || bad "matrix.md totals"
[ -s "$RO/matrix.json" ] && have "$RO/matrix.json" '"T3":"FAIL"' && ok "matrix.json per-host" || bad "matrix.json per-host"
rm -rf "$RO"

echo "== greetd login retries a busy greeter =="
GT="$(mktemp -d)"; GS="$GT/greetd.sock"
python3 "$HERE/agent/lib/fake_greetd.py" "$GS" 2 rightpw & FG=$!
for _i in 1 2 3 4 5 6 7 8 9 10; do [ -S "$GS" ] && break; sleep 0.2; done
out=$(printf 'rightpw\n' | GREETD_SOCK="$GS" python3 "$HERE/agent/lib/greetd_login.py" rigtest 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q "session started" && ok "busy greeter: login succeeds after cancel+retry" || bad "busy greeter: rc=$rc out=$out"
out=$(printf 'wrongpw\n' | GREETD_SOCK="$GS" python3 "$HERE/agent/lib/greetd_login.py" rigtest 2>&1); rc=$?
[ "$rc" = 1 ] && echo "$out" | grep -q "login failed" && ok "wrong secret still fails (no retry on auth error)" || bad "wrong secret: rc=$rc out=$out"
kill "$FG" 2>/dev/null; wait "$FG" 2>/dev/null; rm -rf "$GT"

echo "== seams reach the session =="
R="$HERE/agent/run_host.sh"
grep -A3 'renv_add "NCZ_FEED_THERMAL_ROOT' "$R" | grep -q 'session_cycle' && ok "T13 re-logs in after staging the thermal seam" || bad "T13 stages the seam without a new session"
grep -q "grep -q 'blank_after'" "$R" && ok "T14 runs only when the feed advertises blank_after" || bad "T14 not gated on the policy marker"
grep -q 'PubkeyAuthentication=no' "$HERE/lockrig" && ok "password hosts skip agent keys" || bad "password hosts may exhaust MaxAuthTries"
out=$(bash -c 'set -u; ATT=(); n=0; for x in ${ATT[@]+"${ATT[@]}"}; do n=1; done; echo ok' 2>&1)
[ "$out" = ok ] && grep -q 'for name in ${ATT\[@\]+"${ATT\[@\]}"}' "$HERE/lockrig" && ok "no attended hosts: loop is safe under set -u" || bad "attended loop unsafe under set -u ($out)"

echo "== LOCKRIG SUMMARY pass=$PASS fail=$FAIL =="
[ "$FAIL" = 0 ]
