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
# owned, so the build user could not `rm -rf` a finished run dir (operator
# 2026-10-11). Hand the whole tree back to the invoking user on EVERY exit path;
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
    serial = [c for c in consoles if c.startswith('console=ttyS')]
    other = [c for c in consoles if not c.startswith('console=ttyS')]
    # Reordering alone is a no-op here: the shipped entry carries only
    # console=tty0, so `serial` is empty and d-i keeps logging to the VGA
    # console that this headless gate cannot read. Add one when absent.
    if not serial:
        serial = ['console=ttyS0,115200']
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
echo "  accel  : $ACCEL cpu=$CPU mem=${MEM}M smp=$SMP"
echo "  target : $DISK (${DISK_GB}G)"

rm -f "$DISK" "$VARS"
qemu-img create -f qcow2 "$DISK" "${DISK_GB}G" >/dev/null || { echo "GATE FAIL: qemu-img" >&2; exit 2; }
cp "$SRCVARS" "$VARS"

S0="$WORK/serial0.log"; ILOG="$WORK/install.log"; BLOG="$WORK/boot.log"
EVIDENCE="$WORK/target-logs"
rm -f "$S0" "$ILOG" "$BLOG" "$WORK/boot-serial0.log"
rm -rf "$EVIDENCE"

fail() { echo; echo "GATE FAIL: $*" >&2; exit 1; }

echo
echo "[4/6] phase 1: install (timeout ${INSTALL_TIMEOUT}s)"
date -u +"  started %H:%M:%SZ"
set +e
timeout "$INSTALL_TIMEOUT" "$QEMU" \
  -M "$MACHINE" -accel "$ACCEL" -cpu "$CPU" -smp "$SMP" -m "$MEM" \
  -drive if=pflash,format=raw,unit=0,file="$CODE",readonly=on \
  -drive if=pflash,format=raw,unit=1,file="$VARS" \
  -drive file="$DISK",if=virtio,format=qcow2 \
  -drive file="$TEST_IMG",if=none,id=usbstick,format=raw \
  -device qemu-xhci,id=xhci \
  -device usb-storage,bus=xhci.0,drive=usbstick,bootindex=1 \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2225-:22,hostfwd=tcp:127.0.0.1:18080-:8080 -device virtio-net-pci,netdev=n0,romfile= \
  -object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-pci,rng=rng0 \
  -serial "file:$S0" \
  -display none -no-reboot \
  > "$ILOG" 2>&1
irc=$?
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
if qemu-img convert -S 4k -O raw "$DISK" "$EVIDENCE_DISK"; then
    ROOT_LBA=$("$SGDISK" -i 3 "$EVIDENCE_DISK" | sed -n 's/^First sector:[[:space:]]*\([0-9]\+\).*/\1/p')
    ROOT_END_LBA=$("$SGDISK" -i 3 "$EVIDENCE_DISK" | sed -n 's/^Last sector:[[:space:]]*\([0-9]\+\).*/\1/p')
    if [ -n "$ROOT_LBA" ] && [ -n "$ROOT_END_LBA" ]; then
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
                    if [ -s "$SCRIPT_DIR/../manifests/install-extra.pkgs" ] && sed 's/#.*//' "$SCRIPT_DIR/../manifests/install-extra.pkgs" | awk 'NF {print $1}' | grep -qx ncz-screensavers; then
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
                "$VERIFIER" "$EVIDENCE_ROOT" "$DEBUGFS" "$ARCH" || rc_v=$?
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

# The gaps this session fixed, each with its own message, so a failure names
# the finding rather than just "install failed".
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
if ncz_norm_log "$ILOG" | grep -qai "Ship-critical post-install hooks failed"; then
    ncz_norm_log "$ILOG" | grep -ai -B2 -A2 "Ship-critical post-install hooks failed" | head -20 >&2
    fail "a ship-critical post-install hook failed -- the install is not shippable"
fi

grep -qE "post-install hooks finished|finalizing apt sources|forcing clean reboot|nclawzero post-install complete|Post-install completed successfully|Completed with optional-step warnings" "$ILOG" \
  || fail "install did not reach the finish stage -- qemu rc=${irc:-?} (rc=124 means the ${INSTALL_TIMEOUT}s timeout expired; any other rc means the run was terminated early, which is NOT a timeout) -- see $ILOG"
echo "  install reached the finish stage with no ship-critical hook failure"
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

# First-boot health: the installed system writes `systemctl --failed` to
# /var/log/ncz-first-boot-failed.txt 30 s after multi-user.target (97-firstboot-report.sh). Read it
# off the disk phase 2 just booted; any failed unit that is not on the allow-list fails the gate.
if true; then   # both architectures
    echo
    echo "  first-boot failed-unit report"
    FBR="$WORK/first-boot-failed.txt"; rm -f "$FBR"
    FB_DISK="$WORK/.fb-disk.raw"; FB_ROOT="$WORK/.fb-root.raw"; rm -f "$FB_DISK" "$FB_ROOT"
    if qemu-img convert -S 4k -O raw "$DISK" "$FB_DISK"; then
        FB_S=$("$SGDISK" -i 3 "$FB_DISK" | sed -n 's/^First sector:[[:space:]]*\([0-9]\+\).*/\1/p')
        FB_E=$("$SGDISK" -i 3 "$FB_DISK" | sed -n 's/^Last sector:[[:space:]]*\([0-9]\+\).*/\1/p')
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
    case "$WP_RC" in
        0|75) echo "    wallpaper helper smoke: fetch --if-stale exit $WP_RC (0 = cache fresh/fetched, 75 = offline)" ;;
        "")   fail "the first-boot report has no wallpaper-bing result (ncz-wallpaper-bing missing or the report script did not run it)" ;;
        *)    fail "ncz-wallpaper-bing fetch --if-stale exited $WP_RC in the guest (expected 0 or 75); see the guest's /var/log/ncz-wallpaper-smoke.log" ;;
    esac
    FAILED_UNITS="$(grep -vE '^#|^[[:space:]]*$' "$FBR" | awk '{print $1}' | sed 's/^[^A-Za-z0-9_@.-]*//' | sort -u || true)"  # grep exits 1 when NO unit failed; under pipefail+set -e that ended the gate silently on amd64
    BAD=""
    for u in $FAILED_UNITS; do
        if [ -f "$ALLOW" ] && grep -vE '^#|^[[:space:]]*$' "$ALLOW" | awk '{print $1}' | grep -qxF "$u"; then
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
if [ "${NCZ_SKIP_UI_CHECK:-0}" = 1 ]; then
    echo "    SKIPPED by NCZ_SKIP_UI_CHECK=1 (not for shipping images)"
elif [ -x "$SCRIPT_DIR/kvm-installer-ui-check.sh" ]; then
    bash "$SCRIPT_DIR/kvm-installer-ui-check.sh" "$IMG" "$ARCH" "$WORK/ui-check" 2>&1 | sed 's/^/    /'
    [ "${PIPESTATUS[0]}" = 0 ] || fail "the installer console UI check failed (see $WORK/ui-check): chatter over the dialogs, an unbranded dialog, or a blank screen after the component dialog"
else
    fail "build/kvm-installer-ui-check.sh is missing"
fi

echo
echo "GATE PASS (phase 1+2): $(basename "$IMG") installs and boots"
echo "WORK=$WORK DISK=$DISK VARS=$VARS CODE=$CODE"
