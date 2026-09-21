#!/bin/bash
# kvm-install-gate-amd64-stock.sh -- F-stock-userspace (dispatch 2b) analogue
# of build/kvm-install-gate-amd64.sh. Same 2-phase design, but the input ISO
# is the UNMODIFIED upstream Debian Forky amd64 netinst — no NCZ initrd
# surgery, no NCZ branding, no NCZ post-install hooks, no generic build-iso-di
# hand-patches. A minimal cixmini/preseed.cfg is fabricated inline to answer
# every locale/keyboard/clock/user question so the install can complete
# unattended. The dispatch (review §10 Stage C, F-stock-userspace candidate):
# does the upstream Forky d-i userspace, with only the kernel cmdline and
# preseed changes strictly required to drive an unattended install, install
# and boot in QEMU/OVMF? Any failure here is a "stock Forky d-i can't run
# the NCZ deployment workflow on amd64" finding, NOT a hardware-internals
# patch-necessity finding.
#
# Differences from build/kvm-install-gate-amd64.sh:
#   * No loglevel=4 base in the upstream grub.cfg → all the cmdline-appending
#     sed patterns are rewired to append after "quiet " instead.
#   * No pre-existing cixmini/preseed.cfg → we write a minimal stock-d-i-
#     compatible preseed.cfg inline (locale, keyboard, clock, user, no
#     partman recipe change — uses upstream's default).
#   * No NCZ-ROOTMODE expectation in the on-disk assertion (we still assert
#     GPT/ESP/banner/rescue per kvm-installed-disk-assert.sh's review §10
#     Stage B requirements).
set -euo pipefail

ISO="${1:?usage: kvm-install-gate-amd64-stock.sh STOCK_FORKY_AMD64_ISO [WORKDIR]}"
WORK="${2:-$HOME/kvm-install-amd64-stock}"
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
if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then ACCEL="kvm"; CPU="host"; fi
# Try chmod a+rw as a best-effort so user-mode KVM works too.
sudo -n chmod a+rw /dev/kvm 2>/dev/null || true

QEMU_ISO="${ISO%.iso}-stock-qemutest.iso"
QEMU_STAGE="$WORK/iso-patch"
rm -rf "$QEMU_STAGE" "$QEMU_ISO"
mkdir -p "$QEMU_STAGE/staging"

echo "[1/6] extracting $ISO -> $QEMU_STAGE/staging"
xorriso -osirrox on -indev "$ISO" -extract . "$QEMU_STAGE/staging" >/dev/null 2>&1 \
  || { echo "GATE FAIL: xorriso extract of $ISO failed"; exit 2; }
chmod -R u+w "$QEMU_STAGE/staging"

CFG="$QEMU_STAGE/staging/boot/grub/grub.cfg"
[ -f "$CFG" ] || { echo "GATE FAIL: $ISO has no boot/grub/grub.cfg"; exit 2; }

echo "[2/6] patching kernel cmdlines for unattended install (stock Forky shape)"
# Stock netinst grub.cfg cmdline shape: linux /install.amd/vmlinuz vga=788 --- quiet
# The kvm-install-gate-amd64.sh seds target "loglevel=4" which doesn't exist
# upstream; rewrite them to target "quiet " instead. Insert preseed/auto args
# BEFORE "---" if present, else at end.
patch_line() {
  # Append $1 immediately after "quiet" on every install.amd/vmlinuz line.
  # $1 should not contain "/" or "&" or shell metacharacters.
  local add="$1"
  sed -i -E "s|(linux[[:space:]]+/install\\.amd/vmlinuz[^[:space:]]*[^[:space:]]+[[:space:]]+quiet)([[:space:]]+---[[:space:]]+quiet)?|\\1 ${add}\\2|" "$CFG"
}
# Use upstream's partitioning defaults (don't override partman-auto's default
# recipe — the stock netinst already makes a working ESP + root layout).
# Force btrfs because that's what NCZ-OS standardizes on.
patch_line "auto=true priority=critical"
patch_line "console=ttyS0,115200"
# Append preseed location (we'll create cixmini/preseed.cfg below)
patch_line "preseed/file=/cdrom/cixmini/preseed.cfg"
patch_line "ncz_unattended=1"

if command -v grub-script-check >/dev/null 2>&1; then
  if grub-script-check "$CFG" 2>/dev/null; then
    echo "    grub-script-check: syntax OK"
  else
    echo "    WARN grub-script-check failed on patched cfg — proceeding anyway"
  fi
fi

# Stage a minimal preseed that answers ONLY locale/keyboard/clock/user —
# leaves partman alone (use upstream defaults), no NCZ branding, no NCZ
# post-install hook execution, no finish-install/late_command overrides.
PSEED_DIR="$QEMU_STAGE/staging/cixmini"
mkdir -p "$PSEED_DIR"
PSEED="$PSEED_DIR/preseed.cfg"
cat > "$PSEED" <<'EOF'
# kvm-install-gate-amd64-stock.sh preseed (F-stock-userspace, dispatch 2b):
# answers only what an unattended install needs. Leaves partitioning to
# upstream defaults so the stock debian-installer builds the ESP + rootfs
# layout it was going to build anyway. No NCZ branding, no NCZ post-install
# hooks — this is testing whether stock Forky d-i can install + boot, period.
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
d-i passwd/user-password-again seen true
EOF

echo "[3/6] repacking -> $QEMU_ISO"
EFI_IMG_REL="boot/grub/efi.img"
[ -f "$QEMU_STAGE/staging/$EFI_IMG_REL" ] || { echo "GATE FAIL: $EFI_IMG_REL missing from extracted ISO"; exit 2; }
rm -f "$QEMU_ISO"
xorriso -as mkisofs \
    -r -V "FORKY_AMD64_STOCK" \
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

echo "=== KVM INSTALL GATE (AMD64/stock-Forky-d-i, F-stock-userspace) ==="
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

# For stock d-i, the install-completion markers are different — no
# NCZ post-install hook "Post-install completed successfully" line.
# Use the stock finish-install completion marker instead.
grep -qE "Debian installer|main-menu\[10\]" "$ILOG" \
  || fail "installer never started (qemu rc=$irc) — see $ILOG"

if grep -qE "Kernel panic - not syncing" "$ILOG"; then
  grep -nE -A10 "Kernel panic" "$ILOG" | head -30 >&2
  fail "kernel panic during install"
fi

# Stock d-i reaches finish-install when choose-mirror / clock-setup /
# user-setup / partman / base-installer all complete. Look for the
# "Finish the installation" prompt OR the "Installation complete" line
# OR a poweroff / reboot request.
grep -qE "Installation complete|finish-install|main-menu.*Finish|Menu finished" "$ILOG" \
  || fail "install did not reach finish stage (timeout at ${INSTALL_TIMEOUT}s?) — see $ILOG"
echo "  install reached finish stage"

echo
echo "--- phase 2: boot installed system (timeout ${BOOT_TIMEOUT}s) ---"
set +e
timeout "$BOOT_TIMEOUT" qemu-system-x86_64 \
  -M q35 -accel "$ACCEL" -cpu "$CPU" -smp "$SMP" -m "$MEM" \
  -drive if=pflash,format=raw,unit=0,file="$CODE",readonly=on \
  -drive if=pflash,format=raw,unit=1,file="$VARS" \
  -drive file="$DISK",if=virtio,format=qcow2 \
  -vga std \
  -netdev user,id=n0,hostfwd=tcp::2224-:22 -device virtio-net-pci,netdev=n0,romfile= \
  -object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-pci,rng=rng0 \
  -serial "file:$WORK/boot-serial0.log" \
  -display none -no-reboot \
  > "$BLOG" 2>&1
brc=$?
set -e
cat "$WORK"/boot-serial0.log >> "$BLOG" 2>/dev/null
echo "  qemu rc=$brc"

grep -qE "Linux version|Booting Linux" "$BLOG" \
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

DEFAULT_KVER=$(grep -aoE 'Linux version [^ ]+' "$BLOG" \
  | tail -1 | sed -E 's/^Linux version //' || true)
echo "  default-boot kernel: ${DEFAULT_KVER:-<unknown>}"

# The on-disk assertion gate is the same as for F-retained-fixes — both
# runs use kvm-installed-disk-assert.sh with arch=amd64. For stock Forky
# d-i we may NOT have a rescue entry (upstream doesn't ship rEFInd +
# rescue — it ships GRUB or systemd-boot) — this is itself a finding:
# the upstream substrate CANNOT satisfy review §10 Stage B check #5
# (rescue entry present and independently selectable).
if [ "${SKIP_DISK_ASSERT:-0}" != "1" ]; then
  echo
  echo "--- post-boot on-disk assertions (GPT, ESP, root mode, rescue) ---"
  _IDA_HELPER="$(cd "$(dirname "$0")" && pwd)/kvm-installed-disk-assert.sh"
  bash "$_IDA_HELPER" "$DISK" "$BLOG" amd64 \
    || fail "installed-disk-assert helper failed (see output above) — this is the on-disk layout / ESP / rescue check, NOT a generic timeout"
fi

echo
echo "GATE PASS (F-stock-userspace phase 1+2): $(basename "$ISO") installs and boots default kernel"
echo "WORK=$WORK DISK=$DISK VARS=$VARS CODE=$CODE"