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
IMAGE="${SINGULARITY_IMAGE:-ubuntu:26.04}"
SRC_REPO="${SINGULARITY_REPO:-https://github.com/singularityos-lab/singularity-desktop}"
SRC_REF="${SINGULARITY_REF:-main}"
VETRO_REPO="${VETRO_REPO:-https://github.com/singularityos-lab/vetro}"
PREFIX="/opt/singularity"
OUT="${OUT:-$(cd "$(dirname "$0")/.." && pwd)/build/sinty-out}"
ARGONAS_DST="/mnt/datapool/archives/ncz/singularity"
PUSH_ARGONAS=0
[ "${1:-}" = "--push-argonas" ] && PUSH_ARGONAS=1

# Container engine: prefer docker, fall back to podman.
CE="$(command -v docker || command -v podman || true)"
[ -n "$CE" ] || { echo "ERROR: need docker or podman on the build host" >&2; exit 1; }

ARCH="$(uname -m)"
case "$ARCH" in
    aarch64|arm64) ;;
    *) echo "WARN: host arch=$ARCH — Singularity payload is arm64; build MUST run on/emulate aarch64 (this container image is $IMAGE)." >&2 ;;
esac

mkdir -p "$OUT"
echo "== build-singularity =="
echo "   image  = $IMAGE"
echo "   source = $SRC_REPO @ $SRC_REF"
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
    libnm-dev \
    libgoa-1.0-dev \
    sassc \
    libdrm-dev libcairo2-dev libpango1.0-dev libgdk-pixbuf-2.0-dev \
    libpoppler-glib-dev \
    build-essential

mkdir -p /work && cd /work

# vetro host tool (UI .vetro -> .ui transpiler). Go 1.24+.
git clone --depth 1 "'"$VETRO_REPO"'" vetro
( cd vetro && go build -o /usr/local/bin/vetro . )
vetro --version 2>/dev/null || true

# Singularity Desktop (recursive: bundled labwc/wlroots + subprojects).
git clone --recursive --branch "'"$SRC_REF"'" "'"$SRC_REPO"'" singularity-desktop
cd singularity-desktop

# NCZ shell integration: close the launcher popup before opening the full-screen
# workspace chooser. Keep this small downstream patch in the installer tree so
# reproducible payload builds do not depend on an unpublished GitHub commit.
git apply --check <<'PATCH_NCZ_SHELL'
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
[ -d build-labwc ] && DESTDIR=/work/stage meson install -C build-labwc || true
[ -f Makefile ] && grep -q "install:" Makefile && DESTDIR=/work/stage make install 2>/dev/null || true

# Sanity: the shell + session launcher must exist.
test -x "/work/stage'"$PREFIX"'/bin/singularity-desktop"
test -x "/work/stage'"$PREFIX"'/bin/singularity-labwc-session"

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
"$CE" run --rm \
    -v "$OUT":/out \
    -e SRC_REF="$SRC_REF" \
    "$IMAGE" \
    bash -euo pipefail -c "$BUILD_SCRIPT"

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
