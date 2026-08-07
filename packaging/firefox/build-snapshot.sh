#!/bin/bash
# Build Firefox from a Mozilla release tarball with the NCZ V4L2 gate patch.
#
# This exists for one patch. Firefox 153 already ships h264/vp8/vp9/hevc/av1
# _v4l2m2m decoder selection upstream - entrpi's decoder patches landed
# somewhere between 146 and 153 - but ShouldEnableLinuxHWDecoding() still gates
# every codec on gfxVars::Use*HwDecode(), which are populated from Firefox's
# VA-API probe. On a V4L2-M2M-only platform those are all false, so
# InitV4L2Decoder() is never reached and Firefox decodes in software.
#
# MEASURED on stock Mozilla 153.0.3: the FFmpeg module reports it supports
# video/avc, vp8, vp9, hevc and av1, while 629 lines of PlatformDecoderModule
# logging contain no V4L2 line at all and /dev/video* is never opened.
#
# The intent is to retire this pipeline: the gate is an upstream bug affecting
# every V4L2-only platform, and the patch is being sent to Mozilla. When it
# lands, delete this directory.
#
# Usage: build-snapshot.sh [--version 153.0.3]
#
# Exit codes:
#   0 success   2 fetch failed   3 patch failed/fuzz   4 configure failed
#   5 build failed
set -u

VERSION="${1:-}"
[ "${1:-}" = "--version" ] && VERSION="$2"
VERSION="${VERSION:-${NCZ_FIREFOX_VERSION:-153.0.3}}"

WORK="${NCZ_FIREFOX_WORK:-$HOME/ff-build}"
PATCH_DIR="${NCZ_PATCH_DIR:-$HOME/cix-installer/docs/upstream-patches/firefox}"
SRC="$WORK/firefox-$VERSION"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }
die() { echo "ERROR: $*" >&2; exit "$2"; }

mkdir -p "$WORK"
cd "$WORK" || die "cannot enter $WORK" 2

# --- fetch ------------------------------------------------------------------
TARBALL="firefox-$VERSION.source.tar.xz"
if [ ! -d "$SRC" ]; then
    if [ ! -f "$TARBALL" ]; then
        log "fetching Firefox $VERSION source"
        curl -fsSL --max-time 900 -O \
            "https://archive.mozilla.org/pub/firefox/releases/$VERSION/source/$TARBALL" \
            || die "download failed" 2
    fi
    log "extracting"
    tar xf "$TARBALL" || die "extract failed" 2
fi
cd "$SRC" || die "no source tree at $SRC" 2

# --- patch ------------------------------------------------------------------
# Fuzz is a hard failure. A hunk that lands slightly off can end up somewhere
# that no longer gates anything, and the build would then succeed while
# silently decoding in software - which is exactly the state this patch exists
# to fix, and exactly how the earlier ESR patches went unnoticed.
log "applying NCZ patch series"
shopt -s nullglob
applied=0
for p in "$PATCH_DIR"/*v4l2-gate*.patch "$PATCH_DIR"/*gate*.patch; do
    [ -f "$p" ] || continue
    out=$(patch -p1 --forward --no-backup-if-mismatch < "$p" 2>&1)
    rc=$?
    if [ $rc -ne 0 ]; then
        echo "$out" | grep -q "Reversed (or previously applied)" \
            && { log "already applied: $(basename "$p")"; applied=$((applied+1)); continue; }
        echo "$out" | sed 's/^/    /'
        die "patch failed: $(basename "$p")" 3
    fi
    echo "$out" | grep -qi fuzz && die "patch applied WITH FUZZ: $(basename "$p")" 3
    applied=$((applied+1))
done
shopt -u nullglob
[ "$applied" -gt 0 ] || die "no gate patch found in $PATCH_DIR" 3

# Confirm the patch did what it claims. Without this a rename upstream would
# leave a build that compiles and does nothing.
n=$(grep -c 'ifdef MOZ_ENABLE_V4L2' dom/media/platforms/ffmpeg/FFmpegVideoDecoder.cpp)
[ "$n" -ge 5 ] || die "expected >=5 MOZ_ENABLE_V4L2 blocks after patching, found $n" 3
log "gate bypass present in $n places"

# --- configure --------------------------------------------------------------
# MOZ_ENABLE_V4L2 is set automatically for aarch64 with the GTK toolkit by
# toolkit/moz.configure - there is no --enable-v4l2 option, and passing one is
# a hard configure error.
cat > mozconfig <<'EOF'
ac_add_options --enable-application=browser
ac_add_options --enable-optimize
ac_add_options --disable-debug
ac_add_options --disable-tests
ac_add_options --without-wasm-sandboxed-libraries
mk_add_options MOZ_OBJDIR=@TOPSRCDIR@/objdir
mk_add_options MOZ_MAKE_FLAGS="-j8"
EOF

export SHELL=/bin/bash
export MOZBUILD_STATE_PATH="$HOME/.mozbuild"
export PATH="$HOME/.cargo/bin:$PATH"
export MOZ_NOSPAM=1

# --- build ------------------------------------------------------------------
log "building (hours)"
./mach build > /tmp/ncz-firefox-build.log 2>&1 || {
    grep -E "^ *[0-9:.]+ E |error:" /tmp/ncz-firefox-build.log | tail -20
    die "build failed, see /tmp/ncz-firefox-build.log" 5
}
[ -x objdir/dist/bin/firefox ] || die "no firefox binary produced" 5

log "built $VERSION"
ls -l objdir/dist/bin/firefox
