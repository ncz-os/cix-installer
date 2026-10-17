#!/bin/bash
# test-installer-esp-theme.sh -- the INSTALLER ESP carries the Cygnus rEFInd
# theme, and NCZ_REFIND_THEME=0 restores the previous unbranded output.
#
# MINOR-004 (2026-10-17): assets/refind/cygnus/ was complete but
# build/iso/build-refind-esp.py never referenced it, so the installer ESP
# booted stock rEFInd while the installed system got the theme from
# assets/refind/ncz-refind-refresh*.sh. The ESP builder now stages
# themes/cygnus/ into both SelfDir candidates (EFI/BOOT + EFI/REFIND, the
# same places refind.conf and icons/ go) and appends the tracked snippet's
# `include themes/cygnus/theme.conf`, on both arches, behind
# NCZ_REFIND_THEME (default 1 for this release).
#
# The behaviour itself is asserted by build/iso/tests/test_refind_esp_theme.py
# (both arches, both settings, theme files + config lines present only when
# enabled, off == byte-identical to the pre-theme tree). This wrapper runs it
# and additionally pins the wiring points that a future refactor could
# silently drop -- the environment switch, the default, and the tracked
# assets it stages.
#
# Usage: build/test-installer-esp-theme.sh
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

ESP="$ROOT/build/iso/build-refind-esp.py"
THEME="$ROOT/assets/refind/cygnus"
PYTEST="$ROOT/build/iso/tests/test_refind_esp_theme.py"

PASS=0; FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS + 1)); }
nok() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

echo "=== 1. ESP tree built both ways, both arches (test_refind_esp_theme.py) ==="
if ! command -v python3 >/dev/null 2>&1; then
    echo "  SKIP  python3 not available"
else
    if ( cd "$ROOT" && python3 "$PYTEST" > /dev/null 2>&1 ); then
        ok "theme files + include line present only when NCZ_REFIND_THEME=1"
    else
        nok "test_refind_esp_theme.py failed:"; ( cd "$ROOT" && python3 "$PYTEST" 2>&1 | tail -30 | sed 's/^/        /' )
    fi
fi

echo "=== 2. wiring: env switch, default, staged assets ==="
if grep -q 'os.environ.get("NCZ_REFIND_THEME", "1")' "$ESP"; then
    ok "build-refind-esp.py reads NCZ_REFIND_THEME with a default of 1"
else
    nok "build-refind-esp.py no longer defaults NCZ_REFIND_THEME to 1"
fi

if grep -q 'theme_include=theme_include_block(theme)' "$ESP"; then
    ok "every refind.conf template is formatted with the theme include"
else
    nok "a refind.conf template lost its theme_include placeholder"
fi

if grep -q 'for dest in (boot_dir / THEME_ESP_DIR, refind_dir / THEME_ESP_DIR)' "$ESP"; then
    ok "the theme is staged next to BOTH SelfDir candidates (EFI/BOOT + EFI/REFIND)"
else
    nok "the theme is not staged into both SelfDir candidates"
fi

if grep -q 'NCZ_REFIND_THEME' "$ROOT/docs/REFIND-THEME.md" \
   && grep -q 'build/iso/build-refind-esp.py' "$ROOT/docs/REFIND-THEME.md"; then
    ok "docs/REFIND-THEME.md documents the ESP wiring"
else
    nok "docs/REFIND-THEME.md does not mention the installer ESP wiring"
fi

# The assets the ESP stages must all still exist in the tree, or the enabled
# build fails closed (FileNotFoundError) and every installer build breaks.
for f in theme.conf background-1920x1080.png selection_big.png \
         selection_small.png os_ncz.png refind.conf.snippet; do
    [ -s "$THEME/$f" ] && ok "theme asset present: $f" || nok "theme asset missing/empty: $f"
done

# The approved design: fillscreen, never noscale, never a pinned resolution.
grep -qx 'banner_scale fillscreen' "$THEME/theme.conf" \
    && ok "theme.conf keeps banner_scale fillscreen" \
    || nok "theme.conf lost banner_scale fillscreen"
grep -q 'banner_scale noscale' "$THEME/theme.conf" \
    && nok "theme.conf reintroduced noscale (O6N crop)" \
    || ok "theme.conf has no noscale"
grep -qx 'include themes/cygnus/theme.conf' "$THEME/refind.conf.snippet" \
    && ok "refind.conf.snippet still carries the include line" \
    || nok "refind.conf.snippet lost the include line"

echo "test-installer-esp-theme: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
