#!/bin/bash
# test-kernel-purity-guards.sh -- regression test for the runtime/legacy
# kernel-purity guards added by the Cygnus 26.10 directive (2026-10-04):
#
#  1. assets/refind/ncz-refind-refresh.sh (arm64) and
#     assets/refind/ncz-refind-refresh-amd64.sh must each REJECT a
#     Debian-named (7.1.x / *-arm64 / *-amd64) kernel as the default. Under the
#     unified 7.3 policy (operator 2026-10-05) an -rcN IS a permitted default
#     while KERNEL-POLICY RC_DEFAULT_ALLOWED=1, so the runtime guard no longer
#     refuses -rcN; the series enforcement is the build-time verifier's job.
#     The guard `case` block is extracted verbatim from the shipped script and
#     executed against sample KVERs, so this tests the real code, not a copy.
#  2. build/build-iso-di.sh (the legacy d-i assembly path) must boot the
#     installer with our staged 7.3 amd64 kernel, not the substrate's Debian
#     forky 7.1.x kernel. This is checked structurally (the amd64 branch exists
#     and extracts a linux-image-*.deb from assets/kernel/amd64-stable) because
#     assembling a real ISO is not a unit test.
#
# Usage: build/test-kernel-purity-guards.sh
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
ARM64="$REPO/assets/refind/ncz-refind-refresh.sh"
AMD64="$REPO/assets/refind/ncz-refind-refresh-amd64.sh"
LEGACY="$REPO/build/build-iso-di.sh"
SQUASH="$REPO/build/build-squashfs-layers.sh"
for f in "$ARM64" "$AMD64" "$LEGACY" "$SQUASH"; do
    [ -r "$f" ] || { echo "EXTRACT FAILED: cannot read $f" >&2; exit 2; }
done

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }

# Extract the first `case "$KVER_NEXT" in` / `case "$KVER_STABLE" in` block
# (a whole case...esac) from a refresh script.
extract_guard() {  # script varname
    awk -v v="$2" '
        $0 ~ ("^case \"\\$" v "\" in") { inblk=1 }
        inblk { print }
        inblk && /^esac/ { exit }
    ' "$1"
}

# run_guard <script> <var> <kver> -> echoes exit status
run_guard() {
    local script="$1" var="$2" kver="$3" snippet
    snippet="$(extract_guard "$script" "$var")"
    if [ -z "$snippet" ]; then printf '99'; return; fi
    ( export "$var=$kver"; set +e; eval "$snippet" ) >/dev/null 2>&1
    printf '%s' $?
}

echo "=== arm64 refresh script guard (ncz-refind-refresh.sh) ==="
snippet="$(extract_guard "$ARM64" KVER_NEXT)"
[ -n "$snippet" ] && ok "KVER_NEXT guard block present" || bad "no KVER_NEXT guard block found"
run_guard "$ARM64" KVER_NEXT "7.3.0-rc6-sky1-ncz" >/dev/null
[ "$(run_guard "$ARM64" KVER_NEXT 7.3.0-rc6-sky1-ncz)" = 0 ] && ok "accepts the NCZ 7.3.0-rc6 Sky1 KVER (rc default allowed)" || bad "rejected the NCZ 7.3.0-rc6 Sky1 KVER"
[ "$(run_guard "$ARM64" KVER_NEXT 7.1.4-arm64)" != 0 ] && ok "rejects Debian 7.1.4-arm64" || bad "accepted Debian 7.1.4-arm64"
[ "$(run_guard "$ARM64" KVER_NEXT 6.1.0-13-arm64)" != 0 ] && ok "rejects Debian 6.1.0-13-arm64" || bad "accepted Debian 6.1.0-13-arm64"

echo "=== amd64 refresh script guard (ncz-refind-refresh-amd64.sh) ==="
snippet="$(extract_guard "$AMD64" KVER_STABLE)"
[ -n "$snippet" ] && ok "KVER_STABLE guard block present" || bad "no KVER_STABLE guard block found"
[ "$(run_guard "$AMD64" KVER_STABLE 7.3.0-rc6-3-t2-edge-aer9011)" = 0 ] && ok "accepts the NCZ 7.3.0-rc6 T2 KVER (rc default allowed)" || bad "rejected the NCZ 7.3.0-rc6 T2 KVER"
[ "$(run_guard "$AMD64" KVER_STABLE 7.1.10-1-amd64)" != 0 ] && ok "rejects Debian 7.1.10-1-amd64" || bad "accepted Debian 7.1.10-1-amd64"

echo "=== legacy build-iso-di.sh: amd64 installer boots our kernel, not Debian's ==="
if grep -qE '^elif \[ "\$NCZ_TARGET_ARCH" = "amd64" \]; then' "$LEGACY"; then
    ok "an amd64 branch exists in the kernel swap"
else
    bad "no amd64 kernel-swap branch (the substrate Debian kernel would boot the installer)"
fi
# The old arm64-only gate must be gone: the swap must no longer be reachable
# only for arm64.
if grep -q 'stock d-i kernel/initrd already boot correctly, no Sky1 kernel swap needed' "$LEGACY"; then
    bad "stale 'amd64 needs no swap' message still present"
else
    ok "the old 'amd64 needs no Sky1 swap' justification is gone"
fi
if grep -q "assets/kernel/amd64-stable" "$LEGACY" \
   && grep -q 'dpkg-deb -x "\$_amd64_deb"' "$LEGACY" \
   && grep -q 'boot/vmlinuz-\$_amd64_kver' "$LEGACY"; then
    ok "amd64 swap extracts vmlinuz from the staged amd64-stable .deb"
else
    bad "amd64 swap does not extract the staged amd64 kernel .deb"
fi
bash -n "$LEGACY" && ok "build-iso-di.sh parses" || bad "build-iso-di.sh has a syntax error"

echo "=== base squashfs layer pins Debian kernels out before its apt install ==="
pin_line="$(grep -n 'ncz_kernel_purity_pin_text' "$SQUASH" | head -1 | cut -d: -f1)"
apt_line="$(grep -n 'apt-get install -y --no-install-recommends \$_base_pkgs' "$SQUASH" | head -1 | cut -d: -f1)"
if [ -n "$pin_line" ] && grep -q '00-ncz-kernel-purity.pref' "$SQUASH"; then
    ok "base layer stages the kernel-purity pin"
else
    bad "base layer does not stage the kernel-purity pin"
fi
if [ -n "$pin_line" ] && [ -n "$apt_line" ] && [ "$pin_line" -lt "$apt_line" ]; then
    ok "the pin is written before the base installer-base.pkgs apt install (line $pin_line < $apt_line)"
else
    bad "the pin is not written before the base apt install (pin=$pin_line apt=$apt_line)"
fi

echo
echo "=== summary: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" = 0 ]
