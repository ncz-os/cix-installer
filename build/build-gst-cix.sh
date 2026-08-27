#!/bin/bash
# build-gst-cix.sh — build CIX's GStreamer plugins OUT OF TREE against the
# distribution's GStreamer, with no fork of any Debian source package.
#
# WHY THIS EXISTS
#
# CIX ships its GStreamer work as one patch against gstreamer 1.22.1
# (github.com/cixtech/cix_gstreamer). Debian forky ships 1.28.4. Applying the
# whole patch would mean carrying downstream forks of FOUR Debian source
# packages (gstreamer1.0, -base, -good, -bad) and rebasing them on every Debian
# update, forever.
#
# But the patch is not one thing. Measured 2026-08-19 on the 2026q2 patch:
#
#     total                                      +4409  -107
#       already upstream in 1.28.4 (drop)         +802     -0   4 files
#         gstv4l2av1codec.{c,h}   -- 1.28.4 already registers v4l2av1dec
#         video-info-dma.{c,h}    -- libgstvideo already exports 16 dma_drm syms
#       gst-plugins-cix subproject               +1770     -0   16 files
#       everything else (needs rebase)           +1837   -107   47 files
#
# The gst-plugins-cix subproject has ZERO deletions: it is purely additive, a
# standalone meson project that consumes only public GStreamer pkg-config
# modules. So it builds against 1.28.4 unmodified, and nothing in Debian has to
# be forked to get it.
#
# MEASURED RESULT (debian:forky container, arm64, 2026-08-19):
#
#     pkg-config --modversion gstreamer-1.0   -> 1.28.4
#     Dependency gstreamer-base-1.0           -> YES 1.28.4
#     Linking target plugins/afbcparse/libgstafbcparse.so
#     gst-inspect-1.0 libgstafbcparse.so:
#         Name afbcparse / Source module gst-plugins-cix / 1 features: 1 elements
#
# WHAT IS AND IS NOT BUILT
#
#   afbcparse  BUILT. The AFBC bitstream parser -- the piece that matters for
#              AFBC handling in a generic pipeline.
#   sr         SKIPPED. The NOE super-resolution plugin needs pkg-config
#              cix-noe-umd (CIX NPU userspace), which is not published.
#              -Dsr=disabled.
#   libs/      SKIPPED. audio_dsp_if.c needs cix_dsp_api.h from CIX's DSP SDK,
#              also unpublished.
#   tests/     SKIPPED. The v4l2 example expects the in-tree config.h.
#
# TWO PIECES OF GLUE ARE REQUIRED, and both are consequences of building a
# subproject outside its parent tree, not of the version gap:
#
#   1. config.h. The sources include it under HAVE_CONFIG_H, which this
#      project's own meson sets unconditionally. In-tree the parent GStreamer
#      build generates it. We generate a minimal one: GST_PLUGIN_DEFINE consumes
#      exactly VERSION, GST_PACKAGE_NAME and GST_PACKAGE_ORIGIN.
#   2. Dropping the libs/ and tests/ subdirs from the top meson.build, per above.
#
# This does NOT address the AFBC-vs-NV12 decoder capture default reported at
# github.com/cixtech/cix_opensource__vpu_driver/issues/6 -- that is a driver
# default, not a GStreamer plugin.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-$REPO/build/gst-cix-out}"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

CIX_GST_URL="${CIX_GST_URL:-https://github.com/cixtech/cix_gstreamer.git}"
# Pin the patch we measured against. A newer quarterly drop may add files or
# move the subproject; re-measure before bumping this rather than assuming.
PATCH_REL="${PATCH_REL:-debian/gstreamer-1.22.1/patches/gstreamer_1_22_1_for_cix_2026q2.patch}"
IMAGE="${GST_CIX_IMAGE:-debian:${NCZ_BASE_CODENAME:-forky}}"

case "$IMAGE" in
    ubuntu*|*/ubuntu*)
        echo "ERROR: refusing to build on Ubuntu ($IMAGE); link against the base we run on." >&2
        exit 1 ;;
esac

command -v docker >/dev/null 2>&1 && ENGINE=docker || ENGINE=podman
command -v "$ENGINE" >/dev/null 2>&1 || { echo "ERROR: need docker or podman" >&2; exit 1; }

echo "== fetching $CIX_GST_URL"
git clone --depth 1 -q "$CIX_GST_URL" "$WORK/cix_gstreamer"
PATCH="$WORK/cix_gstreamer/$PATCH_REL"
[ -f "$PATCH" ] || { echo "ERROR: patch not found: $PATCH_REL" >&2; exit 1; }

echo "== extracting the gst-plugins-cix subproject from the patch"
SRC="$WORK/gst-plugins-cix"
mkdir -p "$SRC"
python3 - "$PATCH" "$SRC" <<'PY'
import os, sys
patch, outroot = sys.argv[1], sys.argv[2]
PREFIX = 'subprojects/gst-plugins-cix/'
cur = None; newfile = False; body = []; n = 0

def flush():
    global n
    if cur and newfile and body:
        dst = os.path.join(outroot, cur[len(PREFIX):])
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        open(dst, 'w').write(''.join(body))
        n += 1

for line in open(patch, errors='replace'):
    if line.startswith('--- '):
        flush(); body = []
        newfile = line[4:].strip().split('\t')[0] == '/dev/null'
        cur = None
        continue
    if line.startswith('+++ '):
        f = line[4:].strip().split('\t')[0]
        if f.startswith('b/'): f = f[2:]
        cur = f if f.startswith(PREFIX) else None
        continue
    if cur and newfile and line.startswith('+'):
        body.append(line[1:])
flush()
print(f"   extracted {n} files")
if n == 0:
    sys.exit("ERROR: extracted nothing -- the patch layout changed")
PY

echo "== applying standalone glue"
cat > "$SRC/config.h" <<'EOF'
/* Generated by build-gst-cix.sh for the standalone (out-of-tree) build.
 * In-tree this comes from the parent GStreamer build; GST_PLUGIN_DEFINE needs
 * exactly these three. */
#define VERSION            "1.22.1"
#define PACKAGE            "gst-plugins-cix"
#define GST_PACKAGE_NAME   "GStreamer CIX Plug-ins"
#define GST_PACKAGE_ORIGIN "https://github.com/cixtech/cix_gstreamer"
EOF

python3 - "$SRC" <<'PY'
import sys, pathlib
root = pathlib.Path(sys.argv[1])
top = root / 'meson.build'
s = top.read_text()
old = "subdir('libs')\nsubdir('plugins')\nsubdir('tests')"
if old not in s:
    sys.exit("ERROR: meson.build subdir block changed; re-check the upstream layout")
s = s.replace(old,
    "# Standalone build: libs/ needs cix_dsp_api.h (CIX DSP SDK, unpublished)\n"
    "# and tests/ expects the in-tree config.h. afbcparse needs neither.\n"
    "subdir('plugins')")
s = s.replace("configinc = include_directories('.')",
    "configinc = include_directories('.')\n"
    "add_project_arguments('-I' + meson.current_source_dir(), language: 'c')")
top.write_text(s)

pl = root / 'plugins' / 'meson.build'
p = pl.read_text().replace("subdir('afbcparse')\nsubdir('sr')", "subdir('afbcparse')")
pl.write_text(p)
print("   scoped to afbcparse")
PY

echo "== building in $IMAGE"
cat > "$WORK/inner.sh" <<'EOS'
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
    build-essential meson ninja-build pkg-config \
    libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev gstreamer1.0-tools >/dev/null
echo "   host gstreamer: $(pkg-config --modversion gstreamer-1.0)"
cd /src
meson setup build -Dsr=disabled >/dev/null
ninja -C build
echo "== gst-inspect (a linked .so is not a working plugin)"
gst-inspect-1.0 /src/build/plugins/afbcparse/libgstafbcparse.so
EOS

"$ENGINE" run --rm -v "$SRC:/src" -v "$WORK/inner.sh:/inner.sh" "$IMAGE" bash /inner.sh

SO="$SRC/build/plugins/afbcparse/libgstafbcparse.so"
[ -f "$SO" ] || { echo "ERROR: no plugin produced" >&2; exit 1; }
mkdir -p "$OUT"
cp -f "$SO" "$OUT/"
echo "== done: $OUT/libgstafbcparse.so ($(du -h "$SO" | cut -f1))"
echo "   install to \$(pkg-config --variable=pluginsdir gstreamer-1.0) to use it."
