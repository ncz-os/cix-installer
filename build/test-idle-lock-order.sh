#!/bin/bash
# test-idle-lock-order.sh -- post-install/63-ncz-idle-lock-order.sh installs a
# GSettings default override that makes the desktop idle screen-lock
# (dev.sinty.lockscreen:idle-delay) fire strictly AFTER the ncz screensaver
# (dev.ncz.screensaver:hack-idle-delay). It is validated against the real
# glib-compile-schemas and the effective value is read back, on fixture schemas.
#
# The bug it guards: both defaults are 300s, so the protocol-exclusive lock
# surface races the layer-shell saver and can win, leaving the saver unseen
# (PROTEUS 2026-10-11).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/post-install/63-ncz-idle-lock-order.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

if ! command -v glib-compile-schemas >/dev/null 2>&1; then echo "SKIP: glib-compile-schemas not installed"; exit 0; fi

# mkschemas DIR [saver-delay] [lock-delay] -- write the two fixture schemas
mkschemas() {
    local dir="$1" saver="${2:-300}" lockdelay="${3:-60}"
    mkdir -p "$dir"
    # Multi-line <key> blocks, exactly like the real shipping schemas (the
    # header, an optional <range/> and the <default> are separate lines).
    cat > "$dir/dev.sinty.lockscreen.gschema.xml" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<schemalist>
  <schema id="dev.sinty.lockscreen" path="/dev/sinty/lockscreen/">
    <key name="lock-enabled" type="b">
      <default>true</default>
      <summary>l</summary>
    </key>
    <key name="idle-delay" type="i">
      <default>300</default>
      <summary>i</summary>
    </key>
    <key name="lock-on-suspend" type="b">
      <default>true</default>
      <summary>s</summary>
    </key>
  </schema>
</schemalist>
XML
    cat > "$dir/dev.ncz.screensaver.gschema.xml" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<schemalist>
  <schema id="dev.ncz.screensaver" path="/dev/ncz/screensaver/">
    <key name="mode" type="s">
      <default>'one'</default>
      <summary>m</summary>
    </key>
    <key name="hack-idle-delay" type="i">
      <default>$saver</default>
      <summary>h</summary>
    </key>
    <key name="lock-delay" type="i">
      <default>$lockdelay</default>
      <summary>d</summary>
    </key>
  </schema>
</schemalist>
XML
}
run() { NCZ_IDLELOCK_SCHEMA_DIR="$1" NCZ_IDLELOCK_SAVER_SCHEMA="$1/dev.ncz.screensaver.gschema.xml" bash "$HOOK" >"$T/out" 2>&1; echo $?; }
# lock_at DIR -> print the override's idle-delay
lock_at() { sed -n 's/^idle-delay=//p' "$1/99-ncz-idle-lock-order.gschema.override" 2>/dev/null | tail -1 | tr -dc '0-9'; }

# 1. defaults 300 + 60 -> lock at 360, and the dir still compiles --strict
mkschemas "$T/a" 300 60
rc=$(run "$T/a")
if [ "$rc" = 0 ] && [ -f "$T/a/99-ncz-idle-lock-order.gschema.override" ]; then ok "override installed"; else bad "no override (rc=$rc): $(tail -3 "$T/out")"; fi
if [ "$(lock_at "$T/a")" = 360 ]; then ok "lock default = saver(300) + lock-delay(60) = 360"; else bad "lock default is '$(lock_at "$T/a")', expected 360"; fi
if glib-compile-schemas --strict --dry-run "$T/a" >/dev/null 2>&1; then ok "schema dir compiles --strict with the override"; else bad "schema dir does not compile with the override"; fi
glib-compile-schemas "$T/a" 2>/dev/null
got=$(GSETTINGS_SCHEMA_DIR="$T/a" GSETTINGS_BACKEND=memory gsettings get dev.sinty.lockscreen idle-delay 2>/dev/null)
if [ "$got" = "360" ]; then ok "effective dev.sinty.lockscreen idle-delay = 360"; else bad "effective idle-delay is '$got', expected 360"; fi
# the override must NOT touch the saver schema
got=$(GSETTINGS_SCHEMA_DIR="$T/a" GSETTINGS_BACKEND=memory gsettings get dev.ncz.screensaver hack-idle-delay 2>/dev/null)
if [ "$got" = "300" ]; then ok "saver schema hack-idle-delay left untouched (300)"; else bad "saver hack-idle-delay changed to '$got'"; fi

# 2. the value tracks the installed saver schema, not a hard-coded 360
mkschemas "$T/b" 120 30
rc=$(run "$T/b")
if [ "$rc" = 0 ] && [ "$(lock_at "$T/b")" = 150 ]; then ok "lock default follows the schema (120 + 30 = 150)"; else bad "value did not follow the schema: $(lock_at "$T/b")"; fi

# 3. lock-delay 0 must not put the lock at the same time as the saver
mkschemas "$T/c" 300 0
rc=$(run "$T/c")
la="$(lock_at "$T/c")"
if [ "$rc" = 0 ] && [ -n "$la" ] && [ "$la" -gt 300 ]; then ok "lock-delay 0 keeps lock strictly after the saver ($la > 300)"; else bad "lock-delay 0 gave lock at '$la'"; fi

# 4. idempotent
before=$(cksum < "$T/a/99-ncz-idle-lock-order.gschema.override")
rc=$(run "$T/a")
after=$(cksum < "$T/a/99-ncz-idle-lock-order.gschema.override")
if [ "$rc" = 0 ] && [ "$before" = "$after" ]; then ok "second run is idempotent"; else bad "second run changed the override"; fi

# 5. no lockscreen schema -> skip cleanly, nothing written
mkdir -p "$T/empty"
rc=$(run "$T/empty")
if [ "$rc" = 0 ] && [ ! -e "$T/empty/99-ncz-idle-lock-order.gschema.override" ]; then ok "skips cleanly without the lockscreen schema"; else bad "wrote an override without the lockscreen schema (rc=$rc)"; fi

# 6. missing saver schema -> fallback 360, still installed
mkschemas "$T/d"
rm -f "$T/d/dev.ncz.screensaver.gschema.xml"
rc=$(run "$T/d")
if [ "$rc" = 0 ] && [ "$(lock_at "$T/d")" = 360 ]; then ok "fallback 360 when the saver schema is absent"; else bad "fallback wrong (rc=$rc, lock=$(lock_at "$T/d"))"; fi

# 7. registered for both platforms and ordered after the saver default hook
for p in sky1-arm64 amd64; do
    if grep -qx '63-ncz-idle-lock-order.sh' "$ROOT/post-install/hooks.list.$p"; then ok "hook listed for $p"; else bad "hook not listed for $p"; fi
done
if [ "$(grep -nE '^(62-cygnus-screensaver-default|63-ncz-idle-lock-order)\.sh$' "$ROOT/post-install/hooks.list.amd64" | head -1 | cut -d: -f2)" = "62-cygnus-screensaver-default.sh" ]; then ok "ordered after 62-cygnus-screensaver-default.sh"; else bad "hook order"; fi

echo "idle-lock-order tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
