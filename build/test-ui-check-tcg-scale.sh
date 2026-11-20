#!/bin/bash
# test-ui-check-tcg-scale.sh: the UI check capture budget scales exactly when the harness runs tcg: kvm only for a
# NATIVE guest on x86_64 or on an aarch64 host with 4 KiB pages (O6N/cixmini); a build host (16 KiB) and cross-arch are tcg.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
eval "$(sed -n '/^ncz_ui_check_runs_tcg() {/,/^}/p' "$HERE/kvm-installer-ui-check.sh")"
fail=0
chk() { NCZ_PAGESIZE="$3" ncz_ui_check_runs_tcg "$1" "$2" && got=tcg || got=kvm
        [ "$got" = "$4" ] || { echo "FAIL host=$1 guest=$2 page=$3 expected $4 got $got"; fail=1; }; }
chk x86_64  x86_64  4096  kvm
chk x86_64  aarch64 4096  tcg
chk aarch64 x86_64  4096  tcg
chk aarch64 aarch64 4096  kvm
chk aarch64 aarch64 16384 tcg
[ "$fail" = 0 ] && echo "test-ui-check-tcg-scale: PASS (5 cases)"
# static guards (zoder 218 review): boot-timeline must pass the guest arch and
# both harnesses must close the probe fd on every path.
grep -q '_accel_cpu("aarch64" if a.arch == "arm64" else "x86_64")' "$HERE/boot-timeline.py" \
  || { echo "FAIL boot-timeline.py: bare _accel_cpu() call (guest arch not passed)"; fail=1; }
for f in boot-screens.py boot-timeline.py; do
  grep -q "finally:" "$HERE/$f" || { echo "FAIL $f: probe fd not closed on all paths (no finally)"; fail=1; }
done
[ "$fail" = 0 ] && echo "static guards: PASS"; exit $fail
