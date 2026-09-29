#!/bin/bash
# kvm-install-gate-amd64.sh — AMD64/forky analogue of kvm-install-gate.sh
# (arm64). Same 2-phase design (patch a throwaway qemutest copy of the ISO
# for unattended install, boot it, then boot the installed disk and verify
# userspace + root-mode): patches a COPY, never the shipped ISO.
#
# AMD64-specific adaptations from the arm64 gate:
#   - qemu-system-x86_64 / OVMF (not qemu-system-aarch64 / AAVMF)
#   - the shipped graphical entry intentionally uses console=tty0 only; the
#     throwaway qemutest copy rewrites that to ttyS0 so a headless gate can
#     observe and drive d-i without changing the release ISO
#   - /install.amd/vmlinuz (not /install.a64/vmlinuz)
#   - virtio disk (/dev/vda) instead of nvme0n1 — matches this session's
#     existing AMD64 QEMU test convention
#   - RNG device (virtio-rng-pci) included from the start in BOTH phases —
#     the arm64 gate's own history shows what happens without one
#     (LUKS/cryptsetup entropy-starvation stall)
set -euo pipefail

ISO="${1:?usage: kvm-install-gate-amd64.sh ISO [WORKDIR]}"
WORK="${2:-$HOME/kvm-install-amd64}"
DISK_GB="${DISK_GB:-30}"
INSTALL_TIMEOUT="${INSTALL_TIMEOUT:-5400}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-600}"
MEM="${MEM:-4096}"
SMP="${SMP:-4}"

mkdir -p "$WORK"
DISK="$WORK/target.qcow2"
VARS="$WORK/OVMF_VARS.fd"
CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
[ -f "$CODE" ] || CODE=/usr/share/OVMF/OVMF_CODE.fd
SRCVARS=/usr/share/OVMF/OVMF_VARS_4M.fd
[ -f "$SRCVARS" ] || SRCVARS=/usr/share/OVMF/OVMF_VARS.fd
ACCEL="tcg"; CPU="qemu64"
if [ -r /dev/kvm ]; then ACCEL="kvm"; CPU="host"; fi

QEMU_ISO="${ISO%.iso}-qemutest.iso"
QEMU_STAGE="$WORK/iso-patch"
rm -rf "$QEMU_STAGE" "$QEMU_ISO"
mkdir -p "$QEMU_STAGE/staging"

echo "[1/6] extracting $ISO -> $QEMU_STAGE/staging"
xorriso -osirrox on -indev "$ISO" -extract / "$QEMU_STAGE/staging" >/dev/null 2>&1 \
  || { echo "GATE FAIL: xorriso extract of $ISO failed"; exit 2; }
chmod -R u+w "$QEMU_STAGE/staging"

CFG="$QEMU_STAGE/staging/boot/grub/grub.cfg"
[ -f "$CFG" ] || { echo "GATE FAIL: $ISO has no boot/grub/grub.cfg"; exit 2; }

echo "[2/6] patching kernel cmdlines for unattended install"
sed -i 's/\(^[[:space:]]*linux[[:space:]]\+\/install\.amd\/vmlinuz.*\)loglevel=4/\1passwd\/username=nczuser passwd\/user-fullname=NCZTestUser passwd\/user-password=nczpassword123 passwd\/user-password-again=nczpassword123 loglevel=4/' "$CFG"
sed -i 's/\(^[[:space:]]*linux[[:space:]]\+\/install\.amd\/vmlinuz.*\)loglevel=4/\1ncz_disk=\/dev\/vda ncz_fs=btrfs loglevel=4/' "$CFG"
sed -i 's/\(^[[:space:]]*linux[[:space:]]\+\/install\.amd\/vmlinuz.*\)loglevel=4/\1ncz_components=desktop,mgmt-container,rescue-partition loglevel=4/' "$CFG"
sed -i 's/\(^[[:space:]]*linux[[:space:]]\+\/install\.amd\/vmlinuz.*\)loglevel=4/\1ncz_unattended=1 loglevel=4/' "$CFG"
# auto=true defers locale/keyboard questions until the preseed on /cdrom is
# available. Without it, a serial-visible guest stops at "Select a language"
# before the appended preseed answers can make the gate unattended.
sed -i '/^[[:space:]]*linux[[:space:]]\+\/install\.amd\/vmlinuz.*auto=true/! s/\(^[[:space:]]*linux[[:space:]]\+\/install\.amd\/vmlinuz.*\)priority=critical/\1auto=true priority=critical/' "$CFG"
# The release's default graphical entry has no serial console by design.
# This gate uses -display none and validates the serial log, so make the
# qemutest COPY serial-only; otherwise the guest boots successfully off-screen
# while the gate waits forever for output that can never reach $S0.
sed -i '/^[[:space:]]*linux[[:space:]]\+\/install\.amd\/vmlinuz/s/console=tty0/console=ttyS0,115200/' "$CFG"

PSEED="$QEMU_STAGE/staging/ncz-payload/preseed.cfg"
[ -f "$PSEED" ] || { echo "GATE FAIL: qemutest ISO has no ncz-payload/preseed.cfg"; exit 2; }
sed -i \
  -e 's/^d-i[[:space:]]\+time\/zone[[:space:]]\+string[[:space:]].*/d-i time\/zone string UTC/' \
  -e 's/^d-i[[:space:]]\+clock-setup\/ntp[[:space:]]\+boolean[[:space:]].*/d-i clock-setup\/ntp boolean false/' \
  "$PSEED"
cat >> "$PSEED" <<'EOF'

##############################################################################
# KVM install gate only (AMD64): keep the qemutest ISO unattended.
##############################################################################
d-i debian-installer/locale string en_US.UTF-8
d-i debian-installer/locale seen true
d-i keyboard-configuration/xkb-keymap select us
d-i keyboard-configuration/xkb-keymap seen true
d-i clock-setup/utc boolean true
d-i clock-setup/utc seen true
d-i time/zone string UTC
d-i time/zone seen true
d-i clock-setup/ntp boolean false
d-i clock-setup/ntp seen true
d-i clock-setup/ntp-server string
d-i clock-setup/ntp-server seen true
d-i passwd/user-fullname string NCZTestUser
d-i passwd/user-fullname seen true
d-i passwd/username string nczuser
d-i passwd/username seen true
d-i passwd/user-password password nczpassword123
d-i passwd/user-password seen true
d-i passwd/user-password-again password nczpassword123
d-i passwd/user-password-again seen true
EOF

if command -v grub-script-check >/dev/null 2>&1; then
  if grub-script-check "$CFG" 2>/dev/null; then
    echo "    grub-script-check: syntax OK"
  else
    echo "    WARN grub-script-check failed on patched cfg — proceeding anyway"
  fi
fi

echo "[3/6] repacking -> $QEMU_ISO"
EFI_IMG_REL="boot/grub/efi.img"
[ -f "$QEMU_STAGE/staging/$EFI_IMG_REL" ] || { echo "GATE FAIL: $EFI_IMG_REL missing from extracted ISO"; exit 2; }
rm -f "$QEMU_ISO"
xorriso -as mkisofs \
    -r -V "NCZ_MAXIMILIAN" \
    -J -joliet-long \
    -cache-inodes \
    -e "$EFI_IMG_REL" \
    -no-emul-boot \
    -append_partition 2 0xef "$QEMU_STAGE/staging/$EFI_IMG_REL" \
    -appended_part_as_gpt \
    -partition_cyl_align all \
    -o "$QEMU_ISO" \
    "$QEMU_STAGE/staging" >/dev/null
echo "    qemutest ISO: $(ls -lh "$QEMU_ISO" | awk '{print $5}')"
ISO="$QEMU_ISO"

echo "=== KVM INSTALL GATE (AMD64/forky) ==="
echo "  iso    : $ISO"
echo "  accel  : $ACCEL cpu=$CPU mem=${MEM}M smp=$SMP"
echo "  target : $DISK (${DISK_GB}G)"

rm -f "$DISK" "$VARS"
qemu-img create -f qcow2 "$DISK" "${DISK_GB}G" >/dev/null || { echo "GATE FAIL: qemu-img"; exit 2; }
cp "$SRCVARS" "$VARS" || { echo "GATE FAIL: no OVMF vars"; exit 2; }

S0="$WORK/serial0.log"
ILOG="$WORK/install.log"
BLOG="$WORK/boot.log"
rm -f "$S0" "$ILOG" "$BLOG"

fail() { echo; echo "GATE FAIL: $*" >&2; exit 1; }

echo
echo "--- phase 1: install (timeout ${INSTALL_TIMEOUT}s) ---"
date -u +"  started %H:%M:%SZ"
set +e
timeout "$INSTALL_TIMEOUT" qemu-system-x86_64 \
  -M q35 -accel "$ACCEL" -cpu "$CPU" -smp "$SMP" -m "$MEM" \
  -drive if=pflash,format=raw,unit=0,file="$CODE",readonly=on \
  -drive if=pflash,format=raw,unit=1,file="$VARS" \
  -drive file="$DISK",if=virtio,format=qcow2 \
  -drive file="$ISO",if=none,id=usbstick,format=raw,readonly=on \
  -device qemu-xhci,id=xhci \
  -device usb-storage,bus=xhci.0,drive=usbstick,bootindex=1 \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0,romfile= \
  -object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-pci,rng=rng0 \
  -serial "file:$S0" \
  -display none -no-reboot \
  > "$ILOG" 2>&1
irc=$?
set -e
cat "$S0" >> "$ILOG" 2>/dev/null
date -u +"  ended   %H:%M:%SZ  (qemu rc=$irc)"

grep -qE "NCZ-OS INSTALLER|Debian installer|Starting system message bus|d-i" "$ILOG" \
  || fail "installer never started (qemu rc=$irc) — see $ILOG"

if grep -qE "Failed to run preseeded command|failed with exit code|install aborts|FAILED rc=|refusing to ship a broken install|refusing to boot" "$ILOG"; then
  echo "--- offending output ---" >&2
  grep -nE -B3 -A6 "Failed to run preseeded command|failed with exit code|install aborts|FAILED rc=|refusing to ship a broken install|refusing to boot" "$ILOG" | head -50 >&2
  fail "the preseed/late_command failed"
fi
if grep -qE "Kernel panic - not syncing" "$ILOG"; then
  grep -nE -A10 "Kernel panic" "$ILOG" | head -30 >&2
  fail "kernel panic during install"
fi
grep -qE "post-install hooks finished|finalizing apt sources|forcing clean reboot|nclawzero post-install complete|Post-install completed successfully|Completed with optional-step warnings" "$ILOG" \
  || fail "install did not reach the finish stage (timeout at ${INSTALL_TIMEOUT}s?) — see $ILOG"

echo "  install completed without a failed hook"
if grep -q "ORPHAN" "$ILOG"; then
  echo "  WARNING: orphaned hooks reported:" >&2
  grep "ORPHAN" "$ILOG" | head -10 >&2
fi

echo
echo "--- phase 2: boot installed system, default kernel (timeout ${BOOT_TIMEOUT}s) ---"
set +e
timeout "$BOOT_TIMEOUT" qemu-system-x86_64 \
  -M q35 -accel "$ACCEL" -cpu "$CPU" -smp "$SMP" -m "$MEM" \
  -drive if=pflash,format=raw,unit=0,file="$CODE",readonly=on \
  -drive if=pflash,format=raw,unit=1,file="$VARS" \
  -drive file="$DISK",if=virtio,format=qcow2 \
  -vga std \
  -netdev user,id=n0,hostfwd=tcp::2223-:22 -device virtio-net-pci,netdev=n0,romfile= \
  -object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-pci,rng=rng0 \
  -serial "file:$WORK/boot-serial0.log" \
  -display none -no-reboot \
  > "$BLOG" 2>&1
brc=$?
set -e
cat "$WORK"/boot-serial0.log >> "$BLOG" 2>/dev/null
echo "  qemu rc=$brc"

grep -qE "Linux version|Booting Linux|Starting vmlinuz-" "$BLOG" \
  || fail "installed system produced no kernel banner — bootloader did not hand off (see $BLOG)"
if grep -qE "Kernel panic - not syncing" "$BLOG"; then
  grep -nE -A12 "Kernel panic" "$BLOG" | head -30 >&2
  fail "installed system panicked on boot"
fi
if grep -qE "Welcome to|systemd\[1\]|Reached target|login:|Started .*getty" "$BLOG"; then
  echo "  installed system reached userspace"
else
  fail "installed system booted a kernel but never reached userspace (see $BLOG)"
fi

DEFAULT_KVER=$(grep -aoE 'Linux version [^ ]+|Starting vmlinuz-[^[:space:]]+' "$BLOG" \
  | tail -1 | sed -E 's/^Linux version //; s/^Starting vmlinuz-//' || true)
echo "  default-boot kernel: ${DEFAULT_KVER:-<unknown>}"

echo
echo "GATE PASS (phase 1+2): $(basename "$ISO") installs and boots default kernel"
echo "WORK=$WORK DISK=$DISK VARS=$VARS CODE=$CODE"
