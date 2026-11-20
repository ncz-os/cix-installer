#!/bin/bash
# test-console-blank.sh -- server console burn-in protection (operator 2026-11-08).
# A server left on a console burns the panel in: the variant must blank after
# 30 minutes (backstop behind the console saver, which runs from 3 min), power
# the panel down after one more, and re-apply on every VT.
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
FAIL=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; FAIL=1; }

H="$ROOT/post-install/48-server-variant.sh"
grep -q 'NCZ_CONSOLE_IDLE_MIN=30' "$H" && ok "config default idle 30 min (backstop behind the saver)" || bad "config idle default missing"
grep -q 'NCZ_CONSOLE_POWERDOWN_MIN=1' "$H" && ok "config default powerdown 1 min" || bad "config powerdown default missing"
grep -q 'NCZ_CONSOLE_SAVER=none' "$H" && ok "config saver default none" || bad "config saver default missing"
grep -q 'ncz-console-blank.service' "$H" && ok "unit installed + enabled" || bad "unit not installed"
grep -q 'setterm --term linux --blank' "$H" && ok "unit applies setterm blanking with an explicit TERM (systemd has none)" || bad "setterm blanking missing --term linux"
grep -q 'vtconsole' "$H" && ok "udev re-applies on a new VT" || bad "no udev re-apply"
! grep -q 'OnUnitActiveSec' "$H" && ok "no periodic timer (true idle tracking)" || bad "periodic timer still used"
# The saver tier moved out of this hook (2026-11-14, B3 decision + single-owner):
# the Python wordmark saver whose source these greps pinned was deleted with
# hook 48's rewrite.  post-install/61-ncz-console-saver.sh is the single owner
# of ncz-console-saver / ncz-bh-console (the Rust black-hole saver shipped in
# assets/console-saver/; build/test-console-saver-wiring.sh and
# build/test-console-saver-single-owner.sh pin the install contract).  Banner
# pacing ("once a minute ... moving a few cells", docs/SERVER-CONSOLE-BLANK.md)
# and the stop-before-blank idle judgement now live inside that binary, so the
# old literal pins are retired -- the on-image acceptance and the doc's manual
# check pin the behaviour.  What stays statically pinnable for the blank
# contract is the shipped conf and the owner hook.
H61="$ROOT/post-install/61-ncz-console-saver.sh"
C="$ROOT/assets/console-saver/console-saver.conf"
grep -q 'ncz-console-saver.service' "$H61" && ok "saver daemon service installed by its single owner (hook 61)" || bad "hook 61 missing the saver unit"
grep -q 'NCZ_CONSOLE_BANNER=yes' "$H" && ok "banner tier enabled by default" || bad "banner config missing"
grep -qE '^enabled = 1$' "$C" && ok "saver enabled by default" || bad "conf enabled != 1"
grep -qE '^idle_seconds = 180$' "$C" && ok "saver arms at 3 min idle (30 min blank backstop stays behind it)" || bad "conf idle_seconds != 180"
grep -qE '^scene = blackhole$' "$C" && ok "saver scene is the black hole" || bad "conf scene != blackhole"
# The saver's text output does not poke the kernel blank timer: the vendored
# daemon must hold the blank interval off (ESC[9;0]) while the saver runs, or
# the backstop blanks the screen mid-animation (two test machines 2026-11-14). The
# escape lives in the binary; the pre-fix binaries do not contain it.
for _a in amd64 arm64; do
    grep -q -a -F "$(printf '\033[9;')" "$ROOT/assets/console-saver/$_a/ncz-console-saver" \
        && ok "$_a console saver holds the kernel blank off while it runs" \
        || bad "$_a console saver binary lacks the blank hold (ESC[9;)"
done
grep -qE 'apt-get install[^#]*(cmatrix|pipes)' "$H" && bad "third-party saver installed" || ok "no third-party saver packages"
for f in assets/refind/ncz-refind-refresh-amd64.sh assets/refind/ncz-refind-refresh.sh; do
    grep -q 'consoleblank=300' "$ROOT/$f" && ok "$f server cmdline" || bad "$f missing consoleblank=300"
done
# The string alone is not enough: the append must land in the option strings
# each generator actually EMITS. On arm64 the amd64 STABLE_* names do not
# exist, so an append to them was a silent no-op and the installed server menu
# carried no consoleblank=300 (kvm-gate caught it 2026-11-09).
grep -q 'STABLE_OPTIONS="$STABLE_OPTIONS consoleblank=300"' "$ROOT/assets/refind/ncz-refind-refresh-amd64.sh" \
    && ok "amd64 DEFAULT entry append targets STABLE_OPTIONS" || bad "amd64 STABLE_OPTIONS append missing"
grep -q 'STABLE_CONSOLE_OPTIONS="$STABLE_CONSOLE_OPTIONS consoleblank=300"' "$ROOT/assets/refind/ncz-refind-refresh-amd64.sh" \
    && ok "amd64 Console entry append targets STABLE_CONSOLE_OPTIONS" || bad "amd64 STABLE_CONSOLE_OPTIONS append missing"
grep -q 'NEXT_CONSOLE_OPTIONS="$NEXT_CONSOLE_OPTIONS consoleblank=300"' "$ROOT/assets/refind/ncz-refind-refresh.sh" \
    && ok "arm64 Console entry append targets NEXT_CONSOLE_OPTIONS" || bad "arm64 NEXT_CONSOLE_OPTIONS append missing"
grep -q 'RESCUEPART_OPTIONS="$RESCUEPART_OPTIONS consoleblank=300"' "$ROOT/assets/refind/ncz-refind-refresh.sh" \
    && ok "arm64 Rescue Partition entry append targets RESCUEPART_OPTIONS" || bad "arm64 RESCUEPART_OPTIONS append missing"
grep -q 'consoleblank=300' "$ROOT/build/kvm-install-gate-gpt.sh" && ok "gate asserts the cmdline" || bad "gate does not assert the cmdline"
grep -q 'ncz-console-blank.service' "$ROOT/build/kvm-install-gate-gpt.sh" && ok "gate asserts the enabled unit" || bad "gate does not assert the unit"

if [ "$FAIL" = 0 ]; then echo "test-console-blank: PASS"; else echo "test-console-blank: FAIL" >&2; exit 1; fi
