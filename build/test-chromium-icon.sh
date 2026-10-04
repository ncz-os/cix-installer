#!/bin/bash
# test-chromium-icon.sh -- the Cygnus NCZ Chromium icon: complete asset set, no orange left,
# crisp-size checks, and the install hook (post-install/61-chromium-icon.sh) diverts the
# package's files, installs ours, and is idempotent. Runs the REAL hook against a fixture
# hicolor tree with a fake dpkg-divert.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS="$ROOT/assets/branding/icons/chromium-ncz-sky1"
HOOK="$ROOT/post-install/61-chromium-icon.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

# 1. assets
missing=""
for s in 16 22 24 32 48 64 128 256 512; do [ -s "$ASSETS/$s.png" ] || missing="$missing $s"; done
[ -s "$ASSETS/chromium-ncz-sky1.svg" ] || missing="$missing svg"
if [ -z "$missing" ]; then ok "all 9 PNG sizes and the scalable SVG are present"; else bad "missing assets:$missing"; fi

python3 - "$ASSETS" <<'PY' > "$T/py.out" 2>&1
import colorsys, sys
from PIL import Image
d = sys.argv[1]
errs = []
for s in (16, 22, 24, 32, 48, 64, 128, 256, 512):
    im = Image.open(f"{d}/{s}.png").convert("RGBA")
    if im.size != (s, s):
        errs.append(f"{s}.png is {im.size}")
    px = im.load()
    orange = cyan = magenta = opaque = 0
    for y in range(s):
        for x in range(s):
            r, g, b, a = px[x, y]
            if a < 200:
                continue
            opaque += 1
            h, sat, v = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
            if sat > 0.5 and v > 0.5:
                deg = h * 360
                if deg < 60 or deg > 345:
                    orange += 1          # red/orange/yellow = the old Maximilian palette
                if 170 <= deg <= 200:
                    cyan += 1
                if 300 <= deg <= 335:
                    magenta += 1
    if orange:
        errs.append(f"{s}.png still has {orange} orange/red pixels")
    if cyan == 0 or magenta == 0:
        errs.append(f"{s}.png lacks the Cygnus pair (cyan={cyan}, magenta={magenta})")
    # corners must be transparent (circular icon, anti-aliased edge)
    if px[0, 0][3] != 0 or px[s - 1, s - 1][3] != 0:
        errs.append(f"{s}.png corners are not transparent")
    # crispness: a vector-drawn disc only has partial alpha on its own rim (about pi*size
    # pixels); a resampled raster smears detail across the whole ring. Allow 1.7x the rim.
    import math
    part = sum(1 for y in range(s) for x in range(s) if 8 < px[x, y][3] < 247)
    if part > 1.7 * math.pi * s + 8:
        errs.append(f"{s}.png edge is soft ({part} partial-alpha px, limit {1.7 * math.pi * s + 8:.0f})")
print("\n".join(errs) if errs else "OK")
PY
if [ "$(cat "$T/py.out")" = "OK" ]; then ok "icons are Cygnus magenta/cyan, no orange, transparent corners, crisp edges"; else bad "icon content: $(tr '\n' ';' < "$T/py.out")"; fi
if grep -q "stroke-width" "$ASSETS/chromium-ncz-sky1.svg" && grep -q "2ED8F0" "$ASSETS/chromium-ncz-sky1.svg"; then ok "SVG is the vector source (Cygnus cyan present)"; else bad "SVG content"; fi

# 2. hook: fixture hicolor tree with the package's old files + fake dpkg-divert
mkdir -p "$T/bin"
cat > "$T/bin/dpkg-divert" <<'FAKE'
#!/bin/sh
# records calls; --list answers from the divert db; --add --rename renames the file like dpkg does
db="$T_DIVERTS"
case "$1" in
  --list) grep -F "$2" "$db" 2>/dev/null; exit 0 ;;
esac
while [ $# -gt 0 ]; do
  case "$1" in
    --divert) div="$2"; shift ;;
    --package|--) shift ;;
    --rename|--add) ;;
    *) file="$1" ;;
  esac
  shift
done
mv "$file" "$div" && echo "$file $div" >> "$db"
FAKE
chmod +x "$T/bin/dpkg-divert"
H="$T/hicolor"
for s in 16 22 24 32 48 64 128 256 512; do
    mkdir -p "$H/${s}x${s}/apps"
    printf 'ORANGE-%s' "$s" > "$H/${s}x${s}/apps/chromium-ncz-sky1.png"
done
run_hook() {
    NCZ_TARGET_ARCH=arm64 T_DIVERTS="$T/diverts" NCZ_ICON_ROOT="$H" NCZ_ICON_ASSETS="$ASSETS" NCZ_ICON_PACKAGE_PRESENT=1 \
        PATH="$T/bin:$PATH" bash "$HOOK" >"$T/hook.out" 2>&1
    echo $?
}
: > "$T/diverts"
rc=$(run_hook)
if [ "$rc" = 0 ]; then ok "hook exits 0"; else bad "hook exit $rc: $(tail -3 "$T/hook.out")"; fi
diverted=$(wc -l < "$T/diverts" | tr -d ' ')
if [ "$diverted" = 9 ]; then ok "all 9 package files diverted before overwrite"; else bad "diverted $diverted of 9"; fi
if [ "$(cat "$H/48x48/apps/chromium-ncz-sky1.png.maximilian-orig")" = "ORANGE-48" ]; then ok "original package file preserved at the divert name"; else bad "original not preserved"; fi
if cmp -s "$H/48x48/apps/chromium-ncz-sky1.png" "$ASSETS/48.png" && cmp -s "$H/512x512/apps/chromium-ncz-sky1.png" "$ASSETS/512.png"; then ok "Cygnus icons installed at the package paths"; else bad "installed icons differ from assets"; fi
if cmp -s "$H/scalable/apps/chromium-ncz-sky1.svg" "$ASSETS/chromium-ncz-sky1.svg"; then ok "scalable SVG installed"; else bad "SVG not installed"; fi
rc=$(run_hook)
if [ "$rc" = 0 ] && [ "$(wc -l < "$T/diverts" | tr -d ' ')" = 9 ]; then ok "second run is idempotent (no further diversions)"; else bad "second run not idempotent"; fi
rc=$(NCZ_TARGET_ARCH=arm64 T_DIVERTS="$T/diverts" NCZ_ICON_ROOT="$H" NCZ_ICON_ASSETS="$T/nonexistent" NCZ_ICON_PACKAGE_PRESENT=1 PATH="$T/bin:$PATH" bash "$HOOK" >/dev/null 2>&1; echo $?)
if [ "$rc" = 0 ]; then ok "missing assets only warns (exit 0)"; else bad "missing assets exit $rc"; fi

rc=$(NCZ_TARGET_ARCH=amd64 T_DIVERTS="$T/diverts2" NCZ_ICON_ROOT="$T/h2" NCZ_ICON_ASSETS="$ASSETS" NCZ_ICON_PACKAGE_PRESENT=1 PATH="$T/bin:$PATH" bash "$HOOK" >"$T/amd.out" 2>&1; echo $?)
if [ "$rc" = 0 ] && grep -q "platform guard" "$T/amd.out" && [ ! -e "$T/h2" ]; then ok "hook skips on amd64 (platform guard)"; else bad "amd64 guard (rc=$rc)"; fi

# 3. registration: Sky1 only
if grep -q "^61-chromium-icon.sh$" "$ROOT/post-install/hooks.list.sky1-arm64" && ! grep -q "^61-chromium-icon.sh$" "$ROOT/post-install/hooks.list.amd64"; then
    ok "hook listed for sky1-arm64 and not amd64"
else
    bad "hook registration (sky1 yes / amd64 no)"
fi

echo "chromium-icon tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
