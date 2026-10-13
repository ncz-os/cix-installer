#!/bin/sh
# media-usb-only.sh -- NCZ-OS installs from a USB drive only.
#
#   media-usb-only.sh mount   mount the NCZ-OS image from a USB drive read-only
#                             at /cdrom; exit 0 when mounted, 1 when not found
#   media-usb-only.sh gate    run before cdrom-detect: when no USB drive with
#                             the image is mounted at /cdrom, show the USB-only
#                             screen until one appears (rescan every 10 s), or
#                             the user opens a shell or reboots
#
# Why USB only: d-i's own media detection only looks at USB partitions and
# whole disks, and an image written to the internal NVMe/SD/eMMC disk is the
# same disk a user is about to install onto. Refusing it keeps detection
# predictable and keeps the installer from erasing the disk it booted from.
#
# Images found on non-USB disks are only identified (ext4 superblock read with
# dd, no mount) and listed on the screen; their parent disks are written to
# $NCZ_NONUSB_MEDIA so disk-fs-chooser.sh never offers them as a target.
#
# Test hooks: NCZ_CDROM, NCZ_MEDIA_LOG, NCZ_NONUSB_MEDIA, NCZ_CONSOLE,
# NCZ_GATE_MAX_ROUNDS, NCZ_GATE_TIMEOUT, NCZ_REBOOT_CMD, NCZ_SHELL_CMD,
# NCZ_USB_RESCAN, NCZ_PROC_MOUNTS, NCZ_SYS_BLOCK.
# POSIX sh (busybox ash in d-i).

CDROM=${NCZ_CDROM:-/cdrom}
LOG=${NCZ_MEDIA_LOG:-/var/log/early_command.log}
NONUSB=${NCZ_NONUSB_MEDIA:-/tmp/ncz-nonusb-media}
CONSOLE=${NCZ_CONSOLE:-/dev/console}
MAX_ROUNDS=${NCZ_GATE_MAX_ROUNDS:-0}
TIMEOUT=${NCZ_GATE_TIMEOUT:-10}
RESCAN=${NCZ_USB_RESCAN:-/tmp/usb-rescan.sh}
MOUNTS=${NCZ_PROC_MOUNTS:-/proc/mounts}
SYSBLOCK=${NCZ_SYS_BLOCK:-/sys/class/block}

log() { echo "media-usb-only: $*" >> "$LOG" 2>/dev/null || true; }

# is_usb <dev>: the block device sits on a USB bus (USB UAS devices may report
# another bus type, so ID_PATH is checked too).
is_usb() {
    udevadm info -q env -n "$1" 2>/dev/null | grep -qE '^ID_BUS=usb$|^ID_PATH=.*usb'
}

usb_candidates() {
    list-devices usb-partition 2>/dev/null
    for _d in $(list-devices disk 2>/dev/null); do
        is_usb "$_d" && echo "$_d"
    done
}

has_payload() {
    [ -f "$CDROM/ncz-payload/preseed.cfg" ] && [ -f "$CDROM/dists/forky/Release" ]
}

cdrom_source() {
    awk -v m="$CDROM" '$2 == m { print $1; exit }' "$MOUNTS" 2>/dev/null
}

# parent_disk <partition>: /dev/nvme1n1p2 -> /dev/nvme1n1 (sysfs first).
parent_disk() {
    _n=${1##*/}
    if [ -f "$SYSBLOCK/$_n/partition" ]; then
        _pp=$(readlink -f "$SYSBLOCK/$_n" 2>/dev/null)
        _parent=$(basename "$(dirname "$_pp")" 2>/dev/null)
        [ -n "$_parent" ] && [ "$_parent" != block ] && { echo "/dev/$_parent"; return 0; }
    fi
    case "$_n" in
        nvme*n*p[0-9]*|mmcblk*p[0-9]*) echo "${1%p[0-9]*}" ;;
        *) echo "$1" | sed 's/[0-9]*$//' ;;
    esac
}

do_mount() {
    _src=$(cdrom_source)
    if [ -n "$_src" ]; then
        if has_payload && is_usb "$_src"; then
            log "image already mounted from USB device $_src"
            return 0
        fi
        log "unmounting $_src from $CDROM (not a USB drive with the NCZ-OS image)"
        umount "$CDROM" 2>/dev/null || true
    fi
    mkdir -p "$CDROM" 2>/dev/null || true
    for _m in $(usb_candidates); do
        mount -t ext4 -o ro,noload "$_m" "$CDROM" 2>>"$LOG" || continue
        if has_payload; then
            log "mounted the NCZ-OS image from USB device $_m at $CDROM"
            rm -f "$NONUSB" 2>/dev/null || true
            return 0
        fi
        umount "$CDROM" 2>/dev/null || true
    done
    return 1
}

# ext4 superblock: magic 0xEF53 at byte 1080, volume label at byte 1144.
is_ncz_image_part() {
    _magic=$(dd if="$1" bs=1 skip=1080 count=2 2>/dev/null)
    [ "$_magic" = "$(printf '\123\357')" ] || return 1
    _label=$(dd if="$1" bs=1 skip=1144 count=16 2>/dev/null | tr -d '\000')
    [ "$_label" = NCZDATA ]
}

find_nonusb_images() {
    : > "$NONUSB.tmp" 2>/dev/null || true
    for _p in $(list-devices partition 2>/dev/null); do
        is_usb "$_p" && continue
        is_ncz_image_part "$_p" || continue
        echo "$_p $(parent_disk "$_p")" >> "$NONUSB.tmp"
    done
    if [ -s "$NONUSB.tmp" ]; then
        awk '{print $2}' "$NONUSB.tmp" | sort -u > "$NONUSB"
    else
        rm -f "$NONUSB" 2>/dev/null || true
    fi
}

diag_hint() {
    _ip=$( (ip -4 -o addr show 2>/dev/null || true) | awk '$2 != "lo" { sub(/\/.*/, "", $4); print $4; exit }')
    echo "Diagnostics: press Alt-F3 for the diagnostics console (remote login details);"
    echo "             Alt-F4 shows the installer log.${_ip:+ Address: $_ip}"
}

draw() {
    {
        printf '\033[2J\033[H'
        echo "=========================================================================="
        echo " NCZ-OS installer: no USB installation drive found"
        echo "=========================================================================="
        echo
        echo " NCZ-OS must be installed from a USB drive. Write the image to a USB stick,"
        echo " boot from it, and choose the internal disk as the target. Installing from"
        echo " an internal disk or SD card is not supported."
        echo
        if [ -s "$NONUSB.tmp" ]; then
            while read -r _p _d; do
                echo "   found image on ${_p##*/} (not USB, disk ${_d##*/} will not be erased)"
            done < "$NONUSB.tmp"
        else
            echo "   no NCZ-OS image found on any USB drive"
        fi
        echo
        diag_hint
        echo
        echo "   R = scan the USB ports again (a new USB drive is also picked up every ${TIMEOUT} s)"
        echo "   S = open a shell (type 'exit' to return to this screen)"
        echo "   B = reboot (then boot from the USB drive)"
        echo
        printf ' Choice [R/S/B]: '
    } > "$CONSOLE" 2>/dev/null
}

gate() {
    if do_mount; then
        return 0
    fi
    log "no USB drive with the NCZ-OS image; showing the USB-only screen"
    _round=0
    while :; do
        find_nonusb_images
        [ -s "$NONUSB.tmp" ] && log "image on non-USB device(s): $(awk '{print $1}' "$NONUSB.tmp" | tr '\n' ' ')"
        draw
        _ans=""
        # busybox ash supports read -t (d-i shell).
        # shellcheck disable=SC3045
        read -t "$TIMEOUT" -r _ans < "$CONSOLE" 2>/dev/null || true
        case "$_ans" in
            r|R)
                # Explicit rescan only: usb-rescan.sh rebinds the USB hub driver,
                # which would also drop a USB keyboard if it ran every round.
                log "user asked for a USB rescan"
                [ -x "$RESCAN" ] && "$RESCAN" </dev/null >/dev/null 2>&1
                ;;
            s|S)
                log "user opened a shell"
                ${NCZ_SHELL_CMD:-sh -i} < "$CONSOLE" > "$CONSOLE" 2>&1 || true
                ;;
            b|B)
                log "user chose reboot"
                ${NCZ_REBOOT_CMD:-reboot -f} 2>/dev/null || echo b > /proc/sysrq-trigger
                ;;
        esac
        if do_mount; then
            printf '\n USB installation drive found, continuing.\n' > "$CONSOLE" 2>/dev/null
            rm -f "$NONUSB.tmp" 2>/dev/null || true
            return 0
        fi
        _round=$((_round + 1))
        [ "$MAX_ROUNDS" -gt 0 ] && [ "$_round" -ge "$MAX_ROUNDS" ] && return 1
    done
}

case "${1:-}" in
    mount) do_mount ;;
    gate) gate ;;
    *) echo "usage: $0 mount|gate" >&2; exit 2 ;;
esac
