#!/bin/bash
# qemu-test-console-patch.sh — produce a QEMU-ONLY copy of a cix-installer
# ISO with earlycon=pl011,0x9000000 + console=ttyAMA0 added to the d-i
# kernel cmdline, for kernel-level (not just d-i-menu-level) serial
# visibility when testing under QEMU.
#
# Why this is a separate script instead of a permanent cmdline change
# (2026-07-28): QEMU's `-M virt` board exposes its UART at a fixed
# pl011@0x9000000 (-> ttyAMA0). Real Sky1 hardware's console lives at
# ttyAMA2, an entirely different physical address -- unconditionally
# baking earlycon=pl011,0x9000000 into the SHIPPED product cmdline would
# have that early-boot raw MMIO probe run on every real board too.
# earlycon does this probe before any device-tree/ACPI validation, so an
# address that's meaningless (or worse, aliases something real) on actual
# Sky1 silicon is a genuine risk, not just dead weight. This script keeps
# that addition strictly QEMU-only: it patches a COPY of the ISO, the
# real build-iso-di.sh output is never touched.
#
# Usage: qemu-test-console-patch.sh <path/to/installer.iso>
# Output: <path/to/installer>-qemutest.iso (siblings to the input)

set -euo pipefail

SRC_ISO="${1:-}"
[ -z "$SRC_ISO" ] && { echo "usage: $0 <path/to/installer.iso>"; exit 1; }
[ ! -f "$SRC_ISO" ] && { echo "ERROR: $SRC_ISO not found"; exit 1; }

for t in xorriso mount; do
    command -v "$t" >/dev/null 2>&1 || { echo "ERROR: $t not found"; exit 1; }
done

OUT_ISO="${SRC_ISO%.iso}-qemutest.iso"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "[1] extracting $SRC_ISO -> $WORK/staging"
mkdir -p "$WORK/staging"
xorriso -osirrox on -indev "$SRC_ISO" -extract / "$WORK/staging" >/dev/null
# xorriso preserves ISO9660's read-only permission bits on extraction --
# make everything writable so the patch below (and the exit trap's rm -rf)
# don't fail on permission-denied.
chmod -R u+w "$WORK/staging"

CFG="$WORK/staging/boot/grub/grub.cfg"
[ -f "$CFG" ] || { echo "ERROR: boot/grub/grub.cfg not found in extracted ISO"; exit 1; }

echo "[2] patching kernel cmdlines (desktop + server entries) with QEMU-only console args"
# Insert right after each menuentry's own args, ahead of the first
# loglevel=... token, on any `linux ... vmlinuz ...` line. Idempotent:
# skip if already patched (re-running against an already-patched copy).
if grep -q "earlycon=pl011,0x9000000" "$CFG"; then
    echo "    already patched, leaving as-is"
else
    sed -i 's/\(^[[:space:]]*linux[[:space:]]\+\/install\.a64\/vmlinuz.*\)loglevel=4/\1earlycon=pl011,0x9000000 console=ttyAMA0,115200 loglevel=8/' "$CFG"
    PATCHED=$(grep -c "earlycon=pl011,0x9000000" "$CFG" || true)
    echo "    patched $PATCHED cmdline(s)"
    [ "$PATCHED" -ge 1 ] || { echo "ERROR: patch matched zero lines -- grub.cfg layout may have changed"; exit 1; }
fi

grub-script-check "$CFG" 2>/dev/null && echo "    grub-script-check: syntax OK" || echo "    WARN: grub-script-check unavailable/failed, proceeding anyway"

echo "[3] repacking -> $OUT_ISO"
EFI_IMG_REL="boot/grub/efi.img"
[ -f "$WORK/staging/$EFI_IMG_REL" ] || { echo "ERROR: $EFI_IMG_REL missing from extracted ISO"; exit 1; }
rm -f "$OUT_ISO"
xorriso -as mkisofs \
    -r -V "NCZ_MAXIMILIAN" \
    -J -joliet-long \
    -cache-inodes \
    -e "$EFI_IMG_REL" \
    -no-emul-boot \
    -append_partition 2 0xef "$WORK/staging/$EFI_IMG_REL" \
    -appended_part_as_gpt \
    -partition_cyl_align all \
    -o "$OUT_ISO" \
    "$WORK/staging" >/dev/null

echo "OUTPUT: $OUT_ISO"
ls -lh "$OUT_ISO"
