#!/bin/bash
# test-lock-saver-plan.sh -- post-install/64-ncz-lock-saver-plan.sh installs the
# single idle/lock/blank owner plan for the NCZ lock renderer: when the lock
# client hosts the screensaver, the session lock is acquired AT the saver time
# (idle-delay = hack-idle-delay), the interim "lock after the saver" override is
# removed (one owner), and the plan is validated against the real
# glib-compile-schemas with the effective value read back on fixture schemas.
# When the renderer is not configured the hook must change nothing, so the
# shipped fallback (hook 63, 360 > 300) stands.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/post-install/64-ncz-lock-saver-plan.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

if ! command -v glib-compile-schemas >/dev/null 2>&1; then echo "SKIP: glib-compile-schemas not installed"; exit 0; fi

# mkschemas DIR [saver-delay] -- lockscreen + saver fixture schemas
mkschemas() {
    local dir="$1" saver="${2:-300}"
    mkdir -p "$dir"
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
  </schema>
</schemalist>
XML
    cat > "$dir/dev.ncz.screensaver.gschema.xml" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<schemalist>
  <schema id="dev.ncz.screensaver" path="/dev/ncz/screensaver/">
    <key name="hack-idle-delay" type="i">
      <default>$saver</default>
      <summary>h</summary>
    </key>
    <key name="lock-delay" type="i">
      <default>60</default>
      <summary>d</summary>
    </key>
  </schema>
</schemalist>
XML
}
# a fallback override, as hook 63 would have left it
mkfallback() { printf '[dev.sinty.lockscreen]\nidle-delay=360\n' > "$1/99-ncz-idle-lock-order.gschema.override"; }
# a renderer conf naming a command
mkconf() { printf 'SINGULARITY_LOCK_RENDERER=%s\n' "${1:-/usr/libexec/ncz-screensaver-feed}" > "$2"; }
# run DIR CONF [ENABLE] -> run the hook against the fixtures
run() {
    NCZ_LOCKSAVER_SCHEMA_DIR="$1" \
    NCZ_LOCKSAVER_SAVER_SCHEMA="$1/dev.ncz.screensaver.gschema.xml" \
    NCZ_LOCKSAVER_CONF="$2" \
    NCZ_LOCKSAVER_ENABLE="${3:-0}" \
    bash "$HOOK" >"$T/out" 2>&1
}
plan_at() { sed -n 's/^idle-delay=//p' "$1/99-ncz-lock-saver-plan.gschema.override" 2>/dev/null | tail -1 | tr -dc '0-9'; }

# 1. renderer NOT configured -> no plan, fallback override untouched
mkschemas "$T/a" 300
: > "$T/none.conf"
mkfallback "$T/a"
run "$T/a" "$T/none.conf"; rc=$?
if [ "$rc" = 0 ] && [ ! -e "$T/a/99-ncz-lock-saver-plan.gschema.override" ]; then ok "renderer absent: no plan installed"; else bad "plan installed without a renderer (rc=$rc)"; fi
if [ -f "$T/a/99-ncz-idle-lock-order.gschema.override" ]; then ok "renderer absent: fallback override left in place"; else bad "fallback override removed without a renderer"; fi

# 2. renderer configured -> plan at hack-idle-delay, fallback removed, compiles
mkschemas "$T/b" 300
mkconf "" "$T/b.conf"
mkfallback "$T/b"
run "$T/b" "$T/b.conf"; rc=$?
if [ "$rc" = 0 ] && [ -f "$T/b/99-ncz-lock-saver-plan.gschema.override" ]; then ok "override installed"; else bad "no plan (rc=$rc): $(tail -3 "$T/out")"; fi
if [ "$(plan_at "$T/b")" = 300 ]; then ok "lock at the saver time (hack-idle-delay 300)"; else bad "plan is '$(plan_at "$T/b")', expected 300"; fi
if [ ! -e "$T/b/99-ncz-idle-lock-order.gschema.override" ]; then ok "superseded interim override removed (one owner)"; else bad "interim override still present"; fi
if glib-compile-schemas --strict --dry-run "$T/b" >/dev/null 2>&1; then ok "schema dir compiles --strict with the plan"; else bad "schema dir does not compile with the plan"; fi
glib-compile-schemas "$T/b" 2>/dev/null
got=$(GSETTINGS_SCHEMA_DIR="$T/b" GSETTINGS_BACKEND=memory gsettings get dev.sinty.lockscreen idle-delay 2>/dev/null)
if [ "$got" = "300" ]; then ok "effective idle-delay = 300 (lock from saver start)"; else bad "effective idle-delay is '$got', expected 300"; fi
got=$(GSETTINGS_SCHEMA_DIR="$T/b" GSETTINGS_BACKEND=memory gsettings get dev.ncz.screensaver hack-idle-delay 2>/dev/null)
if [ "$got" = "300" ]; then ok "saver schema left untouched"; else bad "saver schema changed ('$got')"; fi

# 3. the value tracks the installed saver schema
mkschemas "$T/c" 450
mkconf "" "$T/c.conf"
run "$T/c" "$T/c.conf"; rc=$?
if [ "$rc" = 0 ] && [ "$(plan_at "$T/c")" = 450 ]; then ok "plan follows hack-idle-delay (450)"; else bad "plan did not follow the schema: $(plan_at "$T/c")"; fi

# 4. missing saver schema -> default 300
mkschemas "$T/d" 300
rm -f "$T/d/dev.ncz.screensaver.gschema.xml"
mkconf "" "$T/d.conf"
run "$T/d" "$T/d.conf"; rc=$?
if [ "$rc" = 0 ] && [ "$(plan_at "$T/d")" = 300 ]; then ok "fallback 300 when the saver schema is absent"; else bad "fallback wrong (rc=$rc, plan=$(plan_at "$T/d"))"; fi

# 5. idempotent
before=$(cksum < "$T/b/99-ncz-lock-saver-plan.gschema.override")
run "$T/b" "$T/b.conf"; rc=$?
after=$(cksum < "$T/b/99-ncz-lock-saver-plan.gschema.override")
if [ "$rc" = 0 ] && [ "$before" = "$after" ]; then ok "second run is idempotent"; else bad "second run changed the plan"; fi

# 6. packaging-time force (used by the image gate) works without a conf
mkschemas "$T/e" 300
: > "$T/none2.conf"
run "$T/e" "$T/none2.conf" 1; rc=$?
if [ "$rc" = 0 ] && [ "$(plan_at "$T/e")" = 300 ]; then ok "NCZ_LOCKSAVER_ENABLE=1 forces the plan"; else bad "force did not install the plan (rc=$rc)"; fi

# 7. no lockscreen schema -> skip cleanly
mkdir -p "$T/empty"
mkconf "" "$T/empty.conf"
run "$T/empty" "$T/empty.conf"; rc=$?
if [ "$rc" = 0 ] && [ ! -e "$T/empty/99-ncz-lock-saver-plan.gschema.override" ]; then ok "skips cleanly without the lockscreen schema"; else bad "wrote a plan without the lockscreen schema (rc=$rc)"; fi

# 8. registered for both platforms and in the baked-mode allowlist
for p in sky1-arm64 amd64; do
    if grep -qx '64-ncz-lock-saver-plan.sh' "$ROOT/post-install/hooks.list.$p"; then ok "hook listed for $p"; else bad "hook not listed for $p"; fi
done
if grep -q '64-ncz-lock-saver-plan' "$ROOT/post-install/run-all.sh"; then ok "hook in the run-all.sh machine allowlist"; else bad "hook missing from run-all.sh MACHINE_HOOKS_RE"; fi

echo "lock-saver-plan tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
