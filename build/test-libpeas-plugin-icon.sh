#!/bin/bash
# test-libpeas-plugin-icon.sh -- the Plugins page asks for the icon name "libpeas-plugin" for any
# plugin file without an Icon key; no theme in the image had it (broken-image rows). The NCZ asset
# assets/branding/icons/libpeas-plugin/libpeas-plugin.svg is installed into hicolor by
# post-install/56-icon-theme.sh. This proves: the asset is a small original scalable SVG, the hook
# block installs it (idempotent, never clobbers another file, never fails when the asset is
# missing), it runs before the hook's early exits, and the image build copies the asset.
# NCZ_HOOK_UNDER_TEST overrides the hook (the negative control points it at a copy without the block).
set -u
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HOOK="${NCZ_HOOK_UNDER_TEST:-$ROOT/post-install/56-icon-theme.sh}"
SVG="$ROOT/assets/branding/icons/libpeas-plugin/libpeas-plugin.svg"
W="$(mktemp -d "${TMPDIR:-/var/tmp}/lp-icon.XXXXXX")"; trap 'rm -rf "$W"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

# --- 1. the asset -------------------------------------------------------------
if [ -s "$SVG" ] && python3 -I - "$SVG" <<'PY'
import sys, xml.etree.ElementTree as ET
r = ET.parse(sys.argv[1]).getroot()
assert r.tag == "{http://www.w3.org/2000/svg}svg", r.tag
assert r.get("viewBox") and r.get("width") == r.get("height"), "square viewBox needed"
tags = {e.tag.split("}")[1] for e in r.iter()}
assert not tags & {"script", "image", "text", "foreignObject", "use"}, tags
assert any(e.tag.endswith("path") for e in r.iter()), "no artwork"
PY
then ok "asset is a square, self-contained scalable svg (no script/image/text/use)"
else bad "asset missing or not a plain square svg: $SVG"; fi
[ "$(wc -c < "$SVG" 2>/dev/null || echo 99999)" -lt 4096 ] && ok "asset is small (< 4 KiB)" || bad "asset too large"
grep -qi "trademark\|google\|gnome\|mozilla\|apple" "$SVG" && bad "asset names a third party" || ok "asset names no third party"

# --- 2. the hook block ---------------------------------------------------------
blk="$(sed -n '/BEGIN libpeas-plugin-fallback-icon/,/END libpeas-plugin-fallback-icon/p' "$HOOK")"
[ -n "$blk" ] && ok "hook carries the fallback-icon block" || bad "hook has no fallback-icon block"
run() { ( export NCZ_LIBPEAS_ICON_SRC="$1" NCZ_HICOLOR_ROOT="$2"; eval "$blk" ) 2>&1; }
DST="$W/h1/scalable/apps/libpeas-plugin.svg"
if [ -n "$blk" ]; then out="$(run "$SVG" "$W/h1")"; rc=$?; else out=""; rc=1; fi
if [ $rc = 0 ] && cmp -s "$SVG" "$DST" && [ "$(stat -c %a "$DST" 2>/dev/null)" = 644 ]; then ok "installs the asset into hicolor/scalable/apps, mode 0644"
else bad "asset not installed correctly (rc=$rc): $out"; fi
if [ -n "$blk" ]; then run "$SVG" "$W/h1" >/dev/null; fi
cmp -s "$SVG" "$DST" && ok "second run is idempotent" || bad "second run changed the file"
mkdir -p "$W/h2/scalable/apps"; echo other > "$W/h2/scalable/apps/libpeas-plugin.svg"
if [ -n "$blk" ]; then out="$(run "$SVG" "$W/h2")"; rc=$?; else rc=1; fi
[ $rc = 0 ] && [ "$(cat "$W/h2/scalable/apps/libpeas-plugin.svg")" = other ] && ok "a different pre-existing libpeas-plugin.svg is left alone" || bad "pre-existing file clobbered"
if [ -n "$blk" ]; then out="$(run "$W/none.svg" "$W/h3")"; rc=$?; else rc=1; fi
[ $rc = 0 ] && [ ! -e "$W/h3/scalable/apps/libpeas-plugin.svg" ] && echo "$out" | grep -q WARN && ok "missing asset: warns, installs nothing, does not fail" || bad "missing asset mishandled (rc=$rc)"

# --- 3. placement ---------------------------------------------------------------
b=$(grep -n 'BEGIN libpeas-plugin-fallback-icon' "$HOOK" | head -1 | cut -d: -f1)
e=$(grep -n '^[[:space:]]*exit 0' "$HOOK" | sed -n 2p | cut -d: -f1)   # 1st = server variant, 2nd = missing NCZ theme
[ -n "$b" ] && [ -n "$e" ] && [ "$b" -lt "$e" ] && ok "block runs before the missing-theme early exit" || bad "block is after an early exit"
grep -q 'cp -a "\$ROOT/assets/branding/\." ' "$ROOT/build/build-squashfs-layers.sh" && ok "image build copies assets/branding wholesale" || bad "image build no longer copies assets/branding"
for l in amd64 sky1-arm64; do
    grep -qx '56-icon-theme.sh' "$ROOT/post-install/hooks.list.$l" && ok "56-icon-theme.sh is on hooks.list.$l" || bad "56-icon-theme.sh missing from hooks.list.$l"
done
echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
