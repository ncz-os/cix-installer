#!/bin/bash
# test-about-logo-mark.sh -- MINOR-006: the Singularity About page squeezed the 696x52 Cygnus
# wordmark into a 96x96 square. Two fixes, both checked here: shell patch 0025 draws the os-release
# LOGO icon through a Picture that keeps its aspect ratio, and post-install/55-greeter.sh installs
# a square Cygnus mark under the LOGO name in the SIZED hicolor directories (which GTK icon-theme
# lookups read), while the wordmark stays in /usr/share/pixmaps (which the greeter and splashes read
# before hicolor/256x256). This proves: the mark is a square, text-free vector in the Cygnus tokens
# with PNGs of the right sizes that its generator reproduces; the hook block installs every size,
# never writes scalable/apps (the greeter's first choice), runs after the wordmark install so the
# square wins at 256, and does not fail when the mark is missing; the shell patch is queued.
# NCZ_HOOK_UNDER_TEST overrides the hook (the negative control points it at a copy without the block).
set -u
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HOOK="${NCZ_HOOK_UNDER_TEST:-$ROOT/post-install/55-greeter.sh}"
MARK="$ROOT/assets/branding/logo/cygnus-mark"
GEN="$ROOT/branding/cygnus/tools/make-cygnus-mark.py"
PATCH="$ROOT/assets/singularity/patches/singularity-shell/0025-about-keep-the-distro-logo-aspect-ratio.patch"
W="$(mktemp -d "${TMPDIR:-/var/tmp}/about-mark.XXXXXX")"; trap 'rm -rf "$W"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

# --- 1. the mark ----------------------------------------------------------------
if python3 -I - "$MARK/ncz-os-cygnus-mark.svg" "$ROOT/branding/cygnus/tokens.json" <<'PY'
import json, sys, xml.etree.ElementTree as ET
r = ET.parse(sys.argv[1]).getroot()
assert r.tag == "{http://www.w3.org/2000/svg}svg", r.tag
assert r.get("width") == r.get("height") and r.get("viewBox") == "0 0 256 256", "square 256 viewBox"
tags = {e.tag.split("}")[1] for e in r.iter()}
assert not tags & {"script", "image", "text", "foreignObject", "use"}, tags
src = open(sys.argv[1]).read()
s = json.load(open(sys.argv[2]))["scales"]
for c in (s["violet"]["950"], s["magenta"]["400"], s["cyan"]["400"]):
    assert c in src, "token colour missing: " + c
PY
then ok "mark svg is square, text-free and uses the Cygnus tokens"
else bad "mark svg missing, not square, or off-palette"; fi
for size in 48 64 96 128 192 256; do
    f="$MARK/$size.png"
    dim="$(python3 -I -c 'import struct,sys; d=open(sys.argv[1],"rb").read(24); assert d[:8]==b"\x89PNG\r\n\x1a\n"; print("%dx%d" % struct.unpack(">II", d[16:24]))' "$f" 2>/dev/null)"
    [ "$dim" = "${size}x${size}" ] && ok "$size.png is ${size}x${size}" || bad "$size.png is '${dim:-missing}', want ${size}x${size}"
done
if python3 -I - "$GEN" "$MARK/ncz-os-cygnus-mark.svg" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("mark", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
assert m.svg() == open(sys.argv[2]).read(), "committed svg differs from the generator"
PY
then ok "generator reproduces the committed svg byte for byte"
else bad "committed svg is not what make-cygnus-mark.py draws"; fi

# --- 2. the hook block ------------------------------------------------------------
blk="$(sed -n '/^# --- square Cygnus mark/,/^fi$/p' "$HOOK")"
[ -n "$blk" ] && ok "hook carries the square-mark block" || bad "hook has no square-mark block"
# shellcheck disable=SC2034  # ASSETS and LOGO_NAME are read by the eval-ed hook block
run() { ( ASSETS="$1" LOGO_NAME=ncz-os-cygnus; eval "${blk//\/usr\/share\/icons/$2}" ) 2>&1; }
if [ -n "$blk" ]; then out="$(run "$ROOT/assets/branding" "$W/i1")"; rc=$?; else out=""; rc=1; fi
all=1
for size in 48 64 96 128 192 256; do
    cmp -s "$MARK/$size.png" "$W/i1/hicolor/${size}x${size}/apps/ncz-os-cygnus.png" || all=0
done
[ $rc = 0 ] && [ $all = 1 ] && ok "installs the mark at every size under the LOGO name" || bad "mark not installed at every size (rc=$rc): $out"
[ ! -e "$W/i1/hicolor/scalable" ] && ok "never writes hicolor/scalable (the greeter's first choice)" || bad "wrote hicolor/scalable"
if [ -n "$blk" ]; then out="$(run "$W/none" "$W/i2")"; rc=$?; else rc=1; fi
[ $rc = 0 ] && [ ! -e "$W/i2/hicolor" ] && echo "$out" | grep -q WARN && ok "missing mark: warns, installs nothing, does not fail" || bad "missing mark mishandled (rc=$rc)"
grep -q 'scalable/apps/\$LOGO_NAME' "$HOOK" && bad "hook installs a scalable LOGO icon (would replace the greeter wordmark)" || ok "hook installs no scalable LOGO icon"
grep -q 'install -m0644 "\$LOGO_PNG" "/usr/share/pixmaps/\$LOGO_NAME.png"' "$HOOK" && ok "wordmark still goes to pixmaps for the greeter and splashes" || bad "wordmark no longer installed to pixmaps"
w=$(grep -n 'hicolor/256x256/apps/\$LOGO_NAME.png"' "$HOOK" | head -1 | cut -d: -f1)
m=$(grep -n '^# --- square Cygnus mark' "$HOOK" | head -1 | cut -d: -f1)
[ -n "$w" ] && [ -n "$m" ] && [ "$m" -gt "$w" ] && ok "mark block runs after the wordmark install, so the square wins at 256" || bad "mark block does not follow the wordmark install"

# --- 3. the shell patch and wiring ---------------------------------------------------
if [ -f "$PATCH" ] && grep -q 'ContentFit.CONTAIN' "$PATCH" && grep -q 'new Picture.for_paintable' "$PATCH"; then
    ok "shell patch 0025 draws the logo through a Picture with ContentFit.CONTAIN"
else bad "shell patch 0025 missing or does not keep the aspect ratio"; fi
grep -q '0025-about-keep-the-distro-logo-aspect-ratio.patch' "$ROOT/assets/singularity/patches/README.md" && ok "patch README documents 0025" || bad "patch README does not mention 0025"
grep -q 'cp -a "\$ROOT/assets/branding/\." ' "$ROOT/build/build-squashfs-layers.sh" && ok "image build copies assets/branding wholesale" || bad "image build no longer copies assets/branding"
for l in amd64 sky1-arm64; do
    grep -qx '55-greeter.sh' "$ROOT/post-install/hooks.list.$l" && ok "55-greeter.sh is on hooks.list.$l" || bad "55-greeter.sh missing from hooks.list.$l"
done
echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
