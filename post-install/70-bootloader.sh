#!/bin/bash
# 70-bootloader.sh — rEFInd boot manager install (install-time entry point).
#
# 26.6-r118: switched from systemd-boot to rEFInd (operator preference —
# "more resilient"). rEFInd ships as a binary (refind_aa64.efi) under
# /usr/local/lib/cix-installer/assets/refind/ and is installed to the ESP at
# the firmware removable-media fallback path /EFI/BOOT/BOOTAA64.EFI, so the
# box boots even with an empty NVRAM BootOrder (confirmed on Sky1/MS-R1).
#
# 26.6-r193: the actual ESP-write logic (kernel staging, cmdline assembly,
# refind.conf generation) moved into a shared script,
# ncz-refind-refresh.sh, installed to /usr/local/sbin/ncz-refind-refresh so
# it stays callable AFTER install too. Root cause: 10-our-kernel.sh used to
# raw-copy the kernel from ISO assets, completely bypassing dpkg -- apt
# had zero record any kernel package was installed, so `apt upgrade` could
# never pull a new kernel (nothing to upgrade FROM). 10-our-kernel.sh now
# installs the kernel via `apt-get install linux-image-cixmini-*`, which
# means the kernel can change again later via a plain apt upgrade -- and
# THAT needs a way to regenerate refind.conf for the new kernel. That part
# is handled by post-install/11-fix-cixmini-boot.sh (redirects the
# `cixmini-boot` package's own kernel-postinst hook, which fires on every
# apt kernel install/upgrade, to call ncz-refind-refresh instead of
# writing an inert systemd-boot entry) -- NOT by
# /etc/kernel/postinst.d/run-parts, which an earlier version of this fix
# assumed but which nothing on this system actually invokes (confirmed
# live on .66). This script is now just: read the static KVER_NEXT sidecar
# baked into the ISO, install the shared script to its permanent location,
# then run it once for the initial install.
#
# Menu (refind.conf manual entries), in order: Mali (default) / Panthor
# (experimental) / Console (no GUI, Mali accelerators off) / Rescue
# Partition (separate on-disk recovery rootfs, if present) / any
# operator-staged RESCUE -tag rescue kernels.
#
# TRADEOFF vs systemd-boot (deliberate, r118): rEFInd has no boot-counting,
# so there is NO automatic edge->stable rollback. The menu's `timeout`
# always presents itself so the operator can pick rescue if a Mali or
# Panthor boot misbehaves.
set -euo pipefail

echo "[70] rEFInd bootloader — install-time setup"

INSTALLER_META=/usr/local/lib/cix-installer
KVER_NEXT=""
[ -f "$INSTALLER_META/KVER_NEXT" ] && KVER_NEXT=$(cat "$INSTALLER_META/KVER_NEXT" 2>/dev/null || true)
BUILD_VERSION="(unknown)"
[ -f "$INSTALLER_META/BUILD_VERSION" ] && BUILD_VERSION=$(cat "$INSTALLER_META/BUILD_VERSION" 2>/dev/null || true)
if [ ! -s "$INSTALLER_META/RELEASE" ]; then
    echo "ERROR: release identity missing at $INSTALLER_META/RELEASE"
    exit 1
fi
# shellcheck disable=SC1091
. "$INSTALLER_META/RELEASE"

if [ -z "$KVER_NEXT" ]; then
    echo "ERROR: KVER_NEXT sidecar missing (edge kernel is the only supported channel)"
    exit 1
fi

# Install the shared refresh script to its permanent home. Staged as an ISO
# asset (assets/refind/ncz-refind-refresh.sh) so it's identical to the
# version installed here, not regenerated -- one source of truth.
SHARED_SRC="$INSTALLER_META/assets/refind/ncz-refind-refresh.sh"
SHARED_DST=/usr/local/sbin/ncz-refind-refresh
if [ ! -s "$SHARED_SRC" ]; then
    echo "ERROR: shared refresh script missing at $SHARED_SRC"
    exit 1
fi
install -D -m 0755 "$SHARED_SRC" "$SHARED_DST"
echo "  installed shared refresh script -> $SHARED_DST"

# Run the shared script now, for the initial install. (Wiring it up for
# future apt-driven kernel upgrades is post-install/11-fix-cixmini-boot.sh's
# job, which runs earlier in this same install pass, right after
# 10-our-kernel.sh -- both this script and that one install/depend on
# ncz-refind-refresh, but neither needs the other to have run first since
# each installs its own copy of what it needs.)
export KVER_NEXT BUILD_VERSION NCZ_PRODUCT_NAME NCZ_RELEASE_VERSION NCZ_RELEASE_CODENAME
"$SHARED_DST"
