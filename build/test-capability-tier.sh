#!/bin/bash
# test-capability-tier.sh -- tests for the capability profiler and its hook.
#
#   1. the pure scoring unit tests + fleet fixtures
#      (assets/capability/tests/test_capability.py): CYCLOPS HD3000 and the Dell
#      .70 must land T2, a software renderer or a spinning disk must cap at T1.
#   2. post-install/65-capability-tier.sh installs the tool, the feature map, the
#      preference schema, the first-boot service and the recheck timer/udev rule
#      into a temp root, idempotently.
#   3. `ncz-capability apply` writes tier DEFAULTS into a temp root and an
#      /etc/ncz/capability.override file wins over the measured tier.
#
# Needs python3 (the tool is Python).  glib-compile-schemas is used when present.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/post-install/65-capability-tier.sh"
TOOL="$ROOT/assets/capability/ncz-capability"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not installed"; exit 0; }

# --- 1. scoring unit tests + fleet regression --------------------------------
if python3 "$ROOT/assets/capability/tests/test_capability.py" >"$T/units" 2>&1; then
    ok "scoring unit tests + fleet fixtures pass ($(tail -1 "$T/units"))"
else
    bad "scoring unit tests failed:"; sed 's/^/     /' "$T/units" | tail -20
fi

# --- 2. install hook into a temp root ----------------------------------------
TROOT="$T/root"
SCHEMA="$TROOT/usr/share/glib-2.0/schemas"
mkdir -p "$SCHEMA"
cat > "$SCHEMA/dev.ncz.screensaver.gschema.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<schemalist><schema id="dev.ncz.screensaver" path="/dev/ncz/screensaver/">
<key name="render-scale" type="d"><default>1.0</default><summary>x</summary></key>
</schema></schemalist>
XML
cat > "$SCHEMA/dev.sinty.desktop.gschema.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<schemalist><schema id="dev.sinty.desktop" path="/dev/sinty/desktop/">
<key name="blur-strength" type="i"><default>60</default><summary>x</summary></key>
</schema></schemalist>
XML

run_hook() { NCZ_CAP_ASSET_SRC="$ROOT/assets/capability" NCZ_CAP_ROOT="$TROOT" \
             NCZ_CAP_SCHEMA_DIR="$SCHEMA" bash "$HOOK" >"$T/hook.out" 2>&1; echo $?; }
rc=$(run_hook)
[ "$rc" = 0 ] && ok "hook exits 0" || bad "hook exit $rc: $(tail -3 "$T/hook.out")"
[ -x "$TROOT/usr/bin/ncz-capability" ] && ok "ncz-capability installed" || bad "ncz-capability missing"
[ -f "$TROOT/usr/share/ncz/capability/capability-features.tsv" ] && ok "feature map installed" || bad "feature map missing"
[ -f "$TROOT/usr/lib/systemd/system/ncz-capability.service" ] && ok "first-boot service installed" || bad "first-boot service missing"
[ -f "$TROOT/usr/lib/systemd/system/ncz-capability-recheck.service" ] && ok "recheck service installed" || bad "recheck service missing"
[ -f "$TROOT/usr/lib/systemd/system/ncz-capability-recheck.timer" ] && ok "recheck timer installed" || bad "recheck timer missing"
[ -f "$TROOT/etc/udev/rules.d/72-ncz-capability-recheck.rules" ] && ok "udev rule installed" || bad "udev rule missing"
[ -L "$TROOT/usr/lib/systemd/system/multi-user.target.wants/ncz-capability.service" ] && ok "first-boot service enabled" || bad "first-boot service not enabled"
[ -L "$TROOT/usr/lib/systemd/system/timers.target.wants/ncz-capability-recheck.timer" ] && ok "recheck timer enabled" || bad "recheck timer not enabled"
if command -v glib-compile-schemas >/dev/null 2>&1; then
    [ -f "$SCHEMA/dev.ncz.capability.gschema.xml" ] && ok "preference schema installed" || bad "preference schema missing"
    if glib-compile-schemas --strict --dry-run "$SCHEMA" >/dev/null 2>&1; then ok "schema dir compiles --strict with the preference schema"; else bad "schema dir fails --strict"; fi
else
    echo "note: glib-compile-schemas absent -- schema install/compile checks skipped"
fi
# idempotent
b1=$(find "$TROOT/usr/bin/ncz-capability" -exec cksum {} \;)
rc=$(run_hook)
b2=$(find "$TROOT/usr/bin/ncz-capability" -exec cksum {} \;)
[ "$rc" = 0 ] && [ "$b1" = "$b2" ] && ok "second hook run is idempotent" || bad "hook not idempotent"

# --- 3. apply writes tier defaults; capability.override wins ------------------
AROOT="$T/applyroot"
ASCH="$AROOT/usr/share/glib-2.0/schemas"
mkdir -p "$ASCH"
cp "$SCHEMA"/*.gschema.xml "$ASCH"/ 2>/dev/null
# override forces T0 regardless of what this machine measures
cat > "$T/ovr" <<'EOF'
# capability.override
tier = T0
EOF
if python3 "$TOOL" apply --root "$AROOT" --override "$T/ovr" --no-calibrate >"$T/apply.out" 2>&1; then
    ok "apply --root exits 0"
else
    bad "apply failed: $(tail -3 "$T/apply.out")"
fi
[ -f "$AROOT/etc/environment.d/60-ncz-capability.conf" ] && ok "env defaults written" || bad "env defaults missing"
[ -f "$AROOT/etc/ncz/capability/features.env" ] && ok "feature flags written" || bad "feature flags missing"
if grep -q '^NCZ_SAVER_LOCK_FPS=4$' "$AROOT/etc/environment.d/60-ncz-capability.conf" 2>/dev/null; then ok "T0 env value (saver fps 4) applied"; else bad "T0 env value wrong: $(grep SAver "$AROOT/etc/environment.d/60-ncz-capability.conf" 2>/dev/null)"; fi
if grep -q '^CAPABILITY_SPLASH=off$' "$AROOT/etc/ncz/capability/features.env" 2>/dev/null; then ok "T0 splash flag off"; else bad "T0 splash flag wrong"; fi
OVR_FILE="$(find "$ASCH" -name '99-ncz-capability.gschema.override' 2>/dev/null | head -1)"
if [ -n "$OVR_FILE" ]; then
    ok "gschema default override written"
    grep -q "blur-strength=0" "$OVR_FILE" && ok "T0 blur-strength=0 in override" || bad "override missing T0 blur"
else
    bad "no gschema override written"
fi

# A --tier pin beats the override file
if python3 "$TOOL" apply --root "$AROOT" --tier T3 --override "$T/ovr" --no-calibrate >"$T/apply2.out" 2>&1; then
    if grep -q '^NCZ_SAVER_LOCK_FPS=12$' "$AROOT/etc/environment.d/60-ncz-capability.conf" 2>/dev/null; then
        ok "--tier overrides the override file"
    else
        bad "--tier did not win: $(grep LOCK_FPS "$AROOT/etc/environment.d/60-ncz-capability.conf")"
    fi
else
    bad "apply --tier failed: $(tail -3 "$T/apply2.out")"
fi

# --- 4. registered for both platforms, ordered after 64 ----------------------
grep -q "^65-capability-tier.sh$" "$ROOT/post-install/hooks.list.sky1-arm64" && \
grep -q "^65-capability-tier.sh$" "$ROOT/post-install/hooks.list.amd64" && \
    ok "hook listed for sky1-arm64 and amd64" || bad "hook not listed on both platforms"
if grep -q -- '65-capability-tier' "$ROOT/post-install/run-all.sh"; then ok "hook in run-all MACHINE_HOOKS_RE"; else bad "hook missing from run-all"; fi
if grep -q 'capability' "$ROOT/build/build-squashfs-layers.sh"; then ok "assets/capability staged by the base build"; else bad "capability not in the asset allowlist"; fi

# --- 5. the boot splash wrapper consumes the capability flag -----------------
if grep -q 'CAPABILITY_SPLASH' "$ROOT/post-install/60-boot-splash.sh"; then
    ok "boot-splash wrapper honours CAPABILITY_SPLASH (off/lite/full)"
else
    bad "boot-splash wrapper does not consume the capability flag"
fi

echo "capability-tier tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
