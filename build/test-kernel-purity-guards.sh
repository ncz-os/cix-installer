#!/bin/bash
# test-kernel-purity-guards.sh -- regression test for the runtime/image-build
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
#  2. The raw GPT image build (build/build-installer-image.sh, which drives
#     build/iso/patch-initrd-t2-kernel.py) must boot the installer with our
#     staged amd64 kernel, not the substrate's Debian forky 7.1.x kernel.
#     This is checked structurally (the amd64 branch selects a linux-image-*.deb
#     from assets/kernel/amd64-stable and hands it to the initrd patcher, which
#     extracts boot/vmlinuz-<kver> from that .deb) because assembling a real
#     image is not a unit test.
#
# Usage: build/test-kernel-purity-guards.sh
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
ARM64="$REPO/assets/refind/ncz-refind-refresh.sh"
AMD64="$REPO/assets/refind/ncz-refind-refresh-amd64.sh"
IMGBUILD="$REPO/build/build-installer-image.sh"
INITRD_PATCHER="$REPO/build/iso/patch-initrd-t2-kernel.py"
SQUASH="$REPO/build/build-squashfs-layers.sh"
KVMGATE="$REPO/build/kvm-install-gate-gpt.sh"
VERIFIER="$REPO/build/verify-installed-target.sh"
AMMANIFEST="$REPO/assets/kernel/amd64-stable-manifest.json"
for f in "$ARM64" "$AMD64" "$IMGBUILD" "$INITRD_PATCHER" "$SQUASH" "$KVMGATE" "$VERIFIER" "$AMMANIFEST"; do
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
[ "$(run_guard "$AMD64" KVER_STABLE 7.3.0-rc7-t2-ncz)" = 0 ] && ok "accepts the NCZ 7.3.0-rc7 T2 KVER (rc default allowed)" || bad "rejected the NCZ 7.3.0-rc7 T2 KVER"
[ "$(run_guard "$AMD64" KVER_STABLE 7.1.10-1-amd64)" != 0 ] && ok "rejects Debian 7.1.10-1-amd64" || bad "accepted Debian 7.1.10-1-amd64"

echo "=== raw GPT image build: amd64 installer boots our kernel, not Debian's ==="
# The kernel/initrd step must have an explicit arm64 branch and an else
# (amd64) branch; without the amd64 branch the substrate's Debian kernel
# would boot the installer.
if grep -qE '^if \[ "\$ARCH" = arm64 \]; then' "$IMGBUILD" \
   && awk '/^if \[ "\$ARCH" = arm64 \]; then/{f=1} f&&/^else$/{print "else"; exit}' "$IMGBUILD" | grep -q else; then
    ok "build-installer-image.sh has an amd64 branch in the kernel/initrd step"
else
    bad "no amd64 kernel/initrd branch in build-installer-image.sh (the substrate Debian kernel would boot the installer)"
fi
if grep -q 'assets/kernel/amd64-stable' "$IMGBUILD" \
   && grep -qE "KERNEL_DEB=.*-name 'linux-image-\*\.deb'" "$IMGBUILD" \
   && grep -q 'INITRD_ARGS+=(--kernel-deb "\$KERNEL_DEB")' "$IMGBUILD"; then
    ok "amd64 branch passes the staged amd64-stable linux-image .deb to the initrd patcher"
else
    bad "amd64 branch does not pass the staged amd64-stable kernel .deb to the initrd patcher"
fi
if grep -q 'build/iso/patch-initrd-t2-kernel.py" "\${INITRD_ARGS\[@\]}"' "$IMGBUILD"; then
    ok "build-installer-image.sh runs patch-initrd-t2-kernel.py with those arguments"
else
    bad "build-installer-image.sh does not run patch-initrd-t2-kernel.py with INITRD_ARGS"
fi
if grep -q '"dpkg-deb", "-x", str(kernel_deb)' "$INITRD_PATCHER" \
   && grep -q 'glob(f"vmlinuz-{kver}")' "$INITRD_PATCHER"; then
    ok "initrd patcher extracts boot/vmlinuz-<kver> from the staged .deb"
else
    bad "initrd patcher does not extract vmlinuz from the staged kernel .deb"
fi
bash -n "$IMGBUILD" && ok "build-installer-image.sh parses" || bad "build-installer-image.sh has a syntax error"

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

echo "=== cyclops boot-GPU fix (2010): installer AND installed kernel are the pinned r2 build ==="
# The amd64 image must BOOT and INSTALL the same cyclops-fixed r2 kernel (patch
# 2010). KVER is identical across r1/r2 (7.3.0-rc7-t2-ncz), so KVER-keyed checks
# cannot tell them apart -- the pin is the manifest's identity.vmlinuz_sha256.
# Three places enforce it and this test asserts all three exist:
#   1. build-installer-image.sh  -- the installer kernel file is the pin
#   2. kvm-install-gate-gpt.sh   -- the ESP /linux installer kernel is the pin,
#                                   and the pin is exported to phase 2
#   3. verify-installed-target.sh-- the INSTALLED /boot/vmlinuz-<kver> is the pin
if python3 - "$AMMANIFEST" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
p = d["source"]["t2_cyclops_patch"]
assert p.endswith("2010-vga-switcheroo-keep-boot-gpu-guard-on-non-t2-apple.patch"), p
assert d["identity"]["vmlinuz_sha256"], "no vmlinuz_sha256 pin"
PY
then ok "manifest pins the 2010 cyclops patch and a vmlinuz sha256"; else bad "manifest does not pin the 2010 cyclops patch"; fi
if grep -q 'vmlinuz_sha256' "$IMGBUILD" && grep -q 't2_cyclops_patch' "$IMGBUILD" \
   && grep -q 'installer kernel' "$IMGBUILD"; then
    ok "build-installer-image.sh asserts the installer kernel == the pinned r2 vmlinuz (2010)"
else
    bad "build-installer-image.sh does not assert the installer kernel is the pinned 2010 r2 build"
fi
if grep -q '::/linux' "$KVMGATE" && grep -q 'VERIFY_EXPECT_VMLINUZ_SHA256' "$KVMGATE" \
   && grep -q '2010-vga-switcheroo-keep-boot-gpu-guard-on-non-t2-apple' "$KVMGATE"; then
    ok "kvm-install-gate-gpt.sh asserts the ESP installer kernel is the pinned 2010 r2 build"
else
    bad "kvm-install-gate-gpt.sh does not assert the ESP /linux installer kernel against the 2010 pin"
fi
if grep -q 'VERIFY_EXPECT_VMLINUZ_SHA256' "$VERIFIER" \
   && grep -q '/boot/vmlinuz-' "$VERIFIER" \
   && grep -q '_have_vmlinuz' "$VERIFIER"; then
    ok "verify-installed-target.sh asserts the installed kernel is the pinned r2 vmlinuz"
else
    bad "verify-installed-target.sh does not assert the installed kernel against the pinned r2 vmlinuz sha"
fi
bash -n "$KVMGATE" && ok "kvm-install-gate-gpt.sh parses" || bad "kvm-install-gate-gpt.sh has a syntax error"
bash -n "$VERIFIER" && ok "verify-installed-target.sh parses" || bad "verify-installed-target.sh has a syntax error"

echo
echo "=== summary: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" = 0 ]
