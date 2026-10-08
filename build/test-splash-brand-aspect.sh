#!/bin/bash
# test-splash-brand-aspect.sh -- render the SESSION splash (loginui_render_brand,
# what singularity-splash paints after greeter login) through the real
# singularity-loginui sources and check the wordmark keeps its aspect ratio.
#
#   LOGINUI_SRC=/path/to/singularity-loginui OUT_DIR=/path/out \
#       bash build/test-splash-brand-aspect.sh
#
# PATCH=1 (default) applies assets/singularity/patches/singularity-loginui/*
# to a private copy first. PATCH=0 + EXPECT=fail proves the check catches the
# original squeeze. Needs cc, cairo, pangocairo, gdk-pixbuf dev packages.
# (test-splash-logo-fit.sh, the boot-splash render_splash check, is a separate
# manual tool; it needs the same toolchain and is not wired into make.)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ -z "${LOGINUI_SRC:-}" ] || [ -z "${OUT_DIR:-}" ]; then
    echo "SKIP: test-splash-brand-aspect.sh needs an external singularity-loginui checkout (set LOGINUI_SRC=<checkout at the pin in assets/singularity/upstream-pins.tsv> and OUT_DIR=<dir>); not testable in a bare repo checkout. Exit 0 is a skip, not a pass." >&2
    exit 0
fi
SRC="${LOGINUI_SRC:?set LOGINUI_SRC to a singularity-loginui checkout}"
OUT="${OUT_DIR:?set OUT_DIR to a directory for the rendered PNGs}"
LOGO="${LOGO:-$ROOT/assets/branding/greeter/cygnus/ncz-os-cygnus-logo.png}"
PATCH="${PATCH:-1}"
EXPECT="${EXPECT:-pass}"
RESOLUTIONS="${RESOLUTIONS:-1536x960 1920x1080 1366x768 1024x768 800x1280}"
CC="${CC:-cc}"
[ -f "$LOGO" ] || { echo "FATAL: logo not found: $LOGO" >&2; exit 2; }
[ -f "$SRC/src/brand.c" ] || { echo "FATAL: not a loginui tree: $SRC" >&2; exit 2; }
mkdir -p "$OUT"
WORK="$(mktemp -d "${TMPDIR:-$OUT}/brand-aspect.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
cp -a "$SRC/." "$WORK/loginui"
if [ "$PATCH" = 1 ]; then
    for p in "$ROOT"/assets/singularity/patches/singularity-loginui/*.patch; do
        [ -e "$p" ] || continue
        (cd "$WORK/loginui" && rm -rf .git && patch -p1 -s < "$p") || { echo "FATAL: patch does not apply: $(basename "$p")" >&2; exit 2; }
    done
fi
# shellcheck disable=SC2046
"$CC" -O1 -o "$WORK/harness" -I"$WORK/loginui" -I"$WORK/loginui/src" \
    "$ROOT/build/hidpi/brand-render-harness.c" \
    "$WORK/loginui/src/image.c" "$WORK/loginui/src/draw.c" "$WORK/loginui/src/brand.c" \
    $(pkg-config --cflags --libs cairo pangocairo gdk-pixbuf-2.0 gio-2.0) -lm \
    || { echo "FATAL: harness build failed" >&2; exit 2; }
tag=patched; [ "$PATCH" = 1 ] || tag=upstream
fails=0; n=0
for r in $RESOLUTIONS; do
    w=${r%x*}; h=${r#*x}; n=$((n + 1))
    line=$("$WORK/harness" "$LOGO" "$w" "$h" "$OUT/brand-$tag-${w}x${h}.png"); rc=$?
    echo "$line"
    [ "$rc" = 2 ] && { echo "FATAL: harness error at $r" >&2; exit 2; }
    [ "$rc" = 0 ] || fails=$((fails + 1))
done
if [ "$EXPECT" = fail ]; then
    [ "$fails" = "$n" ] && { echo "ok: every resolution flagged ($fails/$n)"; exit 0; }
    echo "FAIL: expected all flagged, got $fails/$n"; exit 1
fi
[ "$fails" = 0 ] && { echo "ok: aspect kept and logo on screen at all $n resolutions"; exit 0; }
echo "FAIL: $fails/$n resolutions squeezed or clipped"; exit 1
