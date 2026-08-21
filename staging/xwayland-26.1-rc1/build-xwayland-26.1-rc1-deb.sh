#!/bin/bash
# build-xwayland-26.1-rc1-deb.sh — build an installable .deb for Xwayland 26.0.99.901.
#
# This wraps the upstream xwayland-26.0.99.901 source into a drop-in .deb that
# REPLACES the distro xwayland package (via Provides=+Conflicts= on the same
# virtual name). It is intended as a real shipping candidate for NCZ-OS, not
# just a sandbox test -- the choice of Provides/Conflicts/R* is what lets
# `apt full-upgrade` from an offline mirror actually swap the binary in.
#
# Layout follows the gtk4-layer-shell pattern in this repo (packaging/gtk4-layer-shell/
# make-deb.sh): single-binary, runtime-only .deb, manually-rolled DEBIAN/control,
# dpkg-deb --build. No quilt/dh; the package is tiny (one binary + manpage +
# .desktop + .pc), and the build is reproducible from the same tarball + a few
# dev packages listed below.
#
# Build deps (all already satisfied on this build host; if missing, install with
# `sudo apt-get -y install --no-install-recommends ...`):
#   meson (>= 1.0.0 -- we ship 1.11.1)
#   ninja, pkg-config, gcc, libc6-dev
#   wayland-protocols (>= 1.38 -- we ship 1.49)
#   xserver-xorg-dev           (provides dri.pc, xorg-server.pc, xorg headers)
#   libdrm-dev libgbm-dev libxfont-dev libxshmfence-dev libxcvt-dev
#   libei-dev liboeffis-dev libgcrypt20-dev libtirpc-dev libsystemd-dev
#   libxkbcommon-dev libxkbfile-dev
#   libxcb-randr0-dev libxcb-icccm4-dev libdecor-0-dev
#   libavahi-client-dev libavahi-common-dev libselinux-dev
#   libgpg-error-dev libfontenc-dev libdbus-1-dev libpng-dev
#   x11proto-dev xkb-data xorg-sgml-doctools
#
# Usage: build-xwayland-26.1-rc1-deb.sh [outdir]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$PWD}"

UPSTREAM_TARBALL="${XWAYLAND_TARBALL:-$HERE/xwayland-26.0.99.901.tar.xz}"
# Pinned tarball location: staging/xwayland-26.1-rc1/xwayland-26.0.99.901.tar.xz.
# SHA256 verified against the [ANNOUNCE] xwayland 26.0.99.901 mail
# (https://lists.x.org/archives/xorg/2026-August/062280.html):
#   9d5fc0dfec66e210d5df81cf9fe950bfba685613f448c63941102076412a3a47
UPSTREAM_VER="26.0.99.901"
# Sort ABOVE Debian's xwayland 2:24.1.13-1 so apt prefers ours in the offline mirror.
# Suffix is `+ncz1.<YYYYMMDD>` to mark it as our rebuild, and the date ensures
# re-builds win over older rebuilds of the same upstream version.
DEB_VER="${DEB_VER:-2:${UPSTREAM_VER}-1+ncz1.$(date -u +%Y%m%d)}"
PKG="xwayland"

if [ ! -f "$UPSTREAM_TARBALL" ]; then
    echo "[xwayland] FATAL: tarball not found: $UPSTREAM_TARBALL"
    echo "[xwayland]   expected at staging/xwayland-26.1-rc1/xwayland-26.0.99.901.tar.xz"
    exit 1
fi

# Re-verify the tarball every build so a stale tarball can't silently ship.
EXPECTED_SHA="9d5fc0dfec66e210d5df81cf9fe950bfba685613f448c63941102076412a3a47"
ACTUAL_SHA="$(sha256sum "$UPSTREAM_TARBALL" | awk '{print $1}')"
if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
    echo "[xwayland] FATAL: tarball SHA256 mismatch"
    echo "[xwayland]   expected: $EXPECTED_SHA"
    echo "[xwayland]   actual:   $ACTUAL_SHA"
    exit 1
fi

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

echo "[xwayland] extracting $UPSTREAM_TARBALL"
tar -xJf "$UPSTREAM_TARBALL" -C "$WORK"
SRC="$WORK/xwayland-$UPSTREAM_VER"

# Verify the source tree really is the version we expect (defends against a
# tarball being replaced with a different RC). The version string lives both
# in the project() call and in Xwayland's runtime -version output.
SRC_VER=$(grep -m1 "version:" "$SRC/meson.build" | sed -E "s/.*version: '([^']+)'.*/\1/")
if [ "$SRC_VER" != "$UPSTREAM_VER" ]; then
    echo "[xwayland] FATAL: tarball version ($SRC_VER) != expected ($UPSTREAM_VER)"
    exit 1
fi

echo "[xwayland] configuring (meson setup)"
# -Dxwayland_ei=socket is what Debian's xwayland package builds (the 'portal'
# variant needs xdg-desktop-portal-remsh and a different liboeffis surface; the
# 'auto' default would resolve to 'socket' on this system anyway, but being
# explicit matches the distro package and keeps ReproducibleBuilds happier).
rm -rf "$WORK/build"
meson setup "$WORK/build" "$SRC" \
    --prefix=/usr \
    --libdir=lib/aarch64-linux-gnu \
    -Dglamor=true \
    -Dxwayland_ei=socket \
    >/dev/null

echo "[xwayland] building (ninja, $(nproc) jobs)"
ninja -C "$WORK/build" -j"$(nproc)" >/dev/null

echo "[xwayland] staging install"
STAGE="$WORK/stage"
DESTDIR="$STAGE" ninja -C "$WORK/build" install >/dev/null

# Runtime package only -- no headers, no pkgconfig.
# The xwayland.pc is shipped by the distro xwayland-dev, not the runtime .deb.
rm -f "$STAGE/usr/share/pkgconfig/xwayland.pc" 2>/dev/null || true

# Layout sanity: ensure the binary and manpage are where dpkg expects.
[ -x "$STAGE/usr/bin/Xwayland" ] || { echo "FATAL: Xwayland binary not in stage"; exit 1; }
[ -f "$STAGE/usr/share/man/man1/Xwayland.1" ] || { echo "FATAL: Xwayland.1 manpage not in stage"; exit 1; }

mkdir -p "$STAGE/DEBIAN"
cat > "$STAGE/DEBIAN/control" <<EOF
Package: $PKG
Version: $DEB_VER
Architecture: arm64
Maintainer: Jason Perlow <jperlow@gmail.com>
Section: x11
Priority: optional
Depends: xserver-common, libc6 (>= 2.38), libdecor-0-0 (>= 0.1.0), libdrm2 (>= 2.4.116), libei1 (>= 1.0.0), libepoxy0 (>= 1.5.2), libgbm1 (>= 21.3.0~rc1), libgcrypt20 (>= 1.12.0), libgl1, liboeffis1 (>= 1.0.0), libpixman-1-0 (>= 0.30.0), libtirpc3t64 (>= 1.0.2), libwayland-client0 (>= 1.20.0), libxau6 (>= 1:1.0.11), libxcvt0 (>= 0.1.0), libxdmcp6 (>= 1:1.1.5), libxfont2 (>= 1:2.0.1), libxshmfence1
Provides: xwayland
Conflicts: xwayland
Replaces: xwayland
Description: X server for running X clients under Wayland (NCZ build)
 Xwayland $UPSTREAM_VER (standalone Xwayland 26.1.0 RC1, tag
 xwayland-26.0.99.901, released 2026-08-19) rebuilt for NCZ-OS 26.7.
 .
 Same runtime as Debian's xwayland 2:24.1.13-1 plus:
  * rootful clipboard/primary-selection bridge (-clipboard flag)
  * multi-seat via XInput2 (Wayland seats mirrored into an Xi2 hierarchy)
  * wl_fixes protocol support (destroy_global/ack_global_remove)
  * improved RandR mode emulation (native modes up to physical resolution,
    rotation-aware)
  * xdg-system-bell protocol support (system bell through Wayland)
  * EGLStream support REMOVED (no-op for the Mali/Panthor stack).
 .
 Built against wayland-protocols 1.49 (>= 1.38 required) and meson 1.11.1
 (>= 1.0.0 required). Source: xorg.freedesktop.org tarball, SHA256 verified.
Homepage: https://gitlab.freedesktop.org/xorg/xserver/
EOF

# Record the build provenance. Useful when someone later asks "what exactly is
# in this .deb" without rebuilding -- single file, human-readable.
cat > "$STAGE/DEBIAN/source-info" <<EOF
Xwayland upstream tag: xwayland-26.0.99.901
Upstream tarball URL: https://xorg.freedesktop.org/archive/individual/xserver/xwayland-26.0.99.901.tar.xz
Upstream tarball SHA256: $EXPECTED_SHA
Build host: $(uname -a)
Build date (UTC): $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

dpkg-deb --build --root-owner-group "$STAGE" "$OUT/${PKG}_${DEB_VER}_arm64.deb" >/dev/null
echo "[xwayland] built $OUT/${PKG}_${DEB_VER}_arm64.deb"
dpkg-deb -f "$OUT/${PKG}_${DEB_VER}_arm64.deb" Package Version