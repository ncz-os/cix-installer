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

# ---------------------------------------------------------------------------
# QEMU-only console + preseed patch (mandatory under -display none)
# ---------------------------------------------------------------------------
# Why this exists (the bug it fixes, measured 2026-08-21 on ARGOS):
#
#   The shipped ISO's install menuentry appends
#       console=tty0 console=ttyAMA2,115200
#   ttyAMA2 is the O6/O6N hardware UART — it does NOT exist as a /dev node
#   under QEMU's virt board (which only instantiates ttyAMA0). d-i runs with
#   auto=true (from DI_OPTS), which trips reopen-console's "preseed" path:
#   that path picks the kernel's "preferred" console = LAST console= on the
#   cmdline, and runs d-i on EXACTLY ONE console.
#
#   reopen-console's preferred-console selection is NOT gated by the /dev
#   node actually existing (only the separate "which consoles get d-i spawned
#   on" list is). With console=ttyAMA2 last, reopen-console picks ttyAMA2,
#   steal-ctty fails with ENOENT, and d-i's actual startup (inittab respawn
#   via kill -HUP 1) either lands on some other console our serial capture
#   isn't watching OR falls back to tty1.
#
#   This gate runs QEMU with -display none. If reopen-console lands on tty1,
#   the kernel renders d-i into a framebuffer that has no listener and the
#   installer never progresses — the install phase times out at
#   INSTALL_TIMEOUT (5400s) and the gate fails with no useful diagnostic in
#   $ILOG. That is exactly the failure mode that has been misdiagnosed as
#   "kvm-install-gate.sh hangs" since the 2026-08-20 stale build.
#
# Fix: produce a QEMU-only patched copy of the ISO whose install cmdline has
#   console=ttyAMA0 (the UART QEMU actually has) as the LAST console= entry,
#   so reopen-console picks one that exists under QEMU. This is the same
#   patch that build/qemu-test-console-patch.sh performs for interactive
#   QEMU testing; inlined here so the gate is self-contained (no external
#   step, no chance of forgetting it on a fresh host).
#
# ALSO: the gate must boot unattended. The preseed deliberately leaves some
# questions UNSEEN so a real install stops and asks a human -- by design, not
# a gap (see preseed.cfg r177 and localization comments). The escape hatch
# d-i supports is /proc/cmdline-as-override-preseed for simple values and a
# qemutest-only preseed.cfg patch for questions that also need seen=true.
#
# ALSO: the disk-fs-chooser ALWAYS shows an interactive destructive-disk
# confirm (operator requirement 2026-07-04). Under an unattended KVM run
# there is no operator, so the confirm stalls forever. ncz_disk=/dev/vda
# (the virtio target) + ncz_fs=btrfs take the OVR_DISK auto-select path and
# the run proceeds. NEVER shipped — the qemutest ISO is a throwaway.
#
# The shipped ISO's correctness on real hardware (ttyAMA2, no test overrides)
# is preserved: this script PATCHES A COPY. The original $ISO is left
# untouched.
# ---------------------------------------------------------------------------
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

# Idempotent: if the qemutest copy already exists with the patches, re-extracting
# from a fresh $ISO rebuilds it cleanly anyway because we patch below every time.
echo "[2/6] patching kernel cmdlines: console=ttyAMA2 -> ttyAMA0, add unattended preseed overrides"
# (1) make ttyAMA0 (real under QEMU) the kernel's preferred console so
# reopen-console picks one with an existing /dev node. QEMU virt has only
# ttyAMA0 — see the section comment for why this matters under auto=true.
sed -i 's/console=ttyAMA2,115200/console=ttyAMA0,115200/g' "$CFG"
SWAPPED=$(grep -c "console=ttyAMA0,115200" "$CFG" || true)
echo "    swapped $SWAPPED console= entry/entries to ttyAMA0"
[ "$SWAPPED" -ge 1 ] || { echo "GATE FAIL: console=ttyAMA2 swap matched zero lines — grub.cfg layout may have changed"; exit 2; }

# (2) unattended preseed overrides: the preseed deliberately leaves the
# user/passwd questions UNSEEN so a real install stops for a human (by
# design, see preseed.cfg r177 comment). For unattended runs, d-i reads
# /proc/cmdline as override-preseed values. No spaces inside any value:
# the kernel cmdline tokenizer splits on whitespace, so a spaced fullname
# would silently break into extra bogus params instead of one preseed value.
sed -i 's/\(^[[:space:]]*linux[[:space:]]\+\/install\.a64\/vmlinuz.*\)loglevel=4/\1passwd\/username=nczuser passwd\/user-fullname=NCZTestUser passwd\/user-password=nczpassword123 passwd\/user-password-again=nczpassword123 loglevel=4/' "$CFG"

# (3) unattended disk selection: disk-fs-chooser ALWAYS shows an interactive
# destructive-disk confirm; under unattended KVM there is no operator. Take
# the OVR_DISK auto-select path. Never shipped — qemutest ISO only.
sed -i 's/\(^[[:space:]]*linux[[:space:]]\+\/install\.a64\/vmlinuz.*\)loglevel=4/\1ncz_disk=\/dev\/nvme0n1 ncz_fs=btrfs loglevel=4/' "$CFG"

# (3a) unattended locale + keymap selection: the shipped preseed deliberately
# leaves these unanswered so real installs use Debian's native localechooser
# and keyboard-configuration dialogs. For the gate only, patch the extracted
# qemutest ISO's preseed with standard d-i answers plus seen=true.
PSEED="$QEMU_STAGE/staging/cixmini/preseed.cfg"
[ -f "$PSEED" ] || { echo "GATE FAIL: qemutest ISO has no cixmini/preseed.cfg"; exit 2; }

# Normalize existing clock answers in place before appending the KVM-only
# block. The shipped preseed sets clock-setup/ntp=true and marks it seen for
# real installs; appending a later false value is not reliable once cdebconf
# has already consumed the earlier seen=true answer.
sed -i \
  -e 's/^d-i[[:space:]]\+time\/zone[[:space:]]\+string[[:space:]].*/d-i time\/zone string UTC/' \
  -e 's/^d-i[[:space:]]\+clock-setup\/ntp[[:space:]]\+boolean[[:space:]].*/d-i clock-setup\/ntp boolean false/' \
  "$PSEED"

cat >> "$PSEED" <<'EOF'

##############################################################################
# KVM install gate only: keep the qemutest ISO unattended while the shipped
# preseed leaves locale/keyboard unanswered for native d-i dialogs.
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

##############################################################################
# KVM install gate only: the shipped preseed deliberately leaves the operator
# account unanswered. Kernel cmdline values alone do not mark the passwd
# templates seen on current forky d-i, so user-setup can fail under
# priority=critical before the full install gate reaches post-install hooks.
##############################################################################
d-i passwd/user-fullname string NCZTestUser
d-i passwd/user-fullname seen true
d-i passwd/username string nczuser
d-i passwd/username seen true
d-i passwd/user-password password nczpassword123
d-i passwd/user-password seen true
d-i passwd/user-password-again password nczpassword123
d-i passwd/user-password-again seen true
EOF

# (3b) unattended component selection: the ncz-installer front-end shows an
# interactive multiselect dialog for OPTIONAL components (desktop /
# mgmt-container / rescue-partition) and waits
# for a human to press Enter. With no operator under -display none, the gate
# stalls there forever — same failure mode as the ttyAMA2 one but on a
# different prompt. preseed/component-selector.sh explicitly supports a
# cmdline override (`ncz_components=<comma-list>`) that bypasses the dialog
# entirely. Pin the offered FULL set: desktop still internally enables the
# browser and wallpaper hooks, so the gate keeps testing the shipped default.
sed -i 's/\(^[[:space:]]*linux[[:space:]]\+\/install\.a64\/vmlinuz.*\)loglevel=4/\1ncz_components=desktop,mgmt-container,rescue-partition loglevel=4/' "$CFG"

# (3c) unattended FINISH — late.sh's force-reboot path only fires when
# ncz_unattended=1 is in /proc/cmdline (see late.sh r181). Without it the
# installer parks at the "[!!] Finish the installation" dialog and the gate
# never sees qemu exit. Inject this token alongside the other unattended
# overrides. Never shipped — qemutest ISO only.
sed -i 's/\(^[[:space:]]*linux[[:space:]]\+\/install\.a64\/vmlinuz.*\)loglevel=4/\1ncz_unattended=1 loglevel=4/' "$CFG"

# (4) also drop the auto-attach-to-framebuffer cmdline (console=tty0) since
# we're running -display none — there's no framebuffer to render into, and
# keeping console=tty0 in the list would cause the kernel to register tty0
# as a console that d-i's "first in /proc/consoles" rule (see reopen-console
# comments in build-iso-di.sh) might pick if our swap missed a line. Belt
# and braces: only console=ttyAMA0 stays on the install cmdline.
sed -i 's/\bconsole=tty0\b//g' "$CFG"
# Clean up double-spaces left behind by the sed strips.
sed -i 's/  \+/ /g' "$CFG"

# --- MODEWATCH=1 (opt-in diagnostic): instrument the staged installer with
# a /target root-mode watcher. On ANY mode transition it dumps ps +
# syslog tail to /var/log/ncz-modewatch.log inside the installer (copied to
# /target/var/log/ when possible) and announces the transition on ttyAMA0 so
# the host-side serial capture carries the timeline. This is how you catch a
# mid-install chmod-of-/ red-handed instead of grepping source for it (the
# 2026-08-26 0700-root incident took two ship-and-discover cycles on real
# hardware; this watcher pins the culprit in one QEMU run). qemutest ISO
# only — never shipped.
if [ "${MODEWATCH:-0}" = "1" ]; then
  # NOTE: inject into disk-fs-chooser.sh, NOT extract-rootfs.sh —
  # extract-rootfs.sh is dead code (partman/late_command is not a real d-i
  # hook); disk-fs-chooser.sh actually runs via partman/early_command, so the
  # watcher is live from partman onward and observes the stub extraction.
  ERS="$QEMU_STAGE/staging/cixmini/disk-fs-chooser.sh"
  [ -f "$ERS" ] || { echo "GATE FAIL: MODEWATCH=1 but no cixmini/disk-fs-chooser.sh in staging"; exit 2; }
  MWTMP="$WORK/modewatch-snippet.sh"
  cat > "$MWTMP" <<'MODEWATCH_SNIP'
# ==== MODEWATCH (QEMU diagnostic gate only — NEVER shipped) =================
if [ ! -f /tmp/.ncz-modewatch-started ]; then
  : > /tmp/.ncz-modewatch-started
  (
    last=INIT
    while :; do
      m=$(stat -c "%a" /target 2>/dev/null || echo NONE)
      if [ "$m" != "$last" ]; then
        ts="$(date "+%s") $(date "+%T")"
        {
          echo "MODEWATCH [$ts] /target mode: $last -> $m"
          echo "MODEWATCH ps at transition:"
          ps w 2>/dev/null || ps
          echo "MODEWATCH syslog tail:"
          tail -30 /var/log/syslog 2>/dev/null
          echo "MODEWATCH ---"
        } >> /var/log/ncz-modewatch.log 2>&1
        echo "MODEWATCH [$ts] /target mode: $last -> $m" > /dev/ttyAMA0 2>/dev/null || true
        [ -d /target/var/log ] && cp /var/log/ncz-modewatch.log /target/var/log/ncz-modewatch.log 2>/dev/null
        last="$m"
      fi
      sleep 0.2 2>/dev/null || sleep 1
    done
  ) >/dev/null 2>&1 &
  echo "MODEWATCH armed (pid $!)" > /dev/ttyAMA0 2>/dev/null || true
fi
# ==== END MODEWATCH =========================================================
MODEWATCH_SNIP
  { head -1 "$ERS"; cat "$MWTMP"; tail -n +2 "$ERS"; } > "$ERS.mw"     && mv "$ERS.mw" "$ERS" && chmod +x "$ERS"
  echo "    MODEWATCH: instrumented disk-fs-chooser.sh ($(wc -l < "$ERS") lines)"
fi

# grub-script-check, if available, catches syntax errors in the patched cfg.
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
ISO="$QEMU_ISO"   # everything below gates against the patched copy

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
# Two facts drive this, both measured 2026-08-18:
#   * qemu -kernel does NOT boot this ISO's vmlinuz (49 MB EFI-stub image) --
#     150s produced zero output. So boot the REAL UEFI path, which is also the
#     path that actually ships.
#   * The shipped ISO's install menuentry appends "console=tty0 console=ttyAMA2,115200".
#     ttyAMA2 is the O6/O6N port. QEMU virt gives ttyAMA0 first, so with a single
#     -serial the installer kernel talks to a port nobody is listening to, d-i
#     falls back to tty1, and the gate watches a silent file while the install
#     stalls invisibly. That is exactly how the first v12 run "hung" with
#     target.qcow2 frozen at 196K. The PRE-FLIGHT QEMU-ONLY ISO PATCH above
#     swaps console=ttyAMA2 -> ttyAMA0 in boot/grub/grub.cfg so reopen-console
#     lands on the UART that actually exists under QEMU.
# Firmware and GRUB land on ttyAMA0; the installer kernel lands on ttyAMA0
# (after the patch above) or ttyAMA2 (on real hardware, where ttyAMA0 may not
# be the primary). Capture each to its own file and analyse them together.
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
if grep -qE "Failed to run preseeded command|failed with exit code|install aborts|FAILED rc=|refusing to ship a broken install|refusing to boot" "$ILOG"; then
  echo "--- offending output ---" >&2
  grep -nE -B3 -A6 "Failed to run preseeded command|failed with exit code|install aborts|FAILED rc=|refusing to ship a broken install|refusing to boot" "$ILOG" | head -50 >&2
  fail "the preseed/late_command failed — this is the v11 defect class"
fi
if grep -qE "Kernel panic - not syncing" "$ILOG"; then
  grep -nE -A10 "Kernel panic" "$ILOG" | head -30 >&2
  fail "kernel panic during install"
fi
grep -qE "post-install hooks finished|finalizing apt sources|forcing clean reboot|nclawzero post-install complete|Post-install completed successfully|Completed with optional-step warnings" "$ILOG" \
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
# Keep a headless framebuffer device attached: AAVMF only exposes GOP/UGA
# protocols when a graphics device exists, and installed rEFInd configs use
# "resolution max" during bootloader video setup.
timeout "$BOOT_TIMEOUT" qemu-system-aarch64 \
  -M virt -accel "$ACCEL" -cpu "$CPU" -smp "$SMP" -m "$MEM" \
  -drive if=pflash,format=raw,unit=0,file="$CODE",readonly=on \
  -drive if=pflash,format=raw,unit=1,file="$VARS" \
  -drive file="$DISK",if=none,id=hd,format=qcow2 \
  -device nvme,drive=hd,serial=ncztest01 \
  -device virtio-gpu-pci \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0,romfile= \
  -serial "file:$WORK/boot-serial0.log" -serial "file:$WORK/boot-serial1.log" \
  -serial "file:$WORK/boot-serial2.log" \
  -display none -no-reboot \
  > "$BLOG" 2>&1
cat "$WORK"/boot-serial*.log >> "$BLOG" 2>/dev/null
brc=$?
echo "  qemu rc=$brc"

grep -qE "Linux version|Booting Linux|Starting vmlinuz-" "$BLOG" \
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

# --- root-mode self-test (2026-08-26 0700-root regression class) -----------
# ncz-firstboot (written by the r159 stub in build-iso-di.sh) prints
# "NCZ-ROOTMODE: <mode>" to kmsg+console on first boot, AFTER running
# dpkg --configure -a — i.e. after the last code that runs before a user
# would reach a login screen. Assert it here so a 0700 root is a BUILD
# failure, not a discovery on real hardware hours later. The marker can be
# legitimately absent (boot timeout hit before firstboot finished under
# TCG); warn in that case rather than fail, but a PRESENT marker with a
# wrong mode is always fatal.
RM=$(grep -aoE "NCZ-ROOTMODE: [^[:space:]]+" "$BLOG" | tail -1 | awk '{print $2}')
if [ -n "$RM" ]; then
  [ "$RM" = "755" ] || [ "$RM" = "drwxr-xr-x" ] || fail "installed system reports root mode $RM (expected 755/drwxr-xr-x) — the 0700-root regression class is BACK (see docs/ISO-BUILD-GUARDRAILS.md)"
  echo "  root-mode self-test: / is 755 (NCZ-ROOTMODE marker: $RM)"
else
  echo "  WARN: no NCZ-ROOTMODE marker in boot log — firstboot may not have completed before BOOT_TIMEOUT; root mode NOT verified" >&2
fi

echo
echo "GATE PASS: $(basename "$ISO") installs and boots"
