#!/bin/bash
# kvm-install-gate-amd64-gpt.sh — unattended install gate for the RAW GPT USB
# image built by build/iso/write-usb-image.py.
#
# WHY A SEPARATE GATE (2026-09-24). build/kvm-install-gate-amd64.sh is
# GRUB/ISO9660-based end to end: it xorriso-extracts the artifact, edits
# boot/grub/grub.cfg, and xorriso-repacks it. The amd64 installer is no longer
# an ISO and has no grub.cfg -- it is a two-partition GPT disk image booted by
# rEFInd from its ESP. That gate cannot run against this artifact at all, and
# until now the new writer had NO automated boot gate of any kind; today's QEMU
# validation was entirely manual.
#
# Same two-phase shape as the gate it parallels: phase 1 drives an unattended
# install from a THROWAWAY COPY of the image, phase 2 boots the installed disk
# and checks it reaches userspace. The shipped image is never modified.
#
# HOW THE UNATTENDED ANSWERS GET IN. Not by editing a preseed on the medium:
# since 2026-09-24 preseed.cfg is BAKED INTO THE INITRD (see
# build/iso/patch-initrd-t2-kernel.py) and d-i's S30initrd-preseed loads it
# from there, so a preseed.cfg edited on partition 2 is simply not the one that
# runs. Instead the gate rewrites the rEFInd "Install" entry's `options` line
# on the ESP -- kernel-cmdline preseeding, which d-i honours for any
# question/value pair and which is the technique that was proven by hand
# earlier today. mtools reads and writes the FAT ESP in place via
# "image@@<byte offset>", so no loop mount and no root are needed for the patch.
#
# Usage: build/kvm-install-gate-amd64-gpt.sh IMAGE [WORKDIR]
#   DISK_GB, MEM, SMP, INSTALL_TIMEOUT, BOOT_TIMEOUT overridable by env.
set -euo pipefail

IMG="${1:?usage: kvm-install-gate-amd64-gpt.sh IMAGE.img [WORKDIR]}"
WORK="${2:-$HOME/kvm-install-amd64-gpt}"
DISK_GB="${DISK_GB:-30}"
INSTALL_TIMEOUT="${INSTALL_TIMEOUT:-5400}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-600}"
MEM="${MEM:-4096}"
SMP="${SMP:-4}"

[ -f "$IMG" ] || { echo "GATE FAIL: no such image: $IMG" >&2; exit 2; }
for t in qemu-system-x86_64 qemu-img mcopy mdir; do
    command -v "$t" >/dev/null 2>&1 || { echo "GATE FAIL: $t not installed" >&2; exit 2; }
done
SGDISK="$(command -v sgdisk || echo /sbin/sgdisk)"
[ -x "$SGDISK" ] || { echo "GATE FAIL: sgdisk not installed" >&2; exit 2; }

# NEVER /tmp: it is a RAM-backed tmpfs on several fleet build hosts and this
# copies a multi-GiB image. Same rule as write-usb-image.py's --work-dir.
mkdir -p "$WORK"
DISK="$WORK/target.qcow2"
VARS="$WORK/OVMF_VARS.fd"
CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
[ -f "$CODE" ] || CODE=/usr/share/OVMF/OVMF_CODE.fd
SRCVARS=/usr/share/OVMF/OVMF_VARS_4M.fd
[ -f "$SRCVARS" ] || SRCVARS=/usr/share/OVMF/OVMF_VARS.fd
[ -f "$CODE" ] && [ -f "$SRCVARS" ] || { echo "GATE FAIL: no OVMF firmware" >&2; exit 2; }
ACCEL="tcg"; CPU="qemu64"
if [ -r /dev/kvm ]; then ACCEL="kvm"; CPU="host"; fi

TEST_IMG="$WORK/$(basename "${IMG%.img}")-qemutest.img"

echo "[1/6] copying $IMG -> $TEST_IMG (the shipped image is never modified)"
rm -f "$TEST_IMG"
cp --reflink=auto "$IMG" "$TEST_IMG"

echo "[2/6] locating the ESP in the GPT"
ESP_LBA="$("$SGDISK" -i 1 "$TEST_IMG" | sed -n 's/^First sector:[[:space:]]*\([0-9]\+\).*/\1/p')"
[ -n "$ESP_LBA" ] || { echo "GATE FAIL: could not read partition 1's start LBA" >&2; exit 2; }
ESP_OFF=$((ESP_LBA * 512))
echo "    ESP at LBA $ESP_LBA (byte offset $ESP_OFF)"
mdir -i "$TEST_IMG@@$ESP_OFF" ::/EFI/BOOT >/dev/null 2>&1 \
  || { echo "GATE FAIL: partition 1 is not a readable FAT ESP" >&2; exit 2; }

echo "[3/6] patching the rEFInd Install entry for an unattended run"
CFG="$WORK/refind.conf"
rm -f "$CFG"
mcopy -i "$TEST_IMG@@$ESP_OFF" ::/EFI/BOOT/refind.conf "$CFG" \
  || { echo "GATE FAIL: no EFI/BOOT/refind.conf on the ESP" >&2; exit 2; }
grep -q 'NCZ-OS Installer -- Install' "$CFG" \
  || { echo "GATE FAIL: refind.conf has no Install menuentry" >&2; exit 2; }

# Answers d-i would otherwise stop for. The baked preseed deliberately leaves
# the username/password UNSEEN so real installs prompt; the gate supplies them
# on the cmdline, which does not change that interactive default.
GATE_PARAMS="passwd/username=nczuser passwd/user-fullname=NCZTestUser"
GATE_PARAMS="$GATE_PARAMS passwd/user-password=nczpassword123 passwd/user-password-again=nczpassword123"
GATE_PARAMS="$GATE_PARAMS ncz_disk=/dev/vda ncz_fs=ext4 ncz_unattended=1"
GATE_PARAMS="$GATE_PARAMS ncz_components=desktop,mgmt-container,rescue-partition"
GATE_PARAMS="$GATE_PARAMS debian-installer/locale=en_US.UTF-8 keyboard-configuration/xkb-keymap=us"
GATE_PARAMS="$GATE_PARAMS clock-setup/ntp=false time/zone=UTC"

python3 - "$CFG" "$GATE_PARAMS" <<'PY'
import re, sys
path, params = sys.argv[1], sys.argv[2]
text = open(path).read()

# Boot the Install entry immediately instead of waiting out the menu.
# Every edit here is anchored to a real directive line with (?m)^...$.
# refind.conf's own header comment contains the text "timeout 10", so a plain
# string replace of "timeout 1" rewrites THAT and drops default_selection into
# the middle of a comment, where rEFInd ignores it -- caught by reading the
# patched file back out of the ESP rather than trusting the edit.
text, n = re.subn(r'(?m)^timeout\s+\d+\s*$', 'timeout 1', text, count=1)
if n != 1:
    sys.exit('GATE FAIL: refind.conf has no top-level timeout directive')
if not re.search(r'(?m)^default_selection\b', text):
    text = re.sub(r'(?m)^timeout 1$',
                  'timeout 1\ndefault_selection "NCZ-OS Installer -- Install"',
                  text, count=1)

# Append the gate's answers to that ONE entry's options line. Splitting on the
# menuentry header keeps the expert and rescue entries untouched.
marker = 'menuentry "NCZ-OS Installer -- Install" {'
head, _, rest = text.partition(marker)
if not rest:
    sys.exit('GATE FAIL: Install menuentry not found while patching')
end = rest.index('\n}')
body, tail = rest[:end], rest[end:]
new_body, n = re.subn(r'(options\s+")([^"]*)(")',
                      lambda m: m.group(1) + m.group(2).rstrip() + ' ' + params + m.group(3),
                      body, count=1)
if n != 1:
    sys.exit('GATE FAIL: could not find the options line in the Install entry')
open(path, 'w').write(head + marker + new_body + tail)
print('    patched Install entry options + timeout/default_selection')
PY

mcopy -o -i "$TEST_IMG@@$ESP_OFF" "$CFG" ::/EFI/BOOT/refind.conf \
  || { echo "GATE FAIL: could not write the patched refind.conf back to the ESP" >&2; exit 2; }
# Read it back out of the image, not off our own scratch copy.
VERIFY="$WORK/refind.conf.readback"
mcopy -i "$TEST_IMG@@$ESP_OFF" ::/EFI/BOOT/refind.conf "$VERIFY"
grep -q 'ncz_unattended=1' "$VERIFY" \
  || { echo "GATE FAIL: patched refind.conf did not make it onto the ESP" >&2; exit 2; }
grep -qE '^default_selection "NCZ-OS Installer -- Install"$' "$VERIFY" \
  || { echo "GATE FAIL: default_selection is not a real directive on the ESP (landed in a comment?)" >&2; exit 2; }
grep -qE '^timeout 1$' "$VERIFY" \
  || { echo "GATE FAIL: timeout was not reduced on the ESP" >&2; exit 2; }
echo "    ESP readback confirms options, default_selection and timeout"

echo "=== KVM INSTALL GATE (AMD64 raw GPT image) ==="
echo "  image  : $TEST_IMG"
echo "  accel  : $ACCEL cpu=$CPU mem=${MEM}M smp=$SMP"
echo "  target : $DISK (${DISK_GB}G)"

rm -f "$DISK" "$VARS"
qemu-img create -f qcow2 "$DISK" "${DISK_GB}G" >/dev/null || { echo "GATE FAIL: qemu-img" >&2; exit 2; }
cp "$SRCVARS" "$VARS"

S0="$WORK/serial0.log"; ILOG="$WORK/install.log"; BLOG="$WORK/boot.log"
rm -f "$S0" "$ILOG" "$BLOG" "$WORK/boot-serial0.log"

fail() { echo; echo "GATE FAIL: $*" >&2; exit 1; }

echo
echo "[4/6] phase 1: install (timeout ${INSTALL_TIMEOUT}s)"
date -u +"  started %H:%M:%SZ"
set +e
timeout "$INSTALL_TIMEOUT" qemu-system-x86_64 \
  -M q35 -accel "$ACCEL" -cpu "$CPU" -smp "$SMP" -m "$MEM" \
  -drive if=pflash,format=raw,unit=0,file="$CODE",readonly=on \
  -drive if=pflash,format=raw,unit=1,file="$VARS" \
  -drive file="$DISK",if=virtio,format=qcow2 \
  -drive file="$TEST_IMG",if=none,id=usbstick,format=raw \
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

echo
echo "[5/6] checking the install log"
grep -qE "NCZ-OS INSTALLER|Debian installer|Starting system message bus|d-i |Linux version" "$ILOG" \
  || fail "the installer never started (qemu rc=$irc) -- see $ILOG"

# The gaps this session fixed, each with its own message, so a failure names
# the finding rather than just "install failed".
if grep -q "is NOT the NCZ squashfs stub" "$ILOG"; then
    fail "the r159 debootstrap stub was not installed -- see /var/log/ncz-debootstrap-stub.log in the guest"
fi
if grep -qE "no post-install/ on the install media AND none baked" "$ILOG"; then
    fail "late.sh found no post-install scripts on the medium or in the image"
fi
if grep -qE "disk-fs-chooser.sh not found on install media|extract-rootfs.sh not found on install media|late.sh not found on install media" "$ILOG"; then
    fail "a payload script was not found on the medium -- the data partition may be empty"
fi
if grep -qE "Failed to run preseeded command|failed with exit code|install aborts|FAILED rc=|refusing to ship a broken install|refusing to boot" "$ILOG"; then
    grep -nE -B3 -A6 "Failed to run preseeded command|failed with exit code|install aborts|FAILED rc=|refusing to ship a broken install|refusing to boot" "$ILOG" | head -50 >&2
    fail "a preseeded command failed"
fi
if grep -qE "Kernel panic - not syncing" "$ILOG"; then
    grep -nE -A10 "Kernel panic" "$ILOG" | head -30 >&2
    fail "kernel panic during install"
fi
grep -qE "post-install hooks finished|finalizing apt sources|forcing clean reboot|nclawzero post-install complete|Post-install completed successfully|Completed with optional-step warnings" "$ILOG" \
  || fail "install did not reach the finish stage (timeout at ${INSTALL_TIMEOUT}s?) -- see $ILOG"
echo "  install completed without a failed hook"
grep -q "ORPHAN" "$ILOG" && { echo "  WARNING: orphaned hooks reported:" >&2; grep "ORPHAN" "$ILOG" | head -10 >&2; } || true

echo
echo "[6/6] phase 2: boot the installed disk (timeout ${BOOT_TIMEOUT}s)"
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
cat "$WORK/boot-serial0.log" >> "$BLOG" 2>/dev/null
echo "  qemu rc=$brc"

grep -qE "Linux version|Booting Linux|Starting vmlinuz-" "$BLOG" \
  || fail "the installed system produced no kernel banner -- the bootloader did not hand off (see $BLOG)"
if grep -qE "Kernel panic - not syncing" "$BLOG"; then
    grep -nE -A12 "Kernel panic" "$BLOG" | head -30 >&2
    fail "the installed system panicked on boot"
fi
grep -qE "Welcome to|systemd\[1\]|Reached target|login:|Started .*getty" "$BLOG" \
  || fail "the installed system booted a kernel but never reached userspace (see $BLOG)"
echo "  installed system reached userspace"

DEFAULT_KVER=$(grep -aoE 'Linux version [^ ]+|Starting vmlinuz-[^[:space:]]+' "$BLOG" \
  | tail -1 | sed -E 's/^Linux version //; s/^Starting vmlinuz-//' || true)
echo "  default-boot kernel: ${DEFAULT_KVER:-<unknown>}"

echo
echo "GATE PASS (phase 1+2): $(basename "$IMG") installs and boots"
echo "WORK=$WORK DISK=$DISK VARS=$VARS CODE=$CODE"
