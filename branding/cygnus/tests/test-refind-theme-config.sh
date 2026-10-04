#!/bin/bash
# shellcheck disable=SC2015,SC2016,SC1091  # ok/bad return 0; literal $ in patch/regex matches; generated temp sources
# Regression test for the Cygnus rEFInd theme resolution fix.
#
# The theme used to pick a background from the DRM connector mode
# (pick-theme.sh) and draw it `banner_scale noscale`. On O6N the panel is 4K but
# the firmware GOP mode rEFInd actually gets is ~1920 wide, so the 3840x2160
# background was cropped to its top-left corner. The fix is a single 1920x1080
# background plus `banner_scale fillscreen` (rEFInd stretches it to the exact
# GOP mode; libeg/image.c egScaleImage -> refind/screen.c BANNER_FILLSCREEN), so
# there is no crop at any resolution. This test pins that design and the exact
# approved background blob (its label-band contrast is unchanged).
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
A="$ROOT/assets/refind/cygnus"
B="$ROOT/branding/cygnus/refind"
PASS=0; FAILS=0
ok() { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAILS=$((FAILS+1)); echo "FAIL $1"; }
has() { grep -qxF "$2" "$1" && ok "$3" || bad "$3"; }
hasnt() { grep -qF "$2" "$1" && bad "$3" || ok "$3"; }

# ---- the theme is the same in the source tree and the install tree
cmp -s "$A/theme.conf" "$B/theme.conf" && ok "theme.conf mirrored (assets == branding)" || bad "theme.conf mirror differs"
has "$A/theme.conf" "banner themes/cygnus/background-1920x1080.png" "single 1920x1080 banner directive"
has "$A/theme.conf" "banner_scale fillscreen" "banner_scale fillscreen"
hasnt "$A/theme.conf" "banner_scale noscale" "no noscale left in the theme"
has "$A/refind.conf.snippet" "include themes/cygnus/theme.conf" "snippet includes the theme"

# ---- only the 1080p art ships
[ -f "$A/background-1920x1080.png" ] && ok "1080p background present" || bad "1080p background missing"
for f in background-2560x1440.png background-3840x2160.png theme-1920x1080.conf theme-2560x1440.conf theme-3840x2160.conf pick-theme.sh; do
    [ -e "$A/$f" ] && bad "unused asset still present: $f" || ok "unused asset removed: $f"
    [ -e "$B/$f" ] && bad "unused branding asset still present: $f" || true
done
for f in selection_big.png selection_small.png os_ncz.png; do
    [ -f "$A/$f" ] && ok "kept $f" || bad "missing $f"
done
if command -v python3 >/dev/null 2>&1; then
    dims="$(python3 -c 'from PIL import Image;print("%dx%d"%Image.open(__import__("sys").argv[1]).size)' "$A/background-1920x1080.png" 2>/dev/null || echo '?')"
    [ "$dims" = "1920x1080" ] && ok "background is 1920x1080" || bad "background is $dims, want 1920x1080"
fi

# The approved export is kept byte-for-byte, so the label-band contrast the
# operator approved cannot silently change with a re-render.
APPROVED_SHA=2b088ba8bfabbbef99187e5aa91959b367fad2e75bf9f5d676173b77bc2ca6df
[ "$(sha256sum "$A/background-1920x1080.png" | cut -d' ' -f1)" = "$APPROVED_SHA" ] \
    && ok "approved 1080p background blob unchanged" || bad "1080p background blob changed"

# ---- the refresh scripts stage the single theme and never probe the DRM mode
for s in "$ROOT/assets/refind/ncz-refind-refresh.sh" "$ROOT/assets/refind/ncz-refind-refresh-amd64.sh"; do
    n="$(basename "$s")"
    grep -q 'pick-theme' "$s" && bad "$n still calls pick-theme" || ok "$n does not call pick-theme"
    grep -q 'REFIND_THEME="themes/cygnus/theme.conf"' "$s" && ok "$n includes theme.conf" || bad "$n does not include theme.conf"
    grep -q 'resolution max' "$s" && ok "$n keeps resolution max" || bad "$n lost resolution max"
    grep -q 'resolution 1920 1080' "$s" && bad "$n pins resolution 1920 1080" || ok "$n does not pin a resolution"
done

# ---- the QEMU proof exercises the required modes
grep -q 'RESOLUTIONS:-1920x1080 2560x1440 1280x800 1920x1200' "$ROOT/branding/cygnus/tests/test-refind-theme.sh" \
    && ok "QEMU test defaults cover 1080/1440/800/1200" || bad "QEMU test missing required resolutions"

# ---- the generator only exports the shipped size
grep -q '^REFIND_SIZES = ((1920, 1080),)$' "$ROOT/branding/cygnus/tools/make-cygnus-art.py" \
    && ok "generator ships only 1920x1080" || bad "generator still exports extra sizes"

echo "refind theme config test: $PASS passed, $FAILS failed"
[ "$FAILS" = 0 ]
