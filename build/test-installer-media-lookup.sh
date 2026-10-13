#!/bin/bash
# test-installer-media-lookup.sh -- NCZ-OS installs from a USB drive only.
#
#   1. preseed/media-usb-only.sh mounts the image read-only (ro,noload) at
#      /cdrom from USB devices only; an image on an internal NVMe/SD/eMMC
#      disk is never mounted.
#   2. without a USB drive, "gate" shows the USB-only screen, lists images it
#      finds on non-USB disks (ext4 superblock read, no mount), offers rescan,
#      shell and reboot, and records the image's disk in the non-USB list.
#   3. a USB drive wins when an internal disk also carries an image.
#   4. disk-fs-chooser.sh never offers or erases a disk from the non-USB list.
#   5. preseed.cfg wires the helper in early_command, partman/early_command
#      only searches USB disks, the helper is baked into the initrd, and d-i's
#      GRUB and systemd-boot steps stay skipped.
#
# Usage: build/test-installer-media-lookup.sh
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HELPER="$ROOT/preseed/media-usb-only.sh"
PRESEED="$ROOT/preseed/preseed.cfg"
CHOOSER="$ROOT/preseed/disk-fs-chooser.sh"
KNOWN="$ROOT/build/preseed-known-keys.txt"
INITRD_PATCHER="$ROOT/build/iso/patch-initrd-t2-kernel.py"

PASS=0; FAIL=0
ok()  { echo "PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL  $1" >&2; FAIL=$((FAIL + 1)); }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

SB="$(mktemp -d "${TMPDIR:-$ROOT/build}/.media-lookup.XXXXXX")" || exit 2
trap 'rm -rf "$SB"' EXIT
# The helper runs under plain sh here: busybox sh would call its own mount and
# umount applets instead of the stubs below. busybox ash (d-i) parses it too.
SHX="sh"

check "preseed/media-usb-only.sh exists" test -f "$HELPER"
check "preseed/media-usb-only.sh parses (sh)" sh -n "$HELPER"
if command -v busybox >/dev/null 2>&1; then
    check "preseed/media-usb-only.sh parses (busybox ash)" busybox sh -n "$HELPER"
fi

# ---------------------------------------------------------------- fake devices
# Device nodes are plain files. An ext4 "image" partition carries the ext4
# magic at byte 1080 and the NCZDATA label at byte 1144, which is all the
# helper reads from a non-USB device.
mkdev() { # mkdev <name> <ncz|ext4|none>
    local f="$SB/dev/$1"
    mkdir -p "$SB/dev"; head -c 4096 /dev/zero > "$f"
    case "$2" in
        ncz|ext4)
            printf '\123\357' | dd of="$f" bs=1 seek=1080 conv=notrunc status=none
            [ "$2" = ncz ] && printf 'NCZDATA' | dd of="$f" bs=1 seek=1144 conv=notrunc status=none
            ;;
    esac
    echo "$f"
}
STUB="$SB/bin"; mkdir -p "$STUB"
cat > "$STUB/list-devices" <<'EOF'
#!/bin/sh
case "$1" in
    usb-partition) echo $T_USB ;;
    partition) echo $T_PARTS ;;
    disk) echo $T_DISKS ;;
esac
EOF
cat > "$STUB/udevadm" <<'EOF'
#!/bin/sh
# udevadm info -q env -n <dev>: USB when the device name is in $T_USBDEVS
for a in "$@"; do dev="$a"; done
case " $T_USBDEVS " in *" $dev "*) echo "ID_BUS=usb"; echo "ID_PATH=platform-xhci-hcd.1.auto-usb-0:1:1.0-scsi-0:0:0:0" ;;
    *) echo "ID_BUS=nvme"; echo "ID_PATH=pci-0000:01:00.0-nvme-1" ;; esac
EOF
cat > "$STUB/mount" <<'EOF'
#!/bin/sh
echo "$*" >> "$T_SB/mounts.log"
dev=""; dir=""
for a in "$@"; do case "$a" in -*|ext4|ro,noload|ro) ;; *) if [ -z "$dev" ]; then dev="$a"; else dir="$a"; fi ;; esac; done
case " $T_MEDIA " in *" $dev "*) ;; *) exit 32 ;; esac
mkdir -p "$dir/ncz-payload" "$dir/dists/forky"
: > "$dir/ncz-payload/preseed.cfg"; : > "$dir/dists/forky/Release"
echo "$dev $dir ext4 ro 0 0" >> "$T_SB/proc-mounts"
EOF
cat > "$STUB/umount" <<'EOF'
#!/bin/sh
for a in "$@"; do dir="$a"; done
rm -rf "${dir:?}"/* 2>/dev/null
grep -v " $dir " "$T_SB/proc-mounts" > "$T_SB/proc-mounts.new" 2>/dev/null; mv "$T_SB/proc-mounts.new" "$T_SB/proc-mounts"
EOF
cat > "$STUB/usb-rescan" <<'EOF2'
#!/bin/sh
echo rescan >> "$T_SB/rescan.log"
EOF2
chmod +x "$STUB"/*

# run_helper <mode> ; scenario comes from T_* variables
run_helper() {
    rm -rf "$SB/cdrom" "$SB/mounts.log" "$SB/console" "$SB/nonusb" "$SB/nonusb.tmp" "$SB/media.log" "$SB/rescan.log"
    mkdir -p "$SB/cdrom"; : > "$SB/console"; touch "$SB/proc-mounts"
    PATH="$STUB:$PATH" T_SB="$SB" T_USB="${T_USB:-}" T_PARTS="${T_PARTS:-}" T_DISKS="${T_DISKS:-}" \
      T_MEDIA="${T_MEDIA:-}" T_USBDEVS="${T_USBDEVS:-}" \
      NCZ_CDROM="$SB/cdrom" NCZ_MEDIA_LOG="$SB/media.log" NCZ_NONUSB_MEDIA="$SB/nonusb" \
      NCZ_CONSOLE="$SB/console" NCZ_GATE_MAX_ROUNDS=1 NCZ_GATE_TIMEOUT=1 \
      NCZ_REBOOT_CMD=true NCZ_SHELL_CMD=true NCZ_USB_RESCAN="$SB/bin/usb-rescan" \
      NCZ_PROC_MOUNTS="$SB/proc-mounts" NCZ_SYS_BLOCK="$SB/sys" \
      $SHX "$HELPER" "$1" 2>"$SB/run.err"
}
mounted() { awk -v m="$SB/cdrom" '$2 == m { print $1 }' "$SB/proc-mounts"; }

# ------------------------------------------- 1. image on a second NVMe only
NV1=$(mkdev nvme0n1p2 ext4); NVIMG=$(mkdev nvme1n1p2 ncz); NVESP=$(mkdev nvme1n1p1 none)
: > "$SB/proc-mounts"
T_USB="" T_PARTS="$NV1 $NVESP $NVIMG" T_DISKS="$SB/dev/nvme0n1 $SB/dev/nvme1n1" T_MEDIA="$NVIMG" T_USBDEVS=""
export T_USB T_PARTS T_DISKS T_MEDIA T_USBDEVS
run_helper gate; rc=$?
check "NVMe-only: gate does not continue the install (rc=$rc)" [ "$rc" -ne 0 ]
check "NVMe-only: nothing is mounted at /cdrom" [ -z "$(mounted)" ]
check "NVMe-only: no NVMe device was ever mounted" sh -c '! grep -q nvme "$1" 2>/dev/null' _ "$SB/mounts.log"
check "NVMe-only: screen says NCZ-OS must be installed from a USB drive" grep -q 'NCZ-OS must be installed from a USB drive' "$SB/console"
check "NVMe-only: screen says internal disk or SD card is not supported" grep -q 'an internal disk or SD card is not supported' "$SB/console"
check "NVMe-only: screen lists 'found image on nvme1n1p2 (not USB'" grep -q 'found image on nvme1n1p2 (not USB' "$SB/console"
check "NVMe-only: plain ext4 partition nvme0n1p2 is not reported as an image" sh -c '! grep -q "nvme0n1p2" "$1"' _ "$SB/console"
check "NVMe-only: screen offers rescan, shell and reboot" sh -c 'grep -q "R = scan the USB ports" "$1" && grep -q "S = open a shell" "$1" && grep -q "B = reboot" "$1"' _ "$SB/console"
check "NVMe-only: screen points to the diagnostics console" grep -q 'Alt-F3 for the diagnostics console' "$SB/console"
check "NVMe-only: image disk recorded as never-a-target ($(cat "$SB/nonusb" 2>/dev/null))" grep -qx "$SB/dev/nvme1n1" "$SB/nonusb"
check "NVMe-only: the USB hub rescan does not run without a key press" test ! -e "$SB/rescan.log"
check "NVMe-only: helper ran without shell errors" sh -c '! grep -qiE "syntax error|not found|unexpected" "$1"' _ "$SB/run.err"

# ------------------------------------------------ 2. USB drive only
USBESP=$(mkdev sda1 none); USBIMG=$(mkdev sda2 ncz)
: > "$SB/proc-mounts"
T_USB="$USBESP $USBIMG" T_PARTS="$USBESP $USBIMG" T_DISKS="$SB/dev/sda" T_MEDIA="$USBIMG" T_USBDEVS="$USBESP $USBIMG $SB/dev/sda"
run_helper mount; rc=$?
check "USB: mount succeeds (rc=$rc)" [ "$rc" -eq 0 ]
check "USB: /cdrom holds the USB image partition" [ "$(mounted)" = "$USBIMG" ]
check "USB: every mount is ro,noload" sh -c '! grep -v -- "-o ro,noload " "$1" | grep >/dev/null .' _ "$SB/mounts.log"
: > "$SB/proc-mounts"
run_helper gate; rc=$?
check "USB: gate continues without showing the screen (rc=$rc)" sh -c '[ "$1" -eq 0 ] && [ ! -s "$2" ]' _ "$rc" "$SB/console"

# ------------------------------------- 3. USB drive plus an image on NVMe
: > "$SB/proc-mounts"
T_USB="$USBESP $USBIMG" T_PARTS="$USBESP $USBIMG $NV1 $NVESP $NVIMG" T_DISKS="$SB/dev/sda $SB/dev/nvme0n1 $SB/dev/nvme1n1"
T_MEDIA="$USBIMG $NVIMG"
run_helper gate; rc=$?
check "USB+NVMe: install continues (rc=$rc)" [ "$rc" -eq 0 ]
check "USB+NVMe: the USB image wins" [ "$(mounted)" = "$USBIMG" ]
check "USB+NVMe: the NVMe image is never mounted" sh -c '! grep -q nvme "$1"' _ "$SB/mounts.log"
check "USB+NVMe: no never-a-target list left behind (the NVMe disk is installable)" [ ! -e "$SB/nonusb" ]

# --------------------- 4. /cdrom already holds the NVMe image (manual mount)
echo "$NVIMG $SB/cdrom ext4 ro 0 0" > "$SB/proc-mounts"
T_USB="" T_PARTS="$NV1 $NVESP $NVIMG" T_DISKS="$SB/dev/nvme0n1 $SB/dev/nvme1n1" T_MEDIA="$NVIMG" T_USBDEVS=""
PATH="$STUB:$PATH" T_SB="$SB" T_MEDIA="$T_MEDIA" T_USBDEVS="" T_PARTS="$T_PARTS" T_DISKS="$T_DISKS" \
  NCZ_CDROM="$SB/cdrom" NCZ_MEDIA_LOG="$SB/media.log" NCZ_NONUSB_MEDIA="$SB/nonusb" NCZ_CONSOLE="$SB/console" \
  NCZ_PROC_MOUNTS="$SB/proc-mounts" NCZ_SYS_BLOCK="$SB/sys" NCZ_USB_RESCAN="$SB/none" \
  $SHX "$HELPER" mount 2>/dev/null; rc=$?
check "manual NVMe mount: helper refuses it (rc=$rc) and unmounts /cdrom" sh -c '[ "$1" -ne 0 ] && [ -z "$2" ]' _ "$rc" "$(mounted)"

# ------------------------------------------------ 5. chooser never-a-target
check "disk-fs-chooser.sh reads the non-USB image list" grep -q 'NCZ_NONUSB_MEDIA:-/tmp/ncz-nonusb-media' "$CHOOSER"
check "disk-fs-chooser.sh drops non-USB image disks from the candidates" \
    grep -qE '^[[:space:]]*is_nonusb_media_disk "\$d" && continue' "$CHOOSER"
check "disk-fs-chooser.sh refuses a target that holds the installer image" \
    grep -qE 'is_nonusb_media_disk "\$CHOSEN_DISK"; then' "$CHOOSER"
# Run the chooser's own list/predicate code.
awk '/^NONUSB_MEDIA_FILE=/{on=1} on{print} on && /^}/{exit}' "$CHOOSER" > "$SB/pred.sh"
printf '%s\n' "$SB/dev/nvme1n1" > "$SB/nonusb"
check "chooser predicate: target == image disk is refused" \
    env NCZ_NONUSB_MEDIA="$SB/nonusb" bash -c '. "$1"; is_nonusb_media_disk "$2"' _ "$SB/pred.sh" "$SB/dev/nvme1n1"
check "chooser predicate: another disk is allowed" \
    env NCZ_NONUSB_MEDIA="$SB/nonusb" bash -c '. "$1"; ! is_nonusb_media_disk "$2"' _ "$SB/pred.sh" "$SB/dev/nvme0n1"

# ------------------------------------------------ 6. preseed wiring
check "early_command mounts install media through media-usb-only.sh" \
    grep -qF 'sh /tmp/media-usb-only.sh mount' "$PRESEED"
check "early_command runs the USB-only gate" grep -qF 'sh /tmp/media-usb-only.sh gate' "$PRESEED"
check "early_command no longer mounts list-devices disk/partition candidates itself" \
    sh -c '! grep -q "for _ncz_media in" "$1"' _ "$PRESEED"
check "partman/early_command searches USB disks only" \
    grep -qF 'for _blk in /sys/block/sd* ; do' "$PRESEED"
check "partman/early_command checks the USB bus before mounting" \
    grep -qF "udevadm info -q env -p \"\${_blk#/sys}\"" "$PRESEED"
check "media-usb-only.sh is baked into the initrd" grep -qE '^[[:space:]]*"media-usb-only\.sh",' "$INITRD_PATCHER"
for k in grub-installer/skip systemd-boot-installer/skip; do
    check "preseed.cfg answers $k true and seen" sh -c 'grep -qE "^d-i $2 boolean true\$" "$1" && grep -qE "^d-i $2 seen true\$" "$1"' _ "$PRESEED" "$k"
    check "$k is in the preseed known-keys allow-list" grep -qE "^[[:space:]]*$k([[:space:]]|\$)" "$KNOWN"
done

echo "media-lookup: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
