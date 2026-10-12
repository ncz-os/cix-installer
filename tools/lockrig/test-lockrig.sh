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

echo "== hosts.tsv =="
n=$(awk -F'\t' '!/^#/ && NF>=9' "$HERE/hosts.tsv" | wc -l | tr -d ' ')
[ "$n" -ge 6 ] && ok "hosts.tsv has $n host rows" || bad "hosts.tsv only $n rows"
awk -F'\t' '!/^#/ && NF>=9 { if ($8!="0" && $8!="1") { print "bad attended: "$0; exit 1 } if ($9!="0" && $9!="1") { print "bad headless: "$0; exit 1 } }' "$HERE/hosts.tsv" \
  && ok "attended/headless flags are 0/1" || bad "attended/headless flags malformed"

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

echo "== LOCKRIG SUMMARY pass=$PASS fail=$FAIL =="
[ "$FAIL" = 0 ]
