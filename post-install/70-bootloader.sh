#!/bin/bash
# NCZ-MIXED-HOOK: rEFInd on both arches via run_refind_arm64 and run_refind_amd64; TODO split into per-platform bodies (docs/platform-inventory.tsv; runs on every platform, listed in both hooks.list files)
# 70-bootloader.sh — bootloader install (install-time entry point).
#
# Both arm64/Sky1 and AMD64 use rEFInd (operator directive, 2026-09-16:
# "standardize on rEFInd on amd64, we should not diverge" -- same boot
# menu shape, same branding/art, same preference-learning and
# rescue-promotion mechanics on both architectures). AMD64 previously had a
# separate GRUB path (run_grub_amd64(), removed); see
# assets/refind/ncz-refind-refresh-amd64.sh's header for the concrete list
# of what differs from the arm64 script (refind_x64.efi vs refind_aa64.efi,
# BOOTX64.EFI vs BOOTAA64.EFI, no Sky1-specific cmdline/GPU-driver logic,
# stable-vs-edge kernel-line entries instead of Mali-vs-Panthor) and what's
# identical (rescue promotion, timeout/default learning, banner/icon
# staging, NVRAM fallback).
#
# Dispatch is by dpkg architecture, not by any Sky1-specific signal, because
# that's the actual fork this file needs: which rEFInd binary + kernel-line
# model applies to this hardware family, not which board within a family.
set -euo pipefail
_pm="$(dirname "$0")/lib/progress-msg.sh"; [ -r "$_pm" ] || _pm=/usr/local/lib/cix-installer/post-install/lib/progress-msg.sh
[ -r "$_pm" ] && . "$_pm"
command -v ncz_msg >/dev/null 2>&1 && ncz_msg "Bootloader: writing rEFInd boot entries and syncing the ESP (about a minute; log: /var/log/cix-install/70-bootloader.log)"

echo "[70] bootloader — install-time setup"

INSTALLER_META=/usr/local/lib/cix-installer
if [ ! -s "$INSTALLER_META/RELEASE" ]; then
    echo "ERROR: release identity missing at $INSTALLER_META/RELEASE"
    exit 1
fi
# shellcheck disable=SC1091
. "$INSTALLER_META/RELEASE"
BUILD_VERSION="(unknown)"
[ -f "$INSTALLER_META/BUILD_VERSION" ] && BUILD_VERSION=$(cat "$INSTALLER_META/BUILD_VERSION" 2>/dev/null || true)

# ----------------------------------------------------------------------------
# arm64/Sky1: rEFInd (26.6-r118 onward). Unchanged -- see original comments.
#
# 26.6-r118: switched from systemd-boot to rEFInd (operator preference --
# "more resilient"). rEFInd ships as a binary (refind_aa64.efi) under
# /usr/local/lib/cix-installer/assets/refind/ and is installed to the ESP at
# the firmware removable-media fallback path /EFI/BOOT/BOOTAA64.EFI, so the
# box boots even with an empty NVRAM BootOrder (confirmed on Sky1/MS-R1).
#
# 26.6-r193: the actual ESP-write logic (kernel staging, cmdline assembly,
# refind.conf generation) moved into a shared script, ncz-refind-refresh.sh,
# installed to /usr/local/sbin/ncz-refind-refresh so it stays callable AFTER
# install too. Root cause: 10-our-kernel.sh used to raw-copy the kernel from
# ISO assets, completely bypassing dpkg -- apt had zero record any kernel
# package was installed, so `apt upgrade` could never pull a new kernel
# (nothing to upgrade FROM). 10-our-kernel.sh now installs the kernel via
# `apt-get install linux-image-cixmini-*`, which means the kernel can change
# again later via a plain apt upgrade -- and THAT needs a way to regenerate
# refind.conf for the new kernel. That part is handled by
# post-install/11-fix-cixmini-boot.sh (redirects the `cixmini-boot` package's
# own kernel-postinst hook, which fires on every apt kernel install/upgrade,
# to call ncz-refind-refresh instead of writing an inert systemd-boot entry)
# -- NOT by /etc/kernel/postinst.d/run-parts, which an earlier version of
# this fix assumed but which nothing on this system actually invokes
# (confirmed live on .66). This script is now just: read the static
# KVER_NEXT sidecar baked into the ISO, install the shared script to its
# permanent location, then run it once for the initial install.
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
run_refind_arm64() {
    KVER_NEXT=""
    [ -f "$INSTALLER_META/KVER_NEXT" ] && KVER_NEXT=$(cat "$INSTALLER_META/KVER_NEXT" 2>/dev/null || true)
    if [ -z "$KVER_NEXT" ]; then
        echo "ERROR: KVER_NEXT sidecar missing (the unified 7.3 kernel is the only supported channel)"
        exit 1
    fi
    # Unified 7.3 (operator 2026-10-05): one kernel. There is no second
    # experimental edge line; a stale KVER_EDGE sidecar is ignored by
    # ncz-refind-refresh.sh.
    KVER_EDGE=""
    [ -f "$INSTALLER_META/KVER_EDGE" ] && KVER_EDGE=$(cat "$INSTALLER_META/KVER_EDGE" 2>/dev/null || true)

    # Install the shared refresh script to its permanent home. Staged as an
    # ISO asset (assets/refind/ncz-refind-refresh.sh) so it's identical to
    # the version installed here, not regenerated -- one source of truth.
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
    export KVER_NEXT KVER_EDGE BUILD_VERSION NCZ_PRODUCT_NAME NCZ_RELEASE_VERSION NCZ_RELEASE_CODENAME
    "$SHARED_DST"
}

# ----------------------------------------------------------------------------
# AMD64: rEFInd, one kernel (amd64-stable). The edge line was retired with
# the unified 7.3 policy (operator 2026-10-05). Was GRUB via
# run_grub_amd64()/assets/grub/ncz-grub-refresh.sh until 2026-09-16.
run_refind_amd64() {
    KVER_LIST="$INSTALLER_META/KVER_LIST_AMD64"
    if [ ! -s "$KVER_LIST" ]; then
        echo "ERROR: $KVER_LIST missing (post-install/10-amd64-kernel.sh should have written it)"
        exit 1
    fi
    # Line 1 is the installed amd64-stable KVER. A second line used to be
    # the retired edge channel; do not read it. ncz-refind-refresh-amd64.sh
    # ignores KVER_EDGE, and passing one only emits a warning.
    KVER_STABLE="$(sed -n '1p' "$KVER_LIST")"
    KVER_EDGE=""
    if [ -z "$KVER_STABLE" ]; then
        echo "ERROR: no stable KVER in $KVER_LIST"
        exit 1
    fi

    # Staged as an ISO asset (assets/refind/ncz-refind-refresh-amd64.sh) so
    # it's identical to the version installed here, not regenerated -- same
    # one-source-of-truth pattern as arm64's ncz-refind-refresh.sh.
    SHARED_SRC="$INSTALLER_META/assets/refind/ncz-refind-refresh-amd64.sh"
    SHARED_DST=/usr/local/sbin/ncz-refind-refresh-amd64
    if [ ! -s "$SHARED_SRC" ]; then
        echo "ERROR: shared refresh script missing at $SHARED_SRC"
        exit 1
    fi
    install -D -m 0755 "$SHARED_SRC" "$SHARED_DST"
    echo "  installed shared refresh script -> $SHARED_DST"

    # Standard Debian /etc/kernel/postinst.d/ hook so a future `apt upgrade`
    # of either kernel line regenerates refind.conf -- the same hookpoint
    # grub-efi-amd64 used to provide via its own postinst.d script
    # (update-grub), now that AMD64 boots rEFInd instead. Real target now
    # that both kernel lines are actually published to a real apt repo
    # (2026-09-16, ncz-apt via ncz-reprepro-publish.sh) -- see
    # assets/refind/zz1-ncz-refind-refresh-amd64's own header for why this
    # is simpler than arm64's cixmini-boot-redirect equivalent
    # (11-fix-cixmini-boot.sh): AMD64 has no special-cased kernel package to
    # redirect, just the plain standard hookpoint to use.
    HOOK_SRC="$INSTALLER_META/assets/refind/zz1-ncz-refind-refresh-amd64"
    HOOK_DST=/etc/kernel/postinst.d/zz1-ncz-refind-refresh-amd64
    if [ -s "$HOOK_SRC" ]; then
        install -D -m 0755 "$HOOK_SRC" "$HOOK_DST"
        echo "  installed kernel postinst.d hook -> $HOOK_DST"
    else
        echo "  WARN: $HOOK_SRC missing -- future apt kernel upgrades will NOT regenerate refind.conf"
    fi

    export KVER_STABLE KVER_EDGE BUILD_VERSION NCZ_PRODUCT_NAME NCZ_RELEASE_VERSION NCZ_RELEASE_CODENAME
    "$SHARED_DST"
}

case "$(dpkg --print-architecture 2>/dev/null || uname -m)" in
    arm64|aarch64) run_refind_arm64 ;;
    amd64|x86_64)  run_refind_amd64 ;;
    *) echo "ERROR: unsupported architecture for bootloader install" >&2; exit 1 ;;
esac
