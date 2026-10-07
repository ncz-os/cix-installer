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
# UPSTREAM PINS (2026-10-06). Every upstream repository this build clones --
# the singularity-desktop superproject, each of its submodules, vetro and the
# boot splash -- is checked out at the exact commit in
# assets/singularity/upstream-pins.tsv, through build/singularity-pins.sh.
# Until then the superproject was taken from master and every submodule was
# re-pinned to its tracked branch head on every run, so a stage-1 rebuild of
# a release was a build of whatever upstream had pushed that hour: the r199
# respin broke the same day because libsingularity f3d0f49 (15:01Z) no longer
# took our patch queue. A repository with no pin FAILS the build with its
# path named; nothing falls back to a branch head.
#
# NCZ_SINGULARITY_TRACK_HEAD=1 is the explicit opt-in to the old behaviour
# (superproject at SINGULARITY_REF, default master; submodules at their
# tracked branch heads), for evaluating an upstream bump before pinning it.
# Its output is not reproducible and says so.
PINS_FILE="${NCZ_SINGULARITY_PINS:-$REPO_ROOT/assets/singularity/upstream-pins.tsv}"
TRACK_HEAD="${NCZ_SINGULARITY_TRACK_HEAD:-0}"
SRC_REPO="${SINGULARITY_REPO:-https://github.com/singularityos-lab/singularity-desktop}"
if [ "$TRACK_HEAD" = 1 ]; then
    SRC_REF="${SINGULARITY_REF:-master}"
else
    if [ -n "${SINGULARITY_REF:-}" ]; then
        echo "ERROR: SINGULARITY_REF=$SINGULARITY_REF is not honoured in a pinned build." >&2
        echo "       Change the '.' row of $PINS_FILE, or set NCZ_SINGULARITY_TRACK_HEAD=1" >&2
        echo "       for an explicitly unpinned evaluation build." >&2
        exit 1
    fi
    NCZ_SINGULARITY_PINS="$PINS_FILE" bash "$REPO_ROOT/build/singularity-pins.sh" validate || {
        echo "ERROR: Singularity upstream pins are missing or invalid -- refusing to build from moving branch heads" >&2
        exit 1
    }
    SRC_REF="$(NCZ_SINGULARITY_PINS="$PINS_FILE" bash "$REPO_ROOT/build/singularity-pins.sh" sha .)" || exit 1
fi
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
# The Depends sidecar is regenerated with the tarball; never let a previous
# run's sidecar sit next to a new tarball.
rm -f "$OUT/singularity-opt.tgz.depends" "$OUT/singularity-opt.tgz.sources"
echo "== build-singularity =="
echo "   image  = $IMAGE"
echo "   source = $SRC_REPO @ $SRC_REF"
if [ "$TRACK_HEAD" = 1 ]; then
    echo "   pins   = NONE (NCZ_SINGULARITY_TRACK_HEAD=1: branch heads, NOT reproducible)"
else
    echo "   pins   = $PINS_FILE"
fi
[ -z "$SRC_DIR" ] || echo "   local  = $SRC_DIR (explicit NCZ source override)"
echo "   prefix = $PREFIX"
echo "   out    = $OUT/singularity-opt.tgz"
echo "           $OUT/singularity-opt.tgz.depends (Depends sidecar)"
echo "           $OUT/singularity-opt.tgz.sources (upstream commit of every repo built)"

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
    libgee-0.8-dev libsoup-3.0-dev libenchant-2-dev \
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
    libsdl2-dev libgl-dev libglu1-mesa-dev libx11-dev \
    libcairo2-dev libpango1.0-dev libwayland-bin \
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
    cmake libcups2-dev libfuse3-dev libges-1.0-dev libgles-dev \
    libgnutls28-dev libharfbuzz-dev liblcms2-dev libsqlite3-dev zlib1g-dev \
    libgphoto2-dev libtiff-dev libwebp-dev \
    freerdp3-dev libarchive-dev libfido2-dev libfreetype-dev liblzma-dev \
    libsane-dev libxcb-render-util0-dev libxcb-xinput-dev libzbar-dev \
    libzstd-dev nettle-dev \
    libusb-1.0-0-dev libnss3-dev \
    build-essential

mkdir -p /work && cd /work

# vetro host tool (UI .vetro -> .ui transpiler). Go 1.24+.
if [ "$NCZ_SINGULARITY_TRACK_HEAD" = 1 ]; then
    git clone --depth 1 "'"$VETRO_REPO"'" vetro
else
    NCZ_SINGULARITY_URL_OVERRIDE="${VETRO_REPO_OVERRIDE:-}" bash /ncz-build/singularity-pins.sh clone vetro vetro
fi
( cd vetro && go build -o /usr/local/bin/vetro . )
vetro --version 2>/dev/null || true

# Singularity Desktop (recursive: bundled labwc/wlroots + subprojects).  The
# local override is for reviewed NCZ commits that have not yet been published
# upstream; it is mounted read-only and copied into the disposable container
# workspace before any build writes occur.
if [ -n "${SINGULARITY_SOURCE_DIR:-}" ]; then
    cp -a "$SINGULARITY_SOURCE_DIR" singularity-desktop
elif [ "$NCZ_SINGULARITY_TRACK_HEAD" = 1 ]; then
    git clone --recursive --branch "'"$SRC_REF"'" "'"$SRC_REPO"'" singularity-desktop
else
    # Superproject at its pin, then every submodule at ITS pin. checkout-tree
    # fails, naming the path, if .gitmodules declares a submodule the pin file
    # does not cover (or the pin file names one that no longer exists).
    NCZ_SINGULARITY_URL_OVERRIDE="${SINGULARITY_REPO_OVERRIDE:-}" \
        bash /ncz-build/singularity-pins.sh clone . singularity-desktop
    bash /ncz-build/singularity-pins.sh checkout-tree singularity-desktop
fi
cd singularity-desktop

# The superproject commits fixed submodule pins, and they can be stale
# relative to the branch .gitmodules itself declares each one tracks --
# measured 2026-09-06: singularity-shell was dozens of commits behind its
# own main, and labwc was pinned to a commit on main (an unrelated branch)
# when .gitmodules says branch = singularity. A stale pin is not just
# missing recent work -- it changes the file layout our downstream patches
# expect, so a patch that applies cleanly against a subproject real branch
# tip can fail against whatever old commit the superproject happens to have
# committed.
#
# Re-pinning ONLY the subprojects carrying NCZ patches is not enough either:
# doing that alone left singularity-shell on its current main (freshly
# re-pinned) while libsingularity stayed on the superproject stale pin, and
# shell main calls UtilizationMonitor / UtilizationReading / CapacityReading
# APIs that the stale libsingularity does not define yet -- a real compile
# failure, not a patch-apply failure. Submodules are cross-coupled by API,
# not independent, so re-pin every submodule .gitmodules declares a tracked
# branch for, to one consistent all-current-upstream baseline -- this is the
# same policy already used to build this tree (see fc29d68, make the tree
# build again from upstream HEAD), not a new one.
# Since 2026-10-06 this re-pin runs ONLY in an explicit
# NCZ_SINGULARITY_TRACK_HEAD=1 evaluation build. A normal build already has
# every submodule at its pinned commit (singularity-pins.sh checkout-tree
# above), taken from one consistent upstream state, so the cross-coupling
# problem described here cannot arise and upstream pushes cannot reach it.
if [ -z "${SINGULARITY_SOURCE_DIR:-}" ] && [ "$NCZ_SINGULARITY_TRACK_HEAD" = 1 ]; then
    echo "    WARNING: NCZ_SINGULARITY_TRACK_HEAD=1 -- re-pinning submodules to branch heads (not reproducible)"
    git config -f .gitmodules --get-regexp "branch$" | while read -r _key _branch; do
        case "$_key" in
            submodule.*.branch) ;;
            *) continue ;;
        esac
        _tree=${_key#submodule.}
        _tree=${_tree%.branch}
        [ -d "$_tree" ] || continue
        echo "    re-pinning $_tree to its tracked branch ($_branch)"
        git -C "$_tree" fetch origin "$_branch"
        git -C "$_tree" checkout FETCH_HEAD
        if [ -f "$_tree/.gitmodules" ]; then
            git -C "$_tree" submodule update --init --recursive
        fi
    done
fi

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

# NCZ downstream patches against the bundled subprojects. Applied after the
# upstream queue so upstream always wins a conflict. Each patch is checked with
# --check first and skipped when already applied, so re-running is safe; a
# patch that does not apply is a HARD failure rather than a warning, because a
# silently-unpatched build looks identical to a patched one and that is exactly
# how the labwc replug fix went missing from an earlier tarball.
# Layout is /ncz-patches/<subproject>/NNNN-*.patch, and each patch applies with
# paths relative to the root of THAT subproject. Keeping the subproject in the
# directory name rather than guessing from the patch content means a patch can
# never be applied against the wrong tree -- the first version of this assumed
# every patch was for labwc, which would have silently mis-targeted the shell.
if [ -d /ncz-patches ]; then
    for _sub in /ncz-patches/*/; do
        [ -d "$_sub" ] || continue
        _name=$(basename "$_sub")
        _tree="subprojects/$_name"
        # A patch directory named after the ROOT repo itself (singularity-desktop
        # is not its own subproject/submodule) applies at the top level instead.
        # Added 2026-09-18 for the first such patch (PR #251, gschema keys) --
        # every prior ncz-patches entry targeted an actual subproject/submodule.
        if [ ! -d "$_tree" ] && [ "$_name" = "$(basename "$PWD")" ]; then
            _tree="."
        fi
        if [ ! -d "$_tree" ]; then
            echo "ERROR: ncz patches exist for $_name but $_tree is not in this tree" >&2
            exit 1
        fi
        for _p in "$_sub"*.patch; do
            [ -e "$_p" ] || continue
            if git -C "$_tree" apply --check "$_p" 2>/dev/null; then
                git -C "$_tree" apply "$_p"
                echo "    ncz patch applied: $_name/$(basename "$_p")"
            elif git -C "$_tree" apply --reverse --check "$_p" 2>/dev/null; then
                echo "    ncz patch already present: $_name/$(basename "$_p")"
            else
                echo "ERROR: ncz patch does not apply: $_name/$(basename "$_p")" >&2
                exit 1
            fi
        done
    done
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
start = s.find("    private void toggle_workspace_overview() {")
end = s.find("\n    }", start)
if start < 0 or end < 0:
    raise SystemExit("ERROR: toggle_workspace_overview() gone -- upstream moved; rebase the NCZ launcher-popup fix")
body = s[start:end]
anchor = "        if (!ensure_workspace_overview()) return;"
if anchor not in body:
    raise SystemExit("ERROR: toggle_workspace_overview() anchor gone -- upstream moved; rebase the NCZ launcher-popup fix")
add = ("        // Close the launcher popup first: the workspace chooser is a\n"
       "        // full-screen TOP layer, and leaving AppMenu visible lets the\n"
       "        // chooser hover over (and visually occlude) the main menu when\n"
       "        // Workspaces is invoked from the panel/dock.\n"
       "        if (app_menu != null && app_menu.visible) {\n"
       "            app_menu.toggle();\n"
       "        }\n")
patched = body.replace(anchor, add + anchor, 1)
open(f, "w", encoding="utf-8").write(s[:start] + patched + s[end:])
print("    shell: launcher-popup fix applied")
PY_NCZ_SHELL
fi

# SKIP singularity-gestures on this build.
#
# Its meson.build requires include_directories(..., "runtime/include"), and
# runtime/ ships only a .gitignore -- the directory is populated by
# scripts/bootstrap-runtime.sh, which downloads MediaPipe and ONNX Runtime at
# build time. That script has NO architecture detection: it hardcodes
#   onnxruntime-linux-x64-$onnx_version.tgz
# so on aarch64 it fetches x86-64 binaries. The subproject is pulled in
# unconditionally by the top-level meson.build (there is no meson option to
# turn it off), so an arm64 build of singularity-desktop cannot configure at
# all as of upstream d642160.
#
# Dropping the subproject line is a BUILD workaround, not a fix, and it is
# deliberately confined to this staging copy -- nothing is committed upstream.
# Reported separately; the real fix belongs in bootstrap-runtime.sh.
if grep -q "subproject('"'"'singularity-gestures'"'"')" meson.build; then
    sed -i "/subproject('"'"'singularity-gestures'"'"')/d" meson.build
    echo "    NOTE: singularity-gestures skipped (bootstrap-runtime.sh is x86-64 only)"
fi

# SKIP singularity-edit on this build (TEMPORARY, 2026-09-05, wallpaper-UX
# verification build only -- NOT committed upstream, NOT a permanent fix).
#
# Its vendored tree-sitter runtime (subprojects/singularity-edit/vendor/
# tree-sitter/lib/src/lib.c) fails to compile under the GCC in this image
# (16.2.0-1, Debian forky) -- ninja stops with subcommand failed and ZERO
# compiler diagnostic output, reproduced identically 3 times at the exact
# same object (vendor_tree-sitter_lib_src_lib.c.o), which is a toolchain/
# vendored-code issue unrelated to any NCZ patch. singularity-edit is a
# standalone subproject() call in the top-level meson.build with no
# variable captured from it, so it is not a build dependency of
# singularity-shell/singularity-desktop -- safe to skip when the goal is
# testing shell-side changes, not the editor app itself.
if grep -q "subproject('"'"'singularity-edit'"'"')" meson.build; then
    sed -i "/subproject('"'"'singularity-edit'"'"')/d" meson.build
    echo "    NOTE: singularity-edit skipped (tree-sitter vendor build fails under this GCC, unrelated to NCZ patches)"
fi
# The Makefile pulls the same bootstrap in independently of meson:
#   Makefile:8   $(BUILD_DIR)/build.ninja: | gesture-runtime
#   Makefile:17  compile: gesture-runtime $(BUILD_DIR)/build.ninja labwc
# so `make compile` runs scripts/bootstrap-runtime.sh even after the subproject
# is dropped. That script also hardcodes /usr/bin/python3.12, which does not
# exist in this container, so it dies with "Error 127" before any download is
# even attempted. Strip the prerequisite from both rules.
if [ -f Makefile ] && grep -q "gesture-runtime" Makefile; then
    sed -i "s/^compile: gesture-runtime /compile: /" Makefile
    sed -i "s/: | gesture-runtime$/:/" Makefile   # keep the rule colon
    echo "    NOTE: gesture-runtime make prerequisite removed"
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

# The local wallpaper-selector branch provides these pure-logic regressions
# and a non-installed probe for comparing the gallery with live board state.
if [ -x build/subprojects/singularity-shell/wallpaper-gallery-probe ]; then
    meson test -C build --print-errorlogs wallpaper-gallery wallpaper-collections wallpaper-rotation-state
    cp build/subprojects/singularity-shell/wallpaper-gallery-probe /out/
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
if [ "$NCZ_SINGULARITY_TRACK_HEAD" = 1 ]; then
    git clone --depth 1 --recurse-submodules \
        https://github.com/singularityos-lab/singularity-boot-splash.git
else
    bash /ncz-build/singularity-pins.sh clone singularity-boot-splash singularity-boot-splash
fi
cd singularity-boot-splash
# The boot splash bundles its OWN copy of singularity-loginui (the Cairo
# renderer that draws the logo and loading bar), so the loginui patches the
# desktop tree received above must be applied here as well, or the boot splash
# keeps the unpatched renderer while the session splash gets the fixed one.
# Same contract as the desktop loop: apply, or skip when already present, or
# fail the build. Only the loginui queue applies here; the other patch
# directories target subprojects this repository does not bundle.
if [ -d /ncz-patches/singularity-loginui ]; then
    for _p in /ncz-patches/singularity-loginui/*.patch; do
        [ -e "$_p" ] || continue
        _lt=subprojects/singularity-loginui
        if git -C "$_lt" apply --check "$_p" 2>/dev/null; then
            git -C "$_lt" apply "$_p"
            echo "    ncz patch applied (boot-splash): singularity-loginui/$(basename "$_p")"
        elif git -C "$_lt" apply --reverse --check "$_p" 2>/dev/null; then
            echo "    ncz patch already present (boot-splash): singularity-loginui/$(basename "$_p")"
        else
            echo "ERROR: ncz patch does not apply to the boot-splash loginui: $(basename "$_p")" >&2
            exit 1
        fi
    done
fi
meson setup build --prefix='"$PREFIX"' --libdir=lib --buildtype=release
ninja -C build
DESTDIR=/work/stage meson install -C build
test -x "/work/stage'"$PREFIX"'/bin/singularity-boot-splash"

# Package. Paths are opt/singularity/... so `tar -C /` lands at /opt/singularity.
cd /work/stage
tar -czf /out/singularity-opt.tgz opt/singularity
echo "STAGED $(du -h /out/singularity-opt.tgz | cut -f1)"

# Provenance sidecar: the upstream commit of every repository that went into
# this tarball, bound to it by sha256. Recovering what r199 was built from
# took a time-window argument over upstream history because nothing recorded
# it; this is that record.
_tgz_sha="$(sha256sum /out/singularity-opt.tgz | cut -d" " -f1)"
[ -n "$_tgz_sha" ]
{
    echo "# singularity-opt.tgz sha256 $_tgz_sha"
    if [ "$NCZ_SINGULARITY_TRACK_HEAD" = 1 ]; then echo "# mode track-head (NOT pinned)";
    elif [ -n "${SINGULARITY_SOURCE_DIR:-}" ]; then echo "# mode local-source-dir (NOT pinned)";
    else echo "# mode pinned"; fi
    bash /ncz-build/singularity-pins.sh provenance /work/singularity-desktop /work/vetro /work/singularity-boot-splash
} > /out/singularity-opt.tgz.sources
echo "== upstream sources =="; cat /out/singularity-opt.tgz.sources

# Depends sidecar for build-singularity-deb.sh. Derived HERE because this
# container is the one userland where every library the payload links is
# installed, at exactly the versions it was linked against (dpkg-shlibdeps
# reads their shlibs/symbols files). Bound to the tarball by sha256 so a
# stale sidecar can never describe a different payload.
bash /ncz-build/singularity-deb-depends.sh --direct \
    --payload-sha256 "$(sha256sum /out/singularity-opt.tgz | cut -d" " -f1)" \
    -o /out/singularity-opt.tgz.depends /work/stage
grep "^Depends: " /out/singularity-opt.tgz.depends
'

# Pin the container platform explicitly. Without this, a locally-cached
# image under the SAME tag but a DIFFERENT architecture (e.g. pulled earlier
# in a session doing arm64 work) is reused as-is by both docker and podman --
# no re-resolve, no warning -- and the whole build silently runs under qemu
# emulation for the wrong target. Caught 2026-09-15 building this natively
# on amd64 PROTEUS: "debian:forky" was still cached from an arm64 pipeline
# run earlier the same session, so uname -m inside the container reported
# aarch64 despite the host being amd64, and apt pulled arm64 packages the
# whole way through with no visible error.
case "$(dpkg --print-architecture 2>/dev/null || uname -m)" in
    amd64|x86_64) NCZ_CONTAINER_PLATFORM=linux/amd64 ;;
    arm64|aarch64) NCZ_CONTAINER_PLATFORM=linux/arm64 ;;
    *) NCZ_CONTAINER_PLATFORM="" ;;
esac

echo "== running build in $IMAGE ($CE)${NCZ_CONTAINER_PLATFORM:+ platform=$NCZ_CONTAINER_PLATFORM} =="
CE_ARGS=(--rm --network="$CONTAINER_NETWORK" -v "$OUT":/out \
         -v "$REPO_ROOT/build":/ncz-build:ro \
         -e SRC_REF="$SRC_REF" -e SINGULARITY_METADATA_SEARCH_DEV="$METADATA_SEARCH_DEV" \
         -e NCZ_SINGULARITY_TRACK_HEAD="$TRACK_HEAD")
if [ "$TRACK_HEAD" != 1 ]; then
    CE_ARGS+=(-v "$PINS_FILE":/ncz-pins.tsv:ro -e NCZ_SINGULARITY_PINS=/ncz-pins.tsv)
    # An explicit SINGULARITY_REPO / VETRO_REPO (e.g. a local mirror) still
    # supplies the bytes; the commit still comes from the pin file.
    [ -n "${SINGULARITY_REPO:-}" ] && CE_ARGS+=(-e SINGULARITY_REPO_OVERRIDE="$SINGULARITY_REPO")
    [ "$VETRO_REPO" != "https://github.com/singularityos-lab/vetro" ] && CE_ARGS+=(-e VETRO_REPO_OVERRIDE="$VETRO_REPO")
fi
[ -n "$NCZ_CONTAINER_PLATFORM" ] && CE_ARGS+=(--platform "$NCZ_CONTAINER_PLATFORM")
# On an SELinux-enforcing host the bind mount is unwritable from inside the
# container, and the build only discovers it at the very END -- every subproject
# compiles and installs to /work/stage, then the final tar dies with
#     tar (child): /out/singularity-opt.tgz: Cannot open: Permission denied
#     tar: /out/singularity-opt.tgz: Cannot write: Broken pipe
# The "Broken pipe" is the visible line and is a red herring; the permission
# error above it is the cause. Disable labelling for the mount rather than
# relabelling the tree, which is what y6-run-ultra.sh already does on this host
# for the same reason. Podman only -- docker does not take this flag the same
# way, and this was written on a host without SELinux enforcing.
# NOTE (2026-09-05): basename "$CE" alone is NOT reliable -- podman-docker
# installs a /usr/bin/docker that IS podman under the hood (command -v docker
# picks it first, so $CE resolves to "docker" even on a podman-only host).
# "$CE --version" still prints "podman version ..." in that case since it is
# literally exec-ing the podman binary, so check the version STRING instead
# of the resolved binary's name.
if "$CE" --version 2>/dev/null | grep -qi podman && [ "$(getenforce 2>/dev/null)" = Enforcing ]; then
    CE_ARGS+=(--security-opt label=disable)
    echo "   note: SELinux enforcing -- adding --security-opt label=disable for the /out mount"
fi
if [ -n "$SRC_DIR" ]; then
    CE_ARGS+=(-v "$SRC_DIR":/src:ro -e SINGULARITY_SOURCE_DIR=/src)
fi
# Our downstream patch queue. The build clones its own copy of the source
# INSIDE the container, so assets/singularity/patches/ is invisible to it
# unless mounted -- which is why a tarball built here was a clean upstream
# baseline and silently did NOT contain our labwc fix. Mount it read-only.
NCZ_PATCHES="$REPO_ROOT/assets/singularity/patches"
if [ -d "$NCZ_PATCHES" ]; then
    CE_ARGS+=(-v "$NCZ_PATCHES":/ncz-patches:ro)
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
echo "Next: stage into the repo for the image build:"
echo "  cp $OUT/singularity-opt.tgz assets/singularity/singularity-opt.tgz"
echo "(the blob is gitignored — build-squashfs-layers.sh bakes it into desktop.squashfs.)"
