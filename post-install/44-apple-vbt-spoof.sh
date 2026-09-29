#!/bin/bash
# Apple Macs only: make rEFInd claim to be macOS so the firmware hands over the
# Video BIOS Table.
#
# WHY. Apple firmware withholds the VBT from a non-macOS boot. Without it i915
# reports, measured on MEDUSA (MacBookPro16,1) 2026-09-28:
#     i915: Failed to find VBIOS tables (VBT)
#     i915: failed to retrieve link info, disabling eDP
#     i915: Cannot find any crtc or sizes
# so the integrated GPU has no usable output and the discrete GPU is left
# driving the internal panel. It then cannot runtime-suspend and burns ~14W
# continuously (61C package, vs 41C on a comparable machine whose panel is on
# the iGPU).
#
# rEFInd implements this natively via spoof_osx_version, so no external
# apple_set_os.efi chainloader is needed. Verified present in our own binary:
#     strings BOOTX64.EFI | grep -x spoof_osx_version
#
# PER-MACHINE BY DESIGN. Gated on DMI sys_vendor being Apple. On non-Apple
# hardware this is meaningless at best, so the hook is a no-op there rather
# than shipping a global setting.
# NCZ-PLATFORM-GUARD: amd64 only (docs/PLATFORM-SPLIT-DESIGN.md). Arch order matches
# run-all.sh: NCZ_TARGET_ARCH, then the late.sh BUILD_ARCH stamp, then dpkg. An
# undetectable arch does NOT skip (legacy behavior).
_ncz_pg_arch="${NCZ_TARGET_ARCH:-}"
[ -n "$_ncz_pg_arch" ] || _ncz_pg_arch=$(cat /usr/local/lib/cix-installer/BUILD_ARCH 2>/dev/null | tr -d '[:space:]')
[ -n "$_ncz_pg_arch" ] || _ncz_pg_arch=$(dpkg --print-architecture 2>/dev/null || true)
case "$_ncz_pg_arch" in
    amd64|x86_64|"") ;;
    *) echo "[${0##*/}] platform guard: arch=$_ncz_pg_arch is not amd64; skipping"; exit 0 ;;
esac
unset _ncz_pg_arch
set -u
VENDOR="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)"
PRODUCT="$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)"
case "$VENDOR" in
    Apple*) ;;
    *) echo "[44] not Apple hardware (sys_vendor='${VENDOR:-unknown}'); skipping VBT spoof"; exit 0 ;;
esac
CONF=/boot/efi/EFI/BOOT/refind.conf
[ -f "$CONF" ] || { echo "[44] no $CONF; skipping"; exit 0; }
if grep -q '^spoof_osx_version' "$CONF"; then
    echo "[44] spoof_osx_version already present; leaving it alone"
    exit 0
fi
if ! grep -qx 'spoof_osx_version' <(strings -a /boot/efi/EFI/BOOT/BOOTX64.EFI 2>/dev/null); then
    echo "[44] WARNING: this rEFInd build does not implement spoof_osx_version; not adding it"
    exit 0
fi
printf '\n# Added by 44-apple-vbt-spoof.sh on %s (%s).\n# Apple firmware withholds the VBT from non-macOS boots, which disables eDP on\n# the iGPU and leaves the dGPU driving the panel at a large idle power cost.\nspoof_osx_version 10.9\n' \
    "$PRODUCT" "$(date -u +%Y-%m-%d)" >> "$CONF"
echo "[44] spoof_osx_version enabled for $PRODUCT"
