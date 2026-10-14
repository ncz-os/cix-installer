#!/bin/bash
# kvm-install-gate-gpt.sh — architecture-generic unattended install gate for the RAW GPT USB
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
# Usage: build/kvm-install-gate-gpt.sh IMAGE [WORKDIR]
#   DISK_GB, MEM, SMP, INSTALL_TIMEOUT, BOOT_TIMEOUT overridable by env.
#
# INSTALL OPTIONS. NCZ_GATE_COMPONENTS is the answer to the installer's
# optional-components dialog, passed through the same ncz_components= cmdline
# seam the dialog honours (preseed/component-selector.sh): a comma list of
# desktop, mgmt-container, rescue-partition, cuda, or `none` for every option
# off. Default: desktop,mgmt-container,rescue-partition. The gate then checks
# the result against that answer: the recorded selection on the target, the
# partition layout (no NCZRESCUE partition when it is off), the installed rEFInd
# menu (a Rescue Partition entry only with the partition, the Console entry as
# default without the desktop), the recovery console and container (only with
# mgmt-container), and what the first boot reaches (greeter with the desktop,
# a console login without it). NCZ_GATE_UI_CHECK=0 skips the installer UI check
# (it does not depend on the options; build/kvm-install-gate-matrix.sh runs it
# once, in the full-option run). build/kvm-install-gate-matrix.sh runs the
# standard option sets one after another.
#
# NCZ_GATE_FS=ext4|btrfs picks the root filesystem (default ext4). The target
# logs, the installed-target verifier and the first-boot report are read with
# debugfs, so a btrfs run checks the installed ESP, the GPT and the boot instead.
# NCZ_GATE_STALE_DISK=1 seeds the target disk before the install with an old
# GPT whose partitions start where the installer's will and carry old ext4
# filesystems (a reinstall over an earlier NCZ-OS install): the new root must
# still get a non-empty, correct root=PARTUUID= and the system must boot.
set -euo pipefail

# Resolve the gate's own directory so we can locate sibling scripts
# (verify-installed-target-arm64.sh etc.) even when invoked via relative
# path or via `bash path/to/gate.sh` from another working directory.
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

IMG="${1:?usage: kvm-install-gate-gpt.sh IMAGE.img [WORKDIR]}"
ARCH="${ARCH:-}"
if [ -z "$ARCH" ]; then
    ARCH=$(python3 - "$IMG.receipt.json" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
print(json.loads(p.read_text()).get("arch", "")) if p.is_file() else None
PY
)
fi
case "$ARCH" in amd64|arm64) ;; *) echo "GATE FAIL: set ARCH=amd64|arm64 or provide $IMG.receipt.json" >&2; exit 2 ;; esac
WORK="${2:-$HOME/kvm-install-$ARCH-gpt}"
DISK_GB="${DISK_GB:-30}"
INSTALL_TIMEOUT="${INSTALL_TIMEOUT:-5400}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-600}"
MEM="${MEM:-4096}"
SMP="${SMP:-4}"

[ -f "$IMG" ] || { echo "GATE FAIL: no such image: $IMG" >&2; exit 2; }

# NCZ-GATE-COMPONENTS-BEGIN
# The options answer and the record the installer must write for it (same
# order and expansion as preseed/component-selector.sh: desktop brings browsers
# and wallpaper-rotator; nothing selected is recorded as `none`).
GATE_COMPONENTS="${NCZ_GATE_COMPONENTS:-desktop,mgmt-container,rescue-partition}"
GATE_COMPONENTS=$(printf '%s' "$GATE_COMPONENTS" | tr -d ' \t')
WANT_DESKTOP=0; WANT_MGMT=0; WANT_RESCUE=0; WANT_CUDA=0
_gc_old_ifs=$IFS; IFS=','
for _gc in $GATE_COMPONENTS; do
    case "$_gc" in
        desktop)          WANT_DESKTOP=1 ;;
        mgmt-container)   WANT_MGMT=1 ;;
        rescue-partition) WANT_RESCUE=1 ;;
        cuda)             WANT_CUDA=1 ;;
        none|"")          : ;;
        *) IFS=$_gc_old_ifs; echo "GATE FAIL: NCZ_GATE_COMPONENTS has an unknown option '$_gc' (use desktop, mgmt-container, rescue-partition, cuda or none)" >&2; exit 2 ;;
    esac
done
IFS=$_gc_old_ifs
EXPECT_RECORD=""
[ "$WANT_DESKTOP" = 1 ] && EXPECT_RECORD="desktop,browsers,wallpaper-rotator"
[ "$WANT_MGMT" = 1 ]    && EXPECT_RECORD="${EXPECT_RECORD:+$EXPECT_RECORD,}mgmt-container"
[ "$WANT_RESCUE" = 1 ]  && EXPECT_RECORD="${EXPECT_RECORD:+$EXPECT_RECORD,}rescue-partition"
[ "$WANT_CUDA" = 1 ]    && EXPECT_RECORD="${EXPECT_RECORD:+$EXPECT_RECORD,}cuda"
[ -n "$EXPECT_RECORD" ] || EXPECT_RECORD=none
# The value handed to ncz_components= (`none` when nothing is selected).
GATE_COMPONENTS_ARG="$EXPECT_RECORD"
case "$GATE_COMPONENTS_ARG" in
    none) : ;;
    *) GATE_COMPONENTS_ARG=$(printf '%s' "$GATE_COMPONENTS_ARG" | sed 's/,browsers//; s/,wallpaper-rotator//') ;;
esac
# NCZ-GATE-COMPONENTS-END
QEMU="qemu-system-x86_64"
MACHINE="q35"
CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
SRCVARS=/usr/share/OVMF/OVMF_VARS_4M.fd
if [ "$ARCH" = arm64 ]; then
    QEMU="qemu-system-aarch64"
    MACHINE="virt,gic-version=3"
    CODE=/usr/share/AAVMF/AAVMF_CODE.fd
    SRCVARS=/usr/share/AAVMF/AAVMF_VARS.fd
fi
BOOT_VIDEO_ARGS=()
[ "$ARCH" = amd64 ] && BOOT_VIDEO_ARGS=(-vga std)
[ "$ARCH" = arm64 ] && BOOT_VIDEO_ARGS=(-device virtio-gpu-pci)
for t in "$QEMU" qemu-img mcopy mdir; do
    command -v "$t" >/dev/null 2>&1 || { echo "GATE FAIL: $t not installed" >&2; exit 2; }
done
SGDISK="$(command -v sgdisk || echo /sbin/sgdisk)"
[ -x "$SGDISK" ] || { echo "GATE FAIL: sgdisk not installed" >&2; exit 2; }
DEBUGFS="$(command -v debugfs || echo /sbin/debugfs)"
[ -x "$DEBUGFS" ] || { echo "GATE FAIL: debugfs not installed" >&2; exit 2; }

# NEVER /tmp: it is a RAM-backed tmpfs on several build hosts and this
# copies a multi-GiB image. Same rule as write-usb-image.py's --work-dir.
mkdir -p "$WORK"
# This gate runs as root (build-image.sh invokes it via ncz_sudo). Everything it
# writes under $WORK (target-logs/, ui-check/, the qcow2, logs) would be root-
# owned, so the build user could not `rm -rf` a finished run dir
# (2026-10-11). Hand the whole tree back to the invoking user on EVERY exit path;
# cleanup only -- the trap preserves the gate's exit status.
. "$SCRIPT_DIR/lib/priv.sh" 2>/dev/null || true
if declare -F ncz_trap_chown_back >/dev/null 2>&1; then ncz_trap_chown_back "$WORK"; fi
DISK="$WORK/target.qcow2"
VARS="$WORK/OVMF_VARS.fd"
if [ "$ARCH" = amd64 ]; then
    [ -f "$CODE" ] || CODE=/usr/share/OVMF/OVMF_CODE.fd
    [ -f "$SRCVARS" ] || SRCVARS=/usr/share/OVMF/OVMF_VARS.fd
fi
[ -f "$CODE" ] && [ -f "$SRCVARS" ] || { echo "GATE FAIL: no UEFI firmware for $ARCH" >&2; exit 2; }
ACCEL="tcg"; CPU="qemu64"
[ "$ARCH" = arm64 ] && CPU="max"
if [ -r /dev/kvm ]; then
  ACCEL="kvm"; CPU="host"
elif [ -e /dev/kvm ]; then
  # /dev/kvm EXISTS but this user cannot read it. Falling through to TCG
  # silently is how a gate ends up 10-40x slower and then "fails" on the
  # phase-1 timeout with no functional defect at all -- measured on an amd64 build host
  # 2026-09-27, where /dev/kvm carried gid 987 (which resolves to the
  # unrelated group "crontab") while the real kvm group is gid 992. The
  # user was correctly in group kvm and still had no access, so every gate
  # run on that host had been quietly emulating.
  echo "WARNING: /dev/kvm exists but is not readable by $(id -un) -- falling back to TCG" >&2
  echo "         emulation, which is ROUGHLY 10-40x SLOWER. A phase-1 timeout from here" >&2
  echo "         is probably the timeout, NOT a broken image. Device is $(stat -c '%U:%G (gid %g)' /dev/kvm 2>/dev/null)," >&2
  echo "         your groups are: $(id -Gn). If the gid does not match the kvm group" >&2
  echo "         ($(getent group kvm 2>/dev/null || echo 'no kvm group')), that mismatch is the cause." >&2
  echo "         Re-run as root, or fix the device's group, to get real acceleration." >&2
fi

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

# --- regression gate: the INSTALLER boot kernel must be the pinned r2 build --
# Phase 1 boots the rEFInd "Install" entry, whose loader is /linux on this ESP
# (all four installer entries share it). That file is the kernel d-i runs, and
# it must be the SAME boot-GPU-fixed r2 build the installed system receives.
# Without this, a stale r1 kernel left on the ESP would silently reintroduce
# the Macmini5,1 i915 EPROBE_DEFER bug and the gate would still PASS: it only
# ever sees KVER, and the r1/r2 release strings are identical. Assert the
# installer kernel is byte-for-byte the pinned r2 vmlinuz whose manifest
# records the 2010 boot-GPU fix, then hand the same pin to the phase-2
# installed-target verifier so it asserts the INSTALLED kernel too.
if [ "$ARCH" = amd64 ]; then
  _amman="$SCRIPT_DIR/../assets/kernel/amd64-stable-manifest.json"
  [ -f "$_amman" ] \
    || { echo "GATE FAIL: $_amman missing; cannot assert the installer kernel is the pinned boot-GPU-fixed r2 build" >&2; exit 2; }
  _want_vmlinuz=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["identity"]["vmlinuz_sha256"])' "$_amman")
  _want_kver=$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d.get("kver") or d["identity"]["kernel_release"])' "$_amman")
  _cyclops=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["source"]["t2_cyclops_patch"])' "$_amman")
  case "$_cyclops" in
    *2010-vga-switcheroo-keep-boot-gpu-guard-on-non-t2-apple.patch) : ;;
    *) echo "GATE FAIL: amd64-stable-manifest t2_cyclops_patch='$_cyclops' is not the 2010 boot-GPU fix" >&2; exit 2 ;;
  esac
  _esp_linux="$WORK/esp-linux.image"
  rm -f "$_esp_linux"
  mcopy -o -i "$TEST_IMG@@$ESP_OFF" ::/linux "$_esp_linux" \
    || { echo "GATE FAIL: no ::/linux (the installer kernel) on the ESP" >&2; exit 2; }
  _got_vmlinuz=$(sha256sum "$_esp_linux" | awk '{print $1}')
  rm -f "$_esp_linux"
  [ "$_got_vmlinuz" = "$_want_vmlinuz" ] || {
    echo "GATE FAIL: ESP installer kernel /linux sha256=$_got_vmlinuz != pinned r2 vmlinuz $_want_vmlinuz" >&2
    echo "           (the installer would boot a kernel WITHOUT the 2010 boot-GPU fix)" >&2
    exit 2; }
  echo "    installer kernel /linux is the pinned r2 build ($_want_kver, 2010 boot-GPU fix): $_want_vmlinuz"
  export VERIFY_EXPECT_KVER="${VERIFY_EXPECT_KVER:-$_want_kver}"
  export VERIFY_EXPECT_VMLINUZ_SHA256="${VERIFY_EXPECT_VMLINUZ_SHA256:-$_want_vmlinuz}"
fi

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
GATE_FS="${NCZ_GATE_FS:-ext4}"
case "$GATE_FS" in ext4|btrfs) ;; *) echo "GATE FAIL: NCZ_GATE_FS must be ext4 or btrfs" >&2; exit 2 ;; esac
GATE_PARAMS="$GATE_PARAMS ncz_disk=/dev/vda ncz_fs=$GATE_FS ncz_unattended=1"
GATE_PARAMS="$GATE_PARAMS ncz_components=$GATE_COMPONENTS_ARG"
GATE_PARAMS="$GATE_PARAMS debian-installer/locale=en_US.UTF-8 keyboard-configuration/xkb-keymap=us"
GATE_PARAMS="$GATE_PARAMS clock-setup/ntp=false time/zone=UTC"

python3 - "$CFG" "$GATE_PARAMS" "$ARCH" <<'PY'
import re, sys
path, params, arch = sys.argv[1], sys.argv[2], sys.argv[3]
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
def fix_options(m):
    opts = m.group(2).split()
    # The LAST console= on the cmdline is the one /dev/console resolves to.
    # The shipped entry ends with console=tty0, so every "[ncz] ..." message
    # written to /dev/console by preseed.cfg, disk-fs-chooser.sh and late.sh
    # lands on the VGA screen and never reaches the serial log this gate
    # reads -- which makes a real failure look like an unexplained one.
    # Reorder so the serial console is last. (Measured: without this, a
    # partman/early_command failure showed the cdebconf error dialog with
    # zero NCZ diagnostics anywhere in serial0.log.)
    consoles = [o for o in opts if o.startswith('console=')]
    rest = [o for o in opts if not o.startswith('console=')]
    # the QEMU serial port: 16550 ttyS0 on amd64 (q35), PL011 ttyAMA0 on arm64
    # (virt). console=ttyS0 on arm64 names no device, so /dev/console stayed on
    # tty0 and nothing written to /dev/console reached serial0.log.
    serial = [c for c in consoles if c.startswith(('console=ttyS', 'console=ttyAMA'))]
    other = [c for c in consoles if not c.startswith(('console=ttyS', 'console=ttyAMA'))]
    # Reordering alone is a no-op here: the shipped entry carries only
    # console=tty0, so `serial` is empty and d-i keeps logging to the VGA
    # console that this headless gate cannot read. Add one when absent.
    if not serial:
        serial = ['console=ttyS0,115200'] if arch == 'amd64' else ['console=ttyAMA0,115200']
    return m.group(1) + ' '.join(rest + other + serial) + ' ' + params + m.group(3)

new_body, n = re.subn(r'(options\s+")([^"]*)(")', fix_options, body, count=1)
if n != 1:
    sys.exit('GATE FAIL: could not find the options line in the Install entry')
open(path, 'w').write(head + marker + new_body + tail)
print('    patched Install entry options + timeout/default_selection')
PY

mcopy -o -i "$TEST_IMG@@$ESP_OFF" "$CFG" ::/EFI/BOOT/refind.conf \
  || { echo "GATE FAIL: could not write the patched refind.conf back to the ESP" >&2; exit 2; }
# Read it back out of the image, not off our own scratch copy.
VERIFY="$WORK/refind.conf.readback"
rm -f "$VERIFY"
mcopy -i "$TEST_IMG@@$ESP_OFF" ::/EFI/BOOT/refind.conf "$VERIFY"
grep -q 'ncz_unattended=1' "$VERIFY" \
  || { echo "GATE FAIL: patched refind.conf did not make it onto the ESP" >&2; exit 2; }
grep -qE '^default_selection "NCZ-OS Installer -- Install"$' "$VERIFY" \
  || { echo "GATE FAIL: default_selection is not a real directive on the ESP (landed in a comment?)" >&2; exit 2; }
grep -qE '^timeout 1$' "$VERIFY" \
  || { echo "GATE FAIL: timeout was not reduced on the ESP" >&2; exit 2; }
echo "    ESP readback confirms options, default_selection and timeout"

echo "=== KVM INSTALL GATE ($ARCH raw GPT image) ==="
echo "  image  : $TEST_IMG"
echo "  options: $GATE_COMPONENTS (expected record: $EXPECT_RECORD), root fs $GATE_FS${NCZ_GATE_STALE_DISK:+, stale disk}"
echo "  accel  : $ACCEL cpu=$CPU mem=${MEM}M smp=$SMP"
echo "  target : $DISK (${DISK_GB}G)"

rm -f "$DISK" "$VARS"
qemu-img create -f qcow2 "$DISK" "${DISK_GB}G" >/dev/null || { echo "GATE FAIL: qemu-img" >&2; exit 2; }
if [ "${NCZ_GATE_STALE_DISK:-0}" = 1 ]; then
    # An earlier install's layout: ESP, a 4 GB partition and a root, all at the
    # starts preseed/disk-fs-chooser.sh's recipes produce, with ext4 in the
    # second and third (the old rescue and root).
    _stale="$WORK/.stale-disk.raw"; rm -f "$_stale"
    truncate -s "${DISK_GB}G" "$_stale"
    "$SGDISK" -n 1:2048:3999743 -t 1:ef00 -n 2:3999744:11999231 -n 3:11999232:0 "$_stale" >/dev/null 2>&1 \
        || { echo "GATE FAIL: could not write the stale GPT" >&2; exit 2; }
    MKE2FS="$(command -v mke2fs || echo /sbin/mke2fs)"
    for _off in 3999744 11999232; do
        "$MKE2FS" -q -F -t ext4 -E offset=$((_off * 512)) "$_stale" 1048576 >/dev/null 2>&1 \
            || { echo "GATE FAIL: could not write a stale ext4 at sector $_off" >&2; exit 2; }
    done
    qemu-img convert -O qcow2 "$_stale" "$DISK" && rm -f "$_stale" || { echo "GATE FAIL: stale disk conversion" >&2; exit 2; }
    echo "  target disk seeded with an old GPT + ext4 at sectors 3999744 and 11999232"
fi
cp "$SRCVARS" "$VARS"

S0="$WORK/serial0.log"; ILOG="$WORK/install.log"; BLOG="$WORK/boot.log"
EVIDENCE="$WORK/target-logs"
rm -f "$S0" "$ILOG" "$BLOG" "$WORK/boot-serial0.log"
rm -rf "$EVIDENCE"

fail() { echo; echo "GATE FAIL: $*" >&2; exit 1; }

# Loopback ports for the guest forwards: free ones, so two gates on one build
# host (another session's build, or the option sets) never collide on a fixed
# port. Falls back to the historical numbers when python3 cannot pick one.
ncz_free_port() {
    python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])' 2>/dev/null || echo "$1"
}
FWD_SSH_INSTALL=$(ncz_free_port 2225)
FWD_HTTP_INSTALL=$(ncz_free_port 18080)
FWD_SSH_BOOT=$(ncz_free_port 2224)

# The installed root is the LAST partition: p3 after ESP + NCZRESCUE, p2 when
# the rescue partition was not selected (disk-fs-chooser.sh 2- or 3-stanza).
ncz_last_partnum() {
    "$SGDISK" -p "$1" 2>/dev/null | awk '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ {n=$1} END {print n}'
}

echo
echo "[4/6] phase 1: install (timeout ${INSTALL_TIMEOUT}s)"
date -u +"  started %H:%M:%SZ"
# Sample the running installer over its diagnostics SSH (2225 -> guest 22) for
# the whole of phase 1: brltty must never run and tty1 must never be clamped
# (build/kvm-installer-probe.sh; judged in step 5).
PROBE_LOG="$WORK/installer-probe.log"
rm -f "$PROBE_LOG"
"$SCRIPT_DIR/kvm-installer-probe.sh" sample "$FWD_SSH_INSTALL" "$PROBE_LOG" 15 &
PROBE_PID=$!
trap 'kill "$PROBE_PID" 2>/dev/null; wait "$PROBE_PID" 2>/dev/null' EXIT
set +e
timeout "$INSTALL_TIMEOUT" "$QEMU" \
  -M "$MACHINE" -accel "$ACCEL" -cpu "$CPU" -smp "$SMP" -m "$MEM" \
  -drive if=pflash,format=raw,unit=0,file="$CODE",readonly=on \
  -drive if=pflash,format=raw,unit=1,file="$VARS" \
  -drive file="$DISK",if=virtio,format=qcow2 \
  -drive file="$TEST_IMG",if=none,id=usbstick,format=raw \
  -device qemu-xhci,id=xhci \
  -device usb-storage,bus=xhci.0,drive=usbstick,bootindex=1 \
  -usb -chardev null,id=usbser -chardev file,id=usbbrl,path=/dev/null \
  -device usb-serial,chardev=usbser,always-plugged=on \
  -device usb-braille,chardev=usbbrl -device usb-kbd -device usb-mouse \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:$FWD_SSH_INSTALL-:22,hostfwd=tcp:127.0.0.1:$FWD_HTTP_INSTALL-:8080 -device virtio-net-pci,netdev=n0,romfile= \
  -object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-pci,rng=rng0 \
  -serial "file:$S0" \
  -display none -no-reboot \
  > "$ILOG" 2>&1 &
QEMU_PID=$!
# An interrupted gate must not leave the guest running.
trap 'kill "$QEMU_PID" "$PROBE_PID" 2>/dev/null; wait "$QEMU_PID" "$PROBE_PID" 2>/dev/null; exit 130' INT TERM
# A failed finish leaves d-i on its error dialog until the timeout (90 min).
# Stop the guest as soon as the serial console shows a terminal failure; the
# checks below then report it from the logs as usual.
while kill -0 "$QEMU_PID" 2>/dev/null; do
    if [ -s "$S0" ] && sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' "$S0" 2>/dev/null | tr -s ' ' \
         | grep -aE 'Failed to run preseeded command|install is NOT bootable' >/dev/null; then
        echo "  terminal install failure on the serial console; stopping the guest"
        sleep 20
        kill "$QEMU_PID" 2>/dev/null || true
        break
    fi
    sleep 10
done
wait "$QEMU_PID"
irc=$?
trap - INT TERM
kill "$PROBE_PID" 2>/dev/null; wait "$PROBE_PID" 2>/dev/null
trap - EXIT
set -e
cat "$S0" >> "$ILOG" 2>/dev/null
date -u +"  ended   %H:%M:%SZ  (qemu rc=$irc)"

# The serial console is only progress/UI output.  The actionable failure record
# lives on the installed filesystem, and phase 1 has powered the guest off by
# this point.  Extract it before making any gate decision so a failing gate is
# self-diagnosing.  This is deliberately rootless: convert the qcow2 to sparse
# raw images and let debugfs read the ext4 root partition directly.
echo "  preserving target-side installer logs in $EVIDENCE"
mkdir -p "$EVIDENCE"
EVIDENCE_DISK="$WORK/.target-evidence.raw"
EVIDENCE_ROOT="$WORK/.target-root-evidence.raw"
rm -f "$EVIDENCE_DISK" "$EVIDENCE_ROOT"
OPTION_FAIL=""
if qemu-img convert -S 4k -O raw "$DISK" "$EVIDENCE_DISK"; then
    ROOT_PART=$(ncz_last_partnum "$EVIDENCE_DISK")
    [ -n "$ROOT_PART" ] || { rm -f "$EVIDENCE_DISK"; fail "no partition table on the installed disk (sgdisk -p found no partitions)"; }
    ROOT_LBA=$("$SGDISK" -i "$ROOT_PART" "$EVIDENCE_DISK" | sed -n 's/^First sector:[[:space:]]*\([0-9]\+\).*/\1/p')
    ROOT_END_LBA=$("$SGDISK" -i "$ROOT_PART" "$EVIDENCE_DISK" | sed -n 's/^Last sector:[[:space:]]*\([0-9]\+\).*/\1/p')
    # Install options, part 1: the partition layout and the installed ESP.
    _want_parts=2; [ "$WANT_RESCUE" = 1 ] && _want_parts=3
    [ "$ROOT_PART" = "$_want_parts" ] || OPTION_FAIL="$OPTION_FAIL; the installed disk has $ROOT_PART partitions, expected $_want_parts for options '$GATE_COMPONENTS'"
    ESP1_LBA=$("$SGDISK" -i 1 "$EVIDENCE_DISK" | sed -n 's/^First sector:[[:space:]]*\([0-9]\+\).*/\1/p')
    if [ -n "$ESP1_LBA" ]; then
        _bootbin=BOOTX64.EFI; [ "$ARCH" = arm64 ] && _bootbin=BOOTAA64.EFI
        rm -f "$EVIDENCE/installed-refind.conf"
        mcopy -i "$EVIDENCE_DISK@@$((ESP1_LBA * 512))" ::/EFI/BOOT/refind.conf "$EVIDENCE/installed-refind.conf" 2>/dev/null || true
        if mdir -i "$EVIDENCE_DISK@@$((ESP1_LBA * 512))" ::/EFI/BOOT/$_bootbin >/dev/null 2>&1; then
            echo "  installed ESP carries EFI/BOOT/$_bootbin"
        else
            OPTION_FAIL="$OPTION_FAIL; the installed ESP has no EFI/BOOT/$_bootbin"
        fi
        if [ -s "$EVIDENCE/installed-refind.conf" ]; then
            if grep -q '^menuentry .*Rescue Partition' "$EVIDENCE/installed-refind.conf"; then _has_rp=1; else _has_rp=0; fi
            [ "$_has_rp" = "$WANT_RESCUE" ] || OPTION_FAIL="$OPTION_FAIL; installed rEFInd Rescue Partition entry present=$_has_rp, rescue-partition selected=$WANT_RESCUE"
            if [ "$WANT_DESKTOP" = 0 ]; then
                grep -qE '^default_selection ".*Console[^"]*"$' "$EVIDENCE/installed-refind.conf" \
                    || OPTION_FAIL="$OPTION_FAIL; desktop not selected but the installed rEFInd default is not the Console entry"
            fi
            echo "  installed rEFInd menu: $(grep -c '^menuentry ' "$EVIDENCE/installed-refind.conf") entries, Rescue Partition entry=$_has_rp, $(grep -m1 '^default_selection' "$EVIDENCE/installed-refind.conf")"
            # Every entry names its root, and the normal entries name THIS root partition.
            if grep -nE 'root=(PARTUUID=|UUID=)?([" ]|$)' "$EVIDENCE/installed-refind.conf" >/dev/null; then
                OPTION_FAIL="$OPTION_FAIL; an installed rEFInd entry has an empty root= ($(grep -cE 'root=(PARTUUID=|UUID=)?([" ]|$)' "$EVIDENCE/installed-refind.conf") lines)"
            fi
            _gpt_root=$("$SGDISK" -i "$ROOT_PART" "$EVIDENCE_DISK" | sed -n 's/^Partition unique GUID: //p' | tr 'A-F' 'a-f')
            _cfg_root=$(awk '/^menuentry .*\(Default\)/ {f=1} f && /options/ {print; exit}' "$EVIDENCE/installed-refind.conf" | sed -n 's/.*root=PARTUUID=\([^ "]*\).*/\1/p' | tr 'A-F' 'a-f')
            if [ -n "$_gpt_root" ] && [ "$_cfg_root" = "$_gpt_root" ]; then
                echo "  default entry root=PARTUUID=$_cfg_root is the GPT GUID of partition $ROOT_PART"
            else
                OPTION_FAIL="$OPTION_FAIL; default entry root=PARTUUID='${_cfg_root}' is not the root partition's GPT GUID '${_gpt_root}'"
            fi
        else
            OPTION_FAIL="$OPTION_FAIL; the installed ESP has no EFI/BOOT/refind.conf"
        fi
    fi
    if [ "$GATE_FS" != ext4 ]; then
        echo "  root is $GATE_FS: target logs and the installed-target verifier need ext4 (debugfs); checked from the ESP, the GPT and the boot"
    elif [ -n "$ROOT_LBA" ] && [ -n "$ROOT_END_LBA" ]; then
        ROOT_BYTES=$(((ROOT_END_LBA - ROOT_LBA + 1) * 512))
        if qemu-img convert --image-opts -S 4k -O raw \
            "driver=raw,file.driver=file,file.filename=$EVIDENCE_DISK,offset=$((ROOT_LBA * 512)),size=$ROOT_BYTES" \
            "$EVIDENCE_ROOT"; then
            "$DEBUGFS" -R "dump /var/log/cix-installer-late.log $EVIDENCE/cix-installer-late.log" \
                "$EVIDENCE_ROOT" >/dev/null 2>&1 || true
            "$DEBUGFS" -R "rdump /var/log/cix-install $EVIDENCE" \
                "$EVIDENCE_ROOT" >/dev/null 2>&1 || true
            # arm64 ONLY: before we throw away the raw root image, assert that
            # the installed target actually carries the Sky1/Cix/NPU userspace
            # the rest of the install chain claims it does. The companion
            # script (build/verify-installed-target-arm64.sh) is also arm64-
            # only by intent; the gate is the layer that gates it out on
            # amd64 (this `if` block). Failing here means the shipped image is
            # silently missing accelerator artifacts even though every other
            # gate passed -- which is exactly the regression mode the script
            # exists to catch.
            #
            # The verify script can be missing locally (developer workstation
            # that never wired it up); treat that as a fatal gate defect, not
            # a soft skip, because the gate would then be lying to CI about
            # accelerator coverage.
            if true; then   # both architectures: COMMON sections for all, Sky1 sections for arm64, leak checks for amd64
                VERIFIER="$SCRIPT_DIR/verify-installed-target.sh"
                if [ ! -x "$VERIFIER" ]; then
                    rm -f "$EVIDENCE_DISK" "$EVIDENCE_ROOT"
                    fail "$ARCH installed-target verifier not found/executable at $VERIFIER (refusing to ship an image with no accelerator coverage check)"
                fi
                echo "  arm64: verifying installed target accelerator artifacts"
                # The verifier cannot tell from the target alone whether this image was meant to ship
                # ncz-screensavers (the payload does not carry the seed manifest); ask the checkout.
                if [ -z "${VERIFY_EXPECT_SCREENSAVERS:-}" ]; then
                    if [ -s "$SCRIPT_DIR/../manifests/install-extra.pkgs" ] && sed 's/#.*//' "$SCRIPT_DIR/../manifests/install-extra.pkgs" | awk 'NF {print $1}' | grep >/dev/null -x ncz-screensavers; then
                        export VERIFY_EXPECT_SCREENSAVERS=1
                    else
                        export VERIFY_EXPECT_SCREENSAVERS=0
                    fi
                fi
                # Same for the Singularity screensaver settings plugin: the checkout's pin
                # (post-install/lib/ncz-screensavers-plugin.lock) means this image ships it.
                if [ -z "${VERIFY_EXPECT_SS_PLUGIN:-}" ]; then
                    if [ -s "$SCRIPT_DIR/../post-install/lib/ncz-screensavers-plugin.lock" ] && [ "${VERIFY_EXPECT_SCREENSAVERS:-0}" = 1 ]; then
                        export VERIFY_EXPECT_SS_PLUGIN=1
                    else
                        export VERIFY_EXPECT_SS_PLUGIN=0
                    fi
                fi
                rc_v=0
                VERIFY_EXPECT_COMPONENTS="$EXPECT_RECORD" "$VERIFIER" "$EVIDENCE_ROOT" "$DEBUGFS" "$ARCH" || rc_v=$?
                if [ "$rc_v" -ne 0 ]; then
                    # The verifier prints its own GATE: lines on miss; preserve
                    # the raw image so the operator can re-run the verifier
                    # against it by hand after fixing the build.
                    mv "$EVIDENCE_ROOT" "$WORK/target-root-evidence.kept.raw" \
                        || cp "$EVIDENCE_ROOT" "$WORK/target-root-evidence.kept.raw" \
                        || true
                    rm -f "$EVIDENCE_DISK"
                    fail "$ARCH installed-target check failed (rc=$rc_v) -- raw image preserved at $WORK/target-root-evidence.kept.raw; see $EVIDENCE/cix-install/ for per-hook logs"
                fi
                echo "  $ARCH: installed-target artifacts verified"
            fi
        fi
    fi
fi
rm -f "$EVIDENCE_DISK" "$EVIDENCE_ROOT"
if [ -s "$EVIDENCE/cix-installer-late.log" ]; then
    echo "  preserved: $EVIDENCE/cix-installer-late.log"
else
    echo "  WARNING: target late log was unavailable (install may not have created the root filesystem)" >&2
fi
[ -d "$EVIDENCE/cix-install" ] && echo "  preserved: $EVIDENCE/cix-install/ (per-hook logs)"

echo
echo "[5/6] checking the install log"
grep -qE "NCZ-OS INSTALLER|Debian installer|Starting system message bus|d-i |Linux version|Starting linux|Installing the base system|Starting NCZ-OS post-install plan" "$ILOG" \
  || fail "the installer never started (qemu rc=$irc) -- see $ILOG"

# No braille in the installer. Phase 1 attaches an emulated USB-serial adapter
# (FTDI 0403:6001, a generic id in brltty-udeb's rules) and an emulated USB
# braille display (usb-braille, Baum 0403:fe72, a non-generic id that started
# brltty with no question at all), next to an ordinary USB keyboard, mouse and
# the USB stick itself. The 2026-10-14 regression started brltty on ordinary
# hardware with no such device at all (a cmdline token containing "brltty" made
# brltty-udeb's S37brltty start it), which the probe catches on any boot. brltty-udeb is removed from the initrd at
# build time; if it ever comes back, brltty starts, `stty cols 80 < /dev/tty1`
# narrows the UI and the framebuffer frontend is turned off. The probe samples
# taken over the diagnostics SSH during phase 1 must show no brltty and an
# unclamped tty1 (build/kvm-installer-probe.sh judge).
#
# The USB devices must be on the DEFAULT `-usb` bus: measured on an amd64 build
# host 2026-10-12, `-device usb-serial,bus=xhci.0` (without -usb) is NOT
# enumerated by the d-i guest at all, which makes the check vacuous; the probe
# log lists the guest's USB ids so the devices' presence is on record.
if grep -qai "indeed a braille device" "$ILOG"; then
    grep -ai -B2 -A4 "braille device" "$ILOG" | head -20 >&2
    fail "the installer asked the brltty 'Is the USB serial device indeed a braille device?' question -- the installer must carry no brltty"
fi
probe_verdict="$("$SCRIPT_DIR/kvm-installer-probe.sh" judge "$PROBE_LOG")" \
  || fail "installer probe ($PROBE_LOG): $probe_verdict"
echo "  $probe_verdict"
grep -q "usb .* 0403:fe72" "$PROBE_LOG" \
  || fail "installer probe: the emulated USB braille display (0403:fe72) was not seen by the guest -- the no-brltty check would be vacuous"
grep -q "usb .* 0403:6001" "$PROBE_LOG" \
  || fail "installer probe: the emulated USB-serial adapter (0403:6001) was not seen by the guest -- the no-brltty check would be vacuous"

# The gaps this session fixed, each with its own message, so a failure names
# the finding rather than just "install failed".
# The installer diagnostics login (root / rescue, docs/RECOVERY-LOGINS.md) is in the
# boot banner on every console (preseed/ncz-ui.sh ncz_ui_diag_login); the serial
# console this gate reads is one of them. The value is the documented login, so
# the saved logs carry nothing that needs redacting.
grep -aqE "==== NCZ-OS INSTALLER [^ ]+ ==== diagnostics login: root / [^ ]{4,}" "$ILOG" \
  || fail "the installer boot banner does not show the diagnostics login line (preseed/ncz-ui.sh ncz_ui_diag_login)"
echo "  installer banner shows the diagnostics login line"
if grep -q "is NOT the NCZ squashfs stub" "$ILOG"; then
    fail "the r159 debootstrap stub was not installed -- see /var/log/ncz-debootstrap-stub.log in the guest"
fi
if grep -qE "no post-install/ on the install media AND none baked" "$ILOG"; then
    fail "late.sh found no post-install scripts on the medium or in the image"
fi
# AUTHORITATIVE FIRST: post-install writes one row per step to progress.tsv,
# already preserved under $EVIDENCE/cix-install/. Consult it BEFORE pattern-
# matching the serial log, because the serial log cannot distinguish a real
# failure from d-i quoting the text of a command that failed (see below).
PROGRESS_TSV="$EVIDENCE/cix-install/progress.tsv"
if [ -f "$PROGRESS_TSV" ] && grep -q "^[0-9]*|[0-9]*|FAIL|" "$PROGRESS_TSV"; then
    echo "  post-install step record ($PROGRESS_TSV):" >&2
    grep -E "^[0-9]*\|[0-9]*\|(FAIL|SKIP)\|" "$PROGRESS_TSV" | sed 's/^/    /' >&2
    failed_step="$(grep -m1 "^[0-9]*|[0-9]*|FAIL|" "$PROGRESS_TSV" | cut -d'|' -f7)"
    fail "post-install step ${failed_step:-unknown} failed -- see $EVIDENCE/cix-install/"
fi

# ONLY NOW the serial-log heuristic, and ONLY because progress.tsv did not
# already answer. That ORDERING is the whole fix; the pattern below cannot
# disambiguate on its own and should not be trusted to.
#
# Why: d-i's error dialog ECHOES BACK the full text of the preseeded command
# it ran, and that command literally contains
#     echo "[ncz] FATAL: late.sh not found on install media"
# as its own fallback branch. So the marker appears in the log whenever that
# command fails for ANY reason -- including a reason that has nothing to do
# with a missing payload. Adding the "[ncz] FATAL:" prefix does NOT help:
# tested 2026-09-28 against the real quoted text, it still matches.
#
# Measured 2026-09-28: a build whose real fault was 10-amd64-kernel.sh
# verifying against a stale KVER was reported by this check as "the data
# partition may be empty", while late.sh had in fact run and executed 76
# post-install steps.
#
# What makes the ordering sound: if a payload script really is missing,
# late.sh never runs, so no progress.tsv is produced and control reaches
# here legitimately. If late.sh did run, progress.tsv exists and the check
# above has already reported the real failing step.
if grep -qE "\[ncz\] FATAL: (disk-fs-chooser|extract-rootfs|late)\.sh not found on install media" "$ILOG"; then
    fail "a payload script was not found on the medium -- the data partition may be empty"
fi
if grep -qE "Failed to run preseeded command|failed with exit code|install aborts|70-bootloader\.sh FAILED rc=|Post-install failed: bootloader rc=|refusing to ship a broken install|refusing to boot" "$ILOG"; then
    grep -nE -B3 -A6 "Failed to run preseeded command|failed with exit code|install aborts|70-bootloader\.sh FAILED rc=|Post-install failed: bootloader rc=|refusing to ship a broken install|refusing to boot" "$ILOG" | head -50 >&2
    fail "a preseeded command failed"
fi
if grep -qE "Kernel panic - not syncing" "$ILOG"; then
    grep -nE -A10 "Kernel panic" "$ILOG" | head -30 >&2
    fail "kernel panic during install"
fi
# The serial log is progress/UI output: ANSI sequences and progress-bar
# carriage returns pad and split phrases, so grep the log only after
# normalising it. Without this, "Ship-critical post-install hooks failed"
# is present but unmatchable.
ncz_norm_log() {
    sed 's/\x1b\[[0-9;?]*[A-Za-z]//g; s/\x1b[()][A-Z0-9]//g' "$1" | tr '\r' '\n' | tr -s ' '
}

# A ship-critical hook failure is a FAILED INSTALL, whatever else the log says.
# run-all.sh emits this immediately before late.sh prints its completion
# marker, and late.sh prints that marker unconditionally -- so checking the
# marker alone reports success on a broken install.
if ncz_norm_log "$ILOG" | grep >/dev/null -ai "Ship-critical post-install hooks failed"; then
    ncz_norm_log "$ILOG" | grep -ai -B2 -A2 "Ship-critical post-install hooks failed" | head -20 >&2
    fail "a ship-critical post-install hook failed -- the install is not shippable"
fi

grep -qE "post-install hooks finished|finalizing apt sources|forcing clean reboot|nclawzero post-install complete|Post-install completed successfully|Completed with optional-step warnings" "$ILOG" \
  || fail "install did not reach the finish stage -- qemu rc=${irc:-?} (rc=124 means the ${INSTALL_TIMEOUT}s timeout expired; any other rc means the run was terminated early, which is NOT a timeout) -- see $ILOG"
echo "  install reached the finish stage with no ship-critical hook failure"
[ -z "$OPTION_FAIL" ] || fail "the install does not match the selected options '$GATE_COMPONENTS'${OPTION_FAIL}"
echo "  installed layout and boot menu match the options '$GATE_COMPONENTS'"
grep -q "ORPHAN" "$ILOG" && { echo "  WARNING: orphaned hooks reported:" >&2; grep "ORPHAN" "$ILOG" | head -10 >&2; } || true

# Optional-hook failures do NOT fail the gate: run-all.sh runs Phase 2 in the
# fail-tolerant phase deliberately, so the bootloader always gets written. But
# they were INVISIBLE here -- the gate read only FAIL/SKIP rows, so an image
# passed clean while a hook was broken. O6N shipped and ran for two days with
# 53-chrome.sh failed (a stale desktop-mirror held no google-chrome-stable);
# progress.tsv recorded it as WARN, the gate printed nothing, and the missing
# browser was found by hand. Report them; do not fail on them.
if [ -f "$PROGRESS_TSV" ]; then
    OPTIONAL_WARNS="$(awk -F'|' '$3 == "WARN" && $7 != "" { print $7 }' "$PROGRESS_TSV" | sort -u)"
    if [ -n "$OPTIONAL_WARNS" ]; then
        echo "  WARNING: optional hooks reported failures (install still ships):" >&2
        printf '    %s\n' $OPTIONAL_WARNS >&2
    else
        echo "  no optional-hook warnings in progress.tsv"
    fi
fi

echo
echo "[6/6] phase 2: boot the installed disk (timeout ${BOOT_TIMEOUT}s)"
set +e
timeout "$BOOT_TIMEOUT" "$QEMU" \
  -M "$MACHINE" -accel "$ACCEL" -cpu "$CPU" -smp "$SMP" -m "$MEM" \
  -drive if=pflash,format=raw,unit=0,file="$CODE",readonly=on \
  -drive if=pflash,format=raw,unit=1,file="$VARS" \
  -drive file="$DISK",if=none,id=targetdisk,format=qcow2 \
  -device virtio-blk-pci,drive=targetdisk,bootindex=1,romfile= \
  "${BOOT_VIDEO_ARGS[@]}" \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:$FWD_SSH_BOOT-:22 -device virtio-net-pci,netdev=n0,romfile= \
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
# A login prompt, not just userspace: the serial getty prints "<host> login:".
grep -aqE "[A-Za-z0-9.-]+ login: *$|[A-Za-z0-9.-]+ login: " "$BLOG" \
  || fail "the installed system never offered a login prompt on the serial console (see $BLOG)"
echo "  installed system offered a login prompt"

DEFAULT_KVER=$(grep -aoE 'Linux version [^ ]+|Starting vmlinuz-[^[:space:]]+' "$BLOG" \
  | tail -1 | sed -E 's/^Linux version //; s/^Starting vmlinuz-//' || true)
echo "  default-boot kernel: ${DEFAULT_KVER:-<unknown>}"

# First-boot health: the installed system writes `systemctl --failed` to
# /var/log/ncz-first-boot-failed.txt 30 s after multi-user.target (97-firstboot-report.sh). Read it
# off the disk phase 2 just booted; any failed unit that is not on the allow-list fails the gate.
if [ "$GATE_FS" != ext4 ]; then
    echo "  first-boot report not read (root is $GATE_FS; debugfs reads ext4 only): the login prompt above is the boot check"
else
    echo
    echo "  first-boot failed-unit report"
    FBR="$WORK/first-boot-failed.txt"; rm -f "$FBR"
    FB_DISK="$WORK/.fb-disk.raw"; FB_ROOT="$WORK/.fb-root.raw"; rm -f "$FB_DISK" "$FB_ROOT"
    if qemu-img convert -S 4k -O raw "$DISK" "$FB_DISK"; then
        FB_P=$(ncz_last_partnum "$FB_DISK"); FB_P="${FB_P:-0}"
        FB_S=$("$SGDISK" -i "$FB_P" "$FB_DISK" | sed -n 's/^First sector:[[:space:]]*\([0-9]\+\).*/\1/p')
        FB_E=$("$SGDISK" -i "$FB_P" "$FB_DISK" | sed -n 's/^Last sector:[[:space:]]*\([0-9]\+\).*/\1/p')
        if [ -n "$FB_S" ] && [ -n "$FB_E" ] && qemu-img convert --image-opts -S 4k -O raw \
            "driver=raw,file.driver=file,file.filename=$FB_DISK,offset=$((FB_S * 512)),size=$(((FB_E - FB_S + 1) * 512))" "$FB_ROOT"; then
            "$DEBUGFS" -R "dump /var/log/ncz-first-boot-failed.txt $FBR" "$FB_ROOT" >/dev/null 2>&1 || true
            GHL="$WORK/gpu-health.log"; rm -f "$GHL"
            "$DEBUGFS" -R "dump /var/log/ncz-gpu-health.log $GHL" "$FB_ROOT" >/dev/null 2>&1 || true
        fi
    fi
    rm -f "$FB_DISK" "$FB_ROOT"
    if [ ! -s "$FBR" ]; then
        fail "no first-boot report (/var/log/ncz-first-boot-failed.txt) on the installed disk -- 97-firstboot-report did not run or the guest did not reach multi-user long enough (BOOT_TIMEOUT=${BOOT_TIMEOUT}s)"
    fi
    # never-software-render: 98-gpu-health ran on first boot. A KVM guest has no hardware GPU, so the expected line is
    # "OK no GPU: software allowed"; "FAIL" means a GPU is present and software rendering is in use.
    if [ ! -s "$GHL" ]; then
        fail "no GPU health log (/var/log/ncz-gpu-health.log) on the installed disk -- 98-gpu-health / ncz-gpu-health.service did not run"
    elif grep -q ' FAIL ' "$GHL"; then
        cat "$GHL" >&2; fail "the GPU health check reports software rendering on a machine with a GPU"
    elif grep -q 'no GPU: software allowed' "$GHL"; then
        echo "    GPU health: no GPU: software allowed (KVM guest has no hardware GPU)"
    elif grep -q ' OK hardware GPU' "$GHL"; then
        echo "    GPU health: hardware GPU, no software rendering"
    else
        cat "$GHL" >&2; fail "unrecognized GPU health log"
    fi
    ALLOW="$SCRIPT_DIR/first-boot-failed-allowlist.txt"
    WP_RC="$(sed -n 's/^# wallpaper-bing-rc=//p' "$FBR" | tail -1)"
    if [ "$WANT_DESKTOP" = 1 ]; then
        case "$WP_RC" in
            0|75) echo "    wallpaper helper smoke: fetch --if-stale exit $WP_RC (0 = cache fresh/fetched, 75 = offline)" ;;
            "")   fail "the first-boot report has no wallpaper-bing result (ncz-wallpaper-bing missing or the report script did not run it)" ;;
            *)    fail "ncz-wallpaper-bing fetch --if-stale exited $WP_RC in the guest (expected 0 or 75); see the guest's /var/log/ncz-wallpaper-smoke.log" ;;
        esac
    else
        [ -z "$WP_RC" ] || fail "desktop not selected but the wallpaper helper ran on first boot (rc $WP_RC)"
        echo "    no wallpaper helper (desktop not selected)"
    fi
    # What the first boot reached, against the options (97-firstboot-report.sh).
    FB_TARGET="$(sed -n 's/^# default-target=//p' "$FBR" | tail -1)"
    FB_GREETD="$(sed -n 's/^# greetd=//p' "$FBR" | tail -1)"
    if [ "$WANT_DESKTOP" = 1 ]; then
        [ "$FB_TARGET" = graphical.target ] || fail "desktop selected but the default target is '${FB_TARGET:-unreported}', not graphical.target"
        case "$ARCH:$FB_GREETD" in
            *:active) echo "    first boot: graphical.target, greeter (greetd) active" ;;
            # The arm64 guest has virtio-gpu and no Mali: the Singularity greeter
            # cannot start there and greetd keeps restarting it. Enabled and
            # retrying is what this guest can show; real Sky1 boards run it.
            arm64:activating) echo "    first boot: graphical.target, greetd enabled and restarting its greeter (arm64 guest: no Mali GPU)" ;;
            *) fail "desktop selected but greetd is '${FB_GREETD:-unreported}' on first boot (no greeter)" ;;
        esac
    else
        [ "$FB_TARGET" = multi-user.target ] || fail "desktop not selected but the default target is '${FB_TARGET:-unreported}', not multi-user.target"
        [ "$FB_GREETD" != active ] || fail "desktop not selected but greetd is active"
        echo "    first boot: multi-user.target, console login"
    fi
    FAILED_UNITS="$(grep -vE '^#|^[[:space:]]*$' "$FBR" | awk '{print $1}' | sed 's/^[^A-Za-z0-9_@.-]*//' | sort -u || true)"  # grep exits 1 when NO unit failed; under pipefail+set -e that ended the gate silently on amd64
    BAD=""
    for u in $FAILED_UNITS; do
        if [ -f "$ALLOW" ] && grep -vE '^#|^[[:space:]]*$' "$ALLOW" | awk '{print $1}' | grep >/dev/null -xF "$u"; then
            echo "    failed (allowed): $u"
        else
            BAD="$BAD $u"
        fi
    done
    if [ -n "$BAD" ]; then
        cat "$FBR" >&2
        fail "units failed on the installed system's first boot:$BAD (fix them, or add to build/first-boot-failed-allowlist.txt with the reason)"
    fi
    echo "    no unexpected failed units on first boot ($(echo "$FAILED_UNITS" | grep -c . || true) allowed)"
fi

# Installer console UI: the dialogs the operator reads must be branded and clean, and the screen must never go blank
# after the component dialog (build/kvm-installer-ui-check.sh; needs pyte). A regression here fails the image.
echo
echo "  installer console UI check ($ARCH)"
if [ "${NCZ_GATE_UI_CHECK:-1}" = 0 ]; then
    echo "    skipped for this option set (NCZ_GATE_UI_CHECK=0): the UI check does not depend on the options and runs in the full-option gate"
elif [ "${NCZ_SKIP_UI_CHECK:-0}" = 1 ]; then
    echo "    SKIPPED by NCZ_SKIP_UI_CHECK=1 (not for shipping images)"
elif [ -x "$SCRIPT_DIR/kvm-installer-ui-check.sh" ]; then
    bash "$SCRIPT_DIR/kvm-installer-ui-check.sh" "$IMG" "$ARCH" "$WORK/ui-check" 2>&1 | sed 's/^/    /'
    [ "${PIPESTATUS[0]}" = 0 ] || fail "the installer console UI check failed (see $WORK/ui-check): chatter over the dialogs, an unbranded dialog, or a blank screen after the component dialog"
else
    fail "build/kvm-installer-ui-check.sh is missing"
fi

echo
echo "GATE PASS (phase 1+2): $(basename "$IMG") installs and boots (options: $GATE_COMPONENTS)"
echo "WORK=$WORK DISK=$DISK VARS=$VARS CODE=$CODE"
