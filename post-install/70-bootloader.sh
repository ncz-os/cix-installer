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
    systemd-boot efibootmgr || true

command -v bootctl >/dev/null || { echo "ERROR: bootctl not installed"; exit 1; }

# bootctl install copies systemd-bootaa64.efi onto the ESP.
bootctl install --esp-path=/boot/efi --no-variables || \
    bootctl install --esp-path=/boot/efi || true

# ----------------------------------------------------------------------
# Initrd generation INTENTIONALLY DISABLED.
#
# We tried building an initrd via update-initramfs against our
# 6.6.10 Cix kernel + extracting /boot/config-$KVER from /proc/config.gz
# so initramfs-tools could pick a compression. update-initramfs then
# warned `cp: cannot stat /usr/share/initramfs-tools/init: No such
# file or directory` and built a 221 MB initrd that's missing its
# /init script — likely because cix-debian-misc.postinst renamed
# /usr/share/initramfs-tools/init earlier in 25-cix-proprietary
# (its known list of mv calls includes that path).
#
# Booting against the broken initrd panics the kernel ("can't run /
# init") and triggers an infinite reboot loop on real hardware.
# Tested: cixmini.66 boot-looped on 2026-05-02 evening after I
# referenced this initrd from the loader entry.
#
# Workaround: skip initrd entirely. Our kernel has NVMe + ext4 + USB
# host built-in (per usb-rootfs.cfg), so it can mount root from
# /dev/nvme0n1p2 directly without any initramfs help. Plymouth splash
# DOES require an initrd to render before fbcon hands off, so we lose
# that polish for now — but the kernel boots cleanly.
#
# Real fix needed before re-enabling initrd:
#   - In 25-cix-proprietary, after cix-debian-misc unpacks, RESTORE
#     /usr/share/initramfs-tools/init from the initramfs-tools-core
#     deb (file is at /usr/share/initramfs-tools/init in that deb).
#     OR work upstream to fix cix-debian-misc.postinst's mv calls.
#   - Verify update-initramfs runs without the "cp: cannot stat" warn
#   - Verify resulting initrd has /init via lsinitramfs.
# ----------------------------------------------------------------------

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

# No-initrd loader entry — see comment above re: cix-debian-misc damage
# to /usr/share/initramfs-tools/init.
cat > /boot/efi/loader/entries/nclawzero.conf <<EOF
title   nclawzero (cixmini)
version $KVER
linux   /vmlinuz-$KVER
options $OPTIONS
EOF

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
