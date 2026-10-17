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
#
# SERVER VARIANT (Magnetar, docs/MAGNETAR-SERVER-VARIANT.md). NCZ_GATE_SERVER=1
# runs the gate against a SERVER image (NCZ_VARIANT=server medium: it carries
# the installer substrate only and fetches base.squashfs + the pinned asset
# bundle from the network at install time). The gate then hosts those artifacts
# itself: an HTTP server under the work dir (python http.server), bound to the
# QEMU user-net gateway 10.0.2.2, with the payload and bundle served at
# /base.squashfs and /ncz-assets-<arch>.tar.gz. NCZ_GATE_SERVER_PAYLOAD and
# NCZ_GATE_SERVER_ASSETS point at the real bytes (defaults: the payload work
# dir of the same build, $WORK/.., i.e. <rundir>/../payload and
# <rundir>/../ncz-assets-<arch>.tar.gz); NCZ_GATE_SERVER_OFFLINE=1 runs the
# NEGATIVE half of the contract: the HTTP server is NOT started, so the guest's
# ncz-fetch-payload.sh must give up on the bounded deadline, the guest must
# still power off (the r159 stub exits, d-i aborts), and the installed disk
# must hold NO rootfs at all (no /target population, no /etc/os-release, no
# half-written extract).
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

# NCZ-GATE-SERVER-BEGIN
# --- Magnetar server variant (NCZ_GATE_SERVER=1) ------------------------------
# The server medium carries no payload: the debootstrap stub fetches
# base.squashfs + the pinned asset bundle over HTTP (preseed/ncz-fetch-
# payload.sh), verifying sha256 before use. This gate is what proves that path
# end to end against a real image (docs/MAGNETAR-SERVER-VARIANT.md "Not yet
# proven"). The gate hosts both artifacts on a local HTTP server bound to the
# QEMU user-net gateway (10.0.2.2, the guest's DHCP default gateway), so the
# guest needs no outside network:
#   NCZ_GATE_SERVER=1             run in server mode (implies desktop off:
#                                 NCZ_GATE_COMPONENTS=rescue-partition,
#                                 NCZ_GATE_UI_CHECK=0)
#   NCZ_GATE_SERVER_OFFLINE=1     negative run: do NOT start the HTTP server;
#                                 the install must fail loudly within the
#                                 deadline and must not leave a half-written
#                                 rootfs (see the end of this gate)
#   NCZ_GATE_SERVER_PAYLOAD       path to base.squashfs (default $SERVER_DEFAULTS)
#   NCZ_GATE_SERVER_ASSETS        path to ncz-assets-<arch>.tar.gz (default
#                                 $SERVER_DEFAULTS)
# Both defaults are the build's payload work dir of the same run
# ($WORK/..: build-image.sh passes WORKDIR=$RUN_DIR/kvm-gate/<set> and keeps
# the layer payloads under $RUN_DIR).
NCZ_GATE_SERVER="${NCZ_GATE_SERVER:-0}"
case "$NCZ_GATE_SERVER" in 0|1) ;; *) echo "GATE FAIL: NCZ_GATE_SERVER must be 0 or 1" >&2; exit 2 ;; esac
NCZ_GATE_SERVER_OFFLINE="${NCZ_GATE_SERVER_OFFLINE:-0}"
case "$NCZ_GATE_SERVER_OFFLINE" in 0|1) ;; *) echo "GATE FAIL: NCZ_GATE_SERVER_OFFLINE must be 0 or 1" >&2; exit 2 ;; esac
if [ "$NCZ_GATE_SERVER" = 1 ]; then
    # Server install = console system: no desktop, no management container.
    # The rescue partition IS selected: the documented server menu is
    # Console + Rescue Partition (assets/refind/ncz-refind-refresh.sh).
    NCZ_GATE_COMPONENTS="rescue-partition"
    export NCZ_GATE_COMPONENTS
    export NCZ_GATE_UI_CHECK=0   # the installer UI is identical to desktop; the full set ran it
    # The payload + bundle the gate serves (and the negative run points at
    # with its server off). Defaults: the build's layer work dir, one level
    # up from this gate's per-set work dir.
    _srv_parent="$(cd "$(dirname "$WORK")" 2>/dev/null && pwd || echo "$WORK")"
    NCZ_GATE_SERVER_PAYLOAD="${NCZ_GATE_SERVER_PAYLOAD:-$_srv_parent/payload/base.squashfs}"
    NCZ_GATE_SERVER_ASSETS="${NCZ_GATE_SERVER_ASSETS:-$_srv_parent/ncz-assets-$ARCH.tar.gz}"
    [ -f "$IMG.receipt.json" ] || { echo "GATE FAIL: server mode needs $IMG.receipt.json to confirm the medium is a server image" >&2; exit 2; }
    _rv=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("variant","desktop"))' "$IMG.receipt.json")
    [ "$_rv" = server ] || { echo "GATE FAIL: $IMG.receipt.json records variant=$_rv; server gate needs a server image (build with NCZ_VARIANT=server)" >&2; exit 2; }
    if [ "$NCZ_GATE_SERVER_OFFLINE" != 1 ]; then
        [ -f "$NCZ_GATE_SERVER_PAYLOAD" ] || { echo "GATE FAIL: no base.squashfs to serve at $NCZ_GATE_SERVER_PAYLOAD (set NCZ_GATE_SERVER_PAYLOAD)" >&2; exit 2; }
        [ -f "$NCZ_GATE_SERVER_ASSETS" ] || { echo "GATE FAIL: no asset bundle to serve at $NCZ_GATE_SERVER_ASSETS (set NCZ_GATE_SERVER_ASSETS)" >&2; exit 2; }
    fi
fi
# NCZ-GATE-SERVER-END

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
if [ "$NCZ_GATE_SERVER" = 1 ]; then
    # Server mode fixes the options (rescue-partition only, chosen above)
    # regardless of what the caller passed: the matrix passes the same value
    # and a hand-run with a different answer would be a different install.
    GATE_COMPONENTS="$NCZ_GATE_COMPONENTS"
    WANT_DESKTOP=0; WANT_MGMT=0; WANT_RESCUE=0; WANT_CUDA=0
    EXPECT_RECORD="rescue-partition"
    GATE_COMPONENTS_ARG="rescue-partition"
fi
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
if [ "$NCZ_GATE_SERVER" = 1 ]; then
    echo "  variant: server (MAGNETAR online payload; payload server $([ "$NCZ_GATE_SERVER_OFFLINE" = 1 ] && echo OFF || echo "${SRV_URL_BASE:-starting}"))"
fi

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

# --- Magnetar server variant: host base.squashfs + the asset bundle ---------
# The guest's fetcher (preseed/ncz-fetch-payload.sh) reads the URLs from the
# medium's ncz-fetch-payload.manifest; this gate serves the SAME bytes it
# pinned at build time, bound to the QEMU user-net gateway 10.0.2.2 so the
# guest reaches it on its default network without any outside connectivity.
SRV_DIR=""
SRV_PID=""
SRV_URL_BASE=""
SRV_LOCAL_HOST=""
ncz_srv_cleanup() {
    [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null || true
    [ -n "$SRV_PID" ] && wait "$SRV_PID" 2>/dev/null || true
    SRV_PID=""
}
ncz_gate_srv_start() {
    # $1 = the base URL the guest's manifest pins (scheme://host[:port]).
    # Starts the server and proves it actually ANSWERS (a full HTTP request
    # returns 200) before the guest is allowed to start, so a silent bind
    # failure (port taken, python missing, slow bind) is a gate error, not a
    # 90-minute install timeout. The bind address is the host the MEDIUM'S
    # PIN NAMES (read back from the data partition's
    # ncz-fetch-payload.manifest by the caller -- the gate serves at the pin
    # the guest will follow, so the two cannot drift); on every standard
    # QEMU user-net setup that host is the guest's gateway 10.0.2.2.
    # NCZ_GATE_SERVER_HOST is a BUILD-TIME knob (write-usb-image.py): it
    # puts a non-standard serve host into the pins before the medium exists.
    local bind="$1" host port
    host=${bind#*://}; host=${host%%/*}; host=${host%%:*}
    [ -n "$host" ] || host=10.0.2.2
    port=${bind##*:}; case "$port" in *[!0-9]*|'') port=80 ;; esac
    # 10.0.2.2 is the guest's view of the gate host under QEMU user-net:
    # slirp forwards it to the host's loopback, and the host itself has no
    # 10.0.2.2 address to bind. Any other pinned host must be an address of
    # this host (NCZ_GATE_SERVER_HOST at build time), reached through slirp's NAT.
    case "$host" in
        10.0.2.2) SRV_LOCAL_HOST=127.0.0.1 ;;
        *)        SRV_LOCAL_HOST="$host" ;;
    esac
    SRV_DIR="$WORK/srv"
    rm -rf "$SRV_DIR"; mkdir -p "$SRV_DIR"
    cp "$NCZ_GATE_SERVER_PAYLOAD" "$SRV_DIR/base.squashfs"
    cp "$NCZ_GATE_SERVER_ASSETS" "$SRV_DIR/$(basename "$NCZ_GATE_SERVER_ASSETS")"
    # `python3 - arg1 arg2 <<'PY'` runs the heredoc as the script and passes
    # the args through sys.argv[1:] (argv[0] is '-'); a local run of exactly
    # this form is part of build/test-kvm-gate-server.sh, so the invocation
    # itself is a tested path, not an assumption.
    python3 - "$SRV_DIR" "$SRV_LOCAL_HOST" "$port" <<'PY' >"$WORK/srv.log" 2>&1 &
import http.server, os, socketserver, sys
os.chdir(sys.argv[1])
class H(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
# Bounded bind retry: on a loaded build host the socket can take a moment;
# a single failed bind would otherwise kill the server before it ever served.
for _ in range(20):
    try:
        srv = socketserver.TCPServer((sys.argv[2], int(sys.argv[3])), H)
        break
    except OSError as e:
        if _ == 19:
            raise SystemExit(f"bind {sys.argv[2]}:{sys.argv[3]} failed: {e}")
        import time; time.sleep(0.25)
print("serving", os.getcwd(), "on", sys.argv[2] + ":" + sys.argv[3], flush=True)
srv.serve_forever()
PY
    SRV_PID=$!
    # Prove liveness with a REAL HTTP request (a bare TCP connect would pass
    # while the server is still binding, and a fragment could cut the reply
    # short): GET the first byte of the payload until it answers 200.
    local i=0
    while [ $i -lt 40 ]; do
        if ! kill -0 "$SRV_PID" 2>/dev/null; then
            echo "GATE FAIL: the payload HTTP server died at startup: $(tail -3 "$WORK/srv.log" 2>/dev/null | tr '\n' '; ')" >&2
            exit 2
        fi
        if python3 - "$SRV_LOCAL_HOST" "$port" <<'PY' 2>/dev/null
import socket, sys
s = socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=2)
s.sendall(b"GET /base.squashfs HTTP/1.0\r\nHost: " + sys.argv[1].encode() + b"\r\n\r\n")
buf = b""
s.settimeout(5)
while b"\r\n\r\n" not in buf:
    chunk = s.recv(65536)
    if not chunk: break
    buf += chunk
status = buf.split(b"\r\n", 1)[0].decode("utf-8", "replace")
s.close()
sys.exit(0 if status.endswith(" 200 OK") else 1)
PY
        then
            SRV_URL_BASE="$bind"
            return 0
        fi
        sleep 0.5; i=$((i + 1))
    done
    echo "GATE FAIL: the payload HTTP server on ${host}:${port} never answered 200; phase 1 would only fail on the deadline. Server log: $(tail -3 "$WORK/srv.log" 2>/dev/null | tr '\n' '; ')" >&2
    exit 2
}
if [ "$NCZ_GATE_SERVER" = 1 ] && [ "$NCZ_GATE_SERVER_OFFLINE" != 1 ]; then
    # The URL the guest sees: the medium's manifest pins whatever the build
    # recorded, and the build recorded it with the gate's own base, so the
    # gate MUST serve at exactly that path. Read it from the medium's data
    # partition (the authoritative pin) rather than re-deriving it.
    ncz_gate_srv_extract_manifest() {
        # $1 = image, $2 = out file. Reads the data partition's
        # ncz-payload/ncz-fetch-payload.manifest via sgdisk + debugfs (no
        # loop mount: the gate is rootless-safe on the target side).
        local img="$1" out="$2" _dpart _dlba _dend _db
        _dpart=$("$SGDISK" -p "$img" 2>/dev/null | awk '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ {n=$1} END {print n-1}')
        [ -n "$_dpart" ] && [ "$_dpart" -ge 1 ] || return 1
        _dlba=$("$SGDISK" -i "$_dpart" "$img" | sed -n 's/^First sector:[[:space:]]*\([0-9]\+\).*/\1/p')
        _dend=$("$SGDISK" -i "$_dpart" "$img" | sed -n 's/^Last sector:[[:space:]]*\([0-9]\+\).*/\1/p')
        [ -n "$_dlba" ] && [ -n "$_dend" ] || return 1
        _db=$(mktemp "$WORK/.srv-data-XXXXXX.raw")
        if ! qemu-img convert --image-opts -S 4k -O raw \
            "driver=raw,file.driver=file,file.filename=$img,offset=$((_dlba * 512)),size=$(( ($_dend - _dlba + 1) * 512 ))" "$_db" >/dev/null 2>&1; then
            rm -f "$_db"; return 1
        fi
        if ! "$DEBUGFS" -R "dump ncz-payload/ncz-fetch-payload.manifest $out" "$_db" >/dev/null 2>&1; then
            rm -f "$_db"; return 1
        fi
        rm -f "$_db"
        [ -s "$out" ]
    }
    _srv_man="$WORK/srv-manifest.tsv"
    if ncz_gate_srv_extract_manifest "$TEST_IMG" "$_srv_man"; then
        _srv_purl=$(awk -F'\t' '$1=="base.squashfs" && $4=="file" {print $2}' "$_srv_man" | tail -1)
        _srv_aurl=$(awk -F'\t' '$4=="untar" {print $2}' "$_srv_man" | tail -1)
        [ -n "$_srv_purl" ] && [ -n "$_srv_aurl" ] || _srv_purl=""
    fi
    if [ -z "${_srv_purl:-}" ]; then
        # No readable manifest: fall back to the documented default (the build
        # pins exactly this shape for the gate) and say so.
        _srv_purl="http://10.0.2.2/base.squashfs"
        _srv_aurl="http://10.0.2.2/ncz-assets-$ARCH.tar.gz"
        echo "  WARN: could not read ncz-fetch-payload.manifest from $TEST_IMG; assuming the default pin $_srv_purl"
    fi
    _srv_base="${_srv_purl%/base.squashfs}"
    _srv_pinhost=${_srv_purl#*://}; _srv_pinhost=${_srv_pinhost%%/*}; _srv_pinhost=${_srv_pinhost%%:*}
    # SERVES AT THE PIN IT READS OFF THE MEDIUM: the 200 checks
    # below run against the guest's exact URLs, so a wrong pin is a gate
    # error before the guest starts. NCZ_GATE_SERVER_HOST (build time,
    # see write-usb-image.py) is how a non-standard serve host gets into
    # the pins in the first place; the gate does not rewrite the medium's
    # manifest at run time.
    echo "  server pins point at ${_srv_pinhost} (read from the medium's ncz-fetch-payload.manifest)"
    # The served file must match the manifest's URL path (usually
    # ncz-assets-<arch>.tar.gz; the pin is authoritative).
    _srv_name=$(basename "${_srv_aurl%%\?*}")
    ncz_gate_srv_start "$_srv_base"
    if [ "$(basename "$NCZ_GATE_SERVER_ASSETS")" != "$_srv_name" ]; then
        cp "$NCZ_GATE_SERVER_ASSETS" "$SRV_DIR/$_srv_name"
    fi
    trap 'ncz_srv_cleanup' EXIT
    echo "  server payload at $_srv_purl"
    echo "  server bundle  at ${_srv_base%/}/$_srv_name (served from $SRV_DIR)"
    # The guest's fetcher will follow the EXACT URLs the medium pins; if a
    # pinned path does not exist on THIS server, the guest fails at install
    # time. Prove both artifacts answer 200 NOW (a full HTTP GET read to the
    # end of the headers, which handles fragmented replies) so a wrong pin is
    # a gate error instead of a 90-minute install.
    _srv_check_url() {
        # $1 = pinned URL; requests its exact path from the gate's own server
        # (on SRV_LOCAL_HOST, which is where the guest's gateway lands) and
        # prints the HTTP status line or "NO-RESPONSE".
        python3 - "$1" "$SRV_LOCAL_HOST" <<'PY' 2>/dev/null || echo NO-RESPONSE
import socket, sys
from urllib.parse import urlsplit
u = urlsplit(sys.argv[1])
host, port = sys.argv[2], u.port or 80
rest = u.path or "/"
if u.query:
    rest += "?" + u.query
s = socket.create_connection((host, port), timeout=5)
s.sendall(b"GET " + rest.encode() + b" HTTP/1.0\r\nHost: " + (u.hostname or host).encode() + b"\r\n\r\n")
buf = b""
s.settimeout(10)
while b"\r\n\r\n" not in buf:
    chunk = s.recv(65536)
    if not chunk: break
    buf += chunk
status = buf.split(b"\r\n", 1)[0].decode("utf-8", "replace") if buf else "NO-RESPONSE"
s.close()
print(status)
PY
    }
    _srv_code_p=$(_srv_check_url "$_srv_purl")
    _srv_code_a=$(_srv_check_url "$_srv_aurl")
    case "$_srv_code_p" in *200*) : ;; *) fail "server gate: the payload is not being served at ${_srv_purl} (got: ${_srv_code_p}) -- the guest's fetcher would refuse it at install time" ;; esac
    case "$_srv_code_a" in *200*) : ;; *) fail "server gate: the asset bundle is not being served at ${_srv_aurl} (got: ${_srv_code_a}) -- the guest's fetcher would refuse it at install time" ;; esac
    echo "  both artifacts answer 200 on the gate's server"
elif [ "$NCZ_GATE_SERVER" = 1 ]; then
    # Negative run: the server is deliberately absent. The guest's fetcher
    # must fail loud and bounded; phase 2 and the finish checks below are
    # replaced by the no-rootfs assertions at the end of this gate.
    echo "  NEGATIVE run: the payload HTTP server is OFF; the install must fail within the deadline and leave no rootfs"
fi

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
_NEG_T0=$(date +%s)
# Sample the running installer over its diagnostics SSH (2225 -> guest 22) for
# the whole of phase 1: brltty must never run and tty1 must never be clamped
# (build/kvm-installer-probe.sh; judged in step 5).
PROBE_LOG="$WORK/installer-probe.log"
rm -f "$PROBE_LOG"
"$SCRIPT_DIR/kvm-installer-probe.sh" sample "$FWD_SSH_INSTALL" "$PROBE_LOG" 15 &
PROBE_PID=$!
trap 'kill "$PROBE_PID" 2>/dev/null; wait "$PROBE_PID" 2>/dev/null; ncz_srv_cleanup' EXIT
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
trap 'kill "$QEMU_PID" "$PROBE_PID" 2>/dev/null; wait "$QEMU_PID" "$PROBE_PID" 2>/dev/null; ncz_srv_cleanup; exit 130' INT TERM
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
    # NEGATIVE server run: the fetcher gives up on its own bounded deadline
    # (10 retries + backoff, overall 1800s), the r159 stub exits and d-i
    # aborts -- none of the desktop terminal markers above appear. The moment
    # the loud [FETCH] failure is on the serial console the guest is stopped:
    # the no-rootfs assertions below need no live guest.
    if [ "$NCZ_GATE_SERVER" = 1 ] && [ "$NCZ_GATE_SERVER_OFFLINE" = 1 ] \
        && [ -s "$S0" ] && sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' "$S0" 2>/dev/null | tr -s ' ' \
        | grep -aE '\[FETCH\] (HARD FAIL|FATAL)' >/dev/null; then
        echo "  fetcher gave up (loud, bounded); stopping the guest"
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
# Phase 1 is over: the guest fetched (or failed to fetch) its payload, and
# the installed system boots offline, so the payload server stops here.
ncz_srv_cleanup
trap - EXIT
set -e
cat "$S0" >> "$ILOG" 2>/dev/null
date -u +"  ended   %H:%M:%SZ  (qemu rc=$irc)"

# --- NEGATIVE server run (NCZ_GATE_SERVER_OFFLINE=1): assert loud, bounded,
# and nothing installed. The guest is off; everything below is read from the
# serial log and the target disk without re-powering it.
if [ "$NCZ_GATE_SERVER" = 1 ] && [ "$NCZ_GATE_SERVER_OFFLINE" = 1 ]; then
    _neg_dt=$(( $(date +%s) - _NEG_T0 ))
    [ "$_neg_dt" -le "$INSTALL_TIMEOUT" ] \
        || fail "negative server run: the install ran ${_neg_dt}s, past the ${INSTALL_TIMEOUT}s deadline -- the fetch failure was not bounded"
    echo "  negative run: phase 1 finished after ${_neg_dt}s (deadline ${INSTALL_TIMEOUT}s)"
    ncz_norm_log() {
        sed 's/\x1b\[[0-9;?]*[A-Za-z]//g; s/\x1b[()][A-Z0-9]//g' "$1" | tr '\r' '\n' | tr -s ' '
    }
    ncz_norm_log "$ILOG" | grep -aqE '\[FETCH\] (HARD FAIL|FATAL)' \
        || fail "negative server run: the guest failed WITHOUT a loud [FETCH] failure on the serial console -- a silent fetch failure would leave a headless box with no rootfs and no message"
    echo "  negative run: the fetch failure was loud on the serial console"
    # Nothing unverified may reach the disk. Convert the target (it may be
    # blank, partitioned-but-unwritten, or carry a partial root) and assert
    # no population: no os-release, no installed marker, no dpkg database.
    mkdir -p "$EVIDENCE"
    EVIDENCE_DISK="$WORK/.target-evidence.raw"
    EVIDENCE_ROOT="$WORK/.target-root-evidence.raw"
    rm -f "$EVIDENCE_DISK" "$EVIDENCE_ROOT"
    if qemu-img convert -S 4k -O raw "$DISK" "$EVIDENCE_DISK" >/dev/null 2>&1; then
        ROOT_PART=$(ncz_last_partnum "$EVIDENCE_DISK" || true)
        if [ -n "$ROOT_PART" ] && [ "$ROOT_PART" -ge 1 ] 2>/dev/null; then
            ROOT_LBA=$("$SGDISK" -i "$ROOT_PART" "$EVIDENCE_DISK" | sed -n 's/^First sector:[[:space:]]*\([0-9]\+\).*/\1/p')
            ROOT_END_LBA=$("$SGDISK" -i "$ROOT_PART" "$EVIDENCE_DISK" | sed -n 's/^Last sector:[[:space:]]*\([0-9]\+\).*/\1/p')
            if [ -n "$ROOT_LBA" ] && [ -n "$ROOT_END_LBA" ]; then
                if qemu-img convert --image-opts -S 4k -O raw \
                    "driver=raw,file.driver=file,file.filename=$EVIDENCE_DISK,offset=$((ROOT_LBA * 512)),size=$(( (ROOT_END_LBA - ROOT_LBA + 1) * 512 ))" \
                    "$EVIDENCE_ROOT" >/dev/null 2>&1; then
                    _neg_osrel="$WORK/.neg-osrel"; rm -f "$_neg_osrel"
                    _neg_installed="$WORK/.neg-installed"; rm -f "$_neg_installed"
                    _neg_varls="$WORK/.neg-varls"; rm -f "$_neg_varls"
                    "$DEBUGFS" -R "dump /etc/os-release $_neg_osrel" "$EVIDENCE_ROOT" >/dev/null 2>&1 || true
                    "$DEBUGFS" -R "dump /target/.installed $_neg_installed" "$EVIDENCE_ROOT" >/dev/null 2>&1 || true
                    "$DEBUGFS" -R "ls -l /var/lib/dpkg" "$EVIDENCE_ROOT" > "$_neg_varls" 2>&1 || true
                    if [ -s "$_neg_osrel" ]; then
                        fail "negative server run: /etc/os-release on the target disk -- the failed fetch INSTALLED a rootfs (an unverified or half-written extract reached the disk)"
                    fi
                    if [ -s "$_neg_installed" ]; then
                        fail "negative server run: an extraction ran despite the fetch failure"
                    fi
                    if grep -q '^Inode:' "$_neg_varls"; then
                        fail "negative server run: /var/lib/dpkg on the target disk -- debootstrap wrote to the target despite the fetch failure"
                    fi
                    echo "  negative run: the root partition holds no os-release, no extracted tree, no dpkg database -- nothing was installed"
                fi
            fi
        fi
    fi
    rm -f "$EVIDENCE_DISK" "$EVIDENCE_ROOT" "$_neg_osrel" "$_neg_installed" "$_neg_varls" 2>/dev/null || true
    ncz_srv_cleanup
    trap - EXIT
    echo
    echo "GATE PASS (server-offline-negative): the fetch failure was loud and bounded and left no half-written rootfs"
    echo "WORK=$WORK DISK=$DISK VARS=$VARS CODE=$CODE"
    exit 0
fi

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
if [ "$NCZ_GATE_SERVER" != 1 ] && grep -qE "Failed to run preseeded command|failed with exit code|install aborts|70-bootloader\.sh FAILED rc=|Post-install failed: bootloader rc=|refusing to ship a broken install|refusing to boot" "$ILOG"; then
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
# MAGNETAR(server): the payload came off the network; prove the fetcher
# fetched it and verified the sha256 BEFORE use (its own [FETCH] lines on the
# serial console, which ncz-fetch-payload.sh tees to the serial device).
if [ "$NCZ_GATE_SERVER" = 1 ] && [ "$NCZ_GATE_SERVER_OFFLINE" != 1 ]; then
    # The fetcher logs per artifact ("[FETCH] base.squashfs verified sha256=...",
    # "[FETCH] ncz-assets-<arch>.tar.gz verified sha256=...") and a final
    # "all manifest artifacts fetched and verified" line; idempotent re-runs
    # print "already present and verified" instead, so accept either form.
    ncz_norm_log "$ILOG" | grep -aqE '\[FETCH\] .* (verified sha256=|already present and verified|already fetched and unpacked)' \
        || fail "server gate: the install finished but the serial log has no '[FETCH] ... verified sha256=' line -- the payload was never fetched+verified (it may have come from a stale staging root instead of the network)"
    ncz_norm_log "$ILOG" | grep -aq 'all manifest artifacts fetched and verified' \
        || fail "server gate: the fetcher never reported 'all manifest artifacts fetched and verified'"
    echo "  server gate: payload fetched from ${SRV_URL_BASE} and sha256-verified by the guest before use"
    # The headless server contract on the installed root (debugfs reads,
    # rootless): sshd must be ENABLED (48-server-variant.sh belt-and-
    # suspenders + 35-ssh.sh), and the telnet tiers must not be: :23 is
    # 36-telemetry's telnetd (openbsd-inetd socket or busybox telnetd
    # socket unit), :2323 is 37-failsafe-access's static busybox telnetd
    # (ncz-failsafe.service). The server variant (BUILD_VARIANT=server) does
    # not install 37 (mgmt-container off), and 48 masks the recovery
    # surface; ssh is the only remote access the variant ships.
    _ssh_want="$WORK/.ssh-want"
    # The normal path deleted EVIDENCE_ROOT already; the server assertions
    # need it, so convert the root partition ourselves (rootless, same way
    # the negative run does).
    _SRV_ROOT="$WORK/.server-root.raw"
    if [ -s "$DISK" ] && ! [ -f "$_SRV_ROOT" ]; then
        _SRV_EVD="$WORK/.server-evidence.raw"
        if qemu-img convert -S 4k -O raw "$DISK" "$_SRV_EVD" >/dev/null 2>&1; then
            _SRV_PART=$(ncz_last_partnum "$_SRV_EVD" || true)
            if [ -n "$_SRV_PART" ] && [ "$_SRV_PART" -ge 1 ] 2>/dev/null; then
                _SRV_LBA=$("$SGDISK" -i "$_SRV_PART" "$_SRV_EVD" | sed -n 's/^First sector:[[:space:]]*\([0-9]\+\).*/\1/p')
                _SRV_END=$("$SGDISK" -i "$_SRV_PART" "$_SRV_EVD" | sed -n 's/^Last sector:[[:space:]]*\([0-9]\+\).*/\1/p')
                if [ -n "$_SRV_LBA" ] && [ -n "$_SRV_END" ]; then
                    qemu-img convert --image-opts -S 4k -O raw \
                        "driver=raw,file.driver=file,file.filename=$_SRV_EVD,offset=$((_SRV_LBA * 512)),size=$(( (_SRV_END - _SRV_LBA + 1) * 512 ))" \
                        "$_SRV_ROOT" >/dev/null 2>&1 || true
                fi
            fi
            rm -f "$_SRV_EVD"
        fi
    fi
    EVIDENCE_ROOT="$_SRV_ROOT"
    "$DEBUGFS" -R "ls -p /etc/systemd/system/multi-user.target.wants" "$EVIDENCE_ROOT" > "$_ssh_want" 2>&1 || true
    if grep -q 'ssh.service' "$_ssh_want"; then
        echo "  server gate: ssh.service is enabled on the installed root (SSH listens on first boot)"
    else
        fail "server gate: ssh.service is not enabled under multi-user.target.wants -- a headless server that cannot be reached over SSH"
    fi
    _telnet_wants=""
    for _u in /etc/systemd/system/openbsd-inetd.service /etc/systemd/system/inetd.service \
              /etc/systemd/system/busybox-telnetd.socket /etc/systemd/system/ncz-failsafe.service; do
        if "$DEBUGFS" -R "stat ${_u#?}" "$EVIDENCE_ROOT" 2>&1 | grep -q '^Inode:'; then
            _telnet_wants="$_telnet_wants ${_u##*/}"
        fi
    done
    if [ -n "$_telnet_wants" ]; then
        fail "server gate: telnet surface installed on a headless server variant (SSH is the only remote access the variant ships):$_telnet_wants"
    fi
    rm -f "$_ssh_want"
    echo "  server gate: no telnet surface on the installed root (:23/:2323 would not listen)"
fi
[ -z "$OPTION_FAIL" ] || fail "the install does not match the selected options '$GATE_COMPONENTS'${OPTION_FAIL}"
echo "  installed layout and boot menu match the options '$GATE_COMPONENTS'"
# MAGNETAR(server): the server menu is Console + Rescue Partition ONLY --
# no graphical/Default entry, no Mali/Panthor, no "Rescue / No Accelerators"
# entry (assets/refind/ncz-refind-refresh.sh gates these on NCZ_VARIANT=server;
# the amd64 generator drops them the same way).
if [ "$NCZ_GATE_SERVER" = 1 ] && [ -s "$EVIDENCE/installed-refind.conf" ]; then
    _m_console=$(grep -c '^menuentry .*Console' "$EVIDENCE/installed-refind.conf")
    _m_rp=$(grep -c '^menuentry .*Rescue Partition' "$EVIDENCE/installed-refind.conf")
    _m_total=$(grep -c '^menuentry ' "$EVIDENCE/installed-refind.conf")
    [ "$_m_console" -ge 1 ] || fail "server gate: the installed rEFInd menu has no Console entry"
    [ "$_m_rp" -ge 1 ] || fail "server gate: the installed rEFInd menu has no Rescue Partition entry"
    [ "$_m_total" -le 2 ] || fail "server gate: the installed rEFInd menu has $_m_total entries (server menu is Console + Rescue Partition only; got: $(grep '^menuentry ' "$EVIDENCE/installed-refind.conf" | sed 's/^menuentry \"//; s/\" {.*//' | sort | paste -sd', ' -))"
    if grep -qE '^menuentry .*(\(Default\)|Mali|Panthor|Rescue / No Accelerators)' "$EVIDENCE/installed-refind.conf"; then
        fail "server gate: the installed rEFInd menu still carries a desktop/graphical entry: $(grep -E '^menuentry .*(\(Default\)|Mali|Panthor|Rescue / No Accelerators)' "$EVIDENCE/installed-refind.conf" | head -3)"
    fi
    grep -qE '^default_selection ".*Console' "$EVIDENCE/installed-refind.conf" \
        || fail "server gate: the installed rEFInd default_selection is not a Console entry (got: $(grep '^default_selection' "$EVIDENCE/installed-refind.conf"))"
    echo "  server gate: installed boot menu is Console + Rescue Partition, default on the Console entry"
fi
# MAGNETAR(server): the installed root must carry NO desktop layer. The
# server variant skips post-install/20-desktop.sh (BUILD_VARIANT=server), so
# none of the packages that hook installs may be present. dpkg's status file
# is read from the installed root with debugfs; a stray "install ok
# installed" stanza for any of them is a desktop leak that would have pulled
# the headless build back into a graphical one.
if [ "$NCZ_GATE_SERVER" = 1 ] && [ "$NCZ_GATE_SERVER_OFFLINE" != 1 ]; then
    _dpkg_status="$WORK/.server-dpkg-status"
    "$DEBUGFS" -R "dump /var/lib/dpkg/status $_dpkg_status" "$EVIDENCE_ROOT" >/dev/null 2>&1 || true
    if [ -s "$_dpkg_status" ]; then
        _desk_pkgs="greetd libgtk-4-1 xwayland swaybg fuzzel foot lightdm gdm3 google-chrome-stable ncz-singularity-desktop"
        _leak=""
        for _dp in $_desk_pkgs; do
            if awk -v p="$_dp" '/^Package:/ {pk=$2} /^Status:/ {st=$0} /^$/ {if (pk==p && st ~ /install ok installed/) f=1; pk=""; st=""} END {if (pk==p && st ~ /install ok installed/) f=1; exit !f}' "$_dpkg_status"; then
                _leak="$_leak $_dp"
            fi
        done
        if [ -n "$_leak" ]; then
            fail "server gate: desktop packages installed on the server root (the server variant must skip post-install/20-desktop.sh):$_leak"
        fi
        # The BUILD_VARIANT stamp the variant hooks read must say server.
        _bv="$WORK/.server-variant"
        "$DEBUGFS" -R "dump /usr/local/lib/cix-installer/BUILD_VARIANT $_bv" "$EVIDENCE_ROOT" >/dev/null 2>&1 || true
        if [ -s "$_bv" ]; then
            _bv_val=$(tr -d ' \t\r\n' < "$_bv")
            case "$_bv_val" in
                server|headless) echo "  server gate: BUILD_VARIANT=$_bv_val on the installed root" ;;
                *) fail "server gate: BUILD_VARIANT on the installed root is '$_bv_val' (server install must record server/headless)" ;;
            esac
        else
            fail "server gate: /usr/local/lib/cix-installer/BUILD_VARIANT is missing from the installed root (late.sh never recorded the variant)"
        fi
    else
        fail "server gate: could not read /var/lib/dpkg/status from the installed root -- cannot prove the desktop layer is absent"
    fi
    rm -f "$_dpkg_status" "$WORK/.server-variant" "$_SRV_ROOT"
    EVIDENCE_ROOT=""  # the raw root image is consumed; nothing downstream re-reads it
fi
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
if [ "$NCZ_GATE_SERVER" = 1 ]; then
    echo "    skipped (server run: the installer UI is the desktop UI, which ran in the full-option set)"
elif [ "${NCZ_GATE_UI_CHECK:-1}" = 0 ]; then
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
