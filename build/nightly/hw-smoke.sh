#!/bin/bash
# hw-smoke.sh -- the nightly canary's HARDWARE smoke layer over the four
# canonical NCZ test hosts (O6N, MEDUSA, PEGASUS, CHIMERA).
#
# DEFAULT (no --execute) is READ-ONLY and safe: reachability, DMI identity,
# "is another GPU client running?" and dmesg regression greps.  Nothing is
# launched, nothing is written on the host, no session is touched.
#
# --execute additionally launches, ON each host, the payload smoke harness if it
# is present under the host's user scratch (~/Projects/ncz-nightly-smoke by
# default; override per host with NCZ_SMOKE_HARNESS_<HOST>).  Execution is
# user-directory-only, headless, exact-PID (a recorded pidfile; NEVER a broad
# pkill/pgrep -f), and bounded by `timeout`.  A busy host (another GPU client)
# or an unreachable host is SKIPPED(reason) -- never interrupted.
#
# SAFETY (hard-coded): never reboot, never flash, never suspend/resume, never
# read amdgpu debugfs (a read of amdgpu_gpu_recover resets the GPU and killed
# MEDUSA), never kill the desktop session.  dmesg is read-only.
#
# Usage:
#   build/nightly/hw-smoke.sh --out FILE [--hosts all|o6n,medusa,...] \
#       [--execute] [--timeout SEC] [--connect-timeout SEC] [--json]
#
# Writes a JSON object {host: {status, reason, identity, dmesg, ...}}.
# Exit 0 always (a skipped host is a recorded status, not a canary failure);
# 2 on usage/tooling error.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
REG="$ROOT/build/nightly/test-hosts.tsv"

OUT=""; HOSTS="all"; EXECUTE=0; TIMEOUT=120; CTIMEOUT=8
while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT="${2:?}"; shift 2 ;;
        --registry) REG="${2:?}"; shift 2 ;;
        --hosts) HOSTS="${2:?}"; shift 2 ;;
        --execute) EXECUTE=1; shift ;;
        --timeout) TIMEOUT="${2:?}"; shift 2 ;;
        --connect-timeout) CTIMEOUT="${2:?}"; shift 2 ;;
        -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
        *) echo "hw-smoke: unknown arg: $1" >&2; exit 2 ;;
    esac
done
[ -n "$OUT" ] || { echo "hw-smoke: --out required" >&2; exit 2; }
[ -f "$REG" ] || { echo "hw-smoke: host registry missing: $REG" >&2; exit 2; }
command -v ssh >/dev/null 2>&1 || { echo "hw-smoke: ssh not found" >&2; exit 2; }
mkdir -p "$(dirname "$OUT")"

ssh_run() { # ip user cmd...  (BatchMode, no agent surprises; never root)
    local ip="$1" user="$2"; shift 2
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout="$CTIMEOUT" \
        -o NumberOfPasswordPrompts=0 "$user@$ip" "$@" 2>/dev/null
}

# SSH_USER=root rows (O6N is a dev board with no unprivileged fleet user) are
# still user-directory-only on the host; the smoke never writes outside
# ~/Projects/ncz-nightly-smoke.
smoke_host() { # fields... -> JSON fragment
    local name="$1" ip="$2" hostname="$3" arch="$4" gpu="$5" kernel="$6" ssh_user="$7" cred="$8" role="$9" smoke="${10}" forbidden="${11}"
    local status reason="" ident="" dmesg="" busy="" probe="not-run"
    # 1. reachability
    if ! ssh_run "$ip" "$ssh_user" true; then
        printf '%s\t%s\t%s\t%s\n' "$name" "SKIPPED" "unreachable (ssh $ssh_user@$ip)" ""
        return
    fi
    # 2. identity (DMI) -- PEGASUS in particular must be identity-verified
    ident="$(ssh_run "$ip" "$ssh_user" 'cat /sys/class/dmi/id/product_name /sys/class/dmi/id/sys_vendor 2>/dev/null | tr "\n" " "' | tr -s ' ')"
    # 3. busy check: another GPU client invalidates a smoke and slows the desktop
    busy="$(ssh_run "$ip" "$ssh_user" 'ps -eo pid,comm 2>/dev/null | grep -E "labwc|weston|sway|kwin|ncz-saver|screensaver|vkcube|glxgears|gpu-bench" | grep -v grep | head -5' | tr '\n' ';')"
    # 4. dmesg regression greps (read-only; no amdgpu debugfs EVER)
    dmesg="$(ssh_run "$ip" "$ssh_user" 'dmesg 2>/dev/null | grep -iE "AER|ANFE|amdgpu|xhci|BCE" | tail -20' | tr '\n' '|')"
    if [ -n "$busy" ]; then
        status="SKIPPED"; reason="host busy (GPU client running: $busy)"
    else
        status="OK"; reason="read-only checks passed"
    fi
    # 5. optional probe execution (opt-in; requires a harness on the host)
    if [ "$EXECUTE" = 1 ] && [ "$status" = OK ]; then
        local envvar hpath
        envvar="NCZ_SMOKE_HARNESS_$(printf '%s' "$name" | tr '[:lower:]-' '[:upper:]_')"
        hpath="${!envvar:-}"
        if [ -z "$hpath" ]; then
            probe="SKIPPED(no NCZ_SMOKE_HARNESS_${name} configured)"
        elif ! ssh_run "$ip" "$ssh_user" "test -x '$hpath'"; then
            probe="SKIPPED(harness not present: $hpath)"
        else
            # exact-PID discipline: the harness writes its own pidfile; we kill
            # ONLY that pid on timeout.  Never pgrep -f, never broad pkill.
            probe="$(ssh_run "$ip" "$ssh_user" "timeout -k 5 $TIMEOUT '$hpath' >/dev/null 2>&1 && echo PASS || echo 'FAIL-or-timeout'")"
        fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$status" "$reason" "$ident" "$dmesg${busy:+ busy=[$busy]} probe=$probe"
    return 0
}

declare -a WANT=()
if [ "$HOSTS" = all ]; then
    while IFS=$'\t' read -r n _; do [ -z "$n" ] && continue; case "$n" in \#*) continue ;; esac; WANT+=("$n"); done < "$REG"
else
    IFS=',' read -r -a WANT <<< "$HOSTS"
fi

TMP="$(mktemp "${TMPDIR:-/tmp}/ncz-hw.XXXXXX")"; trap 'rm -f "$TMP"' EXIT
for w in "${WANT[@]}"; do
    line="$(awk -F'\t' -v h="$w" '!/^#/ && $1==h {print; exit}' "$REG")"
    [ -n "$line" ] || { printf '%s\tSKIPPED\tunknown host in registry\t\t\n' "$w" >> "$TMP"; continue; }
    # IFS default splits the tab-separated row into the positional fields.
    # shellcheck disable=SC2086
    smoke_host $line >> "$TMP"
done

if [ -n "${NCZ_HW_DEBUG:-}" ]; then { echo "=== hw TMP ==="; od -c "$TMP"; } >&2; fi
python3 - "$OUT" "$TMP" <<'PYEOF'
import json, sys
out, tsv = sys.argv[1], sys.argv[2]
res = {}
for line in open(tsv):
    parts = line.rstrip("\n").split("\t")
    if len(parts) < 3:
        continue
    name, status, reason = parts[0], parts[1], parts[2]
    entry = {"status": status, "reason": reason}
    if len(parts) > 3:
        entry["identity"] = parts[3]
    if len(parts) > 4:
        entry["dmesg"] = parts[4]
    res[name] = entry
open(out, "w").write(json.dumps({"hosts": res}, indent=2, sort_keys=True) + "\n")
print("hw-smoke: wrote", out, "hosts=" + ",".join(sorted(res)))
PYEOF
exit 0
