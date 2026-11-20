#!/usr/bin/env bash
# test-probe-sing-fleet.sh -- the SING poll must fail loudly and parse correctly.
#
# probe-sing-fleet.sh is part of the cycle ritual, so both of its directions matter:
#   * a healthy fleet must produce parseable rows (and valid JSON with --json);
#   * a DEAD host must end up UNREACHABLE, after all attempts, with a non-zero
#     exit -- a silent empty line was exactly the failure mode that made cycles
#     471/472 look like dead hosts when the login was merely flaky;
#   * a host with NO inventory row must be NO-CREDS and must not be dialled --
#     a config mistake is not an outage, and retrying it three times wastes a
#     minute and writes a misleading "unreachable" into the cycle log.
#
# The test uses a sample inventory and a local stand-in for the login command.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PROBE="$HERE/probe-sing-fleet.sh"
pass=0; fail=0; skip=0
ok()   { pass=$((pass + 1)); echo "  PASS  $1"; }
bad()  { fail=$((fail + 1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }
skipn(){ skip=$((skip + 1)); echo "  SKIP  $1"; }

[ -x "$PROBE" ] || { echo "missing $PROBE"; exit 1; }

T="$(mktemp -d "${TMPDIR:-$PWD}/ncz-probe.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT
printf '#!/bin/sh\nexit 1\n' > "$T/mock-password-command"
chmod +x "$T/mock-password-command"
export NCZ_SING_PASSWORD_COMMAND="$T/mock-password-command"

json_ok() {  # json_ok <line> : valid JSON carrying the fields a consumer needs
    printf '%s' "$1" | python3 -c 'import json,sys
d=json.load(sys.stdin)
miss=[k for k in ("host","payload","engine","cd2h","failed_units","greetd","attempts") if k not in d]
sys.exit(1 if miss else 0)' 2>/dev/null
}

# --- 1. a dead host must be reported, not silently skipped -------------------------
# The stand-in returns no output for this test machine.
cat > "$T/dead.json" <<'JSON'
{"hosts": {"ghost": {"host": "offline.example", "password": "x", "username": "ncz"}}}
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
# parse, do not grep: json.dumps separates with ", " and a grep on the separator
# is exactly the kind of assertion that breaks when the producer changes format.
printf '%s' "$jout" | python3 -c 'import json,sys
d=json.load(sys.stdin); sys.exit(0 if d["host"]=="ghost" and d["attempts"]==3 and d["payload"]=="UNREACHABLE" else 1)' 2>/dev/null \
    && ok "the dead-host JSON records host, UNREACHABLE and 3 attempts" || bad "the dead-host JSON lost host/attempts" "$jout"

# --- 2. a host with no inventory row is NO-CREDS, not an outage -------------------
out="$(NCZ_KEYMASTER="$T/dead.json" NCZ_SING_HOSTS=stranger timeout 60 bash "$PROBE" 2>&1)"; rc=$?
[ "$rc" != 0 ] && ok "a host with no credential row still exits non-zero (rc=$rc)" || bad "NO-CREDS exited 0"
grep -q '^stranger .*NO-CREDS' <<< "$out" && ok "the host is reported NO-CREDS, not UNREACHABLE" || bad "NO-CREDS row missing" "$out"
grep -q 'no hosts.stranger' <<< "$out" && ok "the reason names the missing inventory row" || bad "the reason is not specific" "$out"
grep -q 'UNREACHABLE' <<< "$out" && bad "a missing credential row was reported as an outage" || ok "a config error is not reported as an outage"
# a configured inventory with no fleet rows at all says so, instead of reading like six dead hosts
out="$(NCZ_KEYMASTER="$T/dead.json" NCZ_SING_HOSTS="ghost stranger" timeout 180 bash "$PROBE" 2>&1)"
grep -q "carries no usable hosts rows" <<< "$out" && bad "a mixed fleet was blamed on the configured inventory" || ok "a partially-credentialled fleet is not blamed on the configured inventory"

# --- 2b. the credential triple must survive whitespace inside a field --------------
# A space-separated triple split on whitespace, so a password containing a space
# silently became part of the username and the login failed for the wrong reason.
cat > "$T/spaced.json" <<'JSON'
{"hosts": {"spaced": {"host": "offline.example", "password": "a b c", "username": "ncz"}}}
JSON
out="$(NCZ_SING_DEBUG=1 NCZ_KEYMASTER="$T/spaced.json" NCZ_SING_HOSTS=spaced timeout 180 bash "$PROBE" 2>&1)"
grep -q 'debug: host=offline.example user=ncz pw_len=5' <<< "$out" \
    && ok "a password with spaces stays one field (pw_len=5, user intact)" \
    || bad "the credential triple was split on whitespace" "$out"

# --- 2c. a JSON row must survive a quote and a backslash ---------------------------
sel="$(bash "$PROBE" --selftest-row --json 2>/dev/null)"
json_ok "$sel" && ok "the sample row parses as JSON" || bad "the sample row is not valid JSON" "$sel"
printf '%s' "$sel" | python3 -c 'import json,sys
d=json.load(sys.stdin); sys.exit(0 if d["host"]=="h\"ost" and d["payload"]=="pay\\load" else 1)' 2>/dev/null \
    && ok "the sample row round-trips exactly" || bad "the sample row did not round-trip" "$sel"

# --- 2d. a missing tool is named, not rendered as a zero ---------------------------
awk "/<<'PROBE'\$/{f=1;next} /^PROBE\$/{f=0} f" "$PROBE" > "$T/remote.sh"
[ -s "$T/remote.sh" ] && ok "the remote probe body is extractable for testing" || bad "could not extract the remote probe body"
mkdir -p "$T/emptybin"
rout="$("$BASH" "$T/remote.sh" 2>/dev/null < /dev/null || true)"
PATH="$T/emptybin" "$BASH" "$T/remote.sh" > "$T/rout.txt" 2>/dev/null
pre_line="$(grep '^pre=' "$T/rout.txt" | head -1)"
[ -n "${pre_line#pre=}" ] && ok "a host missing every tool reports them (${pre_line})" || bad "missing tools are not reported" "$(cat "$T/rout.txt")"
grep -q 'missing tools' "$PROBE" && ok "the poll warns when a host lacks a tool" || bad "no warning for a host that lacks a tool"

# --- 4. no fleet address may be embedded in the script itself ----------------------
# The credential block resolves every host from the fleet inventory (configured inventory rows
# with "host" or "ip"). A hard-coded fleet address inside the script both leaks the
# network layout and silently overrides the inventory. The o6n_ncz fallback is a
# classic case: if the row is missing, report it -- do not dial an embedded address.
grep -qE '192[.]168[.]207[.]' "$PROBE" \
    && bad "the probe script embeds a fleet address" "$(grep -nE '192[.]168[.]207[.]' "$PROBE")" \
    || ok "no fleet address is embedded in the probe script"

echo "test-probe-sing-fleet: $pass passed, $fail failed, $skip skipped"
[ "$fail" = 0 ]
