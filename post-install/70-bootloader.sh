#!/bin/bash
# 70-bootloader.sh — systemd-boot install + nclawzero loader entry.
#
# We skipped grub-installer in preseed (cleaner UEFI semantics with
# systemd-boot for our use case). Install systemd-boot to /boot/efi,
# generate an initrd for our kernel (Plymouth splash needs one), copy
# both to the ESP, and write a single-line loader entry.
#
# CRITICAL: systemd-boot's loader entry parser does NOT support
# backslash line-continuation — every line MUST be standalone, and the
# `options` line must be ONE physical line. Earlier versions of this
# hook split options across multiple `\` lines, and bootctl status
# silently logged "Unknown line ..." while only the first half of the
# cmdline reached the kernel. Single-line options is mandatory.
set -euo pipefail

echo "[70] systemd-boot bootloader"

KVER="6.6.10-cix-build-cix-build-generic"

# ----------------------------------------------------------------------
# Install systemd-boot + efibootmgr + initramfs-tools.
#
# systemd-boot's postinst tries to register an EFI boot variable. In a
# chroot (or in QEMU without RW efivarfs) that fails and apt exits 1,
# which set -e would kill — tolerate it. initramfs-tools needed so we
# can build an initrd against our kernel (Plymouth splash + readahead).
# ----------------------------------------------------------------------
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    systemd-boot efibootmgr initramfs-tools || true

command -v bootctl >/dev/null || { echo "ERROR: bootctl not installed"; exit 1; }

# bootctl install copies systemd-bootaa64.efi onto the ESP.
bootctl install --esp-path=/boot/efi --no-variables || \
    bootctl install --esp-path=/boot/efi || true

# ----------------------------------------------------------------------
# Generate /boot/config-$KVER + /boot/initrd.img-$KVER.
#
# Yocto's kernel deploy doesn't ship the kconfig file as /boot/config-*
# the way Debian's linux-image debs do, but initramfs-tools needs it to
# decide which compression to use. Extract from /proc/config.gz at
# install-time (kernel was built with CONFIG_IKCONFIG_PROC=y per Cix
# defconfig, so /proc/config.gz is available). Without the config
# file, update-initramfs falls through every compression check and
# fails — fixed live on the first deployed unit on 2026-05-02.
# ----------------------------------------------------------------------
if [ ! -f "/boot/config-$KVER" ] && [ -f /proc/config.gz ]; then
    zcat /proc/config.gz > "/boot/config-$KVER"
    echo "    extracted /boot/config-$KVER from /proc/config.gz"
fi

# Build the initrd. Many "missing firmware" warnings are harmless —
# initramfs-tools warns about every built-in driver whose firmware
# blob isn't in /lib/firmware/, even if that driver isn't bound to
# any active hardware. Tolerate.
if [ -f "/boot/config-$KVER" ]; then
    update-initramfs -c -k "$KVER" 2>&1 | tail -5 || true
fi

# Discover root partition by PARTUUID (stable across flashes)
ROOT_PARTUUID=$(blkid -s PARTUUID -o value $(findmnt -no SOURCE /))

# Loader config
mkdir -p /boot/efi/loader/entries
cat > /boot/efi/loader/loader.conf <<EOF
default nclawzero
timeout 3
console-mode auto
editor yes
EOF

# Pull `splash quiet` from /etc/kernel/cmdline.d (60-plymouth wrote it).
SPLASH=""
[ -f /etc/kernel/cmdline.d/10-splash.conf ] && SPLASH=$(cat /etc/kernel/cmdline.d/10-splash.conf)

# ----------------------------------------------------------------------
# Loader entry — SINGLE-LINE `options`, NO backslash continuation.
# Cmdline notes:
#   - console=ttyAMA0,115200 console=tty0  →  /dev/console = tty0 (HDMI),
#     userspace writes visible on screen, serial mirror still works
#     for any cable that's plugged in
#   - clk_ignore_unused  →  Cix Sky1 hard requirement (some clocks
#     register unused at boot but actually feed live blocks)
#   - loglevel=3 splash quiet  →  Plymouth shows splash; only errors
#     leak through as text
#   - module_blacklist  →  trilin_drm/trilin_dpsub/linlondp/linlondp_drv/
#     cix_display kept off until the candidate-1 SOFT_RESET pulse patch
#     lands. simpledrm holds the GOP framebuffer through to GDM.
#     Tradeoff: software-rendered GNOME until full DRM is unblocked.
# ----------------------------------------------------------------------
OPTIONS="root=PARTUUID=$ROOT_PARTUUID rootwait rootfstype=ext4 console=ttyAMA0,115200 console=tty0 earlycon clk_ignore_unused loglevel=3"
[ -n "$SPLASH" ] && OPTIONS="$OPTIONS $SPLASH"
OPTIONS="$OPTIONS module_blacklist=trilin_drm,trilin_dpsub,linlondp,linlondp_drv,cix_display"

if [ -f "/boot/initrd.img-$KVER" ]; then
    cat > /boot/efi/loader/entries/nclawzero.conf <<EOF
title   nclawzero (cixmini)
version $KVER
linux   /vmlinuz-$KVER
initrd  /initrd.img-$KVER
options $OPTIONS
EOF
    install -m 0644 "/boot/initrd.img-$KVER" "/boot/efi/initrd.img-$KVER"
else
    cat > /boot/efi/loader/entries/nclawzero.conf <<EOF
title   nclawzero (cixmini)
version $KVER
linux   /vmlinuz-$KVER
options $OPTIONS
EOF
fi

# Copy our kernel to the ESP (systemd-boot reads /boot/efi by default)
install -m 0644 "/boot/vmlinuz-$KVER" "/boot/efi/vmlinuz-$KVER"

# Add a UEFI boot entry pointing at systemd-boot.
#
# `lsblk -no PARTN` is unsupported on the chroot's util-linux version.
# Strip the trailing partition number off the source path instead —
# /dev/vda1 → 1, /dev/nvme0n1p2 → 2 — which is portable.
EFI_DEV=$(findmnt -no SOURCE /boot/efi)
EFI_DISK=$(lsblk -no PKNAME "$EFI_DEV")
EFI_PART="${EFI_DEV##*[!0-9]}"
efibootmgr -c -d "/dev/$EFI_DISK" -p "$EFI_PART" \
    -L "nclawzero" -l '\EFI\systemd\systemd-bootaa64.efi' || true

echo ""
echo "Final loader entry:"
cat /boot/efi/loader/entries/nclawzero.conf
echo ""
echo "bootctl status (warnings about Unknown line = parse bug, should be empty):"
bootctl status 2>&1 | grep -E "Unknown line|without value" | head -5 || true
echo ""
echo "Final EFI boot entries:"
efibootmgr -v 2>&1 | head -10 || true
