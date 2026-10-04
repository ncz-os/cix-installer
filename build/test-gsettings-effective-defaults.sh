#!/bin/bash
# test-gsettings-effective-defaults.sh -- prove the stale-gschemas.compiled gate
# in BOTH directions, using the real glib-compile-schemas/gsettings.
#
# Fixture: a dev.sinty.desktop schema whose stock default for pinned-apps /
# enabled-plugins is the first-party list, plus the Cygnus override that adds
# the browsers, the terminal dock entry and the plugin set.
#
#   1. compile the dir (correct)      -> gate PASSES; effective pinned-apps
#                                        contains google-chrome.desktop.
#   2. overwrite gschemas.compiled with a compile made WITHOUT the override
#      (the exact O6N staleness)      -> gate FAILS on the difference, and
#                                        --expect-contains FAILS.
#   3. recompile                      -> gate PASSES again.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/verify-gsettings-effective-defaults.sh"
[ -x "$GATE" ] || { echo "SKIP: $GATE not executable"; exit 0; }
command -v glib-compile-schemas >/dev/null 2>&1 || { echo "SKIP: glib-compile-schemas not installed"; exit 0; }
command -v gsettings >/dev/null 2>&1 || { echo "SKIP: gsettings not installed"; exit 0; }

PASS=0; FAILS=0
ok()  { PASS=$((PASS + 1)); echo "ok   $1"; }
bad() { FAILS=$((FAILS + 1)); echo "FAIL $1"; }

W="$(mktemp -d "${TMPDIR:-/tmp}/gsettings-gate-test.XXXXXX")"
trap 'rm -rf "$W"' EXIT
S="$W/schemas"; mkdir -p "$S"

cat > "$S/dev.sinty.desktop.gschema.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<schemalist>
  <schema id="dev.sinty.desktop" path="/dev/sinty/desktop/">
    <key name="pinned-apps" type="as">
      <default>['dev.sinty.files.desktop', 'dev.sinty.write.desktop', 'dev.sinty.store.desktop', 'dev.sinty.calculator.desktop']</default>
      <summary>Pinned Apps</summary>
    </key>
    <key name="enabled-plugins" type="as">
      <default>['mpris-dock', 'tray-icons']</default>
      <summary>Enabled Plugins</summary>
    </key>
  </schema>
</schemalist>
XML

cat > "$S/99-ncz-defaults.gschema.override" <<'OVR'
[dev.sinty.desktop]
pinned-apps=['dev.sinty.files.desktop', 'chromium-ncz-sky1.desktop', 'google-chrome.desktop', 'org.gnome.Console.desktop', 'dev.sinty.write.desktop', 'dev.sinty.store.desktop', 'dev.sinty.calculator.desktop']
enabled-plugins=['mpris-dock', 'tray-icons', 'wallpapers-ocs', 'sensors']
OVR

gate() { "$GATE" --schema-dir "$S" "$@"; }

# 1. correct compile -> pass
glib-compile-schemas --strict "$S" 2>/dev/null || { bad "fixture does not compile --strict"; echo "abort"; exit 1; }
if gate >"$W/out" 2>&1; then ok "fresh compiled dir: gate PASSES"; else bad "fresh compiled dir: gate FAILED: $(tail -3 "$W/out")"; fi
if gate --expect-contains pinned-apps google-chrome.desktop >"$W/out" 2>&1 && \
   gate --expect-contains pinned-apps org.gnome.Console.desktop >"$W/out" 2>&1; then
    ok "fresh compiled dir: dock has the browser and the terminal"
else
    bad "fresh compiled dir: expected dock entries missing: $(tail -3 "$W/out")"
fi

# 2. the O6N staleness: compile WITHOUT the override, install that compiled db
STOCK="$W/stock"; mkdir -p "$STOCK"
cp "$S/dev.sinty.desktop.gschema.xml" "$STOCK/"
glib-compile-schemas --strict "$STOCK" 2>/dev/null
cp "$STOCK/gschemas.compiled" "$S/gschemas.compiled"
if gate >"$W/out" 2>&1; then
    bad "stale compiled db: gate PASSED (should FAIL)"
else
    ok "stale compiled db: gate FAILS on the installed-vs-fresh difference"
    grep -q 'differs' "$W/out" && ok "stale compiled db: failure explains the difference" || bad "stale compiled db: failure does not explain the difference"
fi
if gate --expect-contains pinned-apps google-chrome.desktop >"$W/out" 2>&1; then
    bad "stale compiled db: --expect-contains PASSED (should FAIL)"
else
    ok "stale compiled db: --expect-contains FAILS (the Cygnus dock default never took effect)"
fi

# 3. recompile -> pass again
glib-compile-schemas --strict "$S" 2>/dev/null
if gate >"$W/out" 2>&1; then ok "recompiled: gate PASSES again"; else bad "recompiled: gate FAILED: $(tail -3 "$W/out")"; fi

# 4. --require on a missing dir is a hard failure (not a skip)
if "$GATE" --schema-dir "$W/nope" --require >/dev/null 2>&1; then
    bad "--require with a missing schema dir PASSED (should FAIL)"
else
    ok "--require with a missing schema dir FAILS"
fi

echo "gsettings-effective-defaults tests: $PASS passed, $FAILS failed"
[ "$FAILS" = 0 ]
