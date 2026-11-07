#!/usr/bin/env bash
# test-probe-sing-fleet.sh -- the SING poll must fail loudly and parse correctly.
#
# probe-sing-fleet.sh is part of the cycle ritual, so both of its directions matter:
#   * a healthy fleet must produce parseable rows (and valid JSON with --json);
#   * a DEAD host must end up UNREACHABLE, after all attempts, with a non-zero
#     exit -- a silent empty line was exactly the failure mode that made cycles
#     471/472 look like dead hosts when the login was merely flaky;
#   * a host with NO key-master row must be NO-CREDS and must not be dialled --
#     a config mistake is not an outage, and retrying it three times wastes a
#     minute and writes a misleading "unreachable" into the cycle log.
#
# The failure paths are exercised against a SYNTHETIC key master, so they run on any
# host. The live half needs the real fleet credentials; a host whose key master has
# no fleet_test_hosts section (HYDRA carries fleet_credentials instead) skips it BY
# NAME rather than passing quietly.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PROBE="$HERE/probe-sing-fleet.sh"
pass=0; fail=0; skip=0
ok()   { pass=$((pass + 1)); echo "  PASS  $1"; }
bad()  { fail=$((fail + 1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }
skipn(){ skip=$((skip + 1)); echo "  SKIP  $1"; }

[ -x "$PROBE" ] || { echo "missing $PROBE"; exit 1; }
command -v sshpass >/dev/null || { echo "SKIP: no sshpass"; exit 0; }
[ -r "${NCZ_KEYMASTER:-$HOME/.api_keys_master.json}" ] || { echo "SKIP: no key master"; exit 0; }

T="$(mktemp -d "${TMPDIR:-/var/tmp}/ncz-probe.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT

json_ok() {  # json_ok <line> : valid JSON carrying the fields a consumer needs
    printf '%s' "$1" | python3 -c 'import json,sys
d=json.load(sys.stdin)
miss=[k for k in ("host","payload","engine","cd2h","failed_units","greetd","attempts") if k not in d]
sys.exit(1 if miss else 0)' 2>/dev/null
}

# --- 1. a dead host must be reported, not silently skipped -------------------------
# 127.0.0.1:9 is the discard port: nothing listens, so the login fails fast.
cat > "$T/dead.json" <<'JSON'
{"fleet_test_hosts": {"ghost": {"host": "127.0.0.1:9", "password": "x", "username": "ncz"}}}
JSON
out="$(NCZ_KEYMASTER="$T/dead.json" NCZ_SING_HOSTS=ghost timeout 180 bash "$PROBE" 2>&1)"; rc=$?
[ "$rc" != 0 ] && ok "a dead host makes the probe exit non-zero (rc=$rc)" || bad "a dead host exited 0"
grep -q '^ghost .*UNREACHABLE' <<< "$out" && ok "the dead host is printed as UNREACHABLE" || bad "no UNREACHABLE row for ghost" "$out"
grep -q 'unreachable after 3 attempts' <<< "$out" && ok "the summary says it retried 3 times" || bad "the summary does not state the retry count" "$out"
awk '/^ghost .*UNREACHABLE/ {print $NF}' <<< "$out" | grep -qx '3' && ok "the table row records 3 attempts" || bad "the table row omits the attempt count" "$out"

# --- 1b. the same failure in --json must still be JSON ------------------------------
jout="$(NCZ_KEYMASTER="$T/dead.json" NCZ_SING_HOSTS=ghost timeout 180 bash "$PROBE" --json 2>/dev/null)"
lines=$(printf '%s\n' "$jout" | grep -c .)
[ "$lines" = 1 ] && ok "--json prints exactly one line for one host (no header)" || bad "--json printed $lines lines for 1 host" "$jout"
json_ok "$(printf '%s\n' "$jout" | sed -n '1p')" && ok "the dead-host --json line parses with every field" || bad "the dead-host --json line is not valid JSON" "$jout"
printf '%s' "$jout" | grep -q '"host":"ghost".*"attempts":3' && ok "the dead-host JSON records host and 3 attempts" || bad "the dead-host JSON lost host/attempts" "$jout"

# --- 2. a host with no key-master row is NO-CREDS, not an outage -------------------
out="$(NCZ_KEYMASTER="$T/dead.json" NCZ_SING_HOSTS=stranger timeout 60 bash "$PROBE" 2>&1)"; rc=$?
[ "$rc" != 0 ] && ok "a host with no credential row still exits non-zero (rc=$rc)" || bad "NO-CREDS exited 0"
grep -q '^stranger .*NO-CREDS' <<< "$out" && ok "the host is reported NO-CREDS, not UNREACHABLE" || bad "NO-CREDS row missing" "$out"
grep -q 'no fleet_test_hosts.stranger' <<< "$out" && ok "the reason names the missing key-master row" || bad "the reason is not specific" "$out"
grep -q 'UNREACHABLE' <<< "$out" && bad "a missing credential row was reported as an outage" || ok "a config error is not reported as an outage"
# a key master with no fleet rows at all says so, instead of reading like six dead hosts
out="$(NCZ_KEYMASTER="$T/dead.json" NCZ_SING_HOSTS="ghost stranger" timeout 180 bash "$PROBE" 2>&1)"
grep -q "carries no usable fleet_test_hosts rows" <<< "$out" && bad "a mixed fleet was blamed on the key master" || ok "a partially-credentialled fleet is not blamed on the key master"

# --- 3. a healthy fleet yields parseable rows and valid JSON -----------------------
have_live="$(python3 - "${NCZ_KEYMASTER:-$HOME/.api_keys_master.json}" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1])).get("fleet_test_hosts", {})
want = ["dell_70_ncz", "pegasus_85_ncz", "chimera_6_ncz", "medusa_38_ncz", "cixmini_66_ncz", "o6n_ncz"]
print("yes" if all(w in d for w in want) else "no")
PY
)"
if [ "$have_live" != "yes" ]; then
    skipn "live fleet poll: this host's key master has no fleet_test_hosts rows for the six hosts (the poll runs from STUDIO)"
else
    jout="$(timeout 300 bash "$PROBE" --json 2>/dev/null)"; rc=$?
    if [ "$rc" = 0 ] && [ -n "$jout" ]; then
        ok "the live probe exits 0 with six hosts up"
        n=0; bad_json=0
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            n=$((n + 1))
            json_ok "$line" || bad_json=$((bad_json + 1))
        done <<< "$jout"
        [ "$n" = 6 ] && ok "--json prints one row per host (6)" || bad "--json printed $n rows, wanted 6"
        [ "$bad_json" = 0 ] && ok "every --json row parses and carries host/payload/engine/cd2h/failed_units/greetd/attempts" \
            || bad "$bad_json --json row(s) were unparseable or incomplete"
    else
        bad "the live probe did not run (rc=$rc)" "$jout"
    fi
fi

echo "test-probe-sing-fleet: $pass passed, $fail failed, $skip skipped"
[ "$fail" = 0 ]
