#!/bin/bash
# test-chromium-icon.sh -- the Cygnus NCZ Chromium icon: complete asset set, no orange left,
# crisp-size checks, and the install hook (post-install/61-chromium-icon.sh) diverts the
# package's files (hicolor + pixmaps), installs ours, is idempotent, and holds whether the
# package is installed before or after the hook or upgraded later. Runs the REAL hook against a fixture
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
# records diversions in $T_DIVERTS as "file divert"; --list prints dpkg's format;
# --add --rename renames the file like dpkg does (only when it exists, like dpkg).
db="$T_DIVERTS"
case "$1" in
  --list) awk -v f="$2" '$1 == f { print "diversion of " $1 " to " $2 " by ncz-cygnus-branding" }' "$db" 2>/dev/null; exit 0 ;;
esac
while [ $# -gt 0 ]; do
  case "$1" in
    --divert) div="$2"; shift ;;
    --package) shift ;;
    --rename|--add|--) ;;
    *) file="$1" ;;
  esac
  shift
done
[ -e "$file" ] && { mv "$file" "$div" || exit 1; }
echo "$file $div" >> "$db"
FAKE
chmod +x "$T/bin/dpkg-divert"
# pkg_unpack ROOT PIXMAPS TAG: what dpkg does when chromium-ncz-sky1 is installed or upgraded:
# write each package file, honouring diversions recorded in $T_DIVERTS.
pkg_unpack() {
    local root="$1" pix="$2" tag="$3" s f div
    for f in $(for s in 16 22 24 32 48 64 128 256 512; do echo "$root/${s}x${s}/apps/chromium-ncz-sky1.png"; done) "$pix/chromium-ncz-sky1.png"; do
        div=$(awk -v f="$f" '$1 == f { print $2 }' "$T_DIVERTS" 2>/dev/null)
        mkdir -p "$(dirname "$f")"
        printf '%s' "$tag" > "${div:-$f}"
    done
}
H="$T/hicolor"; P="$T/pixmaps"
export T_DIVERTS="$T/diverts"
: > "$T_DIVERTS"
pkg_unpack "$H" "$P" ORANGE
run_hook() {   # run_hook ROOT PIXMAPS PRESENT
    NCZ_TARGET_ARCH=arm64 NCZ_ICON_ROOT="$1" NCZ_ICON_PIXMAPS="$2" NCZ_ICON_ASSETS="$ASSETS" NCZ_ICON_PACKAGE_PRESENT="$3" \
        PATH="$T/bin:$PATH" bash "$HOOK" >"$T/hook.out" 2>&1
    echo $?
}
all_cygnus() {   # all_cygnus ROOT PIXMAPS: every package path holds our asset
    local s
    for s in 16 22 24 32 48 64 128 256 512; do cmp -s "$1/${s}x${s}/apps/chromium-ncz-sky1.png" "$ASSETS/$s.png" || return 1; done
    cmp -s "$2/chromium-ncz-sky1.png" "$ASSETS/256.png"
}
rc=$(run_hook "$H" "$P" 1)
if [ "$rc" = 0 ]; then ok "hook exits 0"; else bad "hook exit $rc: $(tail -3 "$T/hook.out")"; fi
diverted=$(wc -l < "$T_DIVERTS" | tr -d ' ')
if [ "$diverted" = 10 ]; then ok "all 10 package files (9 hicolor + pixmaps) diverted before overwrite"; else bad "diverted $diverted of 10"; fi
if [ "$(cat "$H/48x48/apps/chromium-ncz-sky1.png.maximilian-orig")" = "ORANGE" ] && [ "$(cat "$P/chromium-ncz-sky1.png.maximilian-orig")" = "ORANGE" ]; then ok "original package files preserved at the divert names"; else bad "original not preserved"; fi
if all_cygnus "$H" "$P"; then ok "Cygnus icons installed at every package path, pixmaps included"; else bad "installed icons differ from assets"; fi
if cmp -s "$H/scalable/apps/chromium-ncz-sky1.svg" "$ASSETS/chromium-ncz-sky1.svg"; then ok "scalable SVG installed"; else bad "SVG not installed"; fi
rc=$(run_hook "$H" "$P" 1)
if [ "$rc" = 0 ] && [ "$(wc -l < "$T_DIVERTS" | tr -d ' ')" = 10 ] && all_cygnus "$H" "$P"; then ok "second run is idempotent (no further diversions)"; else bad "second run not idempotent"; fi
pkg_unpack "$H" "$P" ORANGE-UPGRADE
if all_cygnus "$H" "$P" && [ "$(cat "$H/128x128/apps/chromium-ncz-sky1.png.maximilian-orig")" = "ORANGE-UPGRADE" ]; then ok "package upgrade after the hook lands at the divert names; Cygnus icons stay"; else bad "package upgrade restored the old icon"; fi

# package installed AFTER the hook (absent at hook time): the diversion must already hold
H3="$T/h3"; P3="$T/p3"
export T_DIVERTS="$T/diverts3"
: > "$T_DIVERTS"
rc=$(run_hook "$H3" "$P3" 0)
if [ "$rc" = 0 ] && grep -q "not installed yet" "$T/hook.out" && [ "$(wc -l < "$T_DIVERTS" | tr -d ' ')" = 10 ] && all_cygnus "$H3" "$P3"; then
    ok "package absent: paths diverted ahead of it and Cygnus icons installed"
else
    bad "package absent at hook time (rc=$rc, diverts=$(wc -l < "$T_DIVERTS" | tr -d ' ')): $(tail -2 "$T/hook.out")"
fi
pkg_unpack "$H3" "$P3" ORANGE-LATE
if all_cygnus "$H3" "$P3" && [ "$(cat "$H3/16x16/apps/chromium-ncz-sky1.png.maximilian-orig")" = "ORANGE-LATE" ]; then ok "package installed after the hook cannot overwrite the Cygnus icons"; else bad "late package install overwrote the Cygnus icons"; fi
export T_DIVERTS="$T/diverts"

rc=$(NCZ_TARGET_ARCH=arm64 NCZ_ICON_ROOT="$H" NCZ_ICON_PIXMAPS="$P" NCZ_ICON_ASSETS="$T/nonexistent" NCZ_ICON_PACKAGE_PRESENT=1 PATH="$T/bin:$PATH" bash "$HOOK" >/dev/null 2>&1; echo $?)
if [ "$rc" = 0 ]; then ok "missing assets only warns (exit 0)"; else bad "missing assets exit $rc"; fi

rc=$(NCZ_TARGET_ARCH=amd64 T_DIVERTS="$T/diverts2" NCZ_ICON_ROOT="$T/h2" NCZ_ICON_PIXMAPS="$T/p2" NCZ_ICON_ASSETS="$ASSETS" NCZ_ICON_PACKAGE_PRESENT=1 PATH="$T/bin:$PATH" bash "$HOOK" >"$T/amd.out" 2>&1; echo $?)
if [ "$rc" = 0 ] && grep -q "platform guard" "$T/amd.out" && [ ! -e "$T/h2" ] && [ ! -e "$T/p2" ]; then ok "hook skips on amd64 (platform guard)"; else bad "amd64 guard (rc=$rc)"; fi

# 3. registration: Sky1 only, and on the baked allowlist (else --mode full never runs it)
if grep -q "^61-chromium-icon.sh$" "$ROOT/post-install/hooks.list.sky1-arm64" && ! grep -q "^61-chromium-icon.sh$" "$ROOT/post-install/hooks.list.amd64"; then
    ok "hook listed for sky1-arm64 and not amd64"
else
    bad "hook registration (sky1 yes / amd64 no)"
fi
re=$(sed -n 's/^MACHINE_HOOKS_RE="\(.*\)"$/\1/p' "$ROOT/post-install/run-all.sh")
if [ -n "$re" ] && printf '%s\n' 61-chromium-icon.sh | grep -qE "$re"; then
    ok "hook is on run-all.sh MACHINE_HOOKS_RE (runs on baked installs)"
else
    bad "hook missing from run-all.sh MACHINE_HOOKS_RE: baked installs orphan it"
fi

echo "chromium-icon tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
