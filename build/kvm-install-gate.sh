#!/bin/bash
# kvm-install-gate.sh — install the ISO in KVM and boot what it installed.
#
# WHY THIS EXISTS: build/kvm-kernel-gate.sh proves a KERNEL boots. It does not
# prove the INSTALLER works. v11 shipped an ISO whose every install died at
# finish-install ("33-network.sh FAILED rc=1 — install aborts") and nothing
# caught it before it reached hardware, because no gate ever ran the installer.
#
# Two phases, both must pass:
#   1. INSTALL — boot the ISO against a blank NVMe target, unattended, and
#      require the preseed to finish without a failed hook.
#   2. BOOT    — boot the resulting disk with the ISO detached and require
#      the installed system to reach userspace.
#
# Media layout mirrors real hardware: the ISO is a USB stick (the installer
# calls it the "install media parent disk"), the target is an NVMe namespace.
set -uo pipefail

ISO="${1:?usage: kvm-install-gate.sh /path/to.iso [workdir]}"
WORK="${2:-/home/mini/cix-installer/build/kvm-install}"
DISK_GB="${DISK_GB:-40}"
INSTALL_TIMEOUT="${INSTALL_TIMEOUT:-5400}"   # 90 min
BOOT_TIMEOUT="${BOOT_TIMEOUT:-600}"          # 10 min
MEM="${MEM:-4096}"
SMP="${SMP:-4}"

[ -f "$ISO" ] || { echo "GATE FAIL: no such ISO: $ISO" >&2; exit 2; }
mkdir -p "$WORK"
DISK="$WORK/target.qcow2"
ILOG="$WORK/install.log"
BLOG="$WORK/boot.log"
VARS="$WORK/AAVMF_VARS.fd"

CODE=/usr/share/AAVMF/AAVMF_CODE.no-secboot.fd
[ -f "$CODE" ] || CODE=/usr/share/AAVMF/AAVMF_CODE.fd
SRCVARS=/usr/share/AAVMF/AAVMF_VARS.fd

ACCEL="tcg"; CPU="cortex-a72"
if [ -r /dev/kvm ] && [ "$(uname -m)" = "aarch64" ]; then ACCEL="kvm"; CPU="host"; fi

echo "=== KVM INSTALL GATE ==="
echo "  iso    : $ISO"
echo "  accel  : $ACCEL cpu=$CPU mem=${MEM}M smp=$SMP"
echo "  target : $DISK (${DISK_GB}G)"
echo "  logs   : $ILOG / $BLOG"

rm -f "$DISK" "$VARS"
qemu-img create -f qcow2 "$DISK" "${DISK_GB}G" >/dev/null || { echo "GATE FAIL: qemu-img"; exit 2; }
cp "$SRCVARS" "$VARS" || { echo "GATE FAIL: no AAVMF vars"; exit 2; }

# CAPTURE ALL THREE SERIAL PORTS.
#
# Two facts drive this, both measured on 2026-08-18:
#   * qemu -kernel does NOT boot this ISO's vmlinuz (49 MB EFI-stub image) --
#     150s produced zero output. So boot the REAL UEFI path, which is also the
#     path that actually ships.
#   * The ISO's install menuentry appends "console=tty0 console=ttyAMA2,115200".
#     ttyAMA2 is the O6/O6N port. QEMU virt gives ttyAMA0 first, so with a
#     single -serial the installer kernel talks to a port nobody is listening
#     to, d-i falls back to tty1, and the gate watches a silent file while the
#     install stalls invisibly. That is exactly how the first v12 run "hung"
#     with target.qcow2 frozen at 196K.
# Firmware and GRUB land on ttyAMA0; the installer kernel lands on ttyAMA2.
# Capture each to its own file and analyse them together.
S0="$WORK/serial0-firmware.log"
S1="$WORK/serial1.log"
S2="$WORK/serial2-kernel.log"
rm -f "$S0" "$S1" "$S2"

fail() { echo; echo "GATE FAIL: $*" >&2; exit 1; }

# --- phase 1: install -------------------------------------------------------
# -no-reboot so the VM EXITS when d-i reboots; that exit is the success signal.
echo
echo "--- phase 1: install (timeout ${INSTALL_TIMEOUT}s) ---"
date -u +"  started %H:%M:%SZ"
timeout "$INSTALL_TIMEOUT" qemu-system-aarch64 \
  -M virt -accel "$ACCEL" -cpu "$CPU" -smp "$SMP" -m "$MEM" \
  -drive if=pflash,format=raw,unit=0,file="$CODE",readonly=on \
  -drive if=pflash,format=raw,unit=1,file="$VARS" \
  -drive file="$DISK",if=none,id=hd,format=qcow2 \
  -device nvme,drive=hd,serial=ncztest01 \
  -drive file="$ISO",if=none,id=usbstick,format=raw,readonly=on \
  -device qemu-xhci,id=xhci \
  -device usb-storage,bus=xhci.0,drive=usbstick \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0,romfile= \
  -serial "file:$S0" -serial "file:$S1" -serial "file:$S2" \
  -display none -no-reboot \
  > "$ILOG" 2>&1
cat "$S0" "$S1" "$S2" >> "$ILOG" 2>/dev/null
irc=$?
date -u +"  ended   %H:%M:%SZ  (qemu rc=$irc)"

grep -qE "NCZ-OS INSTALLER|Debian installer|Starting system message bus|d-i" "$ILOG" \
  || fail "installer never started (qemu rc=$irc) — see $ILOG"

# Hard failure markers, checked before any success marker so a real abort is
# never masked by later output.
if grep -qE "Failed to run preseeded command|failed with exit code|install aborts|FAILED rc=" "$ILOG"; then
  echo "--- offending output ---" >&2
  grep -nE -B3 -A6 "Failed to run preseeded command|failed with exit code|install aborts|FAILED rc=" "$ILOG" | head -50 >&2
  fail "the preseed/late_command failed — this is the v11 defect class"
fi
if grep -qE "Kernel panic - not syncing" "$ILOG"; then
  grep -nE -A10 "Kernel panic" "$ILOG" | head -30 >&2
  fail "kernel panic during install"
fi
grep -qE "post-install hooks finished|finalizing apt sources|forcing clean reboot" "$ILOG" \
  || fail "install did not reach the finish stage (timeout at ${INSTALL_TIMEOUT}s?) — see $ILOG"

echo "  install completed without a failed hook"
grep -cE "^\s+v [0-9]+-" "$ILOG" 2>/dev/null | sed 's/^/  hooks reported done: /' || true
if grep -q "ORPHAN" "$ILOG"; then
  echo "  WARNING: orphaned hooks reported:" >&2
  grep "ORPHAN" "$ILOG" | head -10 >&2
fi

# --- phase 2: boot what was installed ---------------------------------------
echo
echo "--- phase 2: boot installed system (timeout ${BOOT_TIMEOUT}s) ---"
timeout "$BOOT_TIMEOUT" qemu-system-aarch64 \
  -M virt -accel "$ACCEL" -cpu "$CPU" -smp "$SMP" -m "$MEM" \
  -drive if=pflash,format=raw,unit=0,file="$CODE",readonly=on \
  -drive if=pflash,format=raw,unit=1,file="$VARS" \
  -drive file="$DISK",if=none,id=hd,format=qcow2 \
  -device nvme,drive=hd,serial=ncztest01 \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0,romfile= \
  -serial "file:$WORK/boot-serial0.log" -serial "file:$WORK/boot-serial1.log" \
  -serial "file:$WORK/boot-serial2.log" \
  -display none -no-reboot \
  > "$BLOG" 2>&1
cat "$WORK"/boot-serial*.log >> "$BLOG" 2>/dev/null
brc=$?
echo "  qemu rc=$brc"

grep -qE "Linux version|Booting Linux" "$BLOG" \
  || fail "installed system produced no kernel banner — bootloader did not hand off (see $BLOG)"
if grep -qE "Kernel panic - not syncing|Internal error: Oops" "$BLOG"; then
  grep -nE -A12 "Kernel panic|Internal error: Oops" "$BLOG" | head -30 >&2
  fail "installed system panicked on boot"
fi
if grep -qE "Welcome to|systemd\[1\]|Reached target|login:|Started .*getty" "$BLOG"; then
  echo "  installed system reached userspace"
else
  fail "installed system booted a kernel but never reached userspace (see $BLOG)"
fi

echo
echo "GATE PASS: $(basename "$ISO") installs and boots"
