#!/bin/bash
# 70-bootloader.sh — bootloader install (install-time entry point).
#
# arm64/Sky1 uses rEFInd (see run_refind_arm64() below, unchanged from
# r118-r193 -- history/comments preserved there). AMD64 has no rEFInd
# story and no GPU-accelerator boot-time choice to make, so it gets a
# separate GRUB path (run_grub_amd64()) generating a real dual-kernel menu
# via assets/grub/ncz-grub-refresh.sh -- see that script's header for why
# it hand-authors entries instead of relying on stock 10_linux.
#
# Dispatch is by dpkg architecture, not by any Sky1-specific signal, because
# that's the actual fork this file needs: which bootloader exists on this
# hardware family, not which board within a family.
set -euo pipefail

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
        echo "ERROR: KVER_NEXT sidecar missing (edge kernel is the only supported channel)"
        exit 1
    fi
    # KVER_EDGE (2026-09-15): optional second, EXPERIMENTAL kernel line --
    # see post-install/10-our-kernel.sh for how it gets installed. Absence
    # is fine (single-kernel ISOs still build); ncz-refind-refresh.sh only
    # emits the 5th menu entry when this is non-empty.
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
# AMD64: GRUB, two real kernel lines (2026-09-15). See
# assets/grub/ncz-grub-refresh.sh for why this hand-authors top-level
# entries instead of trusting stock 10_linux (short version: 10_linux's
# newest-kernel-is-default rule would make the untested edge/7.3-rc3 line
# the silent default, since 7.3 sorts above 7.2.6 by plain version compare).
run_grub_amd64() {
    KVER_LIST="$INSTALLER_META/KVER_LIST_AMD64"
    if [ ! -s "$KVER_LIST" ]; then
        echo "ERROR: $KVER_LIST missing (post-install/10-amd64-kernel.sh should have written it)"
        exit 1
    fi
    KVER_STABLE="$(sed -n '1p' "$KVER_LIST")"
    KVER_EDGE="$(sed -n '2p' "$KVER_LIST")"
    if [ -z "$KVER_STABLE" ]; then
        echo "ERROR: no stable KVER in $KVER_LIST"
        exit 1
    fi

    SHARED_SRC="$INSTALLER_META/assets/grub/ncz-grub-refresh.sh"
    SHARED_DST=/usr/local/sbin/ncz-grub-refresh
    if [ ! -s "$SHARED_SRC" ]; then
        echo "ERROR: shared refresh script missing at $SHARED_SRC"
        exit 1
    fi
    install -D -m 0755 "$SHARED_SRC" "$SHARED_DST"
    echo "  installed shared refresh script -> $SHARED_DST"

    export KVER_STABLE KVER_EDGE BUILD_VERSION NCZ_PRODUCT_NAME NCZ_RELEASE_VERSION NCZ_RELEASE_CODENAME
    "$SHARED_DST"

    # ESP fallback path, same rationale as arm64's BOOTAA64.EFI: boot even
    # with an empty NVRAM BootOrder. grub-install already registers a real
    # NVRAM entry on a normal UEFI install; --removable additionally drops
    # the fallback binary so a firmware that ignores/loses NVRAM still boots.
    ESP="$(findmnt -n -o TARGET /boot/efi 2>/dev/null || true)"
    if [ -n "$ESP" ]; then
        grub-install --target=x86_64-efi --efi-directory="$ESP" \
            --bootloader-id=ncz-os --recheck || \
            echo "  WARN: grub-install (NVRAM entry) failed -- continuing on the --removable fallback"
        grub-install --target=x86_64-efi --efi-directory="$ESP" \
            --bootloader-id=ncz-os --removable --recheck || \
            echo "  WARN: grub-install --removable failed -- ESP may not be bootable without a working NVRAM entry"
    else
        echo "  WARN: no /boot/efi mount found -- skipping grub-install (BIOS-only target? not yet handled here)"
    fi
}

case "$(dpkg --print-architecture 2>/dev/null || uname -m)" in
    arm64|aarch64) run_refind_arm64 ;;
    amd64|x86_64)  run_grub_amd64 ;;
    *) echo "ERROR: unsupported architecture for bootloader install" >&2; exit 1 ;;
esac
