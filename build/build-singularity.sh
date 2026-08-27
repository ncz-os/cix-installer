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
#   1. debian:<codename> arm64 container, matching release.conf (native
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
# RULE (operator, 2026-08-17): NCZ-OS packages are NEVER built on Ubuntu.
# The payload is linked against the base it will RUN on. Forky exposes
# libsodium.so.26; an Ubuntu-built payload wants libsodium.so.23, so an
# Ubuntu build produces a package that cannot load on the shipped system.
# The base is taken from release.conf and pinned to the CODENAME, not the
# moving "testing" alias -- when forky is released, "testing" silently
# becomes the next suite and the payload would be built against the wrong
# libraries with no error.
METADATA_SEARCH_DEV="libtracker-sparql-3.0-dev"
DEFAULT_IMAGE="debian:${NCZ_BASE_CODENAME:-forky}"
IMAGE="${SINGULARITY_IMAGE:-$DEFAULT_IMAGE}"

case "$IMAGE" in
    ubuntu*|*/ubuntu*)
        echo "ERROR: refusing to build an NCZ-OS package on Ubuntu ($IMAGE)." >&2
        echo "       The payload must be linked against the base it runs on;" >&2
        echo "       Forky has libsodium.so.26, Ubuntu has libsodium.so.23." >&2
        exit 1
        ;;
esac
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
# Everything below runs inside the arm64 debian:<codename> container. The DESTDIR
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

# Apply the downstream patch queue inside the disposable build workspace.
# The helper is idempotent: already-applied patches are skipped, but a patch
# that no longer applies fails the build. This closes the clean-worktree trap
# where a package version could advertise the NCZ patch commit while the built
# binary was plain upstream.
if [ -x scripts/apply-downstream-patches.sh ]; then
    git config --global --add safe.directory /work/singularity-desktop || true
    git config --global --add safe.directory /work/singularity-desktop/subprojects/singularity-shell || true
    git config --global --add safe.directory /work/singularity-desktop/subprojects/libsingularity || true
    # ALWAYS run it -- the script above is already idempotent per patch (each
    # patch is individually reverse-apply-checked and skipped if already
    # present). A wholesale already-patched pre-check used to gate this on
    # marker greps for ONE specific patch set (the sensors-panel series).
    # That is exactly the silent-skip trap the comment above warns about: a
    # SOURCE_DIR checkout that already has the sensors-panel commits (e.g.
    # an active dev branch) but NOT a newer patch set (e.g. the ethernet
    # wired-port series) matched the sensors-only markers and skipped replay
    # entirely -- so the newer patch set silently never applied, with no
    # error, while the deb version string and package metadata looked
    # completely normal. Confirmed 2026-08-26: a build against such a tree
    # shipped a libsingularity.so byte-identical (md5) to the pre-vendor
    # build. Removed the pre-check; the per-patch idempotency in
    # apply-downstream-patches.sh is the correct and only gate.
    bash scripts/apply-downstream-patches.sh
fi

# NCZ shell integration: close the launcher popup before opening the full-screen
# workspace chooser. Applied by ANCHOR, not by line number. Upstream refactors
# this file often -- PR #15 moved every close path into layer_window.vala and
# shifted main.vala past 1900 lines -- and a line-addressed `git apply` fails
# the whole build when that happens (it did, on 2026-08-17).
#
# STILL REQUIRED as of upstream main f0792ab (2026-08-15). Upstream now has
# hide_overview(), which DOES close app_menu -- but toggle_workspace_overview(),
# the path the panel/dock actually uses, never calls it. Verified by reading
# both call sites, not by grepping for the symbol.
if [ -z "${SINGULARITY_SOURCE_DIR:-}" ]; then
python3 - <<'PY_NCZ_SHELL'
import sys
f = "subprojects/singularity-shell/src/core/main.vala"
s = open(f, encoding="utf-8").read()
if "Close the launcher popup first" in s:
    print("    shell: launcher-popup fix already present"); raise SystemExit(0)
anchor = "        if (!ensure_workspace_overview()) return;\n        workspace_overview.toggle();"
if anchor not in s:
    raise SystemExit("ERROR: main.vala anchor gone -- upstream moved; rebase the NCZ launcher-popup fix")
add = ("        // Close the launcher popup first: the workspace chooser is a\n"
       "        // full-screen TOP layer, and leaving AppMenu visible lets the\n"
       "        // chooser hover over (and visually occlude) the main menu when\n"
       "        // Workspaces is invoked from the panel/dock.\n"
       "        if (app_menu != null && app_menu.visible) {\n"
       "            app_menu.toggle();\n"
       "        }\n")
open(f, "w", encoding="utf-8").write(s.replace(anchor, add + anchor, 1))
print("    shell: launcher-popup fix applied")
PY_NCZ_SHELL
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
# Upstream Makefile hardcodes --prefix=/usr for the labwc build directory, so a
# `make compile` tree stages the compositor outside the payload. Retarget the
# build directory before installing: the payload must be self-contained under
# PREFIX (the session launcher resolves labwc from there).
meson configure "$LABWC_BUILD_DIR" --prefix='"$PREFIX"' >/dev/null
DESTDIR=/work/stage meson install -C "$LABWC_BUILD_DIR"

# The upstream Meson install deliberately installs schema XML, but it does not
# install a compiled GSettings database.  Raw XML is not usable by GSettings at
# runtime: launching singularity-desktop then aborts with "Settings schema
# 'dev.sinty.desktop' is not installed".  Compile *inside the staged prefix*
# so the payload is self-contained and GSETTINGS_SCHEMA_DIR can point solely at
# /opt/singularity/share/glib-2.0/schemas.
SCHEMA_DIR="/work/stage'"$PREFIX"'/share/glib-2.0/schemas"
[ -f "$SCHEMA_DIR/dev.sinty.desktop.gschema.xml" ] || {
    echo "ERROR: staged tree is missing dev.sinty.desktop.gschema.xml" >&2; exit 1; }
glib-compile-schemas --strict "$SCHEMA_DIR"

# Sanity: the shell, session launcher, and compositor must all exist.  Report
# what is missing: a bare `test` exits 1 with no output, which reads as a silent
# build hang in the log.
for staged in "/work/stage'"$PREFIX"'/bin/singularity-desktop" \
              "/work/stage'"$PREFIX"'/bin/singularity-labwc-session" \
              "/work/stage'"$PREFIX"'/bin/labwc"; do
    [ -x "$staged" ] || {
        echo "ERROR: staged executable is missing: $staged" >&2; exit 1; }
done
[ -s "$SCHEMA_DIR/gschemas.compiled" ] || {
    echo "ERROR: compiled GSettings schema cache is missing or empty" >&2; exit 1; }

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
echo "  top entries:"; tar tzf "$OUT/singularity-opt.tgz" | awk 'NR <= 3 { print }'

if [ "$PUSH_ARGONAS" = 1 ]; then
    echo "== staging on ARGONAS ($ARGONAS_DST) =="
    # Maintainer push path: ARGONAS_PASS from the environment, else SSH keys.
    if [ -n "${ARGONAS_PASS:-}" ]; then
        GIT_SSH="${GIT_SSH:-sshpass -p $ARGONAS_PASS ssh -o PubkeyAuthentication=no}"
    else
        GIT_SSH="${GIT_SSH:-ssh}"
    fi
    $GIT_SSH root@192.168.207.101 "mkdir -p $ARGONAS_DST" || true
    if [ -n "${ARGONAS_PASS:-}" ]; then
        SCP_CMD="sshpass -p $ARGONAS_PASS scp -o PubkeyAuthentication=no"
    else
        SCP_CMD="scp"
    fi
    $SCP_CMD \
        "$OUT/singularity-opt.tgz" "root@192.168.207.101:$ARGONAS_DST/" \
        && echo "  pushed to ARGONAS:$ARGONAS_DST/singularity-opt.tgz"
fi

echo ""
echo "Next: stage into the repo for the ISO build:"
echo "  cp $OUT/singularity-opt.tgz assets/singularity/singularity-opt.tgz"
echo "(the blob is gitignored — build-squashfs-layers.sh bakes it into desktop.squashfs;"
echo " build-iso-di.sh also stages it to /cixmini/assets/singularity for install-time.)"
