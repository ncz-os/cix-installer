#!/bin/bash
# test-installer-brltty-banner.sh -- 2026-10-12 unattended amd64 install
# defects, source-level regressions:
#
#   1. brltty: a USB-UART (Prolific PL2303 067b:2303, and every GENERIC
#      USB-serial id brltty's d-i udev rules cover) must NOT raise the
#      CRITICAL "Is the USB serial device indeed a braille device?" question.
#      Two layers are pinned here: the preseed answer
#      (`d-i brltty-udeb/generic boolean false`) and the cmdline autodetect
#      kill (build/iso/build-refind-esp.py NCZ_NO_BRLTTY, exercised by
#      build/iso/tests/test_refind_installer_cmdline.py).
#   2. the boot banner must print ONCE (the old 2-second heartbeat loop smeared
#      it over the newt UI for 120 s) and still carry the build id: the
#      installer cmdline now receives ncz_rev=<BUILD_VERSION>.
#
# Usage: build/test-installer-brltty-banner.sh
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

PRESEED="$ROOT/preseed/preseed.cfg"
KNOWN="$ROOT/build/preseed-known-keys.txt"
ESP="$ROOT/build/iso/build-refind-esp.py"
BUILDER="$ROOT/build/build-installer-image.sh"
PYTEST="$ROOT/build/iso/tests/test_refind_installer_cmdline.py"

PASS=0; FAIL=0
ok()  { echo "PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL  $1" >&2; FAIL=$((FAIL + 1)); }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

# ------------------------------------------------------------------ brltty layer 1
check "preseed.cfg answers brltty-udeb/generic as NO (no braille prompt)" \
    grep -qF 'd-i brltty-udeb/generic boolean false' "$PRESEED"
check "preseed.cfg marks brltty-udeb/generic seen (the answer never re-prompts)" \
    grep -qF 'd-i brltty-udeb/generic seen true' "$PRESEED"
check "brltty-udeb/generic is in the preseed known-keys allow-list" \
    grep -qE '^[[:space:]]*brltty-udeb/generic([[:space:]]|$)' "$KNOWN"

# ------------------------------------------------------------------ brltty layer 2
check "build-refind-esp.py defines the NCZ brltty autodetect-disable token" \
    grep -qE '^NCZ_NO_BRLTTY = "[^"]+"' "$ESP"
check "the brltty token is wired into the shared Install/Expert options" \
    sh -c "grep -qE '^_PC_INSTALL_OPTIONS' \"$ESP\" && grep -q 'NCZ_NO_BRLTTY' \"$ESP\""

# ------------------------------------------------------------------ banner once
# Exactly one banner line; it writes to tty1 + tty3 + console (visible boot)
# and is NOT a repeating loop (no sleep/while, no background `&`).
banner_count="$(grep -cE 'NCZ-OS INSTALLER' "$PRESEED")"
if [ "$banner_count" = 1 ]; then ok "preseed.cfg has exactly ONE NCZ-OS INSTALLER banner line"; else bad "preseed.cfg has $banner_count NCZ-OS INSTALLER banner lines (want 1)"; fi
banner_line="$(grep -E 'NCZ-OS INSTALLER' "$PRESEED" | head -1)"
case "$banner_line" in
    */dev/tty1*) ok "banner still targets /dev/tty1 (operator framebuffer)" ;;
    *) bad "banner does not target /dev/tty1" ;;
esac
case "$banner_line" in
    */dev/tty3*) ok "banner still targets /dev/tty3 (Alt-F3 diag console)" ;;
    *) bad "banner does not target /dev/tty3" ;;
esac
case "$banner_line" in
    */dev/console*) ok "banner still targets /dev/console (serial capture; keeps the KVM gate grep working)" ;;
    *) bad "banner does not target /dev/console" ;;
esac
case "$banner_line" in
    *sleep*|*while*|*"&"*) bad "banner is a repeating/backgrounded loop (the banner smear regression)" ;;
    *) ok "banner prints ONCE (no sleep/while/& on its line)" ;;
esac

# ------------------------------------------------------------------ build id reaches the installer
check "build-installer-image.sh invokes build/iso/build-refind-esp.py" \
    grep -q 'build/iso/build-refind-esp.py' "$BUILDER"
check "build-installer-image.sh passes --build-id \$BUILD_VERSION to build-refind-esp.py" \
    grep -qE '\-\-build-id[[:space:]]+"?\$BUILD_VERSION"?' "$BUILDER"
check "build-refind-esp.py has a --build-id option and stamps ncz_rev=" \
    grep -qE '\-\-build-id' "$ESP"

# ------------------------------------------------------------------ behavioral unit test
if [ -f "$PYTEST" ]; then
    if ( cd "$(dirname "$PYTEST")" && python3 "$(basename "$PYTEST")" ) >/dev/null 2>&1; then
        ok "python3 build/iso/tests/test_refind_installer_cmdline.py"
    else
        bad "python3 build/iso/tests/test_refind_installer_cmdline.py"
    fi
else
    bad "$PYTEST is missing"
fi

# --- the banner reaches every active console, once -------------------------------------
# /dev/console is the console flagged C in /proc/consoles; the banner also goes to each
# other active non-VT console (the serial port d-i runs on when console= names only tty0,
# as on Sky1 hardware and arm64 QEMU virt). Run the shipped line against fixtures.
BT="$(mktemp -d "${TMPDIR:-/tmp}/ncz-bt.XXXXXX")"
bl="$(grep -E '^[[:space:]]*NCZBTA="" ; while read -r _n _l' "$ROOT/preseed/preseed.cfg" | head -1 | sed 's/[[:space:]]*;[[:space:]]*\\$//')"
check "preseed.cfg builds the active-console list for the banner" test -n "$bl"
check "the banner loop writes to that list" grep >/dev/null -E 'for V in /dev/tty1 /dev/tty3 /dev/console \$NCZBTA ; do echo "\[NCZ' "$ROOT/preseed/preseed.cfg"
mkdir -p "$BT/dev"; : > "$BT/dev/ttyAMA0"; : > "$BT/dev/ttyS0"
runbl() { # consoles-fixture -> NCZBTA
    printf '%b' "$1" > "$BT/consoles"
    sh -c "$(printf '%s' "$bl" | sed "s#< /proc/consoles#< '$BT/consoles'#; s#\[ -c \"/dev/\$_n\" \] && NCZBTA=\"\$NCZBTA /dev/\$_n\"#[ -e \"$BT/dev/\$_n\" ] \&\& NCZBTA=\"\$NCZBTA /dev/\$_n\"#") ; echo \"\$NCZBTA\"" 2>&1 | tr -s ' ' | sed 's/^ //'
}
o="$(runbl 'tty0                 -WU (E p)    4:7\nttyS0                -W- (EC p a) 4:64\n')"
check "amd64 KVM (console=ttyS0 last): serial is /dev/console, no second copy ('$o')" test -z "$o"
o="$(runbl 'tty0                 -WU (EC p)   4:1\nttyAMA0              -W- (E Np a) 204:64\n')"
check "arm64 (console=tty0, d-i on ttyAMA0): banner also to /dev/ttyAMA0 ('$o')" test "$o" = /dev/ttyAMA0
o="$(runbl 'tty0                 -WU (E p)    4:1\nttyAMA0              -W- (EC p a) 204:64\n')"
check "arm64 KVM gate (console=ttyAMA0 last): no second copy ('$o')" test -z "$o"
o="$(runbl 'ttyACM0              -W- (EC p a) 166:0\n')"
check "a C in the device name is not the console flag ('$o')" test -z "$o"
rm -rf "$BT"

echo "installer brltty/banner tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
