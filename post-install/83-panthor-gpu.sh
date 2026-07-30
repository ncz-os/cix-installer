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
# Selection is via /etc/modprobe.d/ncz-gpu.conf (default: mali) toggled by
# /usr/local/bin/ncz-gpu-select — there is NO dual rEFInd GPU boot menu.
#
# RUNS INSIDE CHROOT via run-all.sh, after 82-mali-gpu.sh.
set +e

INSTALLER_META=/usr/local/lib/cix-installer
ASSET_DIR="$INSTALLER_META/assets/kernel/panthor"      # panthor-cix-dkms source
GPU_ASSET_DIR="$INSTALLER_META/assets/gpu"             # ncz-gpu-select + conf
PKG_NAME=panthor-cix
PKG_VER=7.2.0

# --- 1. install the kernel-driver selector + default (mali) modprobe conf ----
install -d -m 0755 /usr/local/bin
if [ -f "$GPU_ASSET_DIR/ncz-gpu-select" ]; then
    install -m 0755 "$GPU_ASSET_DIR/ncz-gpu-select" /usr/local/bin/ncz-gpu-select
    echo "[83] installed /usr/local/bin/ncz-gpu-select"
else
    echo "[83] WARN: ncz-gpu-select asset missing ($GPU_ASSET_DIR) — selector not installed"
fi

install -d -m 0755 /etc/modprobe.d
# Lay down the DEFAULT (mali) selection. --no-initramfs/--no-reboot-prompt: we
# are in a chroot; the initramfs is (re)built later in the pipeline.
if [ -x /usr/local/bin/ncz-gpu-select ]; then
    /usr/local/bin/ncz-gpu-select mali --no-initramfs --no-reboot-prompt \
        && echo "[83] default GPU kernel-driver selection = mali (/etc/modprobe.d/ncz-gpu.conf)"
elif [ -f "$GPU_ASSET_DIR/ncz-gpu.conf" ]; then
    install -m 0644 "$GPU_ASSET_DIR/ncz-gpu.conf" /etc/modprobe.d/ncz-gpu.conf
    echo "[83] installed default /etc/modprobe.d/ncz-gpu.conf (mali) [static]"
fi

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

if command -v dkms >/dev/null 2>&1; then
    dkms add -m "$PKG_NAME" -v "$PKG_VER" >/dev/null 2>&1 \
        && echo "[83] dkms add ${PKG_NAME}/${PKG_VER}" \
        || echo "[83] dkms add skipped (already registered?)"

    # Build now only if the NEXT (7.2) kernel headers are present; otherwise
    # DKMS autoinstall rebuilds it on the next kernel upgrade. The module is
    # NOT loaded now — mali is the default and panthor is opt-in via
    # ncz-gpu-select, which rebuilds the initramfs at switch time.
    KVER_NEXT=""
    [ -f "$INSTALLER_META/KVER_NEXT" ] && KVER_NEXT=$(tr -d ' \t\r\n' < "$INSTALLER_META/KVER_NEXT")
    if [ -n "$KVER_NEXT" ] && [ -f "/usr/lib/modules/$KVER_NEXT/build/Makefile" ]; then
        dkms build   -m "$PKG_NAME" -v "$PKG_VER" -k "$KVER_NEXT" >/dev/null 2>&1 \
          && dkms install -m "$PKG_NAME" -v "$PKG_VER" -k "$KVER_NEXT" --force >/dev/null 2>&1 \
          && echo "[83] dkms built+installed ${PKG_NAME} for $KVER_NEXT (-> updates/dkms/)" \
          || echo "[83] dkms build/install deferred (will autoinstall on kernel upgrade)"
    else
        echo "[83] no NEXT kernel headers — panthor-cix DKMS will autoinstall on kernel upgrade"
    fi

    # Always fall back to the vermagic-matched patched module when DKMS did
    # not leave one in updates/dkms. A failed DKMS build must not silently
    # select the unpatched in-tree module, which wedges Sky1 ACPI at probe.
    PREBUILT="${SRC}/${KVER_NEXT}/panthor.ko"
    if [ -n "$KVER_NEXT" ] && [ ! -s "/usr/lib/modules/$KVER_NEXT/updates/dkms/panthor.ko" ] && [ -s "$PREBUILT" ]; then
        install -D -m 0644 "$PREBUILT" "/usr/lib/modules/$KVER_NEXT/updates/dkms/panthor.ko"
        depmod -a "$KVER_NEXT" 2>/dev/null || true
        echo "[83] installed vermagic-matched prebuilt Panthor for $KVER_NEXT"
    elif [ -n "$KVER_NEXT" ] && [ ! -s "/usr/lib/modules/$KVER_NEXT/updates/dkms/panthor.ko" ]; then
        echo "[83] WARN: DKMS did not install and no prebuilt Panthor exists for $KVER_NEXT"
    fi
fi

echo "[83] panthor GPU stage done — panthor available via 'ncz-gpu-select panthor' (experimental)"
exit 0
