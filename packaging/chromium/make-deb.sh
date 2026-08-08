#!/bin/bash
# Package a built Chromium tree as chromium-ncz-sky1 (arm64).
#
# Usage: make-deb.sh <out_dir> <chromium_version> <datestamp> <channel>
#
# The package is self-contained apart from the CIX media stack: it Depends on
# the NCZ VA-API driver, because without it the browser silently falls back to
# software decode, which is the whole reason this build exists.
set -eu

OUTDIR="${1:?out dir}"
VERSION="${2:?chromium version}"
STAMP="${3:?datestamp}"
CHANNEL="${4:-stable}"

PKG="chromium-ncz-sky1"
DEBVER="${VERSION}-ncz${STAMP}"
INSTALL="/opt/${PKG}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ICONS="$(cd "$(dirname "$0")/../../assets/branding/browsers" && pwd)"

mkdir -p "$STAGE/DEBIAN" "$STAGE$INSTALL" "$STAGE/usr/bin" \
         "$STAGE/usr/share/applications" "$STAGE/usr/share/doc/$PKG"

# --- runtime payload --------------------------------------------------------
# Only what the browser needs at runtime; the out/ dir also holds gigabytes of
# test binaries and .runtime_deps files that must not ship.
for f in chrome chrome_sandbox chrome_crashpad_handler \
         resources.pak chrome_100_percent.pak chrome_200_percent.pak \
         icudtl.dat v8_context_snapshot.bin; do
    [ -e "$OUTDIR/$f" ] && cp -a "$OUTDIR/$f" "$STAGE$INSTALL/"
done
[ -d "$OUTDIR/locales" ] && cp -a "$OUTDIR/locales" "$STAGE$INSTALL/"
for so in "$OUTDIR"/*.so; do [ -e "$so" ] && cp -a "$so" "$STAGE$INSTALL/"; done

# chrome_sandbox must be setuid root; dpkg records the mode from the tree.
if [ -e "$STAGE$INSTALL/chrome_sandbox" ]; then
    chmod 4755 "$STAGE$INSTALL/chrome_sandbox"
fi

# --- launcher ---------------------------------------------------------------
# Upstream disables hardware decode by default when USE_VAAPI is off
# (kAcceleratedVideoDecodeLinux is DISABLED_BY_DEFAULT), so a V4L2-only build
# needs the feature switched on explicitly or it silently uses software.
# Wayland ozone is likewise required: under X11 ozone, VA-API/V4L2 init fails
# on this platform.
cat > "$STAGE/usr/bin/$PKG" <<EOF
#!/bin/sh
# Chromium NCZ Sky1 Edition launcher.
exec $INSTALL/chrome \\
  --ozone-platform=wayland \\
  --enable-features=AcceleratedVideoDecoder \\
  "\$@"
EOF
chmod 755 "$STAGE/usr/bin/$PKG"

cat > "$STAGE/usr/share/applications/${PKG}.desktop" <<EOF
[Desktop Entry]
Version=1.0
Name=Chromium NCZ Sky1 Edition
GenericName=Web Browser
Comment=Chromium with CIX Sky1 hardware video decode
Exec=$PKG %U
Icon=$PKG
Terminal=false
Type=Application
Categories=Network;WebBrowser;
MimeType=text/html;text/xml;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;
StartupWMClass=chromium-ncz-sky1
EOF

# --- icons ------------------------------------------------------------------
# The Chromium tree ships no icon of its own (only the Google-branded Chrome
# build carries one), which is why an unbranded build shows a blank launcher.
# The NCZ mark is pre-rendered in the repo rather than converted here, so the
# package builds on a host without a working SVG rasteriser.
for sz in 16 22 24 32 48 64 128 256 512; do
    src="$ICONS/$PKG/$sz.png"
    [ -f "$src" ] || { echo "  missing icon $src" >&2; exit 1; }
    install -D -m644 "$src" \
        "$STAGE/usr/share/icons/hicolor/${sz}x${sz}/apps/${PKG}.png"
done
install -D -m644 "$ICONS/${PKG}.svg" \
    "$STAGE/usr/share/icons/hicolor/scalable/apps/${PKG}.svg"
install -D -m644 "$ICONS/$PKG/256.png" "$STAGE/usr/share/pixmaps/${PKG}.png"

# --- default bookmarks ------------------------------------------------------
# Debian's chromium shipped its own bookmark set via
# /usr/share/chromium/initial_bookmarks.html. That package is not installed
# here and its defaults are not ours to ship, so the NCZ projects go in as a
# managed policy instead of a seeded profile: a seeded Bookmarks file is
# written once at first run and then diverges, while a policy stays correct
# across profile resets.
install -D -m644 "$(dirname "$0")/policies/ncz-bookmarks.json" \
    "$STAGE/etc/chromium/policies/managed/ncz-bookmarks.json"

# --- metadata ---------------------------------------------------------------
INSTALLED_KB=$(du -sk "$STAGE" | cut -f1)

cat > "$STAGE/DEBIAN/control" <<EOF
Package: $PKG
Version: $DEBVER
Architecture: arm64
Maintainer: Jason Perlow <jperlow@gmail.com>
Installed-Size: $INSTALLED_KB
Depends: libnss3, libatk1.0-0, libatk-bridge2.0-0, libcups2, libdrm2,
 libxkbcommon0, libxcomposite1, libxdamage1, libxfixes3, libxrandr2,
 libgbm1, libasound2t64 | libasound2, libwayland-client0, libwayland-egl1
Recommends: ncz-ffmpeg
Provides: www-browser
Section: web
Priority: optional
Homepage: https://github.com/perlowja
Description: Chromium with CIX Sky1 hardware video decode
 Chromium built for the CIX Sky1 (Radxa Orion O6) with V4L2-M2M hardware video
 decode enabled, which no upstream or distribution build provides on this
 platform: Debian's arm64 Chromium is built without VA-API and its V4L2 path
 fails on the Arm proprietary Y0A8 capture format, and Ubuntu ships Chromium
 only as a snap.
 .
 Hardware decode covers H.264, VP9, HEVC and AV1. AV1 in particular is
 available nowhere else on this hardware: it works only through V4L2-M2M, so
 prebuilt VA-API browsers such as Chrome and Vivaldi fall back to software.
 .
 Hardware decode needs the amvx VPU driver providing /dev/video0. That is a
 kernel module, not a package this can depend on, so a system without it still
 installs and runs - it just decodes in software. This package deliberately
 does NOT depend on libva or the cix_vaapi driver: the decode path is V4L2-M2M
 and the binary does not link libva at all.
EOF

cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = configure ]; then
    update-desktop-database -q /usr/share/applications 2>/dev/null || true
    gtk-update-icon-cache -q -f -t /usr/share/icons/hicolor 2>/dev/null || true
fi
EOF
chmod 755 "$STAGE/DEBIAN/postinst"

cat > "$STAGE/usr/share/doc/$PKG/README.Debian" <<EOF
Chromium NCZ Sky1 Edition
=========================

Built from Chromium $VERSION ($CHANNEL channel), snapshot $STAMP.

Hardware video decode uses V4L2-M2M rather than VA-API. The launcher passes
--enable-features=AcceleratedVideoDecoder because upstream disables hardware
decode by default in builds without VA-API, and --ozone-platform=wayland
because V4L2/VA-API initialisation fails under X11 ozone on this platform.

The NCZ patches carried on top of upstream are documented in
docs/upstream-patches/chromium/ in the cix-installer repository, along with
which of them are candidates for upstreaming.

Verification of a build is decode output compared byte-for-byte against
software decode on real Sky1 hardware. A build that compiles is not evidence
that any codec works.
EOF

DEB="${PKG}_${DEBVER}_arm64.deb"
dpkg-deb --build --root-owner-group "$STAGE" "$DEB" >/dev/null
echo "  packaged: $DEB ($(du -h "$DEB" | cut -f1))"
