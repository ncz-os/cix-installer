#!/bin/bash
# 83-panthor-gpu.sh — register the Panthor GPU kernel driver as a DKMS package
# (panthor-cix) and install the ncz-gpu-select kernel-driver selector.
#
# 26.7 ships MALI (mali_kbase, 82-mali-gpu.sh) as the DEFAULT and only-supported
# GPU stack. Panthor is EXPERIMENTAL / opt-in (Mesa GL + PanVK Vulkan) and is
# NOT selected by default. This hook only makes panthor *available* to switch
# to; it does not change the running GPU driver.
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
set +e

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

# --- 2. register the panthor-cix DKMS source (opt-in; built on demand) -------
if [ ! -d "$ASSET_DIR" ] || [ ! -f "$ASSET_DIR/dkms.conf" ]; then
    echo "[83] no panthor-cix DKMS source at $ASSET_DIR — skipping DKMS registration"
    echo "[83] panthor GPU stage done (selector installed; DKMS source absent)"
    exit 0
fi

if ! command -v dkms >/dev/null 2>&1; then
    echo "[83] dkms not present — staging panthor-cix source to /usr/src only"
fi

SRC=/usr/src/${PKG_NAME}-${PKG_VER}
rm -rf "$SRC"
install -d -m 0755 "$SRC"
cp -a "$ASSET_DIR"/. "$SRC"/
# drop any stray build artifacts from the asset tree; keep sources + dkms.conf
rm -f "$SRC"/*.o "$SRC"/*.ko "$SRC"/*.mod* "$SRC"/Module.symvers "$SRC"/modules.order 2>/dev/null
# the provenance patch dir is not part of the buildable module
rm -rf "$SRC"/patches 2>/dev/null
echo "[83] staged panthor-cix source -> $SRC"

KVER_NEXT=""
[ -f "$INSTALLER_META/KVER_NEXT" ] && KVER_NEXT=$(tr -d ' \t\r\n' < "$INSTALLER_META/KVER_NEXT")

if command -v dkms >/dev/null 2>&1; then
    dkms add -m "$PKG_NAME" -v "$PKG_VER" >/dev/null 2>&1 \
        && echo "[83] dkms add ${PKG_NAME}/${PKG_VER}" \
        || echo "[83] dkms add skipped (already registered?)"

    # Build now only if the NEXT (7.2) kernel headers are present; otherwise
    # DKMS autoinstall rebuilds it on the next kernel upgrade. The module is
    # NOT loaded now — mali is the default and panthor is opt-in via
    # ncz-gpu-select, which rebuilds the initramfs at switch time.
    if [ -n "$KVER_NEXT" ] && [ -f "/usr/lib/modules/$KVER_NEXT/build/Makefile" ]; then
        dkms build   -m "$PKG_NAME" -v "$PKG_VER" -k "$KVER_NEXT" >/dev/null 2>&1 \
          && dkms install -m "$PKG_NAME" -v "$PKG_VER" -k "$KVER_NEXT" --force >/dev/null 2>&1 \
          && echo "[83] dkms built+installed ${PKG_NAME} for $KVER_NEXT (-> updates/dkms/)" \
          || echo "[83] dkms build/install deferred (will autoinstall on kernel upgrade)"
    else
        echo "[83] no NEXT kernel headers — panthor-cix DKMS will autoinstall on kernel upgrade"
    fi
fi

# Always fall back to the vermagic-matched patched module when DKMS did not
# leave one in updates/dkms — INCLUDING when the dkms binary itself is absent
# from the target (mirrors 82-mali-gpu.sh, whose prebuilt overlay is likewise
# unconditional). This gate being inside the dkms-only path is exactly what
# shipped O6N installs with NO panthor module in updates/dkms: the unpatched
# in-tree panthor.ko then wins depmod, probes the still-secured GPU, and
# wedges the board in the TF-A "IDM: GPU secure access" flood
# (metal-confirmed on O6N, 2026-07-31).
PREBUILT="${SRC}/${KVER_NEXT}/panthor.ko"

# Does updates/dkms already hold a panthor module, UNDER ANY COMPRESSION?
#
# This gate used to test only the bare "panthor.ko" name. DKMS on forky
# installs the module COMPRESSED -- updates/dkms/panthor.ko.xz -- so the test
# saw "nothing there" even on a completely successful DKMS build, and the
# prebuilt fallback below overwrote nothing but happily added a SECOND,
# uncompressed copy beside it.
#
# MEASURED on O6N 2026-08-18, both files present in the same directory:
#   -rw-r--r-- 385272  /lib/modules/7.2.0-sky1-ncz/updates/dkms/panthor.ko
#   -rw-r--r--  82680  /lib/modules/7.2.0-sky1-ncz/updates/dkms/panthor.ko.xz
# which is what made `dkms status` report panthor-cix/7.2.0 as
# "Differences between built and installed modules" -- DKMS compares its own
# .ko.xz against a directory that also contains a foreign .ko it never wrote.
#
# Harmless in the shipping configuration only because BOTH GPU drivers are
# blacklisted in /etc/modprobe.d/ncz-gpu-drivers.conf and mali is the bound
# driver. It would stop being harmless the moment someone selects panthor via
# ncz-gpu-select, since which of the two depmod prefers is not something this
# script should be leaving to chance.
_have_panthor_mod() {
    local d="/usr/lib/modules/$KVER_NEXT/updates/dkms"
    [ -s "$d/panthor.ko" ] || [ -s "$d/panthor.ko.xz" ] \
        || [ -s "$d/panthor.ko.zst" ] || [ -s "$d/panthor.ko.gz" ]
}

if [ -n "$KVER_NEXT" ] && ! _have_panthor_mod && [ -s "$PREBUILT" ]; then
    install -D -m 0644 "$PREBUILT" "/usr/lib/modules/$KVER_NEXT/updates/dkms/panthor.ko"
    depmod -a "$KVER_NEXT" 2>/dev/null || true
    echo "[83] installed vermagic-matched prebuilt Panthor for $KVER_NEXT"
elif [ -n "$KVER_NEXT" ] && ! _have_panthor_mod; then
    echo "[83] WARN: no DKMS-built and no prebuilt Panthor for $KVER_NEXT — in-tree module would flood-wedge Sky1; do NOT expose the Panthor boot entry"
else
    # Clear any uncompressed leftover from a previous install that ran the
    # old gate, so DKMS and the module tree agree from here on.
    _stale="/usr/lib/modules/$KVER_NEXT/updates/dkms/panthor.ko"
    if [ -n "$KVER_NEXT" ] && [ -s "$_stale" ] \
       && [ -s "/usr/lib/modules/$KVER_NEXT/updates/dkms/panthor.ko.xz" ]; then
        rm -f "$_stale"
        depmod -a "$KVER_NEXT" 2>/dev/null || true
        echo "[83] removed stale uncompressed panthor.ko (DKMS .ko.xz is authoritative)"
    else
        echo "[83] panthor module already present in updates/dkms for $KVER_NEXT"
    fi
fi

echo "[83] panthor GPU stage done — panthor available via 'ncz-gpu-select panthor' (experimental)"
exit 0
