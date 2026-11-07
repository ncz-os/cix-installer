#!/usr/bin/env bash
# probe-sing-fleet.sh -- SING-TEST poll with retries, so a flaky login is not reported as a dead host.
#
# WHY. On 2026-11-07 cycles 471 and 472 one or two hosts returned empty output from
# the batch probe: DELL once, then PEGASUS and CIXMINI. Every one of them answered
# on the first attempt when probed alone, and every value matched the previous poll.
# Five or six password logins fired back-to-back from one source is what actually
# failed, and a silent empty line reads exactly like a host that died.
#
# Behaviour: up to 3 attempts per host, 2 s apart. A host that never answers is
# reported as UNREACHABLE and makes the exit code non-zero, so a real outage still
# stops the cycle; a transient one is retried quietly and the attempt count is shown.
#
# Two failure modes are kept DISTINCT on purpose:
#   UNREACHABLE  the host accepted no login (network or auth); retried 3 times.
#   NO-CREDS     the host has no row in the key master; retrying cannot help, so it
#                is reported once and never dialled.
# Conflating a missing credential row with an outage is how a config mistake turns
# into "the host is down".
#
# usage: probe-sing-fleet.sh [--json]
#        NCZ_SING_HOSTS="a b c"   polls only those hosts (default: the six below)
#        NCZ_SING_DEBUG=1         prints the host/user/length it will dial, to stderr
#        --selftest-row           prints one JSON row built from hostile input, exits 0
set -uo pipefail

KEYMASTER="${NCZ_KEYMASTER:-$HOME/.api_keys_master.json}"
if [ -n "${NCZ_SING_HOSTS:-}" ]; then
    read -r -a HOSTS <<< "$NCZ_SING_HOSTS"
else
    HOSTS=(dell_70_ncz pegasus_85_ncz chimera_6_ncz medusa_38_ncz cixmini_66_ncz o6n_ncz)
fi
ATTEMPTS=3
DELAY=2
JSON=0
# Anywhere on the command line: --selftest-row and --json have to work together.
for a in "$@"; do [ "$a" = "--json" ] && JSON=1; done

# row <host> <payload> <engine> <cd2h> <failed_units> <greetd> <attempts>
# One place that decides human table vs JSON, so the failure rows cannot drift.
# JSON is built by json.dumps, not printf: a quote or backslash in any field would
# otherwise produce a row that a consumer cannot parse (review caught that).
row() {
    if [ "$JSON" = 1 ]; then
        python3 -c 'import json, sys
def num(v):
    try:
        return int(str(v).strip())
    except Exception:
        return 0
print(json.dumps({
    "host": sys.argv[1], "payload": sys.argv[2], "engine": sys.argv[3],
    "cd2h": num(sys.argv[4]), "failed_units": num(sys.argv[5]),
    "greetd": sys.argv[6], "attempts": num(sys.argv[7]),
}))' "$1" "$2" "$3" "${4:-}" "${5:-}" "${6:-}" "${7:-0}"
    else
        printf '%-15s %-32s %-14s %-4s %-4s %-7s %s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7"
    fi
}

# Guards, in the only order that works: row() needs python3 in --json mode, and the
# selftest needs row(). The selftest sits between them on purpose -- a host with no
# sshpass and no fleet credentials can still prove that its JSON builder is correct.
command -v python3 >/dev/null || { echo "probe_sing: python3 is required" >&2; exit 2; }

if [ "${1:-}" = "--selftest-row" ]; then
    row 'h"ost' 'pay\load' 'eng' '3' '0' 'active' '1'
    exit 0
fi

command -v sshpass >/dev/null || { echo "probe_sing: sshpass is required" >&2; exit 2; }

[ -r "$KEYMASTER" ] || { echo "probe_sing: cannot read $KEYMASTER" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-$HOME/.cache}/ncz-sing.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/probe.sh" <<'PROBE'
echo "ver=$(dpkg-query -W -f='${Version}' ncz-singularity-desktop 2>/dev/null)"
echo "eng=$(sha256sum /opt/singularity/lib/singularity/plugins/screensaver/libscreensaver.so 2>/dev/null | cut -c1-12)"
echo "cdnew=$(coredumpctl list --since '2 hours ago' --no-pager 2>/dev/null | grep -ciE 'singularity|cairo')"
echo "failunits=$(systemctl --failed --no-legend 2>/dev/null | wc -l)"
echo "greetd=$(systemctl is-active greetd 2>/dev/null)"
# A missing tool would otherwise look exactly like a zero: name it instead.
missing=""
for t in dpkg-query sha256sum coredumpctl systemctl; do
    command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
done
echo "pre=${missing# }"
PROBE

failures=0
nocr=0

# The header is for humans; --json consumers must get JSON on every line.
[ "$JSON" = 1 ] || printf '%-15s %-32s %-14s %-4s %-4s %-7s %s\n' host payload engine cd/res failed greetd attempts

for h in "${HOSTS[@]}"; do
    creds="$(python3 - "$KEYMASTER" "$h" <<'PY' 2>"$WORK/creds.err"
import json, sys
path, name = sys.argv[1], sys.argv[2]
try:
    km = json.load(open(path))
except Exception as e:
    sys.exit("cannot parse %s: %s" % (path, e))
row = km.get("fleet_test_hosts", {}).get(name)
if row is None:
    sys.exit("no fleet_test_hosts.%s" % name)
# o6n_ncz carries no "host" key: it is the read-only board at the end of the list
host = row.get("host") or row.get("ip") or ("192.168.207.3" if name.startswith("o6n") else "")
if not host:
    sys.exit("no host for %s" % name)
if not row.get("password"):
    sys.exit("no password for %s" % name)
# ONE FIELD PER LINE. A space-separated triple split on whitespace, so a password
# containing a space silently became part of the username (review caught that).
print(host)
print(row["password"])
print(row.get("username") or "ncz")
PY
)"
    if [ $? -ne 0 ]; then
        # Retrying cannot fix a missing row, so do not dial.
        echo "probe_sing: $(head -1 "$WORK/creds.err" | sed 's/^ *//')" >&2
        row "$h" NO-CREDS - - - - 0
        failures=$((failures + 1))
        nocr=$((nocr + 1))
        continue
    fi
    ip=""; pw=""; usr=""
    { read -r ip; read -r pw; read -r usr; } <<< "$creds"
    [ "${NCZ_SING_DEBUG:-0}" = 1 ] && echo "debug: host=$ip user=$usr pw_len=${#pw}" >&2
    out=""; used=0
    for try in $(seq 1 "$ATTEMPTS"); do
        used=$try
        out="$(SSHPASS="$pw" sshpass -e ssh -o ConnectTimeout=20 -o IdentitiesOnly=yes \
                -o PreferredAuthentications=password -o PubkeyAuthentication=no \
                "$usr@$ip" 'bash -s' < "$WORK/probe.sh" 2>/dev/null)"
        [ -n "$(printf '%s' "$out" | tr -d '[:space:]')" ] && break
        [ "$try" -lt "$ATTEMPTS" ] && sleep "$DELAY"
    done
    if [ -z "$(printf '%s' "$out" | tr -d '[:space:]')" ]; then
        row "$h" UNREACHABLE - - - - "$ATTEMPTS"
        failures=$((failures + 1))
        continue
    fi
    get() { printf '%s\n' "$out" | sed -n "s/^$1=//p" | head -1; }
    pre="$(get pre)"
    # An incomplete row is worth a warning; a silent blank field looks like a zero.
    [ -n "$pre" ] && echo "probe_sing: $h is missing tools:$pre -- its fields may be blank" >&2
    row "$h" "$(get ver)" "$(get eng)" "$(get cdnew)" "$(get failunits)" "$(get greetd)" "$used"
done

[ "$failures" = 0 ] || echo "probe_sing: $failures host(s) not healthy (unreachable after $ATTEMPTS attempts, or no credentials)" >&2
# A key master with no fleet rows at all is an environment fact, not a host outage.
# Say so once, so the cycle log does not read like six hosts went down.
if [ "$nocr" -gt 0 ] && [ "$nocr" = "${#HOSTS[@]}" ]; then
    echo "probe_sing: this host's key master carries no usable fleet_test_hosts rows for these hosts" >&2
    echo "probe_sing: the poll has to run where the fleet credentials live (STUDIO)" >&2
fi
exit $(( failures > 0 ))
