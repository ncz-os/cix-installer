#!/bin/bash
# build-singularity.sh — reproducible build of the NCZ-OS Singularity Desktop
# payload (/opt/singularity) for CIX Sky1 (arm64).
#
# NCZ-OS 26.7 "Maximilian" ships Singularity Desktop (labwc/wlroots, GTK4/Vala,
# GLES on CIX libmali) as THE desktop, replacing XFCE/X11. This script produces
# the canonical, rebuildable `singularity-opt.tgz` artifact that
# post-install/20-desktop.sh extracts to /opt/singularity at desktop-layer bake
# time. Without this the tarball is a one-off; with it, the payload is
# reproducible from upstream sources.
#
# METHOD (matches the .66 bring-up build, docs/upstream/singularity/):
#   1. ubuntu:26.04 arm64 container (native aarch64 — build on cixmini/.66,
#      ULTRA, or any arm64 host with docker/podman).
#   2. clone singularityos-lab/singularity-desktop --recursive.
#   3. build the `vetro` Go host tool (UI transpiler) and put it on PATH.
#   4. meson setup --prefix=/opt/singularity --libdir=lib ; ninja ; meson install
#      to a DESTDIR stage (top project + bundled labwc/wlroots).
#   5. tar the staged /opt/singularity tree -> out/singularity-opt.tgz.
#
# The tarball extracts to `opt/singularity/...` so `tar -C / -xzf` lands it at
# /opt/singularity (it touches ONLY /opt/singularity — never /lib — so it is
# safe on a live rootfs, unlike a full rootfs/module tarball).
#
# USAGE (on an arm64 build host, e.g. .66):
#   ./build/build-singularity.sh
#   ./build/build-singularity.sh --push-argonas   # also stage on ARGONAS
#
# Outputs:
#   $OUT/singularity-opt.tgz   (default: ./build/sinty-out/singularity-opt.tgz)
set -euo pipefail

# ---- config ----------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The payload must link against the same distribution ABI as the installed
# system.  In particular Forky exposes libsodium.so.26, while an Ubuntu-built
# payload requires libsodium.so.23.
if [ -r "$REPO_ROOT/release.conf" ]; then
    # shellcheck source=../release.conf
    . "$REPO_ROOT/release.conf"
fi
DEFAULT_IMAGE="ubuntu:26.04"
METADATA_SEARCH_DEV="libtracker-sparql-3.0-dev"
if [ "${NCZ_BASE_NAME:-}" = "Debian" ]; then
    DEFAULT_IMAGE="debian:testing"
    METADATA_SEARCH_DEV="libtinysparql-dev"
fi
IMAGE="${SINGULARITY_IMAGE:-$DEFAULT_IMAGE}"
CONTAINER_NETWORK="${SINGULARITY_CONTAINER_NETWORK:-host}"
SRC_REPO="${SINGULARITY_REPO:-https://github.com/singularityos-lab/singularity-desktop}"
SRC_REF="${SINGULARITY_REF:-master}"
# Optional checked-out superproject.  This is intentionally explicit: local
# NCZ fixes must never be mistaken for an upstream main build.
SRC_DIR="${SINGULARITY_SOURCE_DIR:-}"
VETRO_REPO="${VETRO_REPO:-https://github.com/singularityos-lab/vetro}"
PREFIX="/opt/singularity"
OUT="${OUT:-$(cd "$(dirname "$0")/.." && pwd)/build/sinty-out}"
ARGONAS_DST="/mnt/datapool/archives/ncz/singularity"
PUSH_ARGONAS=0
[ "${1:-}" = "--push-argonas" ] && PUSH_ARGONAS=1

# Container engine: prefer docker, fall back to podman.
CE="$(command -v docker || command -v podman || true)"
[ -n "$CE" ] || { echo "ERROR: need docker or podman on the build host" >&2; exit 1; }
[ -z "$SRC_DIR" ] || [ -d "$SRC_DIR" ] || {
    echo "ERROR: SINGULARITY_SOURCE_DIR is not a directory: $SRC_DIR" >&2
    exit 1
}

ARCH="$(uname -m)"
case "$ARCH" in
    aarch64|arm64) ;;
    *) echo "WARN: host arch=$ARCH — Singularity payload is arm64; build MUST run on/emulate aarch64 (this container image is $IMAGE)." >&2 ;;
esac

mkdir -p "$OUT"
echo "== build-singularity =="
echo "   image  = $IMAGE"
echo "   source = $SRC_REPO @ $SRC_REF"
[ -z "$SRC_DIR" ] || echo "   local  = $SRC_DIR (explicit NCZ source override)"
echo "   prefix = $PREFIX"
echo "   out    = $OUT/singularity-opt.tgz"

# ---- in-container build script ---------------------------------------------
# Everything below runs inside the arm64 ubuntu:26.04 container. The DESTDIR
# stage is tarred and copied out via the bind-mounted /out.
BUILD_SCRIPT='
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
# Build deps (Debian 13 / Ubuntu 26.04 names — see docs/upstream/singularity/
# 20-pr-arm64-build.md). No arch guards needed; the tree builds clean on aarch64.
apt-get install -y --no-install-recommends \
    ca-certificates git golang-go \
    libglib2.0-bin \
    valac meson ninja-build pkg-config gettext \
    libgtk-4-dev libadwaita-1-dev libgtk4-layer-shell-dev \
    libwayland-dev wayland-protocols \
    libvte-2.91-gtk4-dev libgtksourceview-5-dev \
    libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
    gstreamer1.0-plugins-good gstreamer1.0-pipewire \
    libpulse-dev libpolkit-gobject-1-dev libpolkit-agent-1-dev \
    libjson-glib-dev libpeas-2-dev libpipewire-0.3-dev \
    libgee-0.8-dev libsoup-3.0-dev \
    libgirepository-1.0-dev gobject-introspection \
    libupower-glib-dev \
    libatspi2.0-dev libcmocka-dev libdbusmenu-glib-dev libfontconfig-dev \
    libglib2.0-dev libgudev-1.0-dev libinput-dev libnm-dev \
    libpng-dev librsvg2-dev libsecret-1-dev libxml2-dev libpixman-1-dev \
    libpoppler-glib-dev libsystemd-dev $SINGULARITY_METADATA_SEARCH_DEV \
    libupower-glib-dev \
    libwebkitgtk-6.0-dev libxcb1-dev libxcb-ewmh-dev \
    libxcb-icccm4-dev libxkbcommon-dev \
    libpam0g-dev libgcrypt20-dev libcrypt-dev libsodium-dev \
    hwdata xwayland libxcb-dri3-dev \
    libxcb-composite0-dev libxcb-render0-dev libxcb-res0-dev \
    libxcb-xfixes0-dev libxcb-errors-dev libxcb-present-dev \
    sassc scdoc \
    libdisplay-info-dev \
    libseat-dev \
    libliftoff-dev \
    libnm-dev \
    libgoa-1.0-dev \
    sassc \
    libdrm-dev libcairo2-dev libpango1.0-dev libgdk-pixbuf-2.0-dev \
    libinput-dev \
    libpoppler-glib-dev \
    hwdata \
    scdoc \
    libdisplay-info-dev \
    libseat-dev \
    libliftoff-dev \
    build-essential

mkdir -p /work && cd /work

# vetro host tool (UI .vetro -> .ui transpiler). Go 1.24+.
git clone --depth 1 "'"$VETRO_REPO"'" vetro
( cd vetro && go build -o /usr/local/bin/vetro . )
vetro --version 2>/dev/null || true

# Singularity Desktop (recursive: bundled labwc/wlroots + subprojects).  The
# local override is for reviewed NCZ commits that have not yet been published
# upstream; it is mounted read-only and copied into the disposable container
# workspace before any build writes occur.
if [ -n "${SINGULARITY_SOURCE_DIR:-}" ]; then
    cp -a "$SINGULARITY_SOURCE_DIR" singularity-desktop
else
    git clone --recursive --branch "'"$SRC_REF"'" "'"$SRC_REPO"'" singularity-desktop
fi
cd singularity-desktop

# NCZ shell integration: close the launcher popup before opening the full-screen
# workspace chooser. Keep this small downstream patch in the installer tree so
# reproducible payload builds do not depend on an unpublished GitHub commit.
if [ -z "${SINGULARITY_SOURCE_DIR:-}" ] && ! grep -q "Close the launcher popup first" subprojects/singularity-shell/src/core/main.vala; then
git apply <<'PATCH_NCZ_SHELL'
diff --git a/subprojects/singularity-shell/src/core/main.vala b/subprojects/singularity-shell/src/core/main.vala
--- a/subprojects/singularity-shell/src/core/main.vala
+++ b/subprojects/singularity-shell/src/core/main.vala
@@ -798,4 +798,11 @@ public class SingularityApp : Singularity.ShellApplication, Singularity.Shell.Sh
         if (overview != null && overview.showing) {
             overview.toggle();
         }
+        // The workspace chooser is a full-screen TOP layer.  Close the
+        // launcher popup first; leaving AppMenu visible lets the chooser
+        // hover over (and visually occlude) the main menu when Workspaces is
+        // invoked from the panel/dock.
+        if (app_menu != null && app_menu.visible) {
+            app_menu.toggle();
+        }
         if (workspace_overview == null) {
PATCH_NCZ_SHELL
fi

# Top project. --libdir=lib keeps libs at $PREFIX/lib (not lib/<triplet>) so the
# session launchers'"'"' fixed LD_LIBRARY_PATH=$PREFIX/lib resolves.
meson setup build --prefix='"$PREFIX"' --libdir=lib --buildtype=release
# Bundled labwc/wlroots (labwc uses the wlroots-0.20 fallback wrap upstream ships).
if [ -f Makefile ] && grep -q LABWC_BUILD Makefile; then
    make compile
else
    ninja -C build
    # labwc subproject, if the tree carries it as a separate meson project
    if [ -d subprojects/labwc ]; then
        meson setup build-labwc subprojects/labwc --prefix='"$PREFIX"' \
            --buildtype=release -Dxwayland=enabled --force-fallback-for=wlroots-0.20
        ninja -C build-labwc
    fi
fi

# Install into the DESTDIR stage.
rm -rf /work/stage
DESTDIR=/work/stage meson install -C build

# labwc is a separate Meson project.  `make install` in the desktop tree is a
# host-deployment helper and does not reliably honour DESTDIR, so it can leave
# the payload with the previous labwc even when `make compile` built a newer
# compositor.  Install the exact build directory explicitly and fail the
# artifact build if it cannot be staged.
LABWC_BUILD_DIR=""
if [ -d subprojects/labwc/build ]; then
    LABWC_BUILD_DIR="subprojects/labwc/build"
elif [ -d build-labwc ]; then
    LABWC_BUILD_DIR="build-labwc"
fi
[ -n "$LABWC_BUILD_DIR" ] || {
    echo "ERROR: labwc build directory is missing after compilation" >&2
    exit 1
}
DESTDIR=/work/stage meson install -C "$LABWC_BUILD_DIR"

# The upstream Meson install deliberately installs schema XML, but it does not
# install a compiled GSettings database.  Raw XML is not usable by GSettings at
# runtime: launching singularity-desktop then aborts with "Settings schema
# 'dev.sinty.desktop' is not installed".  Compile *inside the staged prefix*
# so the payload is self-contained and GSETTINGS_SCHEMA_DIR can point solely at
# /opt/singularity/share/glib-2.0/schemas.
SCHEMA_DIR="/work/stage'"$PREFIX"'/share/glib-2.0/schemas"
test -f "$SCHEMA_DIR/dev.sinty.desktop.gschema.xml"
glib-compile-schemas --strict "$SCHEMA_DIR"
test -s "$SCHEMA_DIR/gschemas.compiled"

# Sanity: the shell, session launcher, and compositor must all exist.
test -x "/work/stage'"$PREFIX"'/bin/singularity-desktop"
test -x "/work/stage'"$PREFIX"'/bin/singularity-labwc-session"
test -x "/work/stage'"$PREFIX"'/bin/labwc"
test -s "/work/stage'"$PREFIX"'/share/glib-2.0/schemas/gschemas.compiled"

# --- singularity-boot-splash (NATIVE KMS boot splash — Plymouth replacement) --
# Separate upstream repo (github.com/singularityos-lab/singularity-boot-splash),
# NOT part of singularity-desktop. Toolkit-less libdrm + shared singularity-
# loginui Cairo renderer: owns the DRM device directly, animates the branded
# logo/loading-bar, hands off to the labwc greeter. Built here so it ships INSIDE
# the /opt/singularity payload alongside the greeter/lock/splash, all on the same
# loginui pixels. Replaces plymouth (which never covered Sky1s late KMS).
cd /work
git clone --depth 1 --recurse-submodules \
    https://github.com/singularityos-lab/singularity-boot-splash.git
cd singularity-boot-splash
meson setup build --prefix='"$PREFIX"' --libdir=lib --buildtype=release
ninja -C build
DESTDIR=/work/stage meson install -C build
test -x "/work/stage'"$PREFIX"'/bin/singularity-boot-splash"

# Package. Paths are opt/singularity/... so `tar -C /` lands at /opt/singularity.
cd /work/stage
tar -czf /out/singularity-opt.tgz opt/singularity
echo "STAGED $(du -h /out/singularity-opt.tgz | cut -f1)"
'

echo "== running build in $IMAGE ($CE) =="
CE_ARGS=(--rm --network="$CONTAINER_NETWORK" -v "$OUT":/out \
         -e SRC_REF="$SRC_REF" -e SINGULARITY_METADATA_SEARCH_DEV="$METADATA_SEARCH_DEV")
if [ -n "$SRC_DIR" ]; then
    CE_ARGS+=(-v "$SRC_DIR":/src:ro -e SINGULARITY_SOURCE_DIR=/src)
fi
"$CE" run "${CE_ARGS[@]}" "$IMAGE" bash -euo pipefail -c "$BUILD_SCRIPT"

echo ""
echo "== done =="
ls -lh "$OUT/singularity-opt.tgz"
echo "  top entries:"; tar tzf "$OUT/singularity-opt.tgz" | head -3

if [ "$PUSH_ARGONAS" = 1 ]; then
    echo "== staging on ARGONAS ($ARGONAS_DST) =="
    GIT_SSH="${GIT_SSH:-sshpass -p REDACTED ssh -o PubkeyAuthentication=no}"
    $GIT_SSH root@192.168.207.101 "mkdir -p $ARGONAS_DST" || true
    sshpass -p 'REDACTED' scp -o PubkeyAuthentication=no \
        "$OUT/singularity-opt.tgz" "root@192.168.207.101:$ARGONAS_DST/" \
        && echo "  pushed to ARGONAS:$ARGONAS_DST/singularity-opt.tgz"
fi

echo ""
echo "Next: stage into the repo for the ISO build:"
echo "  cp $OUT/singularity-opt.tgz assets/singularity/singularity-opt.tgz"
echo "(the blob is gitignored — build-squashfs-layers.sh bakes it into desktop.squashfs;"
echo " build-iso-di.sh also stages it to /cixmini/assets/singularity for install-time.)"
