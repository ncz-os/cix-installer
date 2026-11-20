#!/bin/bash
# 83-panthor-gpu.sh — install the ncz-gpu-switcher GPU-driver selector
# (Mali loader) and purge any Panthor DKMS registration.
#
# PANThOR IS NOT SHIPPED (order 01:35Z 2026-11-15, "NO PANTHOR ANYWHERE"):
# one GPU driver, the vendor Mali stack, on desktop and server. This hook
# used to also register the panthor-cix DKMS package; that section is gone.
# What remains is the stack switcher (one source of truth for driver loading:
# loads the mali trio explicitly, holds both drivers in modprobe.d against
# udev-autoload races) plus the belt-and-braces purge of any stale panthor-cix
# registration. Revisit Panthor after Linux 7.4 ships.
#
# Symmetric with mali-kbase (82-mali-gpu.sh): panthor is packaged as DKMS
# (assets/kernel/panthor) so it is decoupled from the weekly
# kernel rebase and rebuilds automatically on a kernel upgrade. It carries our
# CIX Sky1 patches (ACPI bind, gpu_clk_core con_id, and the ACPI power-supply
# _PR0 un-secure fix — patches/0175) baked into the source.
#
# Selection is via the sky1.gpu= kernel cmdline token, applied at boot by
# ncz-gpu-switcher.service. rEFInd emits one entry per stack, differing only by
# that token. The switcher blacklists BOTH drivers in modprobe.d and loads the
# selected one explicitly, so the kernel driver and its matching GL/Vulkan
# userspace can never end up half-switched.
#
# RUNS INSIDE CHROOT via run-all.sh, after 82-mali-gpu.sh.
# NCZ-PLATFORM-GUARD: sky1-arm64 only (docs/PLATFORM-SPLIT-DESIGN.md). Arch order matches
# run-all.sh: NCZ_TARGET_ARCH, then the late.sh BUILD_ARCH stamp, then dpkg. An
# undetectable arch does NOT skip (legacy behavior).
_ncz_pg_arch="${NCZ_TARGET_ARCH:-}"
[ -n "$_ncz_pg_arch" ] || _ncz_pg_arch=$(cat /usr/local/lib/cix-installer/BUILD_ARCH 2>/dev/null | tr -d '[:space:]')
[ -n "$_ncz_pg_arch" ] || _ncz_pg_arch=$(dpkg --print-architecture 2>/dev/null || true)
case "$_ncz_pg_arch" in
    arm64|aarch64|"") ;;
    *) echo "[${0##*/}] platform guard: arch=$_ncz_pg_arch is not sky1-arm64; skipping"; exit 0 ;;
esac
unset _ncz_pg_arch
set +e

# CIX Sky1/Mali-G720 hardware is arm64-only. Without this guard, run-all.sh
# runs this hook unconditionally on every image (including amd64 T2 builds),
# `dkms add`-registering panthor-cix there too -- confirmed 2026-09-22 on
# real T2 Mac and GU502LV laptop hardware: panthor-cix has no Yocto-staged .deb
# alternative (unlike cix-gpu-kmd/mali, which ships prebuilt and only falls
# back to dkms-add when a .deb is missing), so this dkms-add ALWAYS runs, and
# the amd64 T2 linux-headers-cixmini postinst's "force rebuild every
# registered DKMS package" step then tries to compile Sky1 Mali GLES/Vulkan
# GPU source against an x86_64 kernel -- a real, guaranteed compile failure
# (panthor_gem.c: implicit declaration, wrong arch entirely) that aborted the
# whole kernel package install on both real T2 boxes. Match the existing
# arch-guard convention from 54-gpu-accel.sh / 55-t2-firmware.sh.
if [ "$(dpkg --print-architecture 2>/dev/null)" != "arm64" ]; then
    echo "[83] not arm64 (Sky1/Mali-G720 hardware only) -- skipping panthor-cix entirely"
    exit 0
fi

INSTALLER_META=/usr/local/lib/cix-installer
ASSET_DIR="$INSTALLER_META/assets/kernel/panthor"      # panthor-cix-dkms source
GPU_ASSET_DIR="$INSTALLER_META/assets/gpu"             # ncz-gpu-select + conf
PKG_NAME=panthor-cix
PKG_VER=7.2.0

# --- 1. install the GPU stack switcher (kernel driver + userspace, one unit) --
#
# Design taken from amazingfate's Sky1-Linux sky1-gpu-switcher. It replaces the
# ncz-gpu-select / ncz-gpu-profile pair, which wrote two DIFFERENT modprobe.d
# files and knew nothing about the kernel cmdline. On O6N 2026-08-15 that
# produced a machine whose cmdline blacklisted panthor while modprobe.d
# blacklisted the kbase trio: no GPU driver loaded at all and the desktop ran on
# llvmpipe. One source of truth (sky1.gpu=) removes that failure mode.
install -d -m 0755 /usr/lib/ncz /usr/local/bin /etc/modprobe.d /etc/default

if [ -f "$GPU_ASSET_DIR/ncz-gpu-switcher.sh" ]; then
    install -m 0755 "$GPU_ASSET_DIR/ncz-gpu-switcher.sh" /usr/lib/ncz/gpu-switcher.sh
    install -m 0644 "$GPU_ASSET_DIR/ncz-gpu-switcher.service" /etc/systemd/system/ncz-gpu-switcher.service
    install -m 0755 "$GPU_ASSET_DIR/ncz-gpu-status"      /usr/bin/ncz-gpu-status
    install -m 0755 "$GPU_ASSET_DIR/ncz-gpu-compat-run"  /usr/bin/ncz-gpu-compat-run
    install -m 0755 "$GPU_ASSET_DIR/ncz-gpu-select"      /usr/local/bin/ncz-gpu-select
    ln -sf ncz-gpu-select /usr/local/bin/ncz-gpu-profile
    echo "[83] installed ncz-gpu-switcher (+ status, compat-run, select shim)"

    # Enable by hand rather than via systemctl: this runs in a chroot with no
    # running systemd, where `systemctl enable` can fail on the D-Bus probe.
    install -d -m 0755 /etc/systemd/system/sysinit.target.wants
    ln -sf ../ncz-gpu-switcher.service \
        /etc/systemd/system/sysinit.target.wants/ncz-gpu-switcher.service
    echo "[83] enabled ncz-gpu-switcher.service (sysinit.target.wants)"
else
    echo "[83] WARN: switcher assets missing ($GPU_ASSET_DIR) — GPU selection NOT installed"
fi

# Lay the blacklist down at build time as well as at boot. The initramfs is
# built later in the pipeline and copies modprobe.d into itself; without this
# the first boot could autoload a driver before the switcher ever runs.
cat > /etc/modprobe.d/ncz-gpu-drivers.conf <<'MPCONF'
# Written by 83-panthor-gpu.sh; maintained at boot by ncz-gpu-switcher.
# Both GPU drivers are blacklisted on purpose -- mali_kbase and panthor both
# claim ACPI CIXH5000, so udev autoload would decide the GPU stack by race.
# ncz-gpu-switcher.service loads the selected one explicitly (blacklist stops
# modalias autoload but not an explicit modprobe).
blacklist panthor
blacklist mali_kbase
blacklist memory_group_manager
blacklist protected_memory_allocator
MPCONF
echo "[83] wrote /etc/modprobe.d/ncz-gpu-drivers.conf (both drivers held for the switcher)"

# Fallback selection for a cmdline with no sky1.gpu= token. 26.7 ships mali.
cat > /etc/default/ncz-gpu <<'DEFCONF'
# NCZ-OS GPU stack preference. Consulted by ncz-gpu-switcher ONLY when the
# kernel cmdline carries no sky1.gpu= / ncz.gpu= token -- the cmdline wins.
GPU_MODE=mali
DEFCONF

# Retire the superseded selectors. modprobe.d is additive with no un-blacklist,
# so a stale file left behind here silently overrides the switcher.
rm -f /etc/modprobe.d/ncz-gpu.conf /etc/modprobe.d/ncz-gpu-profile.conf

# NOTE: /usr/local/bin/ncz-gpu-env is deliberately NOT removed. 20-desktop.sh
# creates it and every session launcher sources it; without it the launchers
# fall into an else branch that pins LD_LIBRARY_PATH at /opt/cixgpu-* for ALL
# modes, forcing the blob even on a panthor boot.

# The mali_kbase autoloader from 82-mali-gpu.sh is superseded by the switcher
# and actively harmful now. Its ExecCondition only skips when the cmdline has
# module_blacklist=<kbase trio>, which the sky1.gpu= entries no longer carry --
# so on a panthor boot it would modprobe mali_kbase over the top of panthor.
# It also loads mali_kbase ALONE, without memory_group_manager and
# protected_memory_allocator, which is what makes kbase probe return -517.
rm -f /etc/systemd/system/ncz-mali-kbase-load.service \
      /etc/systemd/system/multi-user.target.wants/ncz-mali-kbase-load.service
# ncz-mali-kbase-allowed was that unit's ExecCondition. Nothing references it
# now, so it would sit on disk looking like live policy.
rm -f /usr/local/sbin/ncz-mali-kbase-allowed
echo "[83] removed ncz-mali-kbase-load.service (ncz-gpu-switcher owns driver loading)"

# Panthor is NOT shipped (operator 2026-11-14): one GPU driver, the vendor Mali stack, on desktop and server.
# panthor-cix is no longer registered with DKMS, no prebuilt overlay is installed, and the rEFInd generator emits
# no Panthor entry. The switcher above stays as the Mali loader. Revisit after Linux 7.4 ships.
rm -rf "/usr/src/${PKG_NAME}-${PKG_VER}" 2>/dev/null
dkms remove -m "$PKG_NAME" -v "$PKG_VER" --all >/dev/null 2>&1 || true
echo "[83] panthor-cix not shipped (Mali only); switcher installed"
exit 0
