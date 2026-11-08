#!/bin/bash
# test-console-blank.sh -- server console burn-in protection (operator 2026-11-08).
# A server left on a console burns the panel in: the variant must blank after
# 5 minutes, power the panel down after one more, and re-apply on every VT.
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
FAIL=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; FAIL=1; }

H="$ROOT/post-install/48-server-variant.sh"
grep -q 'NCZ_CONSOLE_IDLE_MIN=5' "$H" && ok "config default idle 5 min" || bad "config idle default missing"
grep -q 'NCZ_CONSOLE_POWERDOWN_MIN=1' "$H" && ok "config default powerdown 1 min" || bad "config powerdown default missing"
grep -q 'NCZ_CONSOLE_SAVER=none' "$H" && ok "config saver default none" || bad "config saver default missing"
grep -q 'ncz-console-blank.service' "$H" && ok "unit installed + enabled" || bad "unit not installed"
grep -q 'setterm --blank' "$H" && ok "unit applies setterm blanking" || bad "setterm blanking missing"
grep -q 'vtconsole' "$H" && ok "udev re-applies on a new VT" || bad "no udev re-apply"
grep -q 'ncz-console-saver' "$H" && ok "optional wordmark saver installed" || bad "saver missing"
grep -q 'ncz-console-idle.timer' "$H" && ok "idle watcher timer installed" || bad "idle watcher missing"
grep -q 'select.select' "$H" && ok "saver exits on any key (select on console)" || bad "saver does not watch for a key"
grep -qE 'apt-get[^#]*(cmatrix|pipes)' "$H" && bad "third-party saver installed" || ok "no third-party saver packages"
for f in assets/refind/ncz-refind-refresh-amd64.sh assets/refind/ncz-refind-refresh.sh; do
    grep -q 'consoleblank=300' "$ROOT/$f" && ok "$f server cmdline" || bad "$f missing consoleblank=300"
done
grep -q 'consoleblank=300' "$ROOT/build/kvm-install-gate-gpt.sh" && ok "gate asserts the cmdline" || bad "gate does not assert the cmdline"
grep -q 'ncz-console-blank.service' "$ROOT/build/kvm-install-gate-gpt.sh" && ok "gate asserts the enabled unit" || bad "gate does not assert the unit"

if [ "$FAIL" = 0 ]; then echo "test-console-blank: PASS"; else echo "test-console-blank: FAIL" >&2; exit 1; fi
