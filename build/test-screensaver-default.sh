#!/bin/bash
# test-screensaver-default.sh -- post-install/62-cygnus-screensaver-default.sh installs the
# Cygnus black hole default ONLY when the installed dev.ncz.screensaver schema supports it, and
# the installed override compiles. Uses the real glib-compile-schemas on fixture schemas.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/post-install/62-cygnus-screensaver-default.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

if ! command -v glib-compile-schemas >/dev/null 2>&1; then echo "SKIP: glib-compile-schemas not installed"; exit 0; fi

mkschema() { # $1 = dir, $2 = "with" | "without" (cygnus in the enum)
    mkdir -p "$1"
    local cyg=""
    [ "$2" = with ] && cyg='<value nick="cygnus" value="7"/>'
    cat > "$1/dev.ncz.screensaver.gschema.xml" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<schemalist>
  <enum id="dev.ncz.screensaver.BlackholeColorMode">
    <value nick="stylized" value="0"/>
    <value nick="eht" value="6"/>
    $cyg
  </enum>
  <enum id="dev.ncz.screensaver.Mode">
    <value nick="off" value="0"/>
    <value nick="one" value="1"/>
    <value nick="random" value="2"/>
  </enum>
  <schema id="dev.ncz.screensaver" path="/dev/ncz/screensaver/">
    <key name="mode" enum="dev.ncz.screensaver.Mode"><default>'random'</default><summary>m</summary></key>
    <key name="hack-id" type="s"><default>'hyprsaver_aurora_gles3'</default><summary>h</summary></key>
    <key name="blackhole-color-mode" enum="dev.ncz.screensaver.BlackholeColorMode"><default>'stylized'</default><summary>c</summary></key>
  </schema>
</schemalist>
XML
}
run() { NCZ_SS_SCHEMA_DIR="$1" bash "$HOOK" >"$T/out" 2>&1; echo $?; }

# 1. schema with cygnus -> override installed and the combination compiles
mkschema "$T/with" with
rc=$(run "$T/with")
if [ "$rc" = 0 ] && [ -f "$T/with/99-ncz-cygnus-screensaver.gschema.override" ]; then ok "override installed when the schema supports cygnus"; else bad "no override with cygnus schema (rc=$rc): $(tail -3 "$T/out")"; fi
if glib-compile-schemas --strict --dry-run "$T/with" >/dev/null 2>&1; then ok "schema dir still compiles --strict with the override"; else bad "schema dir does not compile with override"; fi
glib-compile-schemas "$T/with" 2>/dev/null
for kv in "mode:'one'" "hack-id:'blackhole_gles3'" "blackhole-color-mode:'cygnus'"; do
    k="${kv%%:*}"; v="${kv#*:}"
    got=$(GSETTINGS_SCHEMA_DIR="$T/with" GSETTINGS_BACKEND=memory gsettings get dev.ncz.screensaver "$k" 2>/dev/null)
    if [ "$got" = "$v" ]; then ok "default $k = $v"; else bad "default $k is '$got', expected $v"; fi
done

# 2. second run changes nothing (idempotent)
before=$(cksum < "$T/with/99-ncz-cygnus-screensaver.gschema.override")
rc=$(run "$T/with")
after=$(cksum < "$T/with/99-ncz-cygnus-screensaver.gschema.override")
if [ "$rc" = 0 ] && [ "$before" = "$after" ]; then ok "second run is idempotent"; else bad "second run changed the override"; fi

# 3. schema WITHOUT cygnus -> nothing installed (an override naming it would break every schema)
mkschema "$T/without" without
rc=$(run "$T/without")
if [ "$rc" = 0 ] && [ ! -e "$T/without/99-ncz-cygnus-screensaver.gschema.override" ]; then ok "no override when the schema lacks cygnus (exit 0)"; else bad "override written for an old schema (rc=$rc)"; fi
if grep -q "0.7.11" "$T/out"; then ok "warning names the required ncz-screensavers version"; else bad "no version hint in the warning"; fi

# 4. an old override left from an earlier install is removed when the schema is downgraded
printf "[dev.ncz.screensaver]\nblackhole-color-mode='cygnus'\n" > "$T/without/99-ncz-cygnus-screensaver.gschema.override"
rc=$(run "$T/without")
if [ ! -e "$T/without/99-ncz-cygnus-screensaver.gschema.override" ]; then ok "stale override removed when the schema no longer supports it"; else bad "stale override left behind"; fi

# 5. no schema at all -> skip cleanly
mkdir -p "$T/empty"
rc=$(run "$T/empty")
if [ "$rc" = 0 ]; then ok "skips cleanly without the schema"; else bad "exit $rc without schema"; fi

# 6. registered for both platforms
if grep -q "^62-cygnus-screensaver-default.sh$" "$ROOT/post-install/hooks.list.sky1-arm64" && grep -q "^62-cygnus-screensaver-default.sh$" "$ROOT/post-install/hooks.list.amd64"; then
    ok "hook listed for sky1-arm64 and amd64"
else
    bad "hook not listed on both platforms"
fi
# 7. runs after the package hook that installs the schema
if [ "$(ls "$ROOT/post-install" | grep -n -E '^(59-ncz-screensavers-pkg|62-cygnus-screensaver-default)\.sh$' | head -1 | cut -d: -f2)" = "59-ncz-screensavers-pkg.sh" ]; then ok "ordered after 59-ncz-screensavers-pkg.sh"; else bad "hook order"; fi

echo "screensaver-default tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
