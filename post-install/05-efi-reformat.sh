#!/bin/bash
# 05-efi-reformat.sh — fix FAT32 geometry mismatch on the EFI partition.
#
# Root cause: mkfs.vfat via partman creates a FAT32 superblock that claims
# slightly more sectors than the actual partition (nvme0n1p1). This causes
# "bootctl: attempt to access beyond end of device" and bootloader I/O errors.
#
# Fix: unmount /boot/efi, reformat with explicit -S 512 -F 32, remount.
# Must run BEFORE 34-fstab.sh so fstab captures the new UUID.
set -euo pipefail

EFI_DEV=/dev/nvme0n1p1

if [ ! -b "$EFI_DEV" ]; then
    echo "[05] $EFI_DEV not a block device — skipping EFI reformat"
    exit 0
fi

echo "[05] reformatting $EFI_DEV with correct FAT32 geometry"
echo "[05]   unmounting /boot/efi..."
umount /boot/efi 2>&1 || { echo "[05] WARN: umount failed — will try anyway"; }

echo "[05]   mkfs.vfat -F 32 -S 512 -n UEFI $EFI_DEV"
mkfs.vfat -F 32 -S 512 -n UEFI "$EFI_DEV" 2>&1

echo "[05]   remounting $EFI_DEV → /boot/efi"
mkdir -p /boot/efi
mount "$EFI_DEV" /boot/efi 2>&1

NEW_UUID=$(blkid -s UUID -o value "$EFI_DEV" 2>/dev/null || true)
echo "[05] EFI partition reformatted. New UUID: ${NEW_UUID:-(unknown)}"
echo "[05] 34-fstab.sh will pick up the new UUID automatically."
