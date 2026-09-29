#!/bin/bash
# ncz-gpu-report.sh — one-shot GPU stack report for an NCZ-OS Sky1 board.
#
# Written for the 2026-08-29 field report where glmark2 segfaulted and
# glmark2-es2 failed with eglGetDisplay() 0x3000 while libMali appeared to be
# absent. The point is to distinguish, with evidence rather than inference:
#
#   (a) the board is in vendor GPU mode but the vendor userland is missing
#   (b) the vendor userland is present but not on the loader path
#   (c) the board is in mesa/panthor mode and something else is wrong
#
# Read-only. Safe to run on a user's machine. Prints a report to stdout.
echo "=== identity"
cat /sys/class/dmi/id/product_name 2>/dev/null
uname -a
grep -m1 PRETTY_NAME /etc/os-release 2>/dev/null
dpkg -l | awk '/linux-image|ncz-singularity|chromium-ncz/ {print $2, $3}' 2>/dev/null

echo; echo "=== requested GPU mode (kernel cmdline)"
tr ' ' '\n' < /proc/cmdline | grep -E "sky1.gpu|module_blacklist|panthor|mali" || echo "(no sky1.gpu on cmdline)"

echo; echo "=== which KMD is actually bound"
for d in /sys/bus/platform/drivers/panthor /sys/bus/platform/drivers/mali /sys/bus/platform/drivers/mali_kbase; do
    [ -d "$d" ] && echo "$d -> $(ls "$d" | grep -v bind | grep -v uevent | tr '\n' ' ')"
done
lsmod | grep -E "panthor|mali_kbase|panfrost" || echo "(no GPU kernel module loaded)"
ls -la /dev/mali0 2>/dev/null || echo "(no /dev/mali0)"
echo "-- DRM nodes and their drivers"
for c in /sys/class/drm/card[0-9]* /sys/class/drm/renderD*; do
    [ -e "$c/device/driver" ] || continue
    echo "$(basename "$c") -> $(basename "$(readlink -f "$c/device/driver")")"
done

echo; echo "=== vendor userland (cix-gpu-umd) present?"
dpkg -l cix-gpu-umd 2>/dev/null | tail -1
ls -la /opt/cixgpu-pro/lib/aarch64-linux-gnu/libmali.so* 2>/dev/null || echo "MISSING: /opt/cixgpu-pro/.../libmali.so*"
ls -la /opt/cixgpu-compat 2>/dev/null | head -3

# ldconfig is in /usr/sbin, which is NOT on a normal user's PATH. Calling it
# bare made this script report libEGL/libmali as "not found" on a board where
# they demonstrably work -- a false negative that would have sent someone
# chasing a missing library that was present all along.
LDCONFIG=$(command -v ldconfig || echo /usr/sbin/ldconfig)
[ -x "$LDCONFIG" ] || LDCONFIG=/sbin/ldconfig

echo; echo "=== loader path: is the vendor userland actually reachable?"
for f in /etc/ld.so.conf.d/*cixgpu*; do
    [ -e "$f" ] || continue
    echo "--- $f"; cat "$f"
    while read -r d; do
        [ -n "$d" ] || continue
        if [ ! -d "$d" ]; then
            echo "    !! $d does not exist"
        elif [ -z "$(ls -A "$d" 2>/dev/null)" ]; then
            echo "    !! $d exists but is EMPTY (dangling loader path)"
        fi
    done < "$f"
done
echo "-- ldconfig cache says:"
"$LDCONFIG" -p 2>/dev/null | grep -iE "libmali|libEGL\.so|libGLESv2\.so|libgbm" | head -10

echo; echo "=== what EGL/GL actually resolves to"
for lib in libEGL.so.1 libGLESv2.so.2 libgbm.so.1; do
    p=$("$LDCONFIG" -p 2>/dev/null | awk -v l="$lib" '$1==l {print $NF; exit}')
    echo "$lib -> ${p:-not found}"
done
command -v eglinfo >/dev/null && eglinfo 2>&1 | head -12 || echo "(eglinfo not installed)"
command -v es2_info >/dev/null && es2_info 2>&1 | head -8

echo; echo "=== ICD / driver config files"
ls -la /etc/vulkan/icd.d/ /usr/share/vulkan/icd.d/ 2>/dev/null
ls -la /etc/ld.so.conf.d/ 2>/dev/null

echo; echo "=== switcher state, if installed"
for t in ncz-gpu-select ncz-gpu-profile ncz-gpu-env ncz-gpu-probe; do
    command -v "$t" >/dev/null && { echo "--- $t"; "$t" --status 2>&1 | head -12 || "$t" 2>&1 | head -12; }
done

echo; echo "=== kernel messages that matter"
dmesg 2>/dev/null | grep -iE "panthor|mali|linlondp|drm|gpu" | tail -30 ||
    echo "(dmesg restricted; run with sudo for this section)"
