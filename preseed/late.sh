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
# 2026-05-04 codex review: rm -rf + cp -a so reruns don't nest cixmini/
# inside existing /target/usr/local/lib/cix-installer/.
rm -rf /target/usr/local/lib/cix-installer
cp -a "$SRC" /target/usr/local/lib/cix-installer
chmod 755 /target/usr/local/lib/cix-installer/post-install/*.sh
echo "    copy ok"
echo

# Stamp the install with the build serial + dual-kernel KVERs so
# 10-our-kernel.sh + 70-bootloader.sh can read them. Files land at
# both /etc/cix-installer/ (easy `cat` from running system) and
# /usr/local/lib/cix-installer/ (where post-install scripts read).
mkdir -p /target/etc/cix-installer
for f in BUILD_VERSION BUILD_DATE BUILD_HOST KVER_LTS KVER_NEXT; do
    if [ -f "$SRC/$f" ]; then
        cp "$SRC/$f" /target/etc/cix-installer/"$f"
        cp "$SRC/$f" /target/usr/local/lib/cix-installer/"$f"
    fi
done

# r77: capture install-time variant choice from kernel cmdline.
# When the unified ISO offers a GRUB chooser between Desktop (Reinhardt)
# and Server (Magnetar), the operator's pick lands as ncz_variant=
# desktop|server on the kernel cmdline. 48-magnetar-variant.sh reads
# the BUILD_VARIANT sidecar at first boot and applies the headless
# toggle when value is "server".
#
# Default: if the cmdline didn't carry ncz_variant (because this isn't
# a unified-chooser ISO, or the operator boot directly to a non-chooser
# entry), fall back to the build's bake-time --variant. The
# BUILD_VARIANT sidecar may already be set on $SRC by build-iso-di.sh
# at bake time; only overwrite it when the kernel cmdline explicitly
# selected one.
ncz_variant=$(sed -n 's/.*\(^\| \)ncz_variant=\([a-z]*\).*/\2/p' /proc/cmdline 2>/dev/null || echo "")
case "$ncz_variant" in
    desktop|server)
        echo "$ncz_variant" > /target/usr/local/lib/cix-installer/BUILD_VARIANT
        echo "    ncz_variant=$ncz_variant captured from kernel cmdline"
        ;;
    *)
        if [ -f "$SRC/BUILD_VARIANT" ]; then
            echo "    ncz_variant from bake-time BUILD_VARIANT: $(cat $SRC/BUILD_VARIANT)"
        else
            echo "desktop" > /target/usr/local/lib/cix-installer/BUILD_VARIANT
            echo "    ncz_variant defaulted to 'desktop' (no cmdline, no bake stamp)"
        fi
        ;;
esac
if [ -f /target/etc/cix-installer/BUILD_VERSION ]; then
    echo "    build stamp: $(cat /target/etc/cix-installer/BUILD_VERSION) ($(cat /target/etc/cix-installer/BUILD_DATE 2>/dev/null))"
fi
if [ -f /target/etc/cix-installer/KVER_LTS ]; then
    echo "    KVER_LTS:  $(cat /target/etc/cix-installer/KVER_LTS)"
fi
if [ -f /target/etc/cix-installer/KVER_NEXT ] && [ -s /target/etc/cix-installer/KVER_NEXT ]; then
    echo "    KVER_NEXT: $(cat /target/etc/cix-installer/KVER_NEXT) [BETA]"
fi
echo

echo "--- post-copy md5 of /target/.../10-our-kernel.sh ---"
md5sum /target/usr/local/lib/cix-installer/post-install/10-our-kernel.sh 2>&1 || echo "md5sum unavailable"
wc -c /target/usr/local/lib/cix-installer/post-install/10-our-kernel.sh 2>&1 || true
echo

# Codex A2 CRITICAL #2 fix: Mount /cdrom inside /target so post-install
# hooks can `apt-get install` from our offline mirror via file:///cdrom.
# Without this, FULL/THIN mode 10-our-kernel.sh + 70-bootloader.sh +
# 20-desktop.sh fail because they need offline pkgs.
#
# 2026-05-07 take7: in NETINSTALL mode the build script doesn't ship a
# main component on /cdrom (forces base-installer onto http mirror).
# Detect that case and skip the cdrom apt source — apt-setup has
# already wired ports.ubuntu.com via mirror/* preseed values.
if [ -f /cdrom/dists/questing/main/binary-arm64/Packages ] || \
   [ -f /cdrom/dists/questing/main/binary-arm64/Packages.gz ]; then
    echo "--- mounting cdrom into /target for offline apt-get during post-install ---"
    mkdir -p /target/cdrom
    mount --bind /cdrom /target/cdrom 2>&1 || \
        { echo "WARN: bind-mount /cdrom into /target failed; post-install apt-get may fail"; }

    # Add file:///cdrom apt source to /target's sources.list so apt-get
    # install in chroot can find packages locally. [trusted=yes] bypasses
    # GPG (we don't sign our offline mirror Release file yet).
    cat > /target/etc/apt/sources.list.d/cixmini-cdrom.list <<'CDROM_LIST'
deb [trusted=yes] file:///cdrom questing main
CDROM_LIST
    echo "    /target/etc/apt/sources.list.d/cixmini-cdrom.list installed"
    in-target apt-get update 2>&1 | tail -3 || \
        { echo "WARN: in-target apt-get update from cdrom failed"; }
    CDROM_BIND_MOUNTED=1
else
    echo "--- netinstall mode: cdrom has no main component, skipping cdrom apt source ---"
    echo "    (post-install hooks rely on ports.ubuntu.com via apt-setup)"
    CDROM_BIND_MOUNTED=0
fi

echo "--- running post-install in chroot ---"
in-target /usr/local/lib/cix-installer/post-install/run-all.sh
RET=$?

# Codex A2 fix: don't leave bind-mount around after late_command finishes
if [ "${CDROM_BIND_MOUNTED:-0}" = "1" ]; then
    umount /target/cdrom 2>&1 || true
    rmdir /target/cdrom 2>&1 || true
fi
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


# r56: hydrate /etc/skel content into existing user homes that d-i created before late_command fired.
# Without this, post-install hooks that populate /etc/skel/Desktop and /etc/skel/.config don't
# reach the user (because d-i's user-creation step copies /etc/skel BEFORE late_command runs).
if [ "$RET" = "0" ]; then
    for home in /target/home/*; do
        [ -d "$home" ] || continue
        user=$(basename "$home")
        in-target rsync -a --ignore-existing /etc/skel/ /home/"$user"/ 2>/dev/null || true
        in-target chown -R "$user":"$user" /home/"$user" 2>/dev/null || true
    done
fi

# r56: loud REMOVE-USB banner so user sees it on every TTY before d-i reboots.
# d-i preseed (reboot_in_progress no longer set to note) will then prompt the
# user to dismiss before the actual reboot fires.
if [ "$RET" = "0" ]; then
    BANNER='\n\n  ============================================================\n  \n    NCZ 26.5 INSTALL COMPLETE\n    \n    >>> REMOVE THE USB STICK NOW <<<\n    \n    Then press Enter on the next dialog to reboot.\n    \n    If you forget, the system will boot back into the\n    installer (USB has higher boot priority than NVMe).\n  \n  ============================================================\n'
    for tty in /dev/tty1 /dev/tty2 /dev/tty3 /dev/tty4 /dev/tty5 /dev/console; do
        if [ -w "$tty" ]; then
            printf '%b' "$BANNER" >> "$tty" 2>/dev/null || true
        fi
    done
    sleep 5
fi
exit $RET
