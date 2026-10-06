#!/bin/bash
# test-run-all-baked-allowlist.sh -- every hook on a platform hooks.list must actually run on
# a baked (--mode full) install.
#
# run-all.sh filters the optional hooks through MACHINE_HOOKS_RE when NCZ_BAKED=1 (which
# every --mode full d-i install is: /etc/ncz-baked). That regex is an allowlist, so a hook
# added to post-install/ and to hooks.list.<platform> but not to the regex is silently
# dropped: no log, no progress record, only an "ORPHAN:" line in the late log. That shipped
# 12-sky1-firmware and 44-rtc-sync dead (r262), and on 2026-10-06 61-chromium-icon.sh on
# Sky1 (orange launcher icon, measured on O6N and MS-R1).
#
# KNOWN_ORPHANS is the one tolerated exception, printed on every run:
#   44-apple-vbt-spoof.sh (amd64) is orphaned the same way (measured on CHIMERA, a
#   MacBookPro16,1: "ORPHAN: 44-apple-vbt-spoof.sh", no spoof_osx_version in refind.conf).
#   Allowlisting it alone would not help: it appends to /boot/efi/EFI/BOOT/refind.conf at
#   44, and ncz-refind-refresh-amd64.sh (run by 70-bootloader and on every kernel upgrade)
#   deletes and regenerates that file without the line. The fix belongs in the refresh
#   script; remove the entry here when that lands.
#
# This runs the REAL run-all.sh in baked mode (its /etc/ncz-baked check redirected to a
# fixture flag) against a stub for every
# hook named on each real hooks.list, then checks: no ORPHAN, and every listed hook ran and
# logged. A negative control proves the check fires on an unlisted hook.
# Run: bash build/test-run-all-baked-allowlist.sh   (RUNALL=<path> to test another run-all.sh)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNALL="${RUNALL:-$ROOT/post-install/run-all.sh}"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
pass=0
fail=0
KNOWN_ORPHANS="44-apple-vbt-spoof.sh"
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

# mkfix DIR LIST [EXTRA_HOOK]: run-all.sh + the list + a stub per listed hook.
mkfix() {
    local d="$1" list="$2" h
    mkdir -p "$d/hooks" "$d/log" "$d/shim"
    # Baked mode is keyed on /etc/ncz-baked; point the copy at a fixture flag instead.
    sed "s#\[ -f /etc/ncz-baked \]#[ -f $d/ncz-baked ]#" "$RUNALL" > "$d/hooks/run-all.sh"
    grep -qF "[ -f $d/ncz-baked ]" "$d/hooks/run-all.sh" || { echo "FAIL $RUNALL has no /etc/ncz-baked check to redirect"; exit 1; }
    : > "$d/ncz-baked"
    cp "$list" "$d/hooks/$(basename "$list")"
    for h in $(grep -vE '^[[:space:]]*(#|$)' "$list" | awk '{print $1}') ${3:-}; do
        printf '#!/bin/bash\necho "stub %s ran"\n' "$h" > "$d/hooks/$h"
        chmod +x "$d/hooks/$h"
    done
}
# runfix DIR ARCH: baked-mode run-all against the fixture; prints its console output.
runfix() {
    env NCZ_HOOK_DIR="$1/hooks" NCZ_LOGDIR="$1/log" NCZ_TTY=/dev/null NCZ_APT_SHIM_DIR="$1/shim" \
        NCZ_DISABLE_APT_SHIM=1 NCZ_TARGET_ARCH="$2" NCZ_OPT_HOOK_TIMEOUT=60 \
        timeout -k 5 300 bash "$1/hooks/run-all.sh" 2>&1
}

for plat in sky1-arm64 amd64; do
    list="$ROOT/post-install/hooks.list.$plat"
    [ -f "$list" ] || { bad "$plat: $list missing"; continue; }
    case "$plat" in sky1-arm64) arch=arm64 ;; *) arch=amd64 ;; esac
    d="$T/$plat"
    nlisted=$(grep -vE '^[[:space:]]*(#|$)' "$list" | awk 'NF{n++} END{print n+0}')
    # Guard against a vacuous pass: an unparsable list would make every check below trivially true.
    if [ "$nlisted" -ge 10 ]; then ok "$plat: $nlisted hooks listed"; else bad "$plat: only $nlisted hooks parsed from $list"; continue; fi
    mkfix "$d" "$list"
    out=$(runfix "$d" "$arch")
    orphans=""; known=""
    for o in $(printf '%s\n' "$out" | sed -n 's/.*ORPHAN: //p'); do
        case " $KNOWN_ORPHANS " in *" $o "*) known="$known $o" ;; *) orphans="$orphans$o " ;; esac
    done
    [ -n "$known" ] && echo "note $plat: known orphan(s) tolerated, see KNOWN_ORPHANS:$known"
    if [ -z "$orphans" ]; then ok "$plat: no listed hook is orphaned in baked mode"; else bad "$plat: baked mode orphans: $orphans(add to run-all.sh MACHINE_HOOKS_RE)"; fi
    notrun=""
    for h in $(grep -vE '^[[:space:]]*(#|$)' "$list" | awk '{print $1}'); do
        case " $KNOWN_ORPHANS " in *" $h "*) continue ;; esac
        grep -qx "stub $h ran" "$d/log/${h%.sh}.log" 2>/dev/null || notrun="$notrun $h"
    done
    if [ -z "$notrun" ]; then ok "$plat: every listed hook ran and logged"; else bad "$plat: listed hooks that never ran:$notrun"; fi
done

# The hook found orphaned on the live Sky1 installs, named explicitly.
[ -s "$T/sky1-arm64/log/61-chromium-icon.log" ] && ok "sky1-arm64: 61-chromium-icon.sh runs on a baked install" || bad "sky1-arm64: 61-chromium-icon.sh did not run"

# Negative control: same harness, plus a listed hook that is not on the allowlist. It must be
# reported and must not run -- proof that the fixture really is in baked mode, so the checks
# above cannot pass vacuously.
d="$T/control"
mkdir -p "$T/control-src"
cp "$ROOT/post-install/hooks.list.sky1-arm64" "$T/control-src/hooks.list.sky1-arm64"
echo "63-zz-unallowlisted.sh" >> "$T/control-src/hooks.list.sky1-arm64"
mkfix "$d" "$T/control-src/hooks.list.sky1-arm64"
out=$(runfix "$d" arm64)
if printf '%s\n' "$out" | grep -q "ORPHAN: 63-zz-unallowlisted.sh" && [ ! -e "$d/log/63-zz-unallowlisted.log" ]; then
    ok "control: an unallowlisted listed hook is reported as ORPHAN and does not run"
else
    bad "control: unallowlisted hook was not detected"
fi

echo "run-all baked allowlist tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
