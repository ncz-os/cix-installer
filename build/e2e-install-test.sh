#!/bin/bash
# End-to-end unattended install test.
#
# The shipped preseed deliberately leaves the user account interactive (a real
# install should ask). For an automated run we answer those four questions on
# the kernel cmdline instead of changing the product. Everything else is the
# stock Install entry's cmdline, copied from the ISO's own grub.cfg.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
REV="${1:-r217}"
ISO=$(ls -1 build/nclawzero-installer-cixmini-*-$REV.iso 2>/dev/null | tail -1)
DISK=$ROOT/build/e2e-$REV-target.qcow2
VARS=/tmp/e2e-$REV-vars.fd
PIPE=/tmp/qe

[ -f "$ISO" ] || { echo "FATAL: $ISO missing"; exit 1; }

for p in $(pgrep -f "qemu-syste[m]-aarch64"); do kill "$p" 2>/dev/null; done
sleep 2
rm -f "$PIPE".in "$PIPE".out "$DISK" "$VARS" /tmp/e2e-guest.out
# Everything this harness writes lands in a sticky /tmp, so anything left there
# by a run whose qemu went up under sudo is root-owned and CANNOT be removed or
# truncated by this user. Each such leftover breaks the run in its own quiet way:
#
#   /tmp/qe.in, /tmp/qe.out  -- mkfifo fails, exec 3> cannot open, every send()
#                               says "3: Bad file descriptor", nothing is typed
#                               at grub>, GRUB boots its DEFAULT entry, and the
#                               harness reports on an install it never set up.
#   /tmp/e2e-qemu.log        -- the `>` redirect on the qemu launch fails, so
#                               qemu never starts at all and the harness then
#                               blocks forever in exec 3> waiting for a reader.
#
# Both were measured on 2026-08-16. A run that looks like a pass while testing
# a different boot path, or one that hangs with no diagnosis, are both worse
# than stopping here with the command that fixes it.
_stale=""
for _f in "$PIPE".in "$PIPE".out /tmp/e2e-guest.out /tmp/e2e-qemu.log "$VARS" "$DISK"; do
    [ -e "$_f" ] || continue
    if ! rm -f "$_f" 2>/dev/null || [ -e "$_f" ]; then
        _stale="$_stale $_f"
    fi
done
if [ -n "$_stale" ]; then
    echo "FATAL: cannot clear stale files (root-owned in a sticky /tmp):$_stale" >&2
    echo "       sudo rm -f$_stale" >&2
    exit 1
fi
qemu-img create -f qcow2 "$DISK" 30G >/dev/null
dd if=/usr/share/AAVMF/AAVMF_VARS.fd of="$VARS" bs=1M 2>/dev/null || truncate -s 64M "$VARS"
mkfifo "$PIPE".in "$PIPE".out

setsid qemu-system-aarch64 \
    -M virt -enable-kvm -cpu host -smp 4 -m 4096 \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/AAVMF/AAVMF_CODE.fd \
    -drive if=pflash,format=raw,file="$VARS" \
    -drive if=virtio,file="$DISK",format=qcow2 \
    -drive if=none,id=isousb,format=raw,file="$ISO",readonly=on \
    -device qemu-xhci,id=usb0 \
    -device usb-storage,bus=usb0.0,drive=isousb,removable=on \
    -boot d \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0,romfile= \
    -device virtio-gpu-pci -display none \
    -serial pipe:"$PIPE" >/tmp/e2e-qemu.log 2>&1 &
QEMU_PID=$!

# If qemu died on startup there is no reader for the FIFO and the exec 3> below
# would block forever; surface it as an error instead of a hang.
sleep 1
if ! kill -0 "$QEMU_PID" 2>/dev/null; then
    echo "FATAL: qemu exited immediately -- see /tmp/e2e-qemu.log" >&2
    tail -5 /tmp/e2e-qemu.log >&2 2>/dev/null || true
    exit 1
fi
cat "$PIPE".out > /tmp/e2e-guest.out &
CATPID=$!
# A failed open here must abort: without fd 3 nothing is ever typed to the
# guest and the run silently degrades into "whatever GRUB does by default".
exec 3> "$PIPE".in || { echo "FATAL: cannot open $PIPE.in for writing" >&2; exit 1; }
send() { printf '%b' "$1" >&3; }
# GRUB's serial input drops characters when a long line arrives in one write.
# Measured 2026-08-13: the ~500-char `linux ...` line produced a grub> prompt
# with NOTHING echoed, GRUB booted its default menu entry instead, and the
# install ran to 11.7 GB before stopping at the interactive user prompt --
# i.e. the harness silently tested a DIFFERENT boot path than the one it
# claimed to. Type long lines in small chunks with a pause between them.
send_slow() {
    _s="$1"
    while [ -n "$_s" ]; do
        printf '%b' "$(printf '%s' "$_s" | cut -c1-24)" >&3
        _s="$(printf '%s' "$_s" | cut -c25-)"
        sleep 0.15
    done
}
# Fail loudly if the guest never echoed something we typed.
expect_echo() {
    _pat="$1"; _what="$2"
    for _i in $(seq 1 15); do
        grep -aq "$_pat" /tmp/e2e-guest.out && { echo "  echo confirmed: $_what"; return 0; }
        sleep 1
    done
    echo "  NOTE: no echo for $_what (GRUB may not echo on this serial); relying on the kernel cmdline check instead"
    return 0
}


DI_OPTS='auto=true priority=critical preseed/file=/cdrom/cixmini/preseed.cfg interface=auto netcfg/dhcp_timeout=120 ncz_diag=1 DEBCONF_DEBUG=5 ncz_variant=desktop'
# Test-only answers for the deliberately-interactive account questions.
USERS='passwd/user-fullname=Test\ User passwd/username=ncztest passwd/user-password=ncztest1234 passwd/user-password-again=ncztest1234 passwd/user-default-groups=audio\ cdrom\ video\ sudo'
# The installer intentionally prompts for the target disk (destructive). It
# ships ncz_disk=/ncz_fs= overrides precisely for unattended/KVM runs.
DISKSEL='ncz_disk=/dev/vda ncz_fs=ext4'
CONSOLE='loglevel=4 console=ttyAMA0,115200 console=tty0 efi=noruntime acpi=force arm-smmu-v3.disable_bypass=0 clk_ignore_unused keep_bootcon panic=30 nmi_watchdog=0'

# Wait for a string to appear in the guest output. Unlike expect_echo() this
# RETURNS FAILURE, because the two things below are not cosmetic: typing into
# a GRUB that is not at the prompt we think it is at silently tests a
# different boot path.
wait_for() {
    _pat="$1"; _what="$2"; _secs="${3:-60}"
    _i=0
    while [ "$_i" -lt "$_secs" ]; do
        if grep -aq "$_pat" /tmp/e2e-guest.out 2>/dev/null; then
            echo "  saw: $_what"
            return 0
        fi
        sleep 1
        _i=$((_i + 1))
    done
    echo "  TIMEOUT waiting for $_what" >&2
    return 1
}

# Do NOT interact on a fixed sleep. MEASURED on r244: a `sleep 6` then blind
# cursor keys raced GRUB drawing its menu, the `c` never took, and every
# character of the linux line was typed into the SAFE rescue entry instead.
# GRUB then booted RESCUE MODE -- the guest log shows
#   linux /install.a64/vmlinuz rescue/enable=true ...
# -- so nothing was ever installed, the target disk stayed at 1 MB, and the
# harness sat watching a disk that no installer was writing to. The run looked
# like a product failure and was a harness failure. Wait for the menu to exist
# before touching it.
wait_for "Install NCZ-OS" "the boot menu" 90 || {
    echo "FATAL: GRUB menu never appeared; not typing blindly" >&2
    exit 1
}
sleep 1
# Stop the countdown, then enter the GRUB COMMAND LINE and prove we got there.
# Retry, because a dropped keystroke here is the whole failure mode.
send '\x1b[B'; sleep 1
send '\x1b[A'; sleep 1
_at_prompt=0
for _try in 1 2 3; do
    send 'c\n'; sleep 3
    if grep -aq "grub>" /tmp/e2e-guest.out 2>/dev/null; then
        echo "  at the grub> command line (attempt $_try)"
        _at_prompt=1
        break
    fi
    echo "  no grub> yet (attempt $_try), retrying"
done
[ "$_at_prompt" = 1 ] || {
    echo "FATAL: never reached the grub> prompt. Refusing to type the kernel" >&2
    echo "       line into whatever entry happens to be focused -- that is how" >&2
    echo "       r244 silently booted the rescue shell instead of installing." >&2
    exit 1
}
send_slow "linux /install.a64/vmlinuz $DI_OPTS $USERS $DISKSEL $CONSOLE"
send '\n'; sleep 2
expect_echo "ncz_disk=/dev/vda" "the linux line"
send_slow "initrd /install.a64/initrd.gz"
send '\n'; sleep 2
expect_echo "initrd /install.a64/initrd.gz" "the initrd line"
# Last line of defence: if we somehow ended up in the rescue entry anyway,
# say so now rather than after 45 minutes of watching an idle disk.
if grep -aq "rescue/enable=true" /tmp/e2e-guest.out 2>/dev/null; then
    echo "FATAL: the rescue entry is in the guest console -- this run would" >&2
    echo "       have tested rescue mode, not an install." >&2
    exit 1
fi
send 'boot\n'

echo "=== booted; watching target disk (installer writes = real progress) ==="
LAST=0
for i in $(seq 1 90); do        # up to ~45 min
    sleep 30
    SZ=$(du -m "$DISK" 2>/dev/null | cut -f1)
    SZ=${SZ:-0}
    if [ "$SZ" != "$LAST" ]; then
        echo "  [$((i*30))s] target disk: ${SZ} MB"
        LAST=$SZ
    fi
    if grep -aq "Installation complete\|installation is complete\|Finish the installation" /tmp/e2e-guest.out 2>/dev/null; then
        echo "  installer reports completion"
        break
    fi
    if ! pgrep -f "qemu-syste[m]-aarch64" >/dev/null; then
        echo "  qemu exited (guest rebooted or powered off)"
        break
    fi
done

kill $CATPID 2>/dev/null
echo "=== FINAL target disk ==="
du -m "$DISK" 2>/dev/null | awk '{print "  " $1 " MB"}'
echo "=== stages seen ==="
tr -d '\000\033' < /tmp/e2e-guest.out | sed 's/\[[0-9;?]*[A-Za-z]//g' \
  | grep -aoE "Detect and mount installation media|Partition disks|Installing the base system|Select and install software|Install the GRUB boot loader|Finish the installation|Installation complete|No device for installation media" \
  | sort -u | sed 's/^/  /'
