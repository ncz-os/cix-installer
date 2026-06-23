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
# 2026-05-07 take8 (per Codex R78-INVALID-RELEASE-AUDIT): minimal
# NETINSTALL ships an EMPTY main/binary-arm64/Packages and removes
# /cdrom/.disk/base_installable so base-installer uses the HTTP mirror.
# 2026-05-08 netinstall-bootstrap keeps base_installable absent but adds a
# small non-empty regular Packages index for pkgsel/include. In that mode,
# file:///cdrom is valid for pkgsel/post-install package fallback.
CDROM_REGULAR_INDEX=/cdrom/dists/resolute/main/binary-arm64/Packages
if [ -e /cdrom/.disk/base_installable ] || [ -s "$CDROM_REGULAR_INDEX" ]; then
    echo "--- mounting cdrom into /target for offline apt-get during post-install ---"
    mkdir -p /target/cdrom
    if grep -qs ' /target/cdrom ' /proc/mounts; then
        echo "    /target/cdrom already mounted"
    else
        mount --bind /cdrom /target/cdrom 2>&1 || \
            { echo "WARN: bind-mount /cdrom into /target failed; post-install apt-get may fail"; }
    fi

    # Add file:///cdrom apt source to /target's sources.list so apt-get
    # install in chroot can find packages locally. [trusted=yes] bypasses
    # GPG (we don't sign our offline mirror Release file yet).
    cat > /target/etc/apt/sources.list.d/cixmini-cdrom.list <<'CDROM_LIST'
deb [trusted=yes] file:///cdrom resolute main
CDROM_LIST
    mkdir -p /target/etc/apt/preferences.d
    cat > /target/etc/apt/preferences.d/00cixmini-bootstrap-pool.pref <<'CDROM_PREF'
Package: *
Pin: release o=nclawzero
Pin-Priority: 1001
CDROM_PREF
    echo "    /target/etc/apt/sources.list.d/cixmini-cdrom.list installed"
    if [ ! -e /cdrom/.disk/base_installable ] && [ -s "$CDROM_REGULAR_INDEX" ]; then
        chroot /target /usr/bin/apt-get \
            -o Dir::Etc::sourcelist="sources.list.d/cixmini-cdrom.list" \
            -o Dir::Etc::sourceparts="-" \
            -o APT::Get::List-Cleanup="0" \
            update 2>&1 | tail -3 || \
            { echo "WARN: local apt-get update from bootstrap pool failed"; }
    else
        in-target apt-get update 2>&1 | tail -3 || \
            { echo "WARN: in-target apt-get update from cdrom failed"; }
    fi
    CDROM_BIND_MOUNTED=1
else
    echo "--- netinstall mode: cdrom has no regular deb component, skipping cdrom apt source ---"
    echo "    (post-install hooks rely on ports.ubuntu.com via apt-setup)"
    CDROM_BIND_MOUNTED=0
fi

# 2026-05-07 take9 (per .66 take8 pkgsel cascade fail): pre-write apt
# retries config so post-install hooks 10-our-kernel.sh / 20-desktop.sh
# / etc retry transient DNS/network blips when fetching packages from
# ports.ubuntu.com. pkgsel itself runs BEFORE late.sh so this doesn't
# help that step — pkgsel/install-recommends=false in preseed handles
# pkgsel resilience by minimizing the dep cascade. This config covers
# everything our hooks do after.
mkdir -p /target/etc/apt/apt.conf.d/
cat > /target/etc/apt/apt.conf.d/99retries <<'APTRETRIES'
# nclawzero — apt resilience for transient DNS/network failures.
# Auto-injected by preseed/late.sh.
Acquire::Retries "5";
Acquire::http::Timeout "60";
Acquire::http::Pipeline-Depth "0";
APTRETRIES
echo "--- /target/etc/apt/apt.conf.d/99retries installed ---"

# 2026-05-07 take10: replace /target/etc/resolv.conf with a STATIC file
# containing multiple nameservers. d-i + Ubuntu chains symlink it to
# /run/systemd/resolve/stub-resolv.conf, but systemd-resolved isn't
# running inside the chroot — and the host stub points at only the
# DHCP-provided nameserver (one IP, often the LAN router). On flaky
# LAN DNS this single source dropped queries on .66 take8.
#
# A real file with three nameservers (LAN router + Google + Cloudflare)
# survives any one being slow. Once the system boots and systemd-resolved
# starts, /etc/resolv.conf gets re-symlinked to the stub during normal
# boot, so this is install-time only.
echo "--- writing static /target/etc/resolv.conf with fallback nameservers ---"
rm -f /target/etc/resolv.conf
cat > /target/etc/resolv.conf <<'RESOLVCONF'
# nclawzero install-time DNS — replaced by systemd-resolved on boot.
search nclawzero.lan
nameserver 192.168.207.1
nameserver 8.8.8.8
nameserver 1.1.1.1
options timeout:2 attempts:3
RESOLVCONF
echo "    /target/etc/resolv.conf:"
cat /target/etc/resolv.conf | sed 's/^/      /'

echo "--- running post-install in chroot ---"
in-target /usr/local/lib/cix-installer/post-install/run-all.sh
RET=$?

# Codex A2 fix: don't leave bind-mount around after late_command finishes
if [ "${CDROM_BIND_MOUNTED:-0}" = "1" ]; then
    umount /target/cdrom 2>&1 || true
    rmdir /target/cdrom 2>&1 || true
fi
echo "in-target run-all.sh exited: $RET"

# r130 fix (MrSBC/COS feedback 2026-06-23): strip ALL CD-ROM apt sources from
# /target before reboot. The offline mirror sources are required DURING
# post-install (file:///cdrom for our pool; d-i apt-setup may also add a
# `deb cdrom:[...]` line), but once the install media is ejected they make the
# installed system's `apt-get update` fail. Remove them as the last apt action.
echo "--- stripping CD-ROM apt sources from /target before reboot ---"
rm -f /target/etc/apt/sources.list.d/cixmini-cdrom.list
rm -f /target/etc/apt/preferences.d/00cixmini-bootstrap-pool.pref
if [ -f /target/etc/apt/sources.list ]; then
    # drop any `deb`/`deb-src` line referencing cdrom: or file:///cdrom
    sed -i -E '/^[[:space:]]*deb(-src)?[[:space:]].*(cdrom:|file:\/\/\/cdrom)/Id' \
        /target/etc/apt/sources.list
fi
for f in /target/etc/apt/sources.list.d/*.list; do
    [ -e "$f" ] || continue
    sed -i -E '/(cdrom:|file:\/\/\/cdrom)/Id' "$f"
    # remove the file entirely if stripping left it empty (no active deb lines)
    grep -qE '^[[:space:]]*deb' "$f" 2>/dev/null || rm -f "$f"
done
echo "    remaining apt sources after cdrom strip:"
grep -rhsE '^[[:space:]]*deb' \
    /target/etc/apt/sources.list /target/etc/apt/sources.list.d/ 2>/dev/null \
    | sed 's/^/      /' || echo "      (none)"

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
