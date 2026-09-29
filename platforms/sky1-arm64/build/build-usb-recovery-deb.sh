#!/bin/bash
# build-usb-recovery-deb.sh — package the USB enumeration recovery for OTA.
#
# WHY THIS EXISTS: the recovery ships as part of post-install/41-usb2-rescan.sh,
# which only runs at INSTALL time. A board already in the field cannot get a fix
# to it without reinstalling, and the Orion O6 report (2026-08-18) was exactly
# that situation: an installed system whose recovery script gave up before
# trying the one thing that works.
#
# NO SECOND COPY OF THE PAYLOAD. The script, the unit and the udev rules are
# EXTRACTED from post-install/41-usb2-rescan.sh at build time rather than
# duplicated here. That file stays the single source of truth, so the deb and a
# fresh install cannot drift apart -- the failure mode this repo has already
# been bitten by more than once (the rEFInd generator, the duplicate patch
# numbering).
#
# PATHS MATCH THE INSTALLER EXACTLY (/usr/local/sbin, /etc/systemd/system).
# They are not where a Debian package would normally put things, but the point
# of this package is to REPLACE what the installer wrote. Shipping the unit to
# /usr/lib/systemd/system instead would leave the installer's /etc copy in
# place, silently shadowing the update -- an "installed" fix that never runs.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO/post-install/41-usb2-rescan.sh"
OUT="$REPO/build/usb-recovery-deb"
PKG=ncz-usb-recovery
VERSION="${NCZ_USB_RECOVERY_VERSION:-1.1}"

[ -f "$SRC" ] || { echo "ERROR: $SRC not found" >&2; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
install -d "$WORK/DEBIAN" \
           "$WORK/usr/local/sbin" \
           "$WORK/etc/systemd/system" \
           "$WORK/etc/udev/rules.d" \
           "$WORK/usr/share/doc/$PKG"

# --- extract the three payloads from the installer hook --------------------
extract() {   # <start-regex> <terminator> -> stdout
    awk -v start="$1" -v term="$2" '
        $0 ~ start { f=1; next }
        f && $0 == term { exit }
        f { print }
    ' "$SRC"
}

extract '^cat > /usr/local/sbin/ncz-usb2-rescan <<.EOF.$' 'EOF' \
    > "$WORK/usr/local/sbin/ncz-usb2-rescan"
extract '^cat > /etc/systemd/system/ncz-usb2-rescan.service <<.EOF.$' 'EOF' \
    > "$WORK/etc/systemd/system/ncz-usb2-rescan.service"
extract '^cat > /etc/udev/rules.d/70-ncz-usb-interactive.rules <<.UDEV.$' 'UDEV' \
    > "$WORK/etc/udev/rules.d/70-ncz-usb-interactive.rules"

chmod 0755 "$WORK/usr/local/sbin/ncz-usb2-rescan"
chmod 0644 "$WORK/etc/systemd/system/ncz-usb2-rescan.service" \
           "$WORK/etc/udev/rules.d/70-ncz-usb-interactive.rules"

# --- refuse to ship an empty or broken payload -----------------------------
# A silently-empty extract would produce a package that installs cleanly and
# does nothing, which is worse than a build failure.
for f in "$WORK/usr/local/sbin/ncz-usb2-rescan" \
         "$WORK/etc/systemd/system/ncz-usb2-rescan.service" \
         "$WORK/etc/udev/rules.d/70-ncz-usb-interactive.rules"; do
    [ -s "$f" ] || { echo "ERROR: extracted $(basename "$f") is EMPTY -- heredoc markers changed?" >&2; exit 1; }
done
bash -n "$WORK/usr/local/sbin/ncz-usb2-rescan" \
    || { echo "ERROR: extracted rescan script does not parse" >&2; exit 1; }
grep -q '^\[Service\]' "$WORK/etc/systemd/system/ncz-usb2-rescan.service" \
    || { echo "ERROR: extracted unit has no [Service] section" >&2; exit 1; }
# The whole point of 1.1: all three recovery stages must be present.
for stage in 'Fast path:' 'Widened path:' 'Last resort:'; do
    grep -q "$stage" "$WORK/usr/local/sbin/ncz-usb2-rescan" \
        || { echo "ERROR: recovery stage '$stage' missing from payload" >&2; exit 1; }
done
echo "  payload verified: 3 recovery stages, unit parses, script parses"

SIZE_KB=$(du -sk "$WORK/usr" "$WORK/etc" | awk '{s+=$1} END {print s}')

cat > "$WORK/DEBIAN/control" <<CONTROL
Package: $PKG
Version: $VERSION
Section: admin
Priority: important
Architecture: all
Maintainer: NCZ <nczero@nclawzero.dev>
Installed-Size: $SIZE_KB
Depends: systemd, udev
Description: CIX Sky1 USB enumeration recovery
 On some boots a Sky1 xHCI controller powers its port and sees the device
 connected, but the hub driver is never told, so nothing enumerates: the board
 reaches the login screen with no keyboard and no mouse.
 .
 This package installs a boot-time recovery ordered before greetd. It tries the
 known USB-A controller first, then any controller with no storage downstream,
 then rebinds the hub driver itself -- the step proven to recover an affected
 Orion O6 by hand. A controller with USB storage below it is never reset.
 .
 On hardware that enumerates normally it exits immediately and changes nothing.
CONTROL

cat > "$WORK/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e
if [ "$1" = configure ]; then
    udevadm control --reload >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable ncz-usb2-rescan.service >/dev/null 2>&1 || true
    # Deliberately NOT started here: it is a boot-time recovery, and running it
    # mid-upgrade could rebind a controller under a live session.
fi
exit 0
POSTINST
chmod 0755 "$WORK/DEBIAN/postinst"

cat > "$WORK/usr/share/doc/$PKG/README" <<'DOC'
Generated from post-install/41-usb2-rescan.sh at package build time. Do not edit
the installed copies: change the installer hook and rebuild, or the next install
and the next upgrade will disagree with each other.

Check which recovery stage fired:
    journalctl -t ncz-usb2-rescan -b
DOC

install -d "$OUT"
DEB="$OUT/${PKG}_${VERSION}_all.deb"
dpkg-deb --build --root-owner-group "$WORK" "$DEB" >/dev/null
echo "  built: $DEB ($(du -h "$DEB" | cut -f1))"
dpkg-deb --contents "$DEB" | awk '{print "    " $NF}' | grep -vE '/$'
