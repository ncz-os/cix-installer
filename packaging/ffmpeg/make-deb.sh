#!/bin/bash
# Package NCZ's ffmpeg libraries as ncz-ffmpeg (arm64).
#
# Debian's libavcodec already carries nine V4L2-M2M decoders (h263, h264, hevc,
# mpeg1, mpeg2, mpeg4, vc1, vp8, vp9). Ours adds av1_v4l2m2m, which exists in
# neither Debian nor upstream FFmpeg and is the only route to AV1 hardware
# decode on this hardware.
#
# Installed alongside the system libraries rather than replacing them: the
# soname is identical (libavcodec.so.62), so overwriting would hijack every
# ffmpeg consumer on the machine. Consumers opt in via ld.so.conf.d ordering or
# LD_LIBRARY_PATH.
#
# Usage: make-deb.sh <path/to/ffmpeg/build/libs> [version]
set -eu

LIBDIR="${1:?path to built ffmpeg libraries}"
VER="${2:-$(date -u +%Y%m%d)}"
PKG="ncz-ffmpeg"
DEST="/usr/lib/ncz-ffmpeg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

[ -d "$LIBDIR" ] || { echo "no such directory: $LIBDIR" >&2; exit 1; }

mkdir -p "$STAGE/DEBIAN" "$STAGE$DEST" "$STAGE/etc/ld.so.conf.d" \
         "$STAGE/usr/share/doc/$PKG"

found=0
for so in "$LIBDIR"/lib*.so.*; do
    [ -e "$so" ] || continue
    cp -a "$so" "$STAGE$DEST/"
    found=$((found + 1))
done
[ "$found" -gt 0 ] || { echo "no shared libraries found in $LIBDIR" >&2; exit 1; }

# Verify the reason this package exists before shipping it.
if ! strings "$STAGE$DEST"/libavcodec.so.* 2>/dev/null | grep -q av1_v4l2m2m; then
    echo "ERROR: av1_v4l2m2m absent from libavcodec - this build has no reason to ship" >&2
    exit 1
fi

# NOT added to the default search path. Dropping these ahead of the system
# libraries would silently replace libavcodec for every application on the
# system; opting in is the caller's decision.
cat > "$STAGE/usr/share/doc/$PKG/README.Debian" <<EOF
ncz-ffmpeg
==========

FFmpeg libraries with the AV1 V4L2-M2M decoder (av1_v4l2m2m), which is absent
from upstream FFmpeg and from Debian's libavcodec.

Originally written by entrpi <entrpi@proton.me> for Sky1-Linux and credited in
the source; submitted upstream to ffmpeg-devel. When it lands upstream this
package can be retired.

Installed to $DEST rather than replacing the system libraries, because the
soname matches (libavcodec.so.62) and overwriting would redirect every ffmpeg
consumer on the machine. To use it for a single application:

  LD_LIBRARY_PATH=$DEST <application>

Note these are ffmpeg *decoders*, not hwaccels, so nothing selects them
automatically. An application must request the decoder by name - for example
'ffmpeg -c:v av1_v4l2m2m'. Firefox does this through its V4L2 path; mpv with
--hwdec=auto does not, and will use software even with this package installed.

Verified: 20 frames of 1280x720 AV1 decode bit-exact against libdav1d,
27,648,000 bytes, md5 4e20cccbf7f5d6246b0a478338759645.
EOF

INSTALLED_KB=$(du -sk "$STAGE" | cut -f1)
cat > "$STAGE/DEBIAN/control" <<EOF
Package: $PKG
Version: $VER
Architecture: arm64
Maintainer: Jason Perlow <jperlow@gmail.com>
Installed-Size: $INSTALLED_KB
Section: libs
Priority: optional
Homepage: https://github.com/perlowja
Description: FFmpeg libraries with CIX Sky1 AV1 V4L2-M2M decode
 FFmpeg built with av1_v4l2m2m, an AV1 decoder for stateful V4L2 hardware that
 exists in neither upstream FFmpeg nor Debian's libavcodec. On CIX Sky1 this is
 the only route to AV1 hardware decode.
 .
 Installed under $DEST rather than replacing the system libraries, since the
 soname is shared. Applications opt in explicitly.
 .
 Originally authored by entrpi for Sky1-Linux; submitted upstream.
EOF

DEB="${PKG}_${VER}_arm64.deb"
dpkg-deb --build --root-owner-group "$STAGE" "$DEB" >/dev/null
echo "  packaged: $DEB ($found libraries)"
