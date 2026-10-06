#!/bin/bash
# test-splash-logo-fit.sh -- render the boot/session splash frame through the
# REAL singularity-loginui renderer at several resolutions and check that the
# NCZ-OS wordmark is fully on screen and at most 60 % of the width.
#
# Needs a loginui source tree (the renderer lives upstream, not in this repo),
# a C compiler and the cairo, pangocairo and gdk-pixbuf development packages,
# so it is a manual tool and is deliberately not wired into `make`:
#
#   LOGINUI_SRC=/path/to/singularity-loginui OUT_DIR=/path/out \
#       bash build/test-splash-logo-fit.sh
#
# PATCH=1 (default) applies assets/singularity/patches/singularity-loginui/*
# to a private copy of LOGINUI_SRC first, exactly as build-singularity.sh does.
# PATCH=0 renders the unpatched upstream renderer; combine it with
# EXPECT=fail to prove the check catches the original cropping.
# RESOLUTIONS overrides the list (space separated WxH). PNGs land in OUT_DIR.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${LOGINUI_SRC:?set LOGINUI_SRC to a singularity-loginui checkout}"
OUT="${OUT_DIR:?set OUT_DIR to a directory for the rendered PNGs}"
LOGO="${LOGO:-$ROOT/assets/branding/greeter/cygnus/ncz-os-cygnus-logo.png}"
PATCH="${PATCH:-1}"
EXPECT="${EXPECT:-pass}"
RESOLUTIONS="${RESOLUTIONS:-3072x1920 1920x1080 1366x768 1024x768 1080x1920}"
CC="${CC:-cc}"

[ -f "$LOGO" ] || { echo "FATAL: logo not found: $LOGO" >&2; exit 2; }
[ -f "$SRC/src/render.c" ] || { echo "FATAL: not a loginui tree: $SRC" >&2; exit 2; }
mkdir -p "$OUT"
WORK="$(mktemp -d "${TMPDIR:-$OUT}/splash-fit.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

cp -a "$SRC/." "$WORK/loginui"
if [ "$PATCH" = 1 ]; then
    for p in "$ROOT"/assets/singularity/patches/singularity-loginui/*.patch; do
        [ -e "$p" ] || continue
        if ! (cd "$WORK/loginui" && git apply "$p" 2>/dev/null || patch -p1 -s < "$p"); then
            echo "FATAL: patch does not apply: $(basename "$p")" >&2
            exit 2
        fi
        echo "applied $(basename "$p")"
    done
fi

# shellcheck disable=SC2046
if ! "$CC" -O1 -o "$WORK/harness" \
        -I"$WORK/loginui" -I"$WORK/loginui/src" \
        "$ROOT/build/hidpi/splash-render-harness.c" \
        "$WORK/loginui/src/image.c" "$WORK/loginui/src/draw.c" "$WORK/loginui/src/render.c" \
        $(pkg-config --cflags --libs cairo pangocairo gdk-pixbuf-2.0) -lm; then
    echo "FATAL: harness build failed" >&2
    exit 2
fi

tag=patched; [ "$PATCH" = 1 ] || tag=upstream
fails=0
for r in $RESOLUTIONS; do
    w=${r%x*}; h=${r#*x}
    png="$OUT/splash-$tag-${w}x${h}.png"
    line=$("$WORK/harness" "$LOGO" "$w" "$h" "$png")
    rc=$?
    echo "$line -> $png"
    [ "$rc" = 2 ] && { echo "FATAL: harness error at $r" >&2; exit 2; }
    [ "$rc" = 0 ] || fails=$((fails + 1))
done

n=$(echo "$RESOLUTIONS" | wc -w | tr -d ' ')
if [ "$EXPECT" = fail ]; then
    if [ "$fails" = "$n" ]; then
        echo "ok: every resolution flagged ($fails/$n) -- the check catches the cropping"
        exit 0
    fi
    echo "FAIL: expected every resolution to be flagged, got $fails/$n"
    exit 1
fi
if [ "$fails" = 0 ]; then
    echo "ok: logo fully on screen and <= 60 % of the width at all $n resolutions"
    exit 0
fi
echo "FAIL: $fails/$n resolutions clipped or too wide"
exit 1
