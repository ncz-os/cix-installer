#!/bin/bash
# Weekly snapshot build of Chromium NCZ Sky1 Edition.
#
# Syncs to a Chromium release tag, applies the NCZ patch series, builds arm64,
# and produces a .deb. Intended to run unattended on an x86 build host
# (cross-compiling to arm64); the decode verification runs separately on real
# Sky1 hardware, because nothing here can prove a codec works.
#
# Usage:  build-snapshot.sh [--channel stable|beta] [--tag <version>] [--skip-sync]
#
# Exit codes are distinct so a scheduler can tell apart "upstream moved under
# us" from "our patches broke" from "the build broke":
#   0  success
#   2  sync failed
#   3  a patch did not apply, or applied with fuzz (see FUZZ POLICY)
#   4  gn gen failed / expected build flags absent
#   5  compile failed
#   6  packaging failed
set -u
set -o pipefail

CHANNEL="stable"
TAG=""
SKIP_SYNC=0
while [ $# -gt 0 ]; do
    case "$1" in
        --channel) CHANNEL="$2"; shift 2 ;;
        --tag)     TAG="$2"; shift 2 ;;
        --skip-sync) SKIP_SYNC=1; shift ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done

SRC_ROOT="${CHROMIUM_SRC_ROOT:-$HOME/chromium-build}"
SRC="$SRC_ROOT/src"
OUT="out/sky1"
PATCH_DIR="${NCZ_PATCH_DIR:-$HOME/cix-installer/docs/upstream-patches/chromium}"
UAPI_DIR="${NCZ_UAPI_DIR:-$HOME/ncz-uapi}"   # v4l2-controls.h + videodev2.h from a >=6.0 kernel
STAMP="$(date -u +%Y%m%d)"
export PATH="$HOME/depot_tools:$PATH"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }
die() { echo "ERROR: $*" >&2; exit "$2"; }

# --- resolve the tag to build -----------------------------------------------
if [ -z "$TAG" ]; then
    log "resolving latest $CHANNEL tag from chromiumdash"
    TAG=$(curl -sL --max-time 30 \
        "https://chromiumdash.appspot.com/fetch_releases?channel=${CHANNEL^}&platform=Linux&num=1" \
        | python3 -c 'import sys,json; print(json.load(sys.stdin)[0]["version"])' 2>/dev/null)
    [ -n "$TAG" ] || die "could not resolve a $CHANNEL version" 2
fi
log "channel=$CHANNEL tag=$TAG"

# --- sync -------------------------------------------------------------------
if [ "$SKIP_SYNC" = 0 ]; then
    cd "$SRC" || die "no source tree at $SRC" 2
    log "fetching tags"
    git fetch --tags origin >/dev/null 2>&1 || die "git fetch failed" 2
    # Discard our patches before checkout; they are reapplied below from the
    # canonical series, so the tree is never a mix of old and new.
    git checkout -- . 2>/dev/null
    git checkout "$TAG" >/dev/null 2>&1 || die "no such tag: $TAG" 2
    log "gclient sync (this is the slow part)"
    gclient sync --no-history --shallow --force -j8 >/tmp/ncz-sync.log 2>&1 \
        || die "gclient sync failed, see /tmp/ncz-sync.log" 2
fi

cd "$SRC" || die "no source tree at $SRC" 2
BUILT_VERSION=$(sed -n 's/^MAJOR=//p;' chrome/VERSION | head -1)
log "tree reports MAJOR=$BUILT_VERSION"

# --- sysroot kernel headers -------------------------------------------------
# Chromium's pinned Debian sysroot ships kernel UAPI 6.1 (LINUX_VERSION_CODE
# 393566); the V4L2 stateless AV1 uAPI landed in 6.5. So use_av1_hw_decoder
# cannot compile against the stock sysroot, and upstream disables it for V4L2
# on purpose - see crrev.com/c/6632634 ("media/gpu/v4l2: Allow enabling AV1
# support on Linux", merged 2025-06-12, Bug 372630272), which added the
# use_av1_hw_decoder flag precisely so builders who DO have suitable headers
# can opt in. We set that flag in args.gn below; this block supplies the
# headers it needs. Do not "fix" this by patching media/gpu/args.gni - that
# reverts a considered upstream decision (we tried; crrev.com/c/8230288 was
# abandoned for exactly this reason).
#
# All three architectures need it: the clang_x64_v8_arm64 host toolchain builds
# against the amd64 sysroot, so patching only arm64 fails late in the build.
#
# If upstream ever refreshes the sysroot (crrev.com/c/7548596 is the open CL),
# the v4l2_ctrl_av1_sequence probe below simply stops firing and this whole
# block becomes a no-op. Nothing else needs changing.
AV1_UAPI_SYMS="v4l2_ctrl_av1_sequence V4L2_CID_MPEG_VIDEO_AV1_PROFILE V4L2_AV1_SEQUENCE_FLAG_SUBSAMPLING_X"
uapi_validated=0
for arch in amd64 arm64 i386; do
    d="build/linux/debian_bullseye_${arch}-sysroot/usr/include/linux"
    [ -d "$d" ] || continue
    if ! grep -q v4l2_ctrl_av1_sequence "$d/v4l2-controls.h" 2>/dev/null; then
        [ -f "$UAPI_DIR/v4l2-controls.h" ] || die "need modern UAPI headers in $UAPI_DIR" 3
        [ -f "$UAPI_DIR/videodev2.h" ]     || die "need modern UAPI headers in $UAPI_DIR" 3
        # Validate the replacement headers ONCE, before copying anything. A
        # too-old $UAPI_DIR used to copy cleanly and then fail ~45 minutes into
        # the compile with "incomplete result type 'struct v4l2_ctrl_av1_sequence'".
        if [ "$uapi_validated" -eq 0 ]; then
            for sym in $AV1_UAPI_SYMS; do
                grep -qr "$sym" "$UAPI_DIR/v4l2-controls.h" "$UAPI_DIR/videodev2.h" 2>/dev/null \
                    || die "$UAPI_DIR headers lack $sym - they predate the V4L2 AV1 uAPI (needs kernel >= 6.5)" 3
            done
            grep -q "V4L2_PIX_FMT_AV1" "$UAPI_DIR/videodev2.h" 2>/dev/null \
                || die "$UAPI_DIR/videodev2.h lacks V4L2_PIX_FMT_AV1 (needs kernel >= 6.5)" 3
            uapi_validated=1
            log "UAPI headers in $UAPI_DIR validated for AV1 V4L2"
        fi
        cp -n "$d/v4l2-controls.h" "$d/v4l2-controls.h.orig" 2>/dev/null
        cp -n "$d/videodev2.h"     "$d/videodev2.h.orig" 2>/dev/null
        cp "$UAPI_DIR/v4l2-controls.h" "$UAPI_DIR/videodev2.h" "$d/"
        log "sysroot $arch: AV1 V4L2 controls installed"
    fi
done

# --- patch series -----------------------------------------------------------
# FUZZ POLICY: a patch that applies with fuzz is treated as a failure, not a
# warning. Fuzz means upstream moved the surrounding code, and a hunk can land
# somewhere that no longer does anything - which is exactly how the Firefox
# V4L2 patches silently stopped working across a version bump. Better to stop
# the build and re-examine than to ship a browser whose acceleration quietly
# turned itself off.
log "applying NCZ patch series from $PATCH_DIR"
shopt -s nullglob
for p in "$PATCH_DIR"/*.patch; do
    out=$(patch -p1 --forward --no-backup-if-mismatch < "$p" 2>&1)
    rc=$?
    echo "$out" | sed 's/^/    /'
    if [ $rc -ne 0 ]; then
        echo "$out" | grep -q "Reversed (or previously applied)" \
            && { log "already applied: $(basename "$p")"; continue; }
        die "patch failed: $(basename "$p")" 3
    fi
    echo "$out" | grep -qi "fuzz" && die "patch applied WITH FUZZ: $(basename "$p") - upstream moved, re-check it still does what it should" 3
done
shopt -u nullglob

# --- configure --------------------------------------------------------------
mkdir -p "$OUT"
cat > "$OUT/args.gn" <<'ARGS'
target_os = "linux"
target_cpu = "arm64"

is_debug = false
is_official_build = true
symbol_level = 0
blink_symbol_level = 0

# V4L2-M2M stateful hardware video decode (CIX Sky1 VPU).
use_v4l2_codec = true
use_vaapi = false
use_linux_v4l2_only = true

# AV1 over V4L2. Set explicitly rather than by patching the upstream default in
# media/gpu/args.gni: upstream cannot turn this on for Linux V4L2 generally,
# because Chromium's own pinned sysroot has NO V4L2 AV1 UAPI at all (no
# V4L2_PIX_FMT_AV1, no V4L2_CID_MPEG_VIDEO_AV1_PROFILE, no
# v4l2_ctrl_av1_sequence), so the AV1 code would not compile. Our build only
# gets away with it because the sysroot step above injects modern kernel
# headers from $UAPI_DIR. It is a declare_args, so setting it here is all we
# ever needed.
use_av1_hw_decoder = true

use_ozone = true
ozone_platform = "wayland"
ozone_platform_wayland = true
ozone_platform_x11 = true

enable_remoting = false
proprietary_codecs = true
ffmpeg_branding = "Chrome"

# Official builds want PGO profiles that .gclient does not fetch.
chrome_pgo_phase = 0

is_cfi = false
use_thin_lto = false
treat_warnings_as_errors = false
ARGS

log "gn gen"
gn gen "$OUT" >/tmp/ncz-gn.log 2>&1 || { tail -20 /tmp/ncz-gn.log; die "gn gen failed" 4; }

# The whole point of the patch series is that these three are true. If upstream
# renames a flag, the build would otherwise succeed with acceleration silently
# disabled.
for want in "use_av1_hw_decoder = true" "use_v4l2_codec = true" "use_vaapi = false"; do
    key="${want%% *}"
    got=$(gn args "$OUT" --list="$key" --short 2>/dev/null | tail -1)
    [ "$got" = "$want" ] || die "expected '$want' but gn reports '$got'" 4
done
log "build flags confirmed"

# --- build ------------------------------------------------------------------
log "building (hours)"
autoninja -C "$OUT" chrome chrome_sandbox >/tmp/ncz-build.log 2>&1 \
    || { grep -E "^FAILED|error:" /tmp/ncz-build.log | head -20; die "compile failed" 5; }
[ -x "$OUT/chrome" ] || die "no chrome binary produced" 5
log "built $(du -h "$OUT/chrome" | cut -f1) binary"

# --- package ----------------------------------------------------------------
log "packaging .deb"
"$(dirname "$0")/make-deb.sh" "$SRC/$OUT" "$TAG" "$STAMP" "$CHANNEL" \
    || die "packaging failed" 6

log "done: channel=$CHANNEL tag=$TAG"
