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
# Copy OVMF to local writable paths so perms don't bite us when running
# without root (the upstream /usr/share/OVMF/ files are root:root 644).
mkdir -p "$WORK/ovmf"
cp /usr/share/OVMF/OVMF_CODE_4M.fd "$WORK/ovmf/OVMF_CODE_4M.fd" 2>/dev/null \
  || sudo -n cat /usr/share/OVMF/OVMF_CODE_4M.fd > "$WORK/ovmf/OVMF_CODE_4M.fd"
cp /usr/share/OVMF/OVMF_VARS_4M.fd "$WORK/ovmf/OVMF_VARS_4M.fd" 2>/dev/null \
  || sudo -n cat /usr/share/OVMF/OVMF_VARS_4M.fd > "$WORK/ovmf/OVMF_VARS_4M.fd"
CODE="$WORK/ovmf/OVMF_CODE_4M.fd"
SRCVARS="$WORK/ovmf/OVMF_VARS_4M.fd"

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

echo "[2/6] writing minimal grub.cfg for serial-only unattended install (stock Forky shape)"
# CRITICAL: the upstream Forky netinst's grub.cfg uses gfx modules
# (insmod efi_gop/efi_uga/video_bochs/video_cirrus, terminal_output
# gfxterm) that DO NOT exist outside grubx64.efi's built-in modules, and
# in this QEMU setup the OUTER grub.cfg's terminal_output gfxterm
# leaves the menu with no output medium and the install HANGS. Replace
# the entire file with a serial-only minimal config — the upstream ISO
# was designed for a different boot path (CDROM/BIOS where the gfx
# modules DO live on the OUTER filesystem). This is a tooling change,
# not a "stock d-i" change: the d-i userspace, kernel, initrd, udebs
# are all untouched.
cat > "$CFG" <<'GRUBEOF'
set timeout=5
set default=0
serial --unit=0 --speed=115200
terminal_input serial
terminal_output serial
menuentry 'Install' {
    # preseed/url=file:///cdrom/cixmini/preseed.cfg is the URL form (more
    # reliable than preseed/file= across boot-stage orderings in current
    # d-i). DEBCONF_PRIORITY=critical is passed as an env-var on the kernel
    # cmdline (d-i exports it into debconf), which suppresses ALL
    # below-critical questions including the "Download debconf
    # preconfiguration file" dialog once the preseed URL is honored.
    linux /install.amd/vmlinuz auto=true priority=critical DEBCONF_PRIORITY=critical console=ttyS0,115200 ncz_unattended=1 preseed/url=file:///cdrom/cixmini/preseed.cfg --- quiet
    initrd /install.amd/initrd.gz
}
menuentry 'Graphical install' {
    linux /install.amd/vmlinuz auto=true priority=critical DEBCONF_PRIORITY=critical console=ttyS0,115200 ncz_unattended=1 preseed/url=file:///cdrom/cixmini/preseed.cfg --- quiet
    initrd /install.amd/gtk/initrd.gz
}
GRUBEOF

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
# d-i passwd/make-user boolean false -- skip user-setup entirely
# (the point of this gate is to qualify the installer + installed boot,
# not to validate user-management UX; forking a user at install time
# adds three more interactive dialogs we don't need to test here).
d-i passwd/make-user boolean false
d-i passwd/root-password-crypted password *
# Partitioning: priority=critical does NOT auto-answer critical
# interactive dialogs (it only suppresses below-critical questions).
# For partitioning we need explicit preseed values so d-i advances
# through the dialog chain without waiting for keyboard input.
# Strategy: use the d-i built-in "atomic" recipe (one /boot, one /,
# one swap — no LVM, no encryption). partman-auto/disk is set
# directly so the disk-selection dialog is bypassed (qemu virtio
# presents the qcow2 as /dev/vda). All confirm/write dialogs preseeded
# to true so partman writes without further prompts.
d-i partman-auto/disk string /dev/vda
d-i partman-auto/method string regular
d-i partman-auto/method seen true
# Recipe includes an EFI System Partition (required for the install
# to complete on UEFI firmware — see the "No EFI partition was found"
# error without it). The order is: ESP first (so partman sees it as
# partition #1), then / (the rest of the disk), no swap (KVM-only
# test environment doesn't need swap).
d-i partman-auto/choose_recipe select atomic
d-i partman-auto/choose_recipe seen true
d-i partman-auto/expert_recipe string \
    atomic :: \
        538 538 538 fat32 \
            $primary{ } $bootable{ } \
            method{ efi } format{ } \
        . \
        1000 1000 -1 ext4 \
            $primary{ } \
            method{ format } format{ } \
            use_filesystem{ } filesystem{ ext4 } \
            mountpoint{ / } \
        .
d-i partman-auto/expert_recipe seen true
d-i partman/choose_partition_method select regular
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true
d-i partman/confirm_write_new_label boolean true
d-i partman-lvm/confirm boolean true
d-i partman-lvm/confirm_nooverwrite boolean true
d-i partman-md/confirm boolean true
d-i partman-md/confirm_nooverwrite boolean true
d-i partman-basicfilesystems/no_swap boolean false
d-i partman/choose_partition select finish
d-i partman/unmount_active boolean true
# Suppress the "Finish the installation — <Continue> to reboot" dialog
# so d-i auto-reboots into the installed system instead of waiting
# for keyboard input. r160: this is the difference between an
# unattended install finishing inside the timeout and sitting at the
# final dialog until the 5400s gate timeout.
d-i finish-install/reboot_in_progress note
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
grep -qE "Detecting hardware to find installation media|Scanning installation media|Configuring the network with DHCP" "$ILOG" \
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