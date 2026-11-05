#!/bin/bash
# kvm-kernel-gate.sh — MANDATORY boot gate for every kernel before it is
# packaged into a deb or an image.
#
# Why this exists (design rule, 2026-08-14): r236 shipped a kernel that
# panicked at 1.2s into every boot of the INSTALLED system —
# cdns3_pci_probe+0x12c/0x360, NULL deref, PID 1, six reboot loops. The
# installer itself booted fine, so nothing in the ISO-level tests caught it.
# No kernel goes into a deb or an image again without being booted first.
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
# Defaults to the staged mainline (shipping) kernel:
#   assets/kernel/mainline/Image-cixmini.bin + assets/kernel/mainline/config-<KVER>
#
# Exit 0 = PASS. Any nonzero = do NOT ship this kernel.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${1:-$REPO/assets/kernel/mainline/Image-cixmini.bin}"
CONFIG="${2:-}"
TIMEOUT="${GATE_TIMEOUT:-120}"
LOG="$(mktemp "${TMPDIR:-/tmp}/kvm-kernel-gate.XXXXXX.log")"

if [ -z "$CONFIG" ]; then
  CONFIG="$(ls "$(dirname "$IMAGE")"/config-* 2>/dev/null | head -1)"
fi

fail() { echo "GATE: FAIL — $*" >&2; echo "  boot log: $LOG" >&2; exit 1; }

[ -f "$IMAGE" ]  || fail "no kernel Image at $IMAGE"
[ -f "$CONFIG" ] || fail "no kernel .config found next to $IMAGE (pass one explicitly)"

echo "=== kvm-kernel-gate ==="
echo "  Image : $IMAGE ($(stat -c%s "$IMAGE") bytes)"
echo "  Config: $CONFIG"
KARCH="${GATE_ARCH:-}"
if [ -z "$KARCH" ]; then
  case "$(file -b "$IMAGE" 2>/dev/null)" in
    *ARM64*) KARCH=arm64 ;;
    *x86*bzImage*|*x86*boot*) KARCH=amd64 ;;
    *) if [ "$(uname -m)" = "aarch64" ]; then KARCH=arm64; else KARCH=amd64; fi ;;
  esac
fi
echo "  Arch  : $KARCH ($(file -b "$IMAGE" 2>/dev/null | cut -c1-46))"

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
lint_rc=0
if [ "$KARCH" = arm64 ]; then
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

fi  # Sky1 PCI lint applies to arm64 only

# Positive assertions: things whose absence has already cost a release.
echo "--- required symbols ---"
# Per-arch minimum. ISO9660 must be builtin on arm64 (the Sky1 installer mounts the
# ISO before modules load); on x86 an installed T2 system legitimately carries it as a
# module, so =y or =m both satisfy the requirement there.
REQ="DEVTMPFS DEVTMPFS_MOUNT BLK_DEV_LOOP"
[ "$KARCH" = arm64 ] && REQ="$REQ ISO9660_FS"
for req in $REQ; do
  if grep -qE "^CONFIG_${req}=y" "$CONFIG"; then
    echo "  ok: CONFIG_$req=y"
  else
    echo "  MISSING: CONFIG_$req=y"
    lint_rc=1
  fi
done
if [ "$KARCH" = amd64 ]; then
  if grep -qE "^CONFIG_ISO9660_FS=(y|m)" "$CONFIG"; then
    echo "  ok: CONFIG_ISO9660_FS=$(grep -oE '^CONFIG_ISO9660_FS=(y|m)' "$CONFIG" | cut -d= -f2) (x86: module acceptable)"
  else
    echo "  MISSING: CONFIG_ISO9660_FS=y or =m"
    lint_rc=1
  fi
fi
[ "$lint_rc" -eq 0 ] || fail "config lint rejected this kernel"

# KVM only when the guest architecture matches this host: cross-arch boot must use TCG,
# otherwise an arm64 image on an x86 host fails on the accelerator and looks like a bad kernel.
HOST_ARCH="$(uname -m)"
ACCEL="tcg"
if [ -r /dev/kvm ]; then
  case "$KARCH:$HOST_ARCH" in
    arm64:aarch64|amd64:x86_64) ACCEL="kvm" ;;
  esac
fi
if [ "$KARCH" = arm64 ]; then
  QEMU=qemu-system-aarch64; MACH="-M virt"; CONSOLE="console=ttyAMA0"
  CPU="cortex-a72"; [ "$ACCEL" = kvm ] && CPU="host"
else
  QEMU=qemu-system-x86_64; MACH=""; CONSOLE="console=ttyS0"
  CPU="max"; [ "$ACCEL" = kvm ] && CPU="host"
fi
echo "  accel=$ACCEL cpu=$CPU qemu=$QEMU timeout=${TIMEOUT}s"

# Test hook: GATE_SKIP_BOOT=1 stops here so the lint can be proven on its own.
if [ "${GATE_SKIP_BOOT:-0}" = "1" ]; then
  echo "lint: PASS (boot skipped by GATE_SKIP_BOOT=1)"
  exit 0
fi

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

# -nic none: the default virt NIC wants an efi-virtio.rom this host does not
# ship, and qemu exits rc=1 before the kernel ever runs. Without it the gate
# fails on a qemu packaging detail and reads as a kernel fault.
# shellcheck disable=SC2086  # $MACH is intentionally word-split (empty for x86)
timeout "$TIMEOUT" $QEMU $MACH \
  -accel "$ACCEL" -cpu "$CPU" -smp 4 -m 2048 -nic none \
  -kernel "$IMAGE" \
  -append "$CONSOLE earlycon panic=-1 loglevel=7" \
  -nographic -no-reboot \
  > "$LOG" 2>&1
qrc=$?

if [ "$KARCH" = arm64 ]; then
  grep -qE "Booting Linux on physical CPU|Linux version" "$LOG" \
    || fail "kernel never produced a boot banner (qemu rc=$qrc) — image may not be bootable"
else
  # x86 may reach the console only after early boot; require kernel-side output.
  grep -qE "Linux version|Kernel command line|VFS: Cannot open root|Kernel panic" "$LOG" \
    || fail "kernel never produced kernel-side output (qemu rc=$qrc) — image may not be bootable"
fi

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
