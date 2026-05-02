#!/bin/bash
# 70-bootloader.sh — systemd-boot install + nclawzero loader entry.
#
# We skipped grub-installer in preseed (cleaner UEFI semantics with
# systemd-boot for our use case). Install systemd-boot to /boot/efi
# now, with a loader entry pointing at our linux-cix-msr1 kernel.
#
# The cmdline includes the cixmini-required `clk_ignore_unused`,
# Plymouth's `splash quiet`, and console redirection (tty0 + UART).
set -euo pipefail

echo "[70] systemd-boot bootloader"

KVER="6.6.10-cix-build-cix-build-generic"

# bootctl ships in the systemd-boot package on bookworm; the base d-i
# install doesn't pull it in. Install it now (idempotent if already
# present from another path).
#
# systemd-boot's postinst tries to register an EFI boot variable. In a
# chroot — and in QEMU without efivarfs — that fails with "Failed to
# create EFI Boot variable entry: No such file or directory" and apt
# exits 1, killing the hook under set -e. The actual file install
# (binaries to /boot/efi) completes successfully before the postinst's
# NVRAM step fires, so tolerate the apt error and verify bootctl is
# present.
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    systemd-boot efibootmgr || true

command -v bootctl >/dev/null || { echo "ERROR: bootctl not installed"; exit 1; }

# Install systemd-boot binaries to /boot/efi
bootctl install --esp-path=/boot/efi --no-variables || \
    bootctl install --esp-path=/boot/efi || true

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

# Compose cmdline
SPLASH=""
[ -f /etc/kernel/cmdline.d/10-splash.conf ] && SPLASH=$(cat /etc/kernel/cmdline.d/10-splash.conf)

cat > /boot/efi/loader/entries/nclawzero.conf <<EOF
title   nclawzero (cixmini)
version $KVER
linux   /vmlinuz-$KVER
options root=PARTUUID=$ROOT_PARTUUID rootwait rootfstype=ext4 \
        console=tty0 console=ttyAMA0,115200 earlycon clk_ignore_unused $SPLASH
EOF

# Copy our kernel to the ESP (systemd-boot reads /boot/efi by default)
install -m 0644 /boot/vmlinuz-$KVER /boot/efi/vmlinuz-$KVER

# Add a UEFI boot entry pointing at systemd-boot.
#
# `lsblk -no PARTN` is unsupported on the chroot's util-linux version
# (run 19 hit "lsblk: unknown column: PARTN" and tripped set -e).
# Strip the trailing partition number off the source path instead —
# /dev/vda1 → 1, /dev/nvme0n1p2 → 2 — which is portable.
EFI_DEV=$(findmnt -no SOURCE /boot/efi)
EFI_DISK=$(lsblk -no PKNAME "$EFI_DEV")
EFI_PART="${EFI_DEV##*[!0-9]}"
efibootmgr -c -d "/dev/$EFI_DISK" -p "$EFI_PART" \
    -L "nclawzero" -l '\EFI\systemd\systemd-bootaa64.efi' || true

echo ""
echo "Final EFI boot entries:"
# Tolerate "EFI variables are not supported on this system" — happens
# in QEMU and any chroot without RW efivarfs. The actual boot entry
# was either created above (real hardware) or has nothing to write to
# (virtualized). pipefail would otherwise turn this informational dump
# into a hook failure exactly when everything else succeeded.
efibootmgr -v 2>&1 | head -10 || true
