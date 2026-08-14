#!/bin/bash
# kvm-kernel-gate.sh — MANDATORY boot gate for every kernel before it is
# packaged into a deb or an ISO.
#
# Why this exists (operator directive, 2026-08-14): r236 shipped a kernel that
# panicked at 1.2s into every boot of the INSTALLED system —
# cdns3_pci_probe+0x12c/0x360, NULL deref, PID 1, six reboot loops. The
# installer itself booted fine, so nothing in the ISO-level tests caught it.
# No kernel goes into a deb or an ISO again without being booted first.
#
# TWO gates run here, because neither alone is sufficient:
#
#   1. BOOT — actually boot the Image under qemu/KVM and fail on any oops,
#      Internal error, or unexpected panic. Catches the broad class of
#      init-path regressions: broken initcalls, missing DEVTMPFS, a driver
#      that dies on probe against a device qemu DOES model, unbootable
#      images, and anything that hangs before late boot.
#
#   2. PCI ID COLLISION LINT — a static check on the .config. The boot gate
#      CANNOT catch the r236 bug: qemu -M virt has no Cadence 17cd:0100
#      device, so cdns3-pci-wrap never binds there and the kernel boots
#      clean. What made r236 fatal is that Sky1's own PCIe root ports
#      enumerate as 17cd:0100 — the exact ID the Cadence USB3 PCI wrapper
#      claims. Any builtin driver matching a Sky1-present PCI ID is a
#      landmine that only fires on real hardware, so it is denied here by
#      symbol instead.
#
# Usage:
#   build/kvm-kernel-gate.sh [IMAGE] [CONFIG]
# Defaults to the staged edge kernel:
#   assets/kernel/edge/Image-cixmini.bin + assets/kernel/edge/config-<KVER>
#
# Exit 0 = PASS. Any nonzero = do NOT ship this kernel.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${1:-$REPO/assets/kernel/edge/Image-cixmini.bin}"
CONFIG="${2:-}"
TIMEOUT="${GATE_TIMEOUT:-120}"
LOG="$(mktemp /tmp/kvm-kernel-gate.XXXXXX.log)"

if [ -z "$CONFIG" ]; then
  CONFIG="$(ls "$(dirname "$IMAGE")"/config-* 2>/dev/null | head -1)"
fi

fail() { echo "GATE: FAIL — $*" >&2; echo "  boot log: $LOG" >&2; exit 1; }

[ -f "$IMAGE" ]  || fail "no kernel Image at $IMAGE"
[ -f "$CONFIG" ] || fail "no kernel .config found next to $IMAGE (pass one explicitly)"

echo "=== kvm-kernel-gate ==="
echo "  Image : $IMAGE ($(stat -c%s "$IMAGE") bytes)"
echo "  Config: $CONFIG"

# ---------------------------------------------------------------------------
# Gate 2 first (it is instant, and a hit here means the boot gate cannot help).
#
# Sky1 PCI IDs that real drivers also claim. Vendor 0x17cd is Cadence, whose IP
# is used BOTH for the SoC's PCIe root complex and for its USB controllers, so
# the collision is structural, not a one-off:
#
#   17cd:0100  PCI_DEVICE_ID_CDNS_USBSS   <- Sky1 PCIe Root Port (x4, lspci -nn)
#   17cd:0120  PCI_DEVICE_ID_CDNS_USB
#   17cd:0200  PCI_DEVICE_ID_CDNS_USBSSP
#
# Drivers matching those IDs must not be builtin. Module is also refused: a
# module autoloads off the PCI modalias and panics just as hard, only later.
# ---------------------------------------------------------------------------
echo "--- PCI ID collision lint ---"
COLLIDERS=(
  USB_CDNS3_PCI_WRAP   # 17cd:0100 — bound Sky1's root ports, panicked r236
  USB_CDNSP_PCI        # 17cd:0100 and 17cd:0200
  USB_CDNS2_UDC        # 17cd:0120
)
lint_rc=0
for sym in "${COLLIDERS[@]}"; do
  val="$(grep -E "^CONFIG_${sym}=" "$CONFIG" || true)"
  if [ -n "$val" ]; then
    echo "  DENIED: $val"
    echo "          matches a PCI ID present on Sky1; must be 'is not set'"
    lint_rc=1
  else
    echo "  ok: CONFIG_$sym not set"
  fi
done

# Positive assertions: things whose absence has already cost a release.
echo "--- required symbols ---"
for req in DEVTMPFS DEVTMPFS_MOUNT BLK_DEV_LOOP ISO9660_FS; do
  if grep -qE "^CONFIG_${req}=y" "$CONFIG"; then
    echo "  ok: CONFIG_$req=y"
  else
    echo "  MISSING: CONFIG_$req=y"
    lint_rc=1
  fi
done
[ "$lint_rc" -eq 0 ] || fail "config lint rejected this kernel"

# ---------------------------------------------------------------------------
# Gate 1: boot it.
#
# No initrd and no root device on purpose. The kernel is EXPECTED to end at
# "Kernel panic - not syncing: VFS: Unable to mount root fs" — reaching that
# line means every initcall ran and the kernel got all the way to mounting
# root, which is exactly the window r236 died in. That specific panic is the
# PASS marker; any other panic, oops, or internal error is a failure.
# ---------------------------------------------------------------------------
echo "--- boot under qemu ---"
ACCEL="tcg"; CPU="cortex-a72"
if [ -r /dev/kvm ] && [ "$(uname -m)" = "aarch64" ]; then
  ACCEL="kvm"; CPU="host"
fi
echo "  accel=$ACCEL cpu=$CPU timeout=${TIMEOUT}s"

# -nic none: the default virt NIC wants an efi-virtio.rom this host does not
# ship, and qemu exits rc=1 before the kernel ever runs. Without it the gate
# fails on a qemu packaging detail and reads as a kernel fault.
timeout "$TIMEOUT" qemu-system-aarch64 \
  -M virt -accel "$ACCEL" -cpu "$CPU" -smp 4 -m 2048 -nic none \
  -kernel "$IMAGE" \
  -append "console=ttyAMA0 earlycon panic=-1 loglevel=7" \
  -nographic -no-reboot \
  > "$LOG" 2>&1
qrc=$?

grep -qE "Booting Linux on physical CPU|Linux version" "$LOG" \
  || fail "kernel never produced a boot banner (qemu rc=$qrc) — image may not be bootable"

# Ordered so a real oops is reported even when the VFS panic also appears.
if grep -qE "Unable to handle kernel|Internal error: Oops|BUG: kernel NULL|Synchronous Exception" "$LOG"; then
  echo "--- offending output ---" >&2
  grep -nE -A12 "Unable to handle kernel|Internal error: Oops|BUG: kernel NULL" "$LOG" | head -40 >&2
  fail "kernel oopsed during boot"
fi

if grep -qE "Kernel panic - not syncing: (VFS: Unable to mount root|No working init)" "$LOG"; then
  echo "  reached root-mount (expected panic, no rootfs supplied)"
elif grep -qE "Freeing unused kernel memory|Run /init as init" "$LOG"; then
  echo "  reached late boot"
elif grep -q "Kernel panic - not syncing" "$LOG"; then
  echo "--- panic ---" >&2
  grep -n -B4 -A12 "Kernel panic - not syncing" "$LOG" | head -40 >&2
  fail "kernel panicked for a reason other than the missing rootfs"
else
  echo "--- tail ---" >&2
  tail -25 "$LOG" >&2
  fail "kernel never reached root mount within ${TIMEOUT}s (hang or silent stall)"
fi

echo "GATE: PASS ✅  $(basename "$IMAGE")"
echo "  boot log: $LOG"
exit 0
