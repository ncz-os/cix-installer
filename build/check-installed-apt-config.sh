#!/bin/bash
# check-installed-apt-config.sh -- audit an apt configuration tree (a mounted
# image rootfs, a chroot, or a copy of /etc/apt) for the NCZ/Debian separation
# invariants. Run it on a build rootfs before shipping and on live machines.
#
#   FAIL when:
#     1. /etc/apt/preferences.d/10-ncz-origin-separation.pref is missing, or
#        differs from the pin text the shipped lib generates
#     2. the Debian kernel-purity pin (00-ncz-kernel-purity.pref) is missing
#     3. more than ONE NCZ repo is enabled (Buildkite + R2 both active)
#     4. t2.list is present but the pin file lacks the T2 host stanza
#
# Usage: build/check-installed-apt-config.sh [ROOT]     (default ROOT=/)
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../post-install/lib/apt-separation.sh
. "$HERE/../post-install/lib/apt-separation.sh"
# shellcheck source=../post-install/lib/kernel-purity.sh
. "$HERE/../post-install/lib/kernel-purity.sh"

ROOT="${1:-/}"; ROOT="${ROOT%/}"
APT="$ROOT/etc/apt"
BAD=0
fail() { echo "FAIL: $*"; BAD=$((BAD + 1)); }
ok()   { echo "  ok: $*"; }

PIN="$APT/preferences.d/$NCZ_APT_PIN_NAME"
if [ ! -f "$PIN" ]; then
    fail "$PIN is missing (NCZ and T2 packages can shadow Debian ones)"
elif ! diff -q <(ncz_apt_separation_pin_text) "$PIN" >/dev/null 2>&1; then
    fail "$PIN differs from post-install/lib/apt-separation.sh (stale or hand-edited; run ncz-apt-policy / re-run hook 24)"
else
    ok "separation pin present and current"
fi

KP="$APT/preferences.d/00-ncz-kernel-purity.pref"
if [ ! -f "$KP" ]; then
    fail "$KP is missing"
elif ! diff -q <(ncz_kernel_purity_pin_text) "$KP" >/dev/null 2>&1; then
    fail "$KP differs from post-install/lib/kernel-purity.sh (stale or hand-edited)"
else
    ok "kernel-purity pin present and current"
fi

# Enabled NCZ repos: any non-comment 'deb' line (classic) or URIs: line (deb822)
# in an active *.list / *.sources file that names an NCZ host.
enabled=()
shopt -s nullglob
for f in "$APT"/sources.list "$APT"/sources.list.d/*.list "$APT"/sources.list.d/*.sources; do
    for h in $NCZ_APT_NCZ_HOSTS; do
        if grep -Eq "^[[:space:]]*(deb[[:space:]].*|URIs:[[:space:]]*.*)$h" "$f" 2>/dev/null; then
            enabled+=("$(basename "$f") -> $h")
        fi
    done
done
n=${#enabled[@]}
if [ "$n" -gt 1 ]; then
    fail "$n NCZ repos enabled at once (exactly one allowed; the other must be *.list.disabled): ${enabled[*]}"
elif [ "$n" -eq 1 ]; then
    ok "exactly one NCZ repo enabled (${enabled[0]})"
else
    fail "no NCZ repo enabled"
fi

if [ -f "$APT/sources.list.d/t2.list" ]; then
    if [ -f "$PIN" ] && grep -q "Pin: origin $NCZ_APT_T2_HOST" "$PIN"; then
        ok "t2.list is covered by the T2 pin"
    else
        fail "t2.list present but the pin has no 'Pin: origin $NCZ_APT_T2_HOST' stanza"
    fi
fi

echo "check-installed-apt-config($ROOT): $BAD failure(s)"
[ "$BAD" -eq 0 ]
