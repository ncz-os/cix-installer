#!/bin/bash
# test-screensaver-gates.sh -- gates for the CYGNUS 26.10 screensaver defaults + ship set.
#
#  A. Schema defaults: dev.ncz.screensaver ships mode='one' and hack-id='blackhole_gles3'
#     (operator 2026-10-03: Black Hole is the default screensaver and it is ON by default).
#     The operator also pinned the delay/lock policy: idle delay 300 s, lock-enabled true,
#     lock-delay 60 -- asserted here so a later tweak is a deliberate, visible change.
#  B. No silent first-boot/install reset: nothing in post-install/, build/ or the desktop
#     overrides dev.ncz.screensaver away from the shipped defaults (the 18e8a14-class bug
#     where an installer quietly flips a default back off).
#  C. Black Hole default uses the Cygnus palette preset where the engine takes options,
#     sourcing the token file rather than forking colours into a new saver.
#  D. Ship set: every id in the generated catalogue is in the approved 84-hack ship set
#     (fix/screensaver-catalog-ship-set-2026-09-30, 0c439e11) -- no GL1/gl4es entries and
#     no unshipped savers (megacity, chitin, fractint, neonspacewar, magmasimplex,
#     leviathan, genxvectorcade, ephemeris) crept in.
#
# Run: bash build/test-screensaver-gates.sh
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$HERE/.."
GS="$ROOT/assets/screensaver-chooser/dev.ncz.screensaver.gschema.xml"
CAT="$ROOT/assets/screensaver-chooser/hacks.tsv"
PAL="$ROOT/branding/cygnus/generated/screensaver/cygnus-palette.json"
REF="0c439e11"
PASS=0; FAILS=0
ok()   { echo "PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL  $1"; FAILS=$((FAILS+1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got '$2' want '$3'"; fi; }

echo "== A. schema defaults =="
[ -f "$GS" ] || { bad "schema missing: $GS"; exit 1; }
# Extract a key's <default> without letting a greedy match bleed into the next key
# (the mode key carries <choices> and the ranged keys carry <range> before <default>).
gval() { awk -v k="$1" '
  match($0, /<key name="[^"]+"/) {
    n = substr($0, RSTART, RLENGTH); key = n; sub(/^<key name="/, "", key); sub(/"$/, "", key)
  }
  key == k && match($0, /<default>([^<]*)<\/default>/) {
    d = substr($0, RSTART + 9, RLENGTH - 19)
    gsub(/^'\''|'\''$/, "", d)   # string keys quote their default; numeric/bool do not
    print d; exit
  }' "$GS"; }
# Same, but returning the whole <key ...>...</key> block on one logical line.
gblock() { tr '\n' ' ' < "$GS" | sed -n "s|\(<key name=\"$1\"[^>]*>.*\?</key>\).*|\1|p"; }
check "mode default is 'one'"        "$(gval mode)"        "one"
check "hack-id default is blackhole" "$(gval hack-id)"     "blackhole_gles3"
check "idle delay stays 300s"        "$(gval hack-idle-delay)" "300"
check "lock-enabled stays true"      "$(gval lock-enabled)"    "true"
check "lock-delay stays 60s"         "$(gval lock-delay)"      "60"
# 'one' must be a legal choice or the chooser writes a value the schema rejects.
if gblock mode | grep -q 'value="one"'; then
  ok "mode 'one' is an allowed choice"
else
  bad "mode 'one' not in <choices> for the mode key"
fi

echo "== B. no install/first-boot reset of the defaults =="
# Any gsettings write or override targeting the schema's own keys would clobber the default.
reset=$(grep -rn "gsettings set dev\.ncz\.screensaver\|dev\.ncz\.screensaver" \
          "$ROOT/post-install" "$ROOT/build" 2>/dev/null \
        | grep -E "gsettings set|gschema\.override" || true)
if [ -z "$reset" ]; then
  ok "no installer/build script overrides dev.ncz.screensaver"
else
  bad "install-time override of the screensaver defaults:"; echo "$reset" | sed 's/^/      /'
fi

echo "== C. Black Hole uses the Cygnus palette preset =="
[ -f "$PAL" ] || { bad "palette token file missing: $PAL"; exit 1; }
if [ -f "$ROOT/assets/screensaver-chooser/options/blackhole.tsv" ] \
   && grep -qi "cygnus" "$ROOT/assets/screensaver-chooser/options/blackhole.tsv"; then
  ok "blackhole.tsv wires the cygnus palette option"
else
  bad "blackhole.tsv does not wire a cygnus palette option (engine preset, not a fork)"
fi

echo "== D. ship set =="
[ -f "$CAT" ] || { bad "catalogue missing: $CAT"; exit 1; }
cur=$(mktemp -t ss-cur.XXXXXX); ship=$(mktemp -t ss-ship.XXXXXX)
trap 'rm -f "$cur" "$ship"' EXIT
grep -vE '^[[:space:]]*(#|$)' "$CAT" | cut -f1 | sort -u > "$cur"
N=$(wc -l < "$cur" | tr -d ' ')
check "catalogue size" "$N" "84"
if git -C "$ROOT" cat-file -e "$REF^{commit}" 2>/dev/null; then
  git -C "$ROOT" show "$REF:assets/screensaver-chooser/hacks.tsv" 2>/dev/null \
    | grep -vE '^[[:space:]]*(#|$)' | cut -f1 | sort -u > "$ship"
  if diff -u "$ship" "$cur" > /dev/null 2>&1; then
    ok "every catalogue id is in the approved ship set ($REF)"
  else
    bad "catalogue drifted from the approved ship set:"; diff -u "$ship" "$cur" | sed 's/^/      /'
  fi
else
  bad "approved ship-set commit $REF not present in this checkout"
fi
if grep -qiE 'gl4es|(^|[_-])gl1([_-]|$)|gles1' "$cur"; then
  bad "GL1/gl4es entry in the shipped catalogue:"; grep -iE 'gl4es|gl1|gles1' "$cur" | sed 's/^/      /'
else
  ok "no GL1/gl4es entries"
fi
unshipped=$(grep -iE 'megacity|chitin|fractint|neonspacewar|magmasimplex|leviathan|genxvectorcade|ephemeris' "$cur" || true)
if [ -z "$unshipped" ]; then ok "no unshipped savers in the catalogue"
else bad "unshipped savers present:"; echo "$unshipped" | sed 's/^/      /'; fi
# The defaults must name a saver that is actually shipped, or first boot shows nothing.
if grep -qx blackhole_gles3 "$cur"; then ok "default hack-id is in the catalogue"
else bad "default hack-id blackhole_gles3 is not in the catalogue"; fi

echo
echo "screensaver gates: $PASS passed, $FAILS failed"
[ "$FAILS" -eq 0 ]
