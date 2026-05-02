#!/bin/sh
# late.sh — run from preseed late_command in the d-i runtime context.
#
# d-i's late_command runs after base install + apt config + bootloader
# but before reboot. /target is mounted; /cdrom *should* be the install
# media, but eject behavior + multi-source detection (cdrom vs hd-media
# vs cd-from-iso) makes hard-coded paths fragile. This script:
#
#   1. logs everything to /target/var/log/cix-installer-late.log
#   2. probes ALL plausible locations for the bundled /cixmini dir
#   3. copies it into /target/usr/local/lib/cix-installer
#   4. invokes /usr/local/lib/cix-installer/post-install/run-all.sh
#      via in-target chroot
#   5. emits a clear, debuggable error if any step fails — including
#      mountpoint state, dir contents, and exit codes
#
# This script lives at /cdrom/cixmini/late.sh in the ISO; preseed's
# late_command invokes it via `sh /cdrom/cixmini/late.sh` (with
# multi-path fallback to find the script itself if /cdrom moved).

set -e

LOG=/target/var/log/cix-installer-late.log
mkdir -p /target/var/log
exec >"$LOG" 2>&1

echo "=== late.sh ($(date -u)) ==="
echo
echo "--- runtime context ---"
echo "PWD: $(pwd)"
echo "USER: $(id)"
echo "PATH: $PATH"
echo
echo "--- mounts ---"
mount | grep -E "cdrom|hd-media|media|target" || true
echo
echo "--- candidate source dirs ---"
for d in /cdrom/cixmini /hd-media/cixmini /media/cdrom/cixmini /run/live/medium/cixmini; do
    if [ -d "$d" ]; then
        echo "FOUND: $d"
        ls -la "$d" | head -10
    else
        echo "MISSING: $d"
    fi
done
echo

# Pick the first source that exists
SRC=""
for d in /cdrom/cixmini /hd-media/cixmini /media/cdrom/cixmini /run/live/medium/cixmini; do
    [ -d "$d" ] && SRC="$d" && break
done

if [ -z "$SRC" ]; then
    echo "FATAL: no /cixmini source found in any expected location."
    echo "Mounts:"
    mount
    echo
    echo "Failing late.sh — preseed late_command will report exit 1."
    exit 1
fi

echo "--- selected source: $SRC ---"
du -sh "$SRC" 2>/dev/null || true
echo
echo "--- pre-copy diagnostics: $SRC/post-install/ ---"
ls -la "$SRC/post-install/" 2>&1 | head -15
echo "--- pre-copy md5 of 10-our-kernel.sh on $SRC ---"
md5sum "$SRC/post-install/10-our-kernel.sh" 2>&1 || echo "md5sum unavailable"
wc -c "$SRC/post-install/10-our-kernel.sh" 2>&1 || true
echo

echo "--- copying $SRC → /target/usr/local/lib/cix-installer ---"
mkdir -p /target/usr/local/lib
cp -r "$SRC" /target/usr/local/lib/cix-installer
chmod 755 /target/usr/local/lib/cix-installer/post-install/*.sh
echo "    copy ok"
echo

echo "--- post-copy md5 of /target/.../10-our-kernel.sh ---"
md5sum /target/usr/local/lib/cix-installer/post-install/10-our-kernel.sh 2>&1 || echo "md5sum unavailable"
wc -c /target/usr/local/lib/cix-installer/post-install/10-our-kernel.sh 2>&1 || true
echo

echo "--- running post-install in chroot ---"
in-target /usr/local/lib/cix-installer/post-install/run-all.sh
RET=$?
echo "in-target run-all.sh exited: $RET"

# Eject the install media on success. We turned cdrom-detect/eject off
# in preseed.cfg so /cdrom would survive into late.sh — now that we're
# done with it, eject it manually. Without this, a real hardware reboot
# would still boot from the USB stick (UEFI BootOrder put it first), and
# in QEMU the next pass of `-boot d` would re-enter d-i for a second
# install pass on top of the just-installed system.
if [ "$RET" = "0" ]; then
    echo "--- ejecting install media ---"
    eject /cdrom 2>&1 || echo "eject /cdrom failed (non-fatal)"
fi

exit $RET
