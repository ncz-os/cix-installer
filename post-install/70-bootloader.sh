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

# Add a UEFI boot entry pointing at systemd-boot
EFI_DISK=$(lsblk -no PKNAME $(findmnt -no SOURCE /boot/efi))
EFI_PART=$(lsblk -no PARTN $(findmnt -no SOURCE /boot/efi))
efibootmgr -c -d "/dev/$EFI_DISK" -p "$EFI_PART" \
    -L "nclawzero" -l '\EFI\systemd\systemd-bootaa64.efi' || true

echo ""
echo "Final EFI boot entries:"
efibootmgr -v 2>&1 | head -10
