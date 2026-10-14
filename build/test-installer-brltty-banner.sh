#!/bin/bash
# test-installer-brltty-banner.sh -- installer source-level regressions:
#
#   1. no braille stack anywhere (docs/ACCESSIBILITY.md): brltty is not in the
#      installer or the image; users add it with `apt install brltty`.
#      - no boot entry carries a token containing "brltty" (brltty-udeb's
#        S37brltty starts brltty when it sees one: the ncz_no_brltty=1
#        regression of 2026-10-14, exercised by
#        build/iso/tests/test_refind_installer_cmdline.py);
#      - no preseed answer, package list or anna module list names brltty;
#      - the build removes brltty-udeb from the initrd and fails if it
#        survives, keeps braille packages out of the medium pool, and the
#        layer, KVM-probe gates exist (behaviour in build/iso/tests and
#        build/test-layers-hardening.sh; probe judge exercised below).
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

# ------------------------------------------------------------------ no braille stack
check "no preseed setting names brltty/braille (comments aside)" \
    sh -c '! { for f in "$1"/preseed/*.cfg; do sed -e "s/#.*//" "$f"; done; } | grep >/dev/null -iE "brltty|brlapi|braille"' _ "$ROOT"
check "brltty-udeb/generic is not in the preseed known-keys list" \
    sh -c '! grep -qE "^[[:space:]]*brltty" "$1"' _ "$KNOWN"
check "no package manifest lists a brltty/brlapi package" \
    sh -c '! { for f in "$1"/manifests/*.pkgs "$1"/sbom/*.txt; do sed -e "s/#.*//" "$f"; done; } | grep >/dev/null -iE "brltty|brlapi"' _ "$ROOT"
check "no post-install hook installs brltty" \
    sh -c '! grep -rqiE "(apt-get|apt|install)[^#]*(brltty|brlapi)" "$1/post-install"' _ "$ROOT"
check "build-refind-esp.py no longer defines the ncz_no_brltty token" \
    sh -c '! grep -qE "NCZ_NO_BRLTTY|\"ncz_no_brltty" "$1"' _ "$ESP"
check "build-refind-esp.py refuses boot options naming brltty" \
    grep -q 'assert_no_brltty_options(conf_text)' "$ESP"
check "the initrd patcher verifies the final initrd carries no braille member" \
    grep -q 'verify_no_braille_initrd(out_initrd)' "$ROOT/build/iso/patch-initrd-t2-kernel.py"
check "the image writer refuses braille packages in the medium pool" \
    grep -q 'find_braille_package_files(stage_dir / "pool")' "$ROOT/build/iso/write-usb-image.py"
check "check-layers.sh runs the no-braille layer check" \
    grep -qE '^[[:space:]]*chk_no_braille "\$l" "\$lbl"' "$ROOT/build/check-layers.sh"
check "the KVM gate attaches usb-braille, usb-serial, usb-kbd and usb-mouse" \
    sh -c 'grep -q -- "-device usb-braille" "$1" && grep -q -- "-device usb-serial" "$1" && grep -q -- "-device usb-kbd" "$1" && grep -q -- "-device usb-mouse" "$1"' _ "$ROOT/build/kvm-install-gate-gpt.sh"
check "the KVM gate judges the installer probe" \
    grep -q 'kvm-installer-probe.sh" judge' "$ROOT/build/kvm-install-gate-gpt.sh"

# probe judge: fixtures in both directions
PJ="$ROOT/build/kvm-installer-probe.sh"
PT="$(mktemp -d "${TMPDIR:-/tmp}/ncz-probe.XXXXXX")"
sample() { # name main_menu brltty_pid tty1cols tty2cols [file]
    { echo "=== sample 1 00:00:00Z"; echo "uptime 30"; echo "main_menu $2"; echo "brltty_pid $3"
      [ -n "${6:-}" ] && echo "brltty_file $6"
      echo "tty1 50 $4"; echo "tty2 50 $5"; echo "usb 1-1 0403:fe72 braille"; } > "$PT/$1"
}
sample good yes none 128 128
check "probe judge: clean installer passes" bash "$PJ" judge "$PT/good"
sample running yes 9509 128 128
check "probe judge: a running brltty fails" sh -c '! bash "$1" judge "$2" >/dev/null' _ "$PJ" "$PT/running"
sample clamped yes none 80 128
check "probe judge: tty1 clamped to 80 columns fails" sh -c '! bash "$1" judge "$2" >/dev/null' _ "$PJ" "$PT/clamped"
sample files yes none 128 128 /usr/lib/udev/rules.d/brltty.rules
check "probe judge: brltty files in the installer fail" sh -c '! bash "$1" judge "$2" >/dev/null' _ "$PJ" "$PT/files"
sample ran yes none 128 128
echo "syslog Jan  1 00:00:02 brltty[690]: BRLTTY 6.9.1" >> "$PT/ran"
check "probe judge: brltty in the installer syslog fails (even after it exited)" sh -c '! bash "$1" judge "$2" >/dev/null' _ "$PJ" "$PT/ran"
sample early no none 128 128
check "probe judge: no sample while main-menu ran fails" sh -c '! bash "$1" judge "$2" >/dev/null' _ "$PJ" "$PT/early"
: > "$PT/empty"
check "probe judge: no sample at all fails" sh -c '! bash "$1" judge "$2" >/dev/null' _ "$PJ" "$PT/empty"
rm -rf "$PT"

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
