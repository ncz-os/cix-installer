#!/bin/bash
# test-console-saver-wiring.sh -- contract test for the Magnetar server
# console saver wiring (04:40Z order, B3):
#   * the payload tree assets/console-saver/ is complete (both arches)
#   * write-usb-image.py stages it on the medium, server-guarded, and keeps
#     it OUT of SERVER_ONLINE_ASSET_DIRS (the bundle would delete it from the
#     medium; the published payload predates the saver)
#   * post-install/61-ncz-console-saver.sh is mandatory on server/headless,
#     skips desktop, never overwrites operator config, and installs the unit
#     whose ExecStart matches the install path
#   * the hook is listed for both platforms (generated hooks lists)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   - $1"; }
bad() { fail=$((fail+1)); echo "FAIL - $1"; }
expect() { # label want_rc want_grep cmd...
    local label="$1" want="$2" pat="$3"; shift 3
    local out rc
    out="$("$@" 2>&1)"; rc=$?
    if [ "$rc" != "$want" ]; then bad "$label (rc=$rc want=$want)"; return; fi
    if [ -n "$pat" ] && ! printf '%s' "$out" | grep -q "$pat"; then
        bad "$label (output lacks '$pat')"; return
    fi
    ok "$label"
}

HOOK="$ROOT/post-install/61-ncz-console-saver.sh"
ASSETS="$ROOT/assets/console-saver"
WUI="$ROOT/build/iso/write-usb-image.py"
RA="$ROOT/post-install/run-all.sh"

# --- 1. inventory + hooks lists --------------------------------------------
grep -qP '^assets/console-saver/\t' "$ROOT/docs/platform-inventory.tsv" \
    && ok "inventory: assets/console-saver/ directory row" \
    || bad "inventory: assets/console-saver/ directory row missing"
grep -qP '^post-install/61-ncz-console-saver\.sh\t' "$ROOT/docs/platform-inventory.tsv" \
    && ok "inventory: the 61 hook row" || bad "inventory: the 61 hook row missing"
grep -qP '^build/test-console-saver-wiring\.sh\t' "$ROOT/docs/platform-inventory.tsv" \
    && ok "inventory: this test's row" || bad "inventory: this test's row missing"
if bash "$ROOT/build/gen-hooks-lists.sh" --check >/dev/null 2>&1; then
    ok "hooks lists: generated lists match the inventory"
else
    bad "hooks lists: gen-hooks-lists.sh --check failed"
fi
for p in amd64 sky1-arm64; do
    grep -qx "61-ncz-console-saver.sh" "$ROOT/post-install/hooks.list.$p" \
        && ok "hooks list $p: 61-ncz-console-saver.sh listed" \
        || bad "hooks list $p: 61-ncz-console-saver.sh missing"
done

# --- 2. staged asset tree ---------------------------------------------------
for f in ncz-console-saver.service console-saver.conf README.md; do
    [ -f "$ASSETS/$f" ] && ok "assets: $f" || bad "assets: $f missing"
done
for a in amd64 arm64; do
    for b in ncz-console-saver ncz-bh-console; do
        [ -f "$ASSETS/$a/$b" ] && ok "assets: $a/$b" || bad "assets: $a/$b missing"
    done
done

# --- 3. unit/hook path contract --------------------------------------------
unit_exec="$(sed -n 's/^ExecStart=//p' "$ASSETS/ncz-console-saver.service")"
[ "$unit_exec" = "/usr/local/bin/ncz-console-saver" ] \
    && ok "unit: ExecStart=$unit_exec" || bad "unit: ExecStart is '$unit_exec'"
grep -q 'usr/local/bin/ncz-console-saver"' "$HOOK" \
    && ok "hook: installs to the unit's ExecStart path" \
    || bad "hook: install path does not match ExecStart"

# --- 4. write-usb-image.py wiring ------------------------------------------
grep -q "def stage_console_saver" "$WUI" \
    && ok "wui: stage_console_saver defined" || bad "wui: stage_console_saver missing"
grep -q 'if _variant() == "server":' "$WUI" && grep -q "stage_console_saver(assets_dst, arch)" "$WUI" \
    && ok "wui: staging is server-guarded" || bad "wui: staging call or server guard missing"
grep -q 'SERVER_ONLINE_ASSET_DIRS = ("rescue", "firmware", "kernel", "branding")' "$WUI" \
    && ok "wui: console-saver NOT in SERVER_ONLINE_ASSET_DIRS (payload coupling rule)" \
    || bad "wui: SERVER_ONLINE_ASSET_DIRS changed without a payload republish (see stage_console_saver docstring)"

# --- 5. hook behaviour in a fake root --------------------------------------
mkroot() { # $1 root, $2 variant, $3 assets-present|assets-missing
    mkdir -p "$1/usr/local/lib/cix-installer" "$1/cdrom/ncz-payload"
    printf '%s\n' "$2" > "$1/usr/local/lib/cix-installer/BUILD_VARIANT"
    if [ "$3" = assets-present ]; then
        mkdir -p "$1/cdrom/ncz-payload/assets/console-saver"
        cp "$ASSETS/ncz-console-saver.service" "$ASSETS/console-saver.conf" \
           "$ASSETS/README.md" "$1/cdrom/ncz-payload/assets/console-saver/"
        printf 'daemon\n' > "$1/cdrom/ncz-payload/assets/console-saver/ncz-console-saver"
        printf 'render\n' > "$1/cdrom/ncz-payload/assets/console-saver/ncz-bh-console"
        chmod 0755 "$1/cdrom/ncz-payload/assets/console-saver/ncz-console-saver" \
                   "$1/cdrom/ncz-payload/assets/console-saver/ncz-bh-console"
    fi
}

R1="$T/r-server"; mkroot "$R1" server assets-present
expect "hook: server installs the payload" 0 "installed without enabling" \
    env NCZ_CS_ROOT="$R1" NCZ_CS_SKIP_ENABLE=1 bash "$HOOK"
grep -q "systemctl enable ncz-console-saver.service" "$HOOK" \
    && ok "hook: server enable wiring present (systemctl enable)" \
    || bad "hook: enable wiring missing"
[ -x "$R1/usr/local/bin/ncz-console-saver" ] && [ -x "$R1/usr/local/bin/ncz-bh-console" ] \
    && ok "hook: binaries installed executable" || bad "hook: binaries missing/not executable"
[ -f "$R1/etc/systemd/system/ncz-console-saver.service" ] \
    && ok "hook: unit installed" || bad "hook: unit missing"
[ -f "$R1/etc/ncz/console-saver.conf" ] \
    && ok "hook: default conf installed" || bad "hook: conf missing"
[ -f "$R1/usr/share/doc/ncz-console-saver/README.md" ] \
    && ok "hook: README installed" || bad "hook: README missing"

printf 'enabled = 0\n' > "$R1/etc/ncz/console-saver.conf"
expect "hook: re-run keeps operator config" 0 "keeping existing" \
    env NCZ_CS_ROOT="$R1" NCZ_CS_SKIP_ENABLE=1 bash "$HOOK"
grep -q '^enabled = 0$' "$R1/etc/ncz/console-saver.conf" \
    && ok "hook: operator config bytes preserved" || bad "hook: operator config overwritten"

R2="$T/r-desktop"; mkroot "$R2" desktop assets-present
expect "hook: desktop skips" 0 "desktop SKU; skipping" \
    env NCZ_CS_ROOT="$R2" NCZ_CS_SKIP_ENABLE=1 bash "$HOOK"
[ ! -e "$R2/usr/local/bin/ncz-console-saver" ] \
    && ok "hook: desktop installs nothing" || bad "hook: desktop installed files"

R3="$T/r-headless"; mkroot "$R3" headless assets-present
expect "hook: headless installs without enabling" 0 "installed without enabling" \
    env NCZ_CS_ROOT="$R3" NCZ_CS_SKIP_ENABLE=1 bash "$HOOK"
[ -x "$R3/usr/local/bin/ncz-console-saver" ] \
    && ok "hook: headless binaries installed" || bad "hook: headless binaries missing"

R4="$T/r-missing"; mkroot "$R4" server assets-missing
expect "hook: missing assets on server is FATAL" 1 "FATAL" \
    env NCZ_CS_ROOT="$R4" NCZ_CS_SKIP_ENABLE=1 bash "$HOOK"

R5="$T/r-partial"; mkroot "$R5" server assets-present
rm "$R5/cdrom/ncz-payload/assets/console-saver/ncz-bh-console"
expect "hook: partial assets on server is FATAL" 1 "FATAL" \
    env NCZ_CS_ROOT="$R5" NCZ_CS_SKIP_ENABLE=1 bash "$HOOK"

# --- 6. run-all.sh dispatch classification (TASK NEEDS-8) -------------------
# The hook's own contract is MANDATORY on the server variant (docs/
# platform-inventory.tsv: mandatory server-variant install, missing assets =
# exit 1; the hook's own FATAL is the enforcement). run-all.sh must therefore
# keep it OUT of the fail-tolerant optional dispatch (MACHINE_HOOKS_RE,
# lib/bounded-run.sh, failure logged + continue) and instead run it through
# the ship-critical path, exactly like 72-rescue-partition / 55-greeter.
# Desktop behaviour is preserved by the hook's own BUILD_VARIANT guard: on a
# desktop install the variant is desktop, the required hook exits 0
# immediately, and the install is untouched.
#
# check-hook-registration.sh requires the hook to live in exactly one of the
# two execution lists; putting it in BOTH lists is ambiguous and can
# double-run, so it must not stay in MACHINE_HOOKS_RE while it is also made
# required.

# run-all.sh keeps the execution lists as inline alternation regex lists; the
# REQUIRED_HOOKS assignments span two lines (command substitution + grep), so
# grep -A1 reaches the alternation line.
grep -qE '\|61-ncz-console-saver\|' <(grep '^MACHINE_HOOKS_RE=' "$RA") \
    && bad "run-all: 61-ncz-console-saver is in MACHINE_HOOKS_RE (optional/bounded dispatch)" \
    || ok "run-all: 61-ncz-console-saver absent from MACHINE_HOOKS_RE"
grep -qE '^REQUIRED_HOOKS' "$RA" && \
    grep -q '61-ncz-console-saver' <(grep -A1 '^REQUIRED_HOOKS' "$RA") \
    && ok "run-all: 61-ncz-console-saver added to the REQUIRED_HOOKS list" \
    || bad "run-all: 61-ncz-console-saver not in the REQUIRED_HOOKS list"
grep -q '61-ncz-console-saver' <(grep -A1 -E '^[[:space:]]*REQUIRED_HOOKS' "$RA") \
    && ok "run-all: 61-ncz-console-saver kept required under NCZ_BAKED=1" \
    || bad "run-all: 61-ncz-console-saver dropped from the baked REQUIRED_HOOKS list"
grep -qE "CRITICAL_OPTIONAL_HOOKS_RE='.*61-ncz-console-saver.*'" "$RA" \
    && ok "run-all: 61-ncz-console-saver is in CRITICAL_OPTIONAL_HOOKS_RE (ship-critical)" \
    || bad "run-all: 61-ncz-console-saver missing from CRITICAL_OPTIONAL_HOOKS_RE"

echo
echo "PASS=$pass FAIL=$fail"
[ "$fail" = 0 ]
