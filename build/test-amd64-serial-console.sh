#!/bin/bash
# test-amd64-serial-console.sh -- installed amd64 boot entries carry
# console=ttyS0 only when ttyS0 is a real UART (r201).
#
# Every installed amd64 entry used to carry console=ttyS0,115200. On machines
# without a UART (the GU502LV laptop, T2 Macs) the 8250 placeholder ttyS0 still exists,
# systemd starts serial-getty@ttyS0 for the console= argument and agetty fails
# "failed to get terminal attributes: Input/output error" in a loop (28 per
# boot on GU502LV). This test runs the real NCZ-SERIAL-CONSOLE block from
# assets/refind/ncz-refind-refresh-amd64.sh against fixture sysfs/proc trees and
# checks that the installer media and arm64 keep their serial consoles.
#
# Run: bash build/test-amd64-serial-console.sh     Exit 0 = pass, 1 = fail.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${NCZ_TEST_ROOT:-$(cd "$HERE/.." && pwd)}"
SRC="$ROOT/assets/refind/ncz-refind-refresh-amd64.sh"
W="$(mktemp -d -t amd64-serial.XXXXXX)"; trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }

awk 'index($0, "NCZ-SERIAL-CONSOLE-BEGIN") {f=1; next} index($0, "NCZ-SERIAL-CONSOLE-END") {f=0} f' "$SRC" > "$W/block.sh"
[ -s "$W/block.sh" ] || { echo "FATAL: NCZ-SERIAL-CONSOLE block missing from $SRC" >&2; exit 2; }

# arg SYSTYPE PROCLINE [ENV...] -> prints NCZ_SERIAL_CONSOLE_ARG
arg() {
    local t="$1" p="$2"; shift 2
    rm -rf "$W/sys" "$W/proc"; mkdir -p "$W/sys/class/tty/ttyS0" "$W/proc/tty/driver"
    [ "$t" = "-" ] || printf '%s\n' "$t" > "$W/sys/class/tty/ttyS0/type"
    [ "$p" = "-" ] || printf '%s\n' "$p" > "$W/proc/tty/driver/serial"
    ( set -euo pipefail; export NCZ_SYSFS_ROOT="$W/sys" NCZ_PROC_ROOT="$W/proc"; for kv in "$@"; do export "${kv?}"; done
      . "$W/block.sh" >/dev/null; printf '%s' "$NCZ_SERIAL_CONSOLE_ARG" )
}

echo "=== detection ==="
[ -z "$(arg 0 -)" ] && ok "ttyS0 type 0 (8250 placeholder, no UART): no console=ttyS0" || bad "placeholder port still gets console=ttyS0"
[ "$(arg 4 -)" = "console=ttyS0,115200 " ] && ok "ttyS0 type 4 (16550A, QEMU/KVM gate): console=ttyS0,115200" || bad "real 16550A lost its console: '$(arg 4 -)'"
[ -z "$(arg - -)" ] && ok "no ttyS0 at all: no console=ttyS0" || bad "absent port gets console=ttyS0"
[ -n "$(arg - '0: uart:16550A port:000003F8 irq:4 tx:0 rx:0')" ] && ok "/proc fallback: uart:16550A -> serial kept" || bad "/proc fallback missed a real UART"
[ -z "$(arg - '0: uart:unknown port:000003F8 irq:4')" ] && ok "/proc fallback: uart:unknown -> no serial" || bad "/proc fallback took a placeholder"
[ -n "$(arg 0 - NCZ_SERIAL_CONSOLE=on)" ] && ok "NCZ_SERIAL_CONSOLE=on forces it" || bad "override on ignored"
[ -z "$(arg 4 - NCZ_SERIAL_CONSOLE=off)" ] && ok "NCZ_SERIAL_CONSOLE=off drops it" || bad "override off ignored"

echo "=== every installed entry uses the detected value ==="
lits=$(grep -nE '^[^#]*console=ttyS0' "$SRC" | grep -v 'NCZ_SERIAL_CONSOLE_ARG="console=ttyS0,115200 "' | grep -v 'echo ' || true)
[ -z "$lits" ] && ok "no hardcoded console=ttyS0 outside the detection block" || bad "hardcoded console=ttyS0 remains" "$lits"
for v in STABLE_CMDLINE_BASE RESCUE_CMDLINE_BASE RESCUEPART_OPTIONS; do
    grep -qF '${NCZ_SERIAL_CONSOLE_ARG:-}console=tty0' <(grep "^$v=" "$SRC") && ok "$v = \${NCZ_SERIAL_CONSOLE_ARG:-}console=tty0 ..." || bad "$v does not use the detected serial console"
done
bl=$(grep -n 'NCZ-SERIAL-CONSOLE-END' "$SRC" | head -1 | cut -d: -f1)
ul=$(grep -n '^STABLE_CMDLINE_BASE=' "$SRC" | head -1 | cut -d: -f1)
[ -n "$bl" ] && [ -n "$ul" ] && [ "$bl" -lt "$ul" ] && ok "detection runs before the first cmdline is assembled" || bad "detection block after STABLE_CMDLINE_BASE"

echo "=== unchanged elsewhere ==="
grep -q 'console=ttyS0,115200n8 console=tty0' "$ROOT/build/iso/build-refind-esp.py" && ok "installer media rescue entry keeps console=ttyS0 (KVM gate / installer behaviour)" || bad "installer media serial console changed"
grep -q "serial = \['console=ttyS0,115200'\]" "$ROOT/build/kvm-install-gate-gpt.sh" && ok "KVM gate still adds its own serial console" || bad "KVM gate serial patch missing"
grep -q '^NEXT_CMDLINE_BASE="console=ttyAMA0,115200 console=tty0' "$ROOT/assets/refind/ncz-refind-refresh.sh" && ok "arm64 keeps console=ttyAMA0" || bad "arm64 ttyAMA0 console changed"

echo "amd64 serial console tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
