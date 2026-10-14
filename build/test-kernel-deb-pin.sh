#!/bin/bash
# test-kernel-deb-pin.sh -- prove the Sky1 kernel-package pin fires on the
# 2026-09-28 incident shape and stays quiet on a correct set.
#
# Builds throwaway linux-image-cixmini / linux-headers-cixmini / cixmini-boot
# .debs (control file only) and drives:
#   * build/check-kernel-deb-pin.sh directly (positive and negative cases);
#   * the real build/build-vendor-mirror.sh end to end with a newer rc in
#     KERNEL_DEBS while the pin says 7.2.8 -- it must FAIL before publishing
#     anything (the pin runs before the network-bound Chrome step, so this
#     negative case needs no network);
#   * the Makefile kernel-debs freshness parser, which must reduce a
#     <KVER>+r<N> filename to <KVER>.
#
# Run: bash build/test-kernel-deb-pin.sh     Exit 0 = all cases pass.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
PIN="$HERE/check-kernel-deb-pin.sh"
command -v dpkg-deb >/dev/null 2>&1 || { echo "SKIP: dpkg-deb not available" >&2; exit 2; }

W="$(mktemp -d -t kernel-deb-pin.XXXXXX)"
trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0

mkdeb() {   # dir pkg version
    local d="$1" pkg="$2" ver="$3" root
    root="$W/pkg-$pkg-$ver"
    mkdir -p "$root/DEBIAN" "$d"
    printf 'Package: %s\nVersion: %s\nArchitecture: arm64\nMaintainer: test <t@t>\nDescription: pin fixture\n' \
        "$pkg" "$ver" > "$root/DEBIAN/control"
    dpkg-deb --build --root-owner-group "$root" "$d/${pkg}_${ver}_arm64.deb" >/dev/null
}
good_set() {  # dir
    mkdeb "$1" linux-image-cixmini   7.2.8-sky1-ncz+r277
    mkdeb "$1" linux-headers-cixmini 7.2.8-sky1-ncz+r277
    mkdeb "$1" cixmini-boot          1.2+r277
}
rc5_set() {   # dir
    mkdeb "$1" linux-image-cixmini   7.3.0-rc5-sky1-ncz+r278
    mkdeb "$1" linux-headers-cixmini 7.3.0-rc5-sky1-ncz+r278
    mkdeb "$1" cixmini-boot          1.2+r278
}
printf '7.2.8-sky1-ncz' > "$W/KVER"      # the mainline pointer's KVER (no newline, like the real file)

check() {   # label want_rc cmd...
    local label="$1" want="$2" out rc
    shift 2
    out="$("$@" 2>&1)"; rc=$?
    printf '%s\n' "$out" | sed 's/^/    /'
    if [ "$rc" = "$want" ]; then
        echo "  PASS  $label (rc=$rc)"; PASS=$((PASS + 1))
    else
        echo "  FAIL  $label (rc=$rc, want $want)"; FAIL=$((FAIL + 1))
    fi
}

echo "=== 1 POSITIVE: 7.2.8+r277 set, pin 7.2.8 ==="
good_set "$W/c1"
check "pinned set passes" 0 bash "$PIN" "$W/KVER" "$W/c1"

echo "=== 2 NEGATIVE (the incident): 7.2.8 set plus a newer rc5 set, pin 7.2.8 ==="
good_set "$W/c2"; rc5_set "$W/c2"
check "newer rc beside the shipping kernel fails" 1 bash "$PIN" "$W/KVER" "$W/c2"

echo "=== 3 NEGATIVE: only the rc5 set, pin 7.2.8 ==="
rc5_set "$W/c3"
check "rc5-only set fails" 1 bash "$PIN" "$W/KVER" "$W/c3"

echo "=== 4 NEGATIVE: Sky1 kernel debs but no KVER pin file ==="
good_set "$W/c4"
check "unpinnable set fails" 1 bash "$PIN" "$W/no-such-KVER" "$W/c4"

echo "=== 5 POSITIVE: no Sky1 kernel packages (amd64-style dir), no pin file ==="
mkdeb "$W/c5" google-chrome-stable 154.0-1
check "dir without Sky1 kernels passes" 0 bash "$PIN" "$W/no-such-KVER" "$W/c5"

echo "=== 6 NEGATIVE: cixmini-boot from a different build than the image ==="
mkdeb "$W/c6" linux-image-cixmini   7.2.8-sky1-ncz+r277
mkdeb "$W/c6" linux-headers-cixmini 7.2.8-sky1-ncz+r277
mkdeb "$W/c6" cixmini-boot          1.2+r276
check "mixed-build boot package fails" 1 bash "$PIN" "$W/KVER" "$W/c6"

echo "=== 6b NEGATIVE: right KVER, revision older than the staged pointer dir ==="
mkdir -p "$W/pool/r277-7.2.8-sky1-ncz-20260927"
printf '7.2.8-sky1-ncz' > "$W/pool/r277-7.2.8-sky1-ncz-20260927/KVER"
ln -s "$W/pool/r277-7.2.8-sky1-ncz-20260927" "$W/mainline"
mkdeb "$W/c6b" linux-image-cixmini   7.2.8-sky1-ncz+r258
mkdeb "$W/c6b" linux-headers-cixmini 7.2.8-sky1-ncz+r258
mkdeb "$W/c6b" cixmini-boot          1.2+r258
check "r258 build of the r277 kernel fails" 1 bash "$PIN" "$W/mainline/KVER" "$W/c6b"
check "r277 build through the same pointer passes" 0 bash "$PIN" "$W/mainline/KVER" "$W/c1"

echo "=== 7 NEGATIVE end to end: build-vendor-mirror.sh with rc5 in KERNEL_DEBS, pin 7.2.8 ==="
good_set "$W/c7-debs"; rc5_set "$W/c7-debs"
mkdir -p "$W/c7-mirror"
check "vendor mirror refuses to ingest the newer rc" 1 env \
    KERNEL_DEBS="$W/c7-debs" VENDOR_MIRROR="$W/c7-mirror" SKY1_KVER_FILE="$W/KVER" \
    ARCH=arm64 USB_RECOVERY_DEBS="$W/none" SINTY_DEBS="$W/none" CHROME_DEB_CACHE="$W/chrome" \
    bash "$REPO/build/build-vendor-mirror.sh"
if find "$W/c7-mirror" -name '*.deb' | grep >/dev/null .; then
    echo "  FAIL  vendor mirror pool is not empty after the refused run"; FAIL=$((FAIL + 1))
else
    echo "  PASS  nothing was published by the refused run"; PASS=$((PASS + 1))
fi

echo "=== 9 in-tree VPU driver (CONFIG_VIDEO_LINLON) inside linux-image-cixmini ==="
mkdeb_amvx() {   # dir version: image deb carrying kernel/drivers/media/platform/cix/amvx.ko
    local d="$1" ver="$2" root kv
    kv="${ver%%+*}"
    root="$W/pkg-amvx-$ver"
    mkdir -p "$root/DEBIAN" "$root/usr/lib/modules/$kv/kernel/drivers/media/platform/cix" "$d"
    printf 'Package: linux-image-cixmini\nVersion: %s\nArchitecture: arm64\nMaintainer: test <t@t>\nDescription: pin fixture\n' \
        "$ver" > "$root/DEBIAN/control"
    printf 'ko' > "$root/usr/lib/modules/$kv/kernel/drivers/media/platform/cix/amvx.ko"
    dpkg-deb --build --root-owner-group "$root" "$d/linux-image-cixmini_${ver}_arm64.deb" >/dev/null
}
printf '7.3.0-rc7-sky1-ncz' > "$W/KVER73"
printf '# fixture\nINTREE_ACCEL_GRANDFATHERED_SKY1=r289\n' > "$W/POLICY"
mkdeb_amvx "$W/c9a" 7.3.0-rc7-sky1-ncz+r290
mkdeb "$W/c9a" linux-headers-cixmini 7.3.0-rc7-sky1-ncz+r290
mkdeb "$W/c9a" cixmini-boot          1.3+r290
check "r290 image with in-tree amvx.ko fails" 1 env KERNEL_POLICY_FILE="$W/POLICY" \
    bash "$PIN" "$W/KVER73" "$W/c9a"
mkdeb_amvx "$W/c9b" 7.3.0-rc7-sky1-ncz+r289
mkdeb "$W/c9b" linux-headers-cixmini 7.3.0-rc7-sky1-ncz+r289
mkdeb "$W/c9b" cixmini-boot          1.3+r289
check "grandfathered r289 image with in-tree amvx.ko passes (warns)" 0 env KERNEL_POLICY_FILE="$W/POLICY" \
    bash "$PIN" "$W/KVER73" "$W/c9b"
printf '# fixture\n' > "$W/POLICY-empty"
check "r289 image with in-tree amvx.ko fails once not grandfathered" 1 env KERNEL_POLICY_FILE="$W/POLICY-empty" \
    bash "$PIN" "$W/KVER73" "$W/c9b"
mkdeb "$W/c9c" linux-image-cixmini   7.3.0-rc7-sky1-ncz+r290
mkdeb "$W/c9c" linux-headers-cixmini 7.3.0-rc7-sky1-ncz+r290
mkdeb "$W/c9c" cixmini-boot          1.3+r290
check "r290 image without in-tree amvx.ko passes" 0 env KERNEL_POLICY_FILE="$W/POLICY" \
    bash "$PIN" "$W/KVER73" "$W/c9c"
if grep -qx 'INTREE_ACCEL_GRANDFATHERED_SKY1=r289' "$REPO/assets/kernel/KERNEL-POLICY"; then
    echo "  PASS  KERNEL-POLICY grandfathers exactly r289"; PASS=$((PASS + 1))
else
    echo "  FAIL  KERNEL-POLICY INTREE_ACCEL_GRANDFATHERED_SKY1 is not exactly r289"; FAIL=$((FAIL + 1))
fi

echo "=== 8 Makefile kernel-debs freshness parser strips +r<N> ==="
sed_expr="$(grep -o "sed -nE 's/\.\*linux-image-cixmini_[^']*'" "$REPO/Makefile" | head -1 | sed "s/^sed -nE '//; s/'\$//")"
got="$(printf '%s\n' "$W/x/linux-image-cixmini_7.2.8-sky1-ncz+r277_arm64.deb" | sed -nE "$sed_expr")"
if [ -n "$sed_expr" ] && [ "$got" = "7.2.8-sky1-ncz" ]; then
    echo "  PASS  freshness parser yields KVER '$got'"; PASS=$((PASS + 1))
else
    echo "  FAIL  freshness parser yields '$got' (expr '$sed_expr')"; FAIL=$((FAIL + 1))
fi

echo
echo "=== kernel deb pin test: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
