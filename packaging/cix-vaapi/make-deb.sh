#!/bin/bash
# Package the NCZ cix_vaapi driver as cix-vaapi-driver (arm64).
#
# This is the VA-API driver Chrome and Vivaldi use for hardware decode. It is a
# hard dependency of chromium-ncz-sky1 and worth installing on its own: without
# it, every VA-API client on this hardware decodes in software.
#
# Usage: make-deb.sh <path/to/libcix_va_drv_video.so> [version]
set -eu

SO="${1:?path to built libcix_va_drv_video.so}"
VER="${2:-$(date -u +%Y%m%d)}"
PKG="cix-vaapi-driver"
DRIDIR="/usr/lib/aarch64-linux-gnu/dri"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

[ -f "$SO" ] || { echo "no such file: $SO" >&2; exit 1; }
SHA=$(sha256sum "$SO" | cut -c1-16)

mkdir -p "$STAGE/DEBIAN" "$STAGE$DRIDIR" "$STAGE/usr/share/doc/$PKG"
install -m 0644 "$SO" "$STAGE$DRIDIR/libcix_va_drv_video.so"

cat > "$STAGE/DEBIAN/control" <<EOF
Package: $PKG
Version: $VER
Architecture: arm64
Maintainer: Jason Perlow <jperlow@gmail.com>
Depends: libva2
Section: libs
Priority: optional
Homepage: https://github.com/perlowja
Description: VA-API driver for the CIX Sky1 video processing unit
 Hardware video decode for the CIX Sky1 (Radxa Orion O6) Arm Linlon MVE VPU,
 exposed through VA-API so that any VA-API client benefits - including prebuilt
 browsers such as Google Chrome and Vivaldi, which cannot be patched.
 .
 Provides hardware H.264, VP9 and HEVC, each verified bit-exact against
 software decode. AV1 and VP8 are deliberately not advertised: the VPU is a
 stateful decoder that requires complete bitstreams, and VA-API supplies parsed
 parameters, so those codecs cannot be reconstructed without substantial extra
 work. Clients fall back to software for them rather than selecting a hardware
 path that produces no frames.
 .
 Built from ${SHA}.
EOF

# The vendor driver ships in a CIX package; divert rather than overwrite so it
# can be restored, and so dpkg does not fight the other package over the path.
cat > "$STAGE/DEBIAN/preinst" <<EOF
#!/bin/sh
set -e
if [ "\$1" = install ] || [ "\$1" = upgrade ]; then
    if [ -e "$DRIDIR/libcix_va_drv_video.so" ] && \\
       ! dpkg-divert --list "$DRIDIR/libcix_va_drv_video.so" | grep -q .; then
        dpkg-divert --add --package $PKG --rename \\
            --divert "$DRIDIR/libcix_va_drv_video.so.distrib" \\
            "$DRIDIR/libcix_va_drv_video.so"
    fi
fi
EOF

cat > "$STAGE/DEBIAN/postrm" <<EOF
#!/bin/sh
set -e
if [ "\$1" = remove ] || [ "\$1" = purge ]; then
    dpkg-divert --remove --package $PKG \\
        --divert "$DRIDIR/libcix_va_drv_video.so.distrib" \\
        "$DRIDIR/libcix_va_drv_video.so" || true
fi
EOF
chmod 755 "$STAGE/DEBIAN/preinst" "$STAGE/DEBIAN/postrm"

cat > "$STAGE/usr/share/doc/$PKG/README.Debian" <<EOF
cix-vaapi-driver
================

Build $SHA.

Verify with:

  LIBVA_DRIVER_NAME=libcix_va vainfo

Hardware decode is confirmed by comparing output byte-for-byte against software
decode - not by an open /dev/video* file descriptor, which can accompany
completely broken output, and not by a player reporting "using hardware
decoding", which has been observed while producing no frames at all.

Patches and their rationale: docs/upstream-patches/cix-vaapi/ in the
cix-installer repository.
EOF

DEB="${PKG}_${VER}_arm64.deb"
dpkg-deb --build --root-owner-group "$STAGE" "$DEB" >/dev/null
echo "  packaged: $DEB (driver $SHA)"
