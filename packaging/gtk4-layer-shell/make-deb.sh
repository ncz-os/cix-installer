#!/bin/bash
# make-deb.sh — build libgtk4-layer-shell0 with the NCZ stale-buffer fix.
#
# WHY THIS EXISTS (2026-08-10): this library carried a one-file patch that lived
# ONLY as an uncommitted `git diff` in ~/g4ls on cixmini. The same day, the
# Singularity payload fix existed only as /opt/singularity.FIXED24 on a test
# board, and chromium-ncz-sky1 had to be reconstructed with dpkg-repack off a
# running O6N because its build tree had been cleaned. None of those three could
# be rebuilt from the repo. This script + patches/ make this one reproducible.
#
# WHAT THE PATCH FIXES (the decisive half of the layer-shell crash):
# GTK keeps ONE wl_surface across hide/show and tears down only the role object,
# so a frame queued by a closing animation can land AFTER unmap and leave a live
# buffer attached. Creating a zwlr_layer_surface_v1 on a wl_surface that has a
# buffer attached is a protocol error, and the compositor kills the client.
# The fix attaches NULL + commits BEFORE get_layer_surface. Placement matters:
# doing it after role creation is both too late and a second violation.
#
# A metal A/B on O6N was decisive: SAME unpatched shell, stock library = instant
# crash; patched library = no crash. The library is the real fix; the shell-side
# unrealize() work is the belt-and-braces half. Upstream: wmww/gtk4-layer-shell
# PR #130 (and singularityos-lab/singularity-shell PR #15 for the client side).
#
# Usage: make-deb.sh [--src /path/to/gtk4-layer-shell-checkout] [outdir]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${GTK4_LAYER_SHELL_SRC:-}"
OUT="${1:-$PWD}"

UPSTREAM_GIT="https://github.com/wmww/gtk4-layer-shell.git"
# Base the patch was developed against: v1.3.0-23-ge8704f4. Pin it so a rebuild
# cannot silently drift onto a tree where the patch context no longer applies.
UPSTREAM_REF="${GTK4_LAYER_SHELL_REF:-e8704f4}"
UPSTREAM_VER="1.3.0"
# Must sort ABOVE Debian's 1.3.0-1+b1 so apt prefers ours in the offline mirror.
DEB_VER="${DEB_VER:-${UPSTREAM_VER}-1+ncz$(date -u +%Y%m%d)}"
PKG="libgtk4-layer-shell0"

if [ "${1:-}" = "--src" ]; then SRC="$2"; shift 2; OUT="${1:-$PWD}"; fi

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

if [ -z "$SRC" ]; then
    echo "[g4ls] cloning $UPSTREAM_GIT @ $UPSTREAM_REF"
    git clone -q "$UPSTREAM_GIT" "$WORK/src"
    git -C "$WORK/src" checkout -q "$UPSTREAM_REF"
    SRC="$WORK/src"
else
    echo "[g4ls] using existing checkout: $SRC"
fi

# Apply every patch in patches/, in order. --forward so a re-run on an already
# patched tree fails loudly rather than half-applying.
for p in "$HERE"/patches/*.patch; do
    [ -e "$p" ] || continue
    echo "[g4ls] applying $(basename "$p")"
    git -C "$SRC" apply --verbose "$p" 2>/dev/null || patch -d "$SRC" -p1 --forward < "$p"
done

# PROVE the patch is in the tree before spending a build on it: the whole point
# is that the buffer is cleared BEFORE get_layer_surface, so check the order.
awk '/wl_surface_attach\(wl_surface, NULL/{a=NR} /get_layer_surface/{g=NR}
     END{ if (!a) { print "FATAL: attach(NULL) not found in layer-surface.c"; exit 1 }
          if (a > g) { print "FATAL: attach(NULL) occurs AFTER get_layer_surface - patch misapplied"; exit 1 }
          print "  patch verified: attach(NULL) at line " a ", get_layer_surface at " g }' \
    "$SRC/src/layer-surface.c"

echo "[g4ls] building"
meson setup "$WORK/build" "$SRC" --prefix=/usr --libdir=lib/aarch64-linux-gnu \
    -Dexamples=false -Ddocs=false -Dtests=false \
    -Dintrospection=false -Dvapi=false >/dev/null
# introspection/vapi off: they need gobject-introspection-1.0 + vapigen, which
# are NOT installed on the build hosts, and this package ships the RUNTIME
# library only -- the GIR/vapi data is stripped below anyway. Leaving them on
# made meson fail with "Dependency gobject-introspection-1.0 not found".
ninja -C "$WORK/build" >/dev/null

STAGE="$WORK/stage"
DESTDIR="$STAGE" ninja -C "$WORK/build" install >/dev/null

# Runtime package only: headers/pkgconfig belong to the -dev package, which we
# do not override.
rm -rf "$STAGE/usr/include" "$STAGE/usr/lib/aarch64-linux-gnu/pkgconfig" \
       "$STAGE/usr/share/gir-1.0" "$STAGE/usr/share/vala" 2>/dev/null || true

mkdir -p "$STAGE/DEBIAN"
cat > "$STAGE/DEBIAN/control" <<EOF
Package: $PKG
Version: $DEB_VER
Architecture: arm64
Maintainer: Jason Perlow <jperlow@gmail.com>
Section: libs
Priority: optional
Depends: libc6, libgtk-4-1, libwayland-client0
Provides: gtk4-layer-shell
Description: gtk4-layer-shell with the NCZ stale-buffer fix
 Upstream $UPSTREAM_VER plus the fix from wmww/gtk4-layer-shell PR #130: clear a
 stale attached buffer (attach NULL + commit) BEFORE creating the
 zwlr_layer_surface_v1 role. GTK reuses one wl_surface across hide/show, so a
 frame landing after unmap leaves a buffer attached, and creating a layer
 surface on such a wl_surface is a protocol error that gets the client killed.
 .
 Metal A/B on the Radxa Orion O6: same unpatched shell, stock library = instant
 crash; this library = no crash.
EOF

dpkg-deb --build --root-owner-group "$STAGE" "$OUT/${PKG}_${DEB_VER}_arm64.deb" >/dev/null
echo "[g4ls] built $OUT/${PKG}_${DEB_VER}_arm64.deb"
dpkg-deb -f "$OUT/${PKG}_${DEB_VER}_arm64.deb" Package Version
