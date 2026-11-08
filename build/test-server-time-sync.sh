#!/bin/bash
# test-server-time-sync.sh -- the server image must ship an enabled time source.
#
# MEDUSA booted the 2026-11-08 server image with "System clock synchronized: no"
# and no NTP client: Debian forky splits systemd-timesyncd out of systemd, a
# medium-mode server carries no offline apt pool for 37-ntp-hostname.sh's
# fallback, and the base layer did not seed the package.
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
FAIL=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; FAIL=1; }

for f in manifests/installer-base.pkgs manifests/installer-base-amd64.pkgs; do
    if grep -qE '^(systemd-timesyncd|chrony|ntpsec)\b' "$ROOT/$f"; then
        ok "$f seeds a time daemon"
    else
        bad "$f does not seed a time daemon (a medium-mode server has no pool to apt-install one)"
    fi
done
grep -q 'systemctl enable .*NCZ_TIME_UNIT' "$ROOT/post-install/37-ntp-hostname.sh" \
    && ok "37-ntp-hostname enables the daemon it finds" \
    || bad "37-ntp-hostname no longer enables a time daemon"
grep -q 'no time-sync unit is enabled in the installed root' "$ROOT/build/kvm-install-gate-gpt.sh" \
    && ok "server gate asserts an enabled time-sync unit" \
    || bad "server gate does not assert an enabled time-sync unit"
grep -q 'MEDUSA' "$ROOT/build/kvm-install-gate-gpt.sh" \
    && ok "the assertion records the defect it prevents" \
    || bad "the assertion does not explain itself"

if [ "$FAIL" = 0 ]; then echo "test-server-time-sync: PASS"; else echo "test-server-time-sync: FAIL" >&2; exit 1; fi
