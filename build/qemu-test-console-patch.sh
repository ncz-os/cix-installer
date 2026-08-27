#!/bin/bash
# qemu-test-console-patch.sh — produce a QEMU-ONLY copy of a cix-installer
# ISO with (1) earlycon=pl011,0x9000000 for early kernel serial visibility
# and (2) console=ttyAMA2 swapped to console=ttyAMA0, for kernel-level AND
# d-i-level visibility when testing under QEMU.
#
# Why (1) is QEMU-only, not a permanent cmdline change (2026-07-28): QEMU's
# `-M virt` board exposes its UART at a fixed pl011@0x9000000 (-> ttyAMA0).
# Real Sky1 hardware's console lives at ttyAMA2, an entirely different
# physical address -- unconditionally baking earlycon=pl011,0x9000000 into
# the SHIPPED product cmdline would have that early-boot raw MMIO probe run
# on every real board too. earlycon does this probe before any device-tree/
# ACPI validation, so an address that's meaningless (or worse, aliases
# something real) on actual Sky1 silicon is a genuine risk, not dead weight.
#
# Why (2) is also required, not just cosmetic (found 2026-07-28 via
# /sbin/reopen-console in the d-i initramfs, package cdebconf-terminal):
# reopen-console picks whichever console the KERNEL reports as "preferred"
# (the LAST console= on the cmdline) and calls `steal-ctty` on it -- but
# the preferred-console selection is NOT gated by the /dev node actually
# existing (only the separate "which consoles get d-i spawned on" list is).
# QEMU's virt board only instantiates ONE pl011 UART (ttyAMA0); it has no
# ttyAMA2 device at all. With console=ttyAMA2 left as the cmdline's last
# entry, ttyAMA2 stays "preferred" even though /dev/ttyAMA2 never gets
# created, so steal-ctty fails with ENOENT and d-i's actual startup
# (inittab respawn via `kill -HUP 1`) either lands on some other console
# our serial capture isn't watching, or the reopen-console flow stalls --
# either way it LOOKS identical to a genuine boot hang. Swapping the
# trailing console=ttyAMA2 to console=ttyAMA0 makes the kernel's preferred
# console one that actually exists under QEMU, matching -serial stdio.
#
# Both changes are kept strictly QEMU-only: this script patches a COPY of
# the ISO, the real build-iso-di.sh output (and its real ttyAMA2 target for
# actual Sky1 hardware) is never touched.
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

echo "[2] patching kernel cmdlines (desktop + server + rescue entries) with QEMU-only console args"
# Idempotent: skip if already patched (re-running against an already-patched copy).
if grep -q "earlycon=pl011,0x9000000" "$CFG"; then
    echo "    already patched, leaving as-is"
else
    # (1) early kernel-level serial visibility
    sed -i 's/\(^[[:space:]]*linux[[:space:]]\+\/install\.a64\/vmlinuz.*\)loglevel=4/\1earlycon=pl011,0x9000000 loglevel=8/' "$CFG"
    # (2) make ttyAMA0 (real under QEMU) the kernel's preferred console
    # instead of ttyAMA2 (real-hardware-only, no /dev node under QEMU) --
    # see the file header for why reopen-console needs this specifically.
    sed -i 's/console=ttyAMA2,115200/console=ttyAMA0,115200/' "$CFG"
    # (3) the preseed deliberately (r177, see preseed.cfg comment) leaves
    # username/fullname/password UNSEEN so a real install always stops and
    # asks a human -- by design, not a gap. The preseed comment itself
    # documents the automated-testing escape hatch: pass these as EXTRA
    # kernel cmdline params (d-i reads /proc/cmdline as override-preseed
    # values), which is exactly what this does, test-only.
    # No spaces in any value here -- the kernel cmdline tokenizer splits on
    # whitespace, so a spaced fullname would silently break into extra
    # bogus params instead of one preseed value.
    sed -i 's/\(^[[:space:]]*linux[[:space:]]\+\/install\.a64\/vmlinuz.*\)loglevel=8/\1passwd\/username=nczuser passwd\/user-fullname=NCZTestUser passwd\/user-password=nczpassword123 passwd\/user-password-again=nczpassword123 loglevel=8/' "$CFG"
    # (4) QEMU-only unattended disk selection: the disk-fs-chooser ALWAYS shows
    # an interactive destructive-disk confirm (operator requirement 2026-07-04),
    # which has no operator under an automated KVM run and would stall forever.
    # ncz_disk=/dev/vda (the virtio target) + ncz_fs=btrfs take the OVR_DISK
    # auto-select path so the run proceeds to extract-rootfs + late.sh. NEVER
    # shipped -- console-patch output is a throwaway test ISO only.
    sed -i 's/\(^[[:space:]]*linux[[:space:]]\+\/install\.a64\/vmlinuz.*\)loglevel=8/\1ncz_disk=\/dev\/vda ncz_fs=btrfs loglevel=8/' "$CFG"
    PATCHED=$(grep -c "earlycon=pl011,0x9000000" "$CFG" || true)
    SWAPPED=$(grep -c "console=ttyAMA0,115200" "$CFG" || true)
    echo "    patched $PATCHED cmdline(s) with earlycon, swapped $SWAPPED to console=ttyAMA0"
    [ "$PATCHED" -ge 1 ] || { echo "ERROR: earlycon patch matched zero lines -- grub.cfg layout may have changed"; exit 1; }
    [ "$SWAPPED" -ge 1 ] || { echo "ERROR: console=ttyAMA2 swap matched zero lines -- grub.cfg layout may have changed"; exit 1; }
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
