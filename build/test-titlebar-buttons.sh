#!/bin/bash
# test-titlebar-buttons.sh -- post-install/65-ncz-titlebar-buttons.sh installs
# a GSettings default override that flips dev.sinty.desktop.legacy-titlebar
# to true (NCZ image default), and the corresponding downstream patch
# (assets/singularity/patches/singularity-shell/0020-titlebar-buttons-when-legacy.patch)
# makes the labwc SSD layout include iconify,max when that key is on. The
# override is validated against glib-compile-schemas and the effective
# value is read back, on fixture schemas.
#
# The behaviour it guards: NCZ ships with minimize+maximize+close on every
# SSD window (Chromium, foot, GTK apps with force-ssd=true) by default; a
# user who later flips legacy-titlebar=false in Settings goes back to
# whatever GNOME's button-layout says (close-only by default) -- the
# override only changes DEFAULTS, never an existing user choice.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/post-install/65-ncz-titlebar-buttons.sh"
export G_MESSAGES_DEBUG=
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

if ! command -v glib-compile-schemas >/dev/null 2>&1; then echo "SKIP: glib-compile-schemas not installed"; exit 0; fi

# mkdesktop DIR -- write the minimal dev.sinty.desktop schema, with the
# legacy-titlebar and force-ssd keys that the patch reads, exactly as in
# the upstream pinned schema.
mkdesktop() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/dev.sinty.desktop.gschema.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<schemalist>
  <schema id="dev.sinty.desktop" path="/dev/sinty/desktop/">
    <key name="force-ssd" type="b">
      <default>false</default>
      <summary>f</summary>
    </key>
    <key name="legacy-titlebar" type="b">
      <default>false</default>
      <summary>l</summary>
    </key>
    <key name="window-rounded-corners" type="b">
      <default>true</default>
      <summary>r</summary>
    </key>
  </schema>
</schemalist>
XML
}
run() { NCZ_TITLEBAR_SCHEMA_DIR="$1" bash "$HOOK" >"$T/out" 2>&1; }
override_lt() { awk -F'=' '/^legacy-titlebar=/ {print $2; exit}' "$1/99-ncz-titlebar.gschema.override" 2>/dev/null; }

# 1. fresh install: override is written, schema still compiles --strict
mkdesktop "$T/a"
run "$T/a"; rc=$?
if [ "$rc" = 0 ] && [ -f "$T/a/99-ncz-titlebar.gschema.override" ]; then ok "override installed"; else bad "no override (rc=$rc): $(tail -3 "$T/out")"; fi
if [ "$(override_lt "$T/a")" = "true" ]; then ok "default = true"; else bad "default is '$(override_lt "$T/a")', expected true"; fi
if glib-compile-schemas --strict --dry-run "$T/a" >/dev/null 2>&1; then ok "schema dir compiles --strict with the override"; else bad "schema dir does not compile with the override"; fi
glib-compile-schemas "$T/a" 2>/dev/null
got=$(GSETTINGS_SCHEMA_DIR="$T/a" GSETTINGS_BACKEND=memory gsettings get dev.sinty.desktop legacy-titlebar 2>/dev/null)
if [ "$got" = "true" ]; then ok "effective dev.sinty.desktop legacy-titlebar = true"; else bad "effective legacy-titlebar is '$got', expected true"; fi
# the override must NOT touch the other desktop keys
got=$(GSETTINGS_SCHEMA_DIR="$T/a" GSETTINGS_BACKEND=memory gsettings get dev.sinty.desktop window-rounded-corners 2>/dev/null)
if [ "$got" = "true" ]; then ok "window-rounded-corners left untouched (true)"; else bad "window-rounded-corners changed to '$got'"; fi

# 2. idempotent
before=$(cksum < "$T/a/99-ncz-titlebar.gschema.override")
run "$T/a"; rc=$?
after=$(cksum < "$T/a/99-ncz-titlebar.gschema.override")
if [ "$rc" = 0 ] && [ "$before" = "$after" ]; then ok "second run is idempotent"; else bad "second run changed the override"; fi

# 3. no dev.sinty.desktop schema -> skip cleanly
mkdir -p "$T/empty"
run "$T/empty"; rc=$?
if [ "$rc" = 0 ] && [ ! -e "$T/empty/99-ncz-titlebar.gschema.override" ]; then ok "skips cleanly without the desktop schema"; else bad "wrote an override without the desktop schema (rc=$rc)"; fi

# 4. legacy-titlebar key absent -> skip cleanly
mkdir -p "$T/nokey"
cat > "$T/nokey/dev.sinty.desktop.gschema.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<schemalist>
  <schema id="dev.sinty.desktop" path="/dev/sinty/desktop/">
    <key name="force-ssd" type="b">
      <default>false</default>
      <summary>f</summary>
    </key>
  </schema>
</schemalist>
XML
run "$T/nokey"; rc=$?
if [ "$rc" = 0 ] && [ ! -e "$T/nokey/99-ncz-titlebar.gschema.override" ]; then ok "skips cleanly without the legacy-titlebar key"; else bad "wrote an override without the key (rc=$rc)"; fi

# 5. registered for both platforms, ordered after the saver default hook
for p in sky1-arm64 amd64; do
    if grep -qx '65-ncz-titlebar-buttons.sh' "$ROOT/post-install/hooks.list.$p"; then ok "hook listed for $p"; else bad "hook not listed for $p"; fi
done
if [ "$(grep -nE '^(64-ncz-lock-saver-plan|65-ncz-titlebar-buttons)\.sh$' "$ROOT/post-install/hooks.list.amd64" | head -1 | cut -d: -f2)" = "64-ncz-lock-saver-plan.sh" ]; then ok "ordered after 64-ncz-lock-saver-plan.sh"; else bad "hook order"; fi

# 6. downstream patch applies to the pinned singularity-shell commit
PATCH="$ROOT/assets/singularity/patches/singularity-shell/0020-titlebar-buttons-when-legacy.patch"
if [ -f "$PATCH" ]; then ok "patch file present"; else bad "patch file missing: $PATCH"; fi
if "$ROOT/build/singularity-pins.sh" check-patches 2>&1 | grep -q "^\\[pins\\] OK: singularity-shell/0020-titlebar-buttons-when-legacy.patch applies to its pinned upstream commit"; then ok "patch applies to its pinned commit (check-patches)"; else bad "patch does not apply (run build/singularity-pins.sh check-patches)"; fi

# 7. README documents the patch in the singularity-shell active block
if grep -q '0020-titlebar-buttons-when-legacy.patch' "$ROOT/assets/singularity/patches/README.md"; then ok "README documents 0020-titlebar-buttons-when-legacy.patch"; else bad "README does not document the patch"; fi

echo "titlebar-buttons tests: $pass passed, $fail failed"
[ "$fail" = 0 ]