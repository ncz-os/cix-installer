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
TMP="$(mktemp -d)"; export LOCKRIG_LEASE_DIR="$TMP"
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
rm -rf "$TMP"; unset LOCKRIG_LEASE_DIR

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
grep -A3 'renv_add "SINGULARITY_LOCK_RENDERER_DELAY_MS' "$R" | grep -q 'session_cycle' && ok "T19 re-logs in after staging the prompt delay" || bad "T19 stages the prompt delay without a new session"
grep -q "grep -q 'freeze=prompt'" "$R" && ! grep -q "grep -q 'freeze=always'" "$R" && ok "T15 expects freeze mode prompt (no timer freeze)" || bad "T15 still expects a timer freeze"
grep -q 'rec T4 FAIL "the saver froze with no input' "$R" && grep -q 'progress_soak "$PS_S"' "$R" && ok "T4/T18 fail an idle saver that freezes without input" || bad "no frame-progress check for the unattended saver"
grep -q 'PubkeyAuthentication=no' "$HERE/lockrig" && ok "password hosts skip agent keys" || bad "password hosts may exhaust MaxAuthTries"
out=$(bash -c 'set -u; ATT=(); n=0; for x in ${ATT[@]+"${ATT[@]}"}; do n=1; done; echo ok' 2>&1)
[ "$out" = ok ] && grep -q 'for name in ${ATT\[@\]+"${ATT\[@\]}"}' "$HERE/lockrig" && ok "no attended hosts: loop is safe under set -u" || bad "attended loop unsafe under set -u ($out)"

echo "== logind lock cases =="
grep -q 'loginctl lock-session "$SID"' "$R" && ok "T16 drives loginctl lock-session on the seat0 session" || bad "T16 missing"
grep -q 'LogindLock: following /org/freedesktop/login1/session/$SID' "$R" && ok "T16 waits for the shell to follow the session" || bad "T16 does not wait for the listener"
grep -q 'rec T16b PASS' "$R" && grep -q 'pgrep -fc "/opt/singularity/bin/singularity-lockscreen"' "$R" && ok "T16b counts lock clients after a repeated lock-session" || bad "T16b missing"
grep -q 'Lock the screen before the system sleeps' "$R" && ok "T17 looks for the shell sleep delay inhibitor" || bad "T17 missing"
grep -q 'LOCKRIG_SUSPEND:-0}" = 1' "$R" && grep -q 'rtcwake -m no' "$R" && ok "real suspend (T17s) is opt-in and needs an RTC wake alarm" || bad "T17s not gated"
grep -q 'T16 T16b T17 T17s' "$HERE/report.sh" && ok "report orders the logind cases" || bad "report.sh order lacks T16..T17s"

echo "== LOCKRIG SUMMARY pass=$PASS fail=$FAIL =="
[ "$FAIL" = 0 ]
