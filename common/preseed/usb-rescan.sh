#!/bin/sh
# usb-rescan.sh — make the installation medium appear when the root-hub port
# scan never happened, and record why the console went dark.
#
# THE USB HALF
# On O6N the xHCI port carrying the USB stick sits at:
#     portsc = 0x0c0006e1  Speed=1 Link=Polling CCS PP WDE WOE
# CCS=1 means the device IS connected and PP=1 means the port is powered, but
# PED=0/PLS=Polling mean it was never reset or enabled -- the hub driver was
# never told to look, so dmesg has no port errors at all. Unbinding and
# rebinding the hub driver forces a fresh scan and the whole tree enumerates.
# Measured on O6N: /proc/partitions went from zero sd* to sda + 3 partitions.
#
# Kernel patch 0192 should make this unnecessary by stopping the CIXH2030
# wrapper runtime-suspending out from under its active xHCI child. This stays
# as a belt-and-braces fallback: if the medium is already visible it does
# nothing at all.
#
# THE VIDEO HALF
# Separate fault, same boot: linlondp loads and creates /dev/dri/card0..2 and
# fb0 (linlondpdrmfb), fbcon binds -- and the screen still stops a couple of
# seconds in. Dump the connector state early, while it is cheap to read, so
# one boot answers both questions instead of two.
#
# Runs under busybox ash in the d-i initrd. Only sh/echo/cat/ls/sleep/grep.
LOG=/var/log/ncz-usb-video.log
exec >>"$LOG" 2>&1
echo "=== usb-rescan $(date -u +%FT%TZ 2>/dev/null) ==="

have_disk() {
    grep -q ' sd[a-z]$' /proc/partitions 2>/dev/null
}

# --- console diagnostic, written STRAIGHT AT THE UART -----------------------
# The Install entry deliberately has no console on the serial line, which also
# means no way to see what went wrong there. Writing to /dev/ttyAMA0 as a
# DEVICE still reaches the wire even when nothing is configured as a console on
# it, so this reports regardless of console setup. Five ISOs were shipped
# guessing at this; instrument it instead.
for _u in /dev/ttyAMA0 /dev/ttyAMA2; do
    [ -c "$_u" ] || continue
    {
        echo ""
        echo "=== NCZ CONSOLE DIAG ==="
        echo "-- /proc/consoles:"
        cat /proc/consoles 2>/dev/null
        echo "-- /sys/class/tty/console/active: $(cat /sys/class/tty/console/active 2>/dev/null)"
        echo "-- /dev/tty1 exists: $([ -c /dev/tty1 ] && echo yes || echo NO)"
        echo "-- /proc/fb: $(cat /proc/fb 2>/dev/null | tr '\n' ';')"
        echo "-- cmdline consoles: $(tr ' ' '\n' < /proc/cmdline | grep -c console=)"
        echo "-- reopen-console decisions:"
        grep -a reopen-console /var/log/syslog 2>/dev/null | tail -12
        echo "-- inittab d-i entries:"
        grep -a "debian-installer" /etc/inittab 2>/dev/null
        echo "=== END CONSOLE DIAG ==="
        echo ""
    } > "$_u" 2>/dev/null
done

# --- video diagnostic first: cheap, and unaffected by the USB path ----------
echo "--- video"
echo "  /proc/fb:      $(cat /proc/fb 2>/dev/null | tr '\n' ';')"
echo "  graphics:      $(ls /sys/class/graphics/ 2>/dev/null | tr '\n' ' ')"
for v in /sys/class/vtconsole/vtcon*; do
    [ -e "$v/name" ] || continue
    echo "  $(basename "$v") bind=$(cat "$v/bind" 2>/dev/null) name=$(cat "$v/name" 2>/dev/null)"
done
for c in /sys/class/drm/*/status; do
    [ -e "$c" ] || continue
    d=$(dirname "$c")
    echo "  $(basename "$d") status=$(cat "$c" 2>/dev/null) enabled=$(cat "$d/enabled" 2>/dev/null) modes=$(cat "$d/modes" 2>/dev/null | head -1)"
done

# --- usb ------------------------------------------------------------------
echo "--- usb"
# Running from /lib/debian-installer-startup.d this fires very early, before
# the kernel's own root-hub scan has necessarily finished. Give it a fair
# chance first -- if patch 0193's power-on-good floor is enough, the disk turns
# up here and we do nothing at all. Only force a rebind once it plainly has not.
w=0
while [ "$w" -lt 10 ]; do
    have_disk && break
    sleep 1
    w=$((w + 1))
done
echo "  waited ${w}s for the kernel's own scan"

if have_disk; then
    echo "  medium already present, no rescan needed:"
    grep ' sd' /proc/partitions | sed 's/^/    /'
else
    echo "  no sd* present; forcing a root-hub rescan"
    echo "  ports before:"
    ls /sys/bus/usb/devices/ 2>/dev/null | grep -v ':' | tr '\n' ' ' | sed 's/^/    /'
    echo
    # Unbind every root-hub interface, then bind them all back. A fresh bind
    # runs hub_activate(), which reads port status and services the connect
    # that was missed at boot.
    for i in /sys/bus/usb/drivers/hub/*-0:1.0; do
        [ -e "$i" ] || continue
        echo "${i##*/}" > /sys/bus/usb/drivers/hub/unbind 2>/dev/null
    done
    sleep 1
    for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
        echo "$n-0:1.0" > /sys/bus/usb/drivers/hub/bind 2>/dev/null
    done
    # Give khubd time to walk the tree and for SCSI to attach.
    n=0
    while [ "$n" -lt 15 ]; do
        have_disk && break
        sleep 1
        n=$((n + 1))
    done
    echo "  ports after:"
    ls /sys/bus/usb/devices/ 2>/dev/null | grep -v ':' | tr '\n' ' ' | sed 's/^/    /'
    echo
    if have_disk; then
        echo "  RESCAN WORKED after ${n}s:"
        grep ' sd' /proc/partitions | sed 's/^/    /'
    else
        echo "  RESCAN DID NOT PRODUCE A DISK -- medium still missing"
    fi
fi
echo "=== usb-rescan done ==="
