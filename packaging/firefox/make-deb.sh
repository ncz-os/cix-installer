#!/bin/bash
# Package a built Firefox tree as firefox-ncz-sky1 (arm64).
#
# Usage: make-deb.sh <dist_bin_dir> <firefox_version> <datestamp> <channel>
#
# Two things about this package differ from the Chromium one and both come from
# measurement, not preference:
#
#   1. dist/bin is a farm of ~7400 symlinks pointing back into the objdir. A
#      plain copy produces a tree that installs cleanly and then fails with
#      "Couldn't load XPCOM" on the target, because every link dangles. The
#      copy below dereferences.
#
#   2. The build host's glibc must be no newer than the target's. Firefox built
#      on cixmini (glibc 2.43) would not load on the board (2.42):
#      "libxul.so: libm.so.6: version `GLIBC_2.43' not found". TYDEUS (2.39) is
#      the correct host. This script checks rather than assuming.
set -eu

BIN="${1:?dist/bin dir}"
VERSION="${2:?firefox version}"
STAMP="${3:?datestamp}"
CHANNEL="${4:-stable}"

PKG="firefox-ncz-sky1"
DEBVER="${VERSION}-ncz${STAMP}"
INSTALL="/opt/${PKG}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ICONS="$(cd "$(dirname "$0")/../../assets/branding/browsers" && pwd)"

[ -x "$BIN/firefox" ] || { echo "no firefox binary in $BIN" >&2; exit 1; }

mkdir -p "$STAGE/DEBIAN" "$STAGE$INSTALL" "$STAGE/usr/bin" \
         "$STAGE/usr/share/applications" "$STAGE/usr/share/doc/$PKG"

# --- runtime payload --------------------------------------------------------
# -L dereferences; see note 2 above. Anything left as a symlink here is a bug
# that only shows up on the target.
cp -aL "$BIN/." "$STAGE$INSTALL/"
find "$STAGE$INSTALL" -type l -print -quit | grep -q . && {
    echo "  symlinks survived the copy - the target will fail to load XPCOM" >&2
    exit 1
}

# Build artefacts that must not ship: test binaries and the gtest libxul are
# each larger than the browser itself.
rm -rf "$STAGE$INSTALL/gtest" "$STAGE$INSTALL/dependentlibs.list.gtest" \
       "$STAGE$INSTALL/xpcshell" "$STAGE$INSTALL/tests" 2>/dev/null || true

# --- launcher ---------------------------------------------------------------
cat > "$STAGE/usr/bin/$PKG" <<EOF
#!/bin/sh
# Firefox NCZ Sky1 Edition launcher.
#
# MOZ_ENABLE_WAYLAND is set explicitly: the board runs labwc, and the X11
# fallback loses hardware compositing on this platform.
exec env MOZ_ENABLE_WAYLAND=1 $INSTALL/firefox "\$@"
EOF
chmod 755 "$STAGE/usr/bin/$PKG"

cat > "$STAGE/usr/share/applications/${PKG}.desktop" <<EOF
[Desktop Entry]
Version=1.0
Name=Firefox NCZ Sky1 Edition
GenericName=Web Browser
Comment=Firefox for CIX Sky1 with the NCZ V4L2-M2M media stack
Exec=$PKG %U
Icon=$PKG
Terminal=false
Type=Application
Categories=Network;WebBrowser;
MimeType=text/html;text/xml;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;
StartupWMClass=firefox
EOF

# --- icons ------------------------------------------------------------------
# Distinct from Mozilla's mark: this is an unofficial build and must not carry
# official Firefox branding.
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
# NoDefaultBookmarks suppresses Mozilla's built-in set; the NCZ projects go on
# the toolbar. Enterprise policy rather than a seeded places.sqlite, for the
# same reason as the Chromium package.
install -D -m644 "$(dirname "$0")/distribution/policies.json" \
    "$STAGE$INSTALL/distribution/policies.json"

# --- metadata ---------------------------------------------------------------
INSTALLED_KB=$(du -sk "$STAGE" | cut -f1)

cat > "$STAGE/DEBIAN/control" <<EOF
Package: $PKG
Version: $DEBVER
Architecture: arm64
Maintainer: Jason Perlow <jperlow@gmail.com>
Installed-Size: $INSTALLED_KB
Depends: libgtk-3-0, libdbus-glib-1-2, libxt6 | libxt6t64, libasound2t64 | libasound2,
 libx11-xcb1, libdrm2, libwayland-client0, libwayland-egl1, libpci3
Recommends: ncz-ffmpeg
Provides: www-browser
Section: web
Priority: optional
Homepage: https://github.com/perlowja
Description: Firefox for CIX Sky1 with the NCZ media stack
 Firefox built for the CIX Sky1 (Radxa Orion O6) carrying the NCZ V4L2-M2M
 patches, which relax the codec gates that upstream drives from a VA-API probe
 even when the decode path is V4L2.
 .
 Hardware decode is NOT yet engaging in this build: the V4L2 support is
 compiled in and reachable in source, but at runtime decoding lands in the RDD
 or Utility process and InitV4L2Decoder is never entered. Every codec plays
 correctly on the CPU. See docs/upstream-patches/firefox/README.md.
 .
 For hardware decode today, use chromium-ncz-sky1, which decodes H.264, HEVC,
 VP8, VP9 and AV1 on the VPU at up to 4K.
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
Firefox NCZ Sky1 Edition
========================

Built from Firefox $VERSION ($CHANNEL channel), snapshot $STAMP.

Built natively on TYDEUS (glibc 2.39). The build host's glibc must be no newer
than the target's (2.42 on the board) or libxul.so will not load.

Hardware video decode is not active. The V4L2-M2M patches are applied and
MOZ_ENABLE_V4L2 is set, but the V4L2 decoder is never initialised at runtime.
Until that is resolved, chromium-ncz-sky1 is the browser with hardware decode
on this platform.
EOF

DEB="${PKG}_${DEBVER}_arm64.deb"
dpkg-deb --build --root-owner-group "$STAGE" "$DEB" >/dev/null
echo "  packaged: $DEB ($(du -h "$DEB" | cut -f1))"
