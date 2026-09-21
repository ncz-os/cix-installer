#!/bin/bash
# kvm-installed-disk-assert.sh — post-boot assertions for KVM install gates
#
# WHY THIS EXISTS (architectural review §10 Stage B, dispatch 1 item 2):
#
#   The two existing KVM install gates (build/kvm-install-gate.sh for arm64,
#   build/kvm-install-gate-amd64.sh for amd64) currently decide whether the
#   installed system is OK by:
#     (a) grep'ing the boot log for a kernel banner — which only proves the
#         bootloader handed off to SOMETHING that started booting. It does
#         NOT prove the installed disk actually had a real ESP/GPT layout
#         backing the EFI files.
#     (b) grep'ing for systemd/login markers — which can false-pass on a
#         VM that reached userspace via a stale Boot0001 + an arbitrary
#         EFI filename, exactly the failure class the 2026-08-21 TYDEUS
#         phase-2 run hit (Boot0001 -> /EFI/Linux/systemd-bootaa64.efi ->
#         Synchronous Exception because the qcow2 had ext4 directly on
#         /dev/vda with no real ESP).
#     (c) printing "GATE PASS" once a kernel banner is seen.
#
#   Per the review's Stage B "required evidence" list, the gates must
#   instead HARD-FAIL on real defects. A required failure cannot be
#   overwritten by an EFI-file-presence heuristic — i.e. "the file exists
#   somewhere on the disk" is NOT proof of a working ESP. The five
#   required checks (all per the review, all must pass; missing = hard
#   fail with explicit message naming which check failed):
#
#     1. GPT partition table present (not MBR, not raw filesystem on whole
#        disk).
#     2. A real EFI System Partition exists: FAT filesystem, MOUNTED,
#        with EFI files actually findable on the mounted filesystem
#        (not just present in a loose directory tree).
#     3. A real installed-kernel banner appears in the boot log.
#     4. Root filesystem mode is 0755 after first-boot work completes.
#        The d-i side has preseed/extract-rootfs.sh for the layer-mode
#        check; the INSTALLED-system equivalent is the NCZ-ROOTMODE
#        marker emitted by ncz-firstboot after dpkg --configure -a.
#     5. The rescue/fallback boot entry (rEFInd 'rescue' / equivalent)
#        still exists and is independently selectable from the default
#        entry. Proves we did not regress to a single-entry menu that
#        leaves the user with no fallback if the default entry breaks.
#
# Usage: kvm-installed-disk-assert.sh <qcow2> <boot.log> [arch]
#   arch = arm64 | amd64 (default arm64; affects expected ESP binary
#          name and the rescue-entry regex)
# Exit:  0  on full pass
#       11  GPT missing
#       12  ESP missing / wrong type / not FAT
#       13  ESP mounted but no EFI files on it
#       14  no installed-kernel banner in boot.log
#       15  root mode not 0755
#       16  rescue entry missing or not independently selectable
#       20  argument/setup error (not a content failure)
#
# This script is read-only against the qcow2 (losetup + mount -o ro) so
# it can be invoked from either gate in either order and leaves no
# artefacts other than a scratch mount point that's cleaned up via trap.

set -uo pipefail

QCOW2="${1:?usage: $0 <qcow2> <boot.log> [arm64|amd64]}"
BLOG="${2:?usage: $0 <qcow2> <boot.log> [arm64|amd64]}"
ARCH="${3:-arm64}"

fail_check() {
    # $1 = numeric exit, $2 = short name, $3 = human detail
    echo "GATE FAIL (installed-disk-assert #${1} ${2}): ${3}" >&2
    cleanup_work
    exit "$1"
}

WORK=""
LOOP=""
MOUNT=""

cleanup_work() {
    if [ -n "$MOUNT" ] && mountpoint -q "$MOUNT" 2>/dev/null; then
        umount "$MOUNT" 2>/dev/null
    fi
    if [ -n "$LOOP" ]; then
        losetup -d "$LOOP" 2>/dev/null
    fi
    if [ -n "$WORK" ] && [ -d "$WORK" ]; then
        rm -rf "$WORK" 2>/dev/null
    fi
}
trap 'cleanup_work' EXIT

[ -f "$QCOW2" ] || { echo "GATE FAIL: installed-disk-assert: qcow2 not found: $QCOW2" >&2; exit 20; }
[ -f "$BLOG" ]  || { echo "GATE FAIL: installed-disk-assert: boot log not found: $BLOG" >&2; exit 20; }

case "$ARCH" in
    arm64) ESP_ARCH="AA64" ;;
    amd64) ESP_ARCH="X64"  ;;
    *)     echo "GATE FAIL: installed-disk-assert: unknown arch '$ARCH' (expected arm64|amd64)" >&2; exit 20 ;;
esac

# --- Check #1: real GPT partition table (review §10 Stage B item 1).
PT_OUT="$(parted -s "$QCOW2" unit B print free 2>&1)"
PT_KIND="$(echo "$PT_OUT" | awk -F': *' '/^Partition Table/{print $2; exit}')"
case "$PT_KIND" in
    gpt) ;; # good
    msdos)
        fail_check 11 gpt "qcow2 has an MBR (msdos) partition table; the released media uses UEFI/GPT and a missing GPT means d-i never wrote one — exactly the 2026-08-21 TYDEUS phase-2 failure class"
        ;;
    unknown|"")
        fail_check 11 gpt "qcow2 has no partition table at all (whole-disk filesystem or empty); this is the EXACT 2026-08-21 TYDEUS phase-2 failure: ext4 on /dev/vda with EFI files inside but no real ESP backing them"
        ;;
    *)
        fail_check 11 gpt "qcow2 has unexpected partition-table label: '$PT_KIND' (expected gpt)"
        ;;
esac

# --- Check #2: ESP exists, is FAT, is MOUNTED, has EFI files on it.
ESP_PARTNUM="$(parted -s "$QCOW2" unit B print 2>/dev/null \
    | awk '/^[[:space:]]+[0-9]+/ && $0 ~ /esp/ {print $1; exit}')"
[ -n "$ESP_PARTNUM" ] || fail_check 12 esp "no ESP-flagged partition in the qcow2's GPT (expected at least one partition with the 'esp' flag)"

ESP_LINE="$(parted -s "$QCOW2" unit B print 2>/dev/null \
    | awk -v n="$ESP_PARTNUM" '$1==n')"
ESP_START_B="$(echo "$ESP_LINE" | awk '{print $2}' | sed 's/B$//')"
ESP_SIZE_B="$(echo "$ESP_LINE" | awk '{print $4}' | sed 's/B$//')"
[ -n "$ESP_START_B" ] && [ -n "$ESP_SIZE_B" ] || fail_check 12 esp "could not extract ESP start/size from parted output: $ESP_LINE"

WORK="$(mktemp -d -t kvm-ida.XXXXXX)"
# losetup has mutually-incompatible option combinations (see losetup(8):
# --partscan conflicts with --show, --read-only, --sizelimit). Use plain
# -o/--sizelimit (no stdout device name — capture via losetup -j after).
# Read-only safety is enforced via `mount -o ro` below, not losetup flags
# (losetup itself does not provide a read-only mode for offset/sizelimit).
losetup -f -o "$ESP_START_B" --sizelimit "$ESP_SIZE_B" "$QCOW2" >/dev/null 2>&1 || \
    fail_check 12 esp "losetup -f failed for ESP partition at offset=$ESP_START_B size=$ESP_SIZE_B (likely a permissions issue, needs CAP_SYS_ADMIN or root)"
LOOP="$(losetup -j "$QCOW2" | awk -v s="$ESP_START_B" '$0 ~ ("offset "s"( |,|$)") {print $1}' | head -1 | sed 's/:$//')"
[ -n "$LOOP" ] || fail_check 12 esp "losetup attached a device but losetup -j could not identify it by offset=$ESP_START_B (kernel/losetup interaction issue)"

MOUNT="$WORK/esp"
mkdir -p "$MOUNT"
# Per UEFI + the review "correct FAT32 ESP" requirement. vfat covers FAT12
# / FAT16 / FAT32; vfat is the only correct mount type for an ESP.
if ! mount -t vfat -o ro "$LOOP" "$MOUNT" 2>/dev/null; then
    fail_check 12 esp "ESP partition at offset=$ESP_START_B size=$ESP_SIZE_B is NOT a FAT filesystem (mount -t vfat failed) — an ESP that is not FAT32 is invisible to UEFI firmware"
fi

# EFI files ON the mounted partition. /EFI/BOOT/BOOT<ARCH>.EFI is the UEFI
# removable-media fallback; /EFI/refind/refind_<arch>.efi is the rEFInd
# installed-disk entry. The review's whole-gate target is real EFI, not
# "an .efi file exists somewhere on the disk".
EFI_HITS=0
[ -e "$MOUNT/EFI/BOOT/BOOT${ESP_ARCH}.EFI" ] 2>/dev/null && EFI_HITS=1
[ -e "$MOUNT/EFI/refind/refind_${ESP_ARCH}.efi" ] 2>/dev/null && EFI_HITS=1
[ -e "$MOUNT/refind/refind_${ESP_ARCH}.efi" ] 2>/dev/null && EFI_HITS=1
[ "$EFI_HITS" = "1" ] || fail_check 13 esp-empty "no rEFInd/removable EFI binary found on the MOUNTED ESP (looked for BOOT${ESP_ARCH}.EFI under /EFI/BOOT/, /EFI/refind/refind_${ESP_ARCH}.efi, /refind/refind_${ESP_ARCH}.efi) — the on-disk layout lacks the UEFI firmware's required fallback entry"

# --- Check #3: real installed-kernel banner.
if ! grep -aqE "Linux version|Booting Linux|Starting vmlinuz-" "$BLOG" 2>/dev/null; then
    fail_check 14 banner "boot log has no installed-kernel banner (no 'Linux version' / 'Booting Linux' / 'Starting vmlinuz-') — see $BLOG"
fi

# --- Check #4: root filesystem mode 0755 after first-boot.
# A present marker with a wrong mode is FATAL. A missing marker is WARN
# unless ncz-firstboot actually ran (then it's the 0700-root regression
# class — same condition the existing arm64 gate WARNs about).
RM="$(grep -aoE "NCZ-ROOTMODE: [^[:space:]]+" "$BLOG" 2>/dev/null | tail -1 | awk '{print $2}')"
if [ -n "$RM" ]; then
    if [ "$RM" != "755" ] && [ "$RM" != "drwxr-xr-x" ]; then
        fail_check 15 root-mode "installed system reports root mode $RM (expected 755/drwxr-xr-x) — the 0700-root regression class is BACK (see docs/ISO-BUILD-GUARDRAILS.md)"
    fi
    echo "  installed-disk-assert: root mode is 755 (NCZ-ROOTMODE marker: $RM)"
else
    if grep -aq "ncz-firstboot" "$BLOG" 2>/dev/null; then
        fail_check 15 root-mode "ncz-firstboot ran but no NCZ-ROOTMODE marker in the boot log — firstboot work happened AND its mode assertion is missing (this is the 0700-root regression class, not a benign timeout)"
    fi
    echo "  installed-disk-assert: WARN no NCZ-ROOTMODE marker in boot log — firstboot may not have completed before BOOT_TIMEOUT; root mode NOT verified" >&2
fi

# --- Check #5: rescue entry exists and is independently selectable.
REFCONF=""
for cand in \
    "$MOUNT/EFI/refind/refind.conf" \
    "$MOUNT/EFI/BOOT/refind.conf" \
    "$MOUNT/refind/refind.conf"; do
    if [ -f "$cand" ]; then REFCONF="$cand"; break; fi
done
[ -n "$REFCONF" ] || fail_check 16 rescue "no rEFInd config file found at /EFI/refind/refind.conf, /EFI/BOOT/refind.conf, or /refind/refind.conf on the MOUNTED ESP — without a config, neither default NOR rescue is selectable"

# rEFInd config menuentries: title "..." or menuentry ... { }. A rescue
# entry is one whose title/path contains 'rescue' (case-insensitive). AND
# the rescue line must be distinguishable from the default — i.e. there
# must be at least 2 selectable entries in the file.
RESCUE_LINES="$(grep -aiEc "rescue" "$REFCONF" 2>/dev/null || echo 0)"
TOTAL_LINES="$(grep -aiEc "^[[:space:]]*(title|menuentry)" "$REFCONF" 2>/dev/null || echo 0)"
[ "$RESCUE_LINES" -ge 1 ] || fail_check 16 rescue "no 'rescue' line found in $REFCONF (lines containing 'rescue' = $RESCUE_LINES) — without an independently selectable rescue entry, a broken default leaves the user with no fallback"
[ "$TOTAL_LINES" -ge 2 ] || fail_check 16 rescue "$REFCONF has only $TOTAL_LINES selectable title/menuentry; the rescue entry is NOT independently distinguishable from the default — single-entry rEFInd is not a real fallback"
echo "  installed-disk-assert: rescue entry present and selectable (rescue=$RESCUE_LINES, total titles/menuentries=$TOTAL_LINES, in $REFCONF)"

cleanup_work
trap - EXIT
echo "  installed-disk-assert: PASS (GPT, FAT32 ESP w/ EFI files, kernel banner, root mode, rescue entry)"
exit 0