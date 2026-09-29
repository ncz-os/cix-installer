#!/bin/bash
# build/component-prompt-gate.sh — regression gate for the INTERACTIVE
# component-prompt path: the exact path metal installs take and the one
# build/kvm-install-gate.sh deliberately bypasses.
#
# WHY THIS EXISTS (2026-08-24): every metal install since 2026-08-20 wedged at
#     main-menu: Internal error! Cannot find "ok" in menu.
# preseed/component-selector.sh showed its multiselect from a BACKGROUNDED
# subshell. POSIX gives a backgrounded command stdin from /dev/null when job
# control is off — and in the d-i postinst context stdin IS the cdebconf
# reply pipe. The subshell's commands still reached cdebconf on the inherited
# fd3, so every one of them queued a reply nobody read; from then on every
# confmodule read in the shared stream (rest of the file-preseed postinst,
# then main-menu itself) received the reply meant for an earlier command.
# main-menu's GET of debian-installer/main-menu read a stale "0 ok", treated
# the literal "ok" as the chosen menu entry, and exited — blank blue screen,
# wedged forever.
#
# The KVM install gate NEVER sees this because it injects ncz_components=
# on the cmdline, which skips the prompt branch entirely. That is how the
# bug shipped three times. This gate closes the hole:
#
#   1. patch a throwaway copy of the ISO with ONLY the QEMU console swap
#      (ttyAMA2 -> ttyAMA0) — NO ncz_components, NO other unattended
#      overrides, so the boot walks the same branch metal does;
#   2. boot it under QEMU/KVM with serial0 wired to a socket (the d-i lean
#      kernel has no virtio-gpu DRM, so the whole d-i UI runs on ttyAMA0);
#   3. wait for the prompt marker AND for the dialog body to actually be
#      drawn on the serial console;
#   4. answer it by sending a real Enter down the UART;
#   5. require the NEXT d-i dialog (localechooser's language list) to render
#      afterwards — proof main-menu survived the prompt round-trip on a
#      clean confmodule stream.
#
# PASS = prompt drawn AND answered AND the language dialog renders after it.
# FAIL = prompt fallback warning, any "Cannot find ... in menu", qemu death,
#        or no post-prompt dialog in time.
#
# Usage: build/component-prompt-gate.sh <iso> [workdir]
set -euo pipefail

ISO="${1:?usage: component-prompt-gate.sh <iso> [workdir]}"
WORK="${2:-$(dirname "$ISO")/component-prompt-gate-work}"
PROMPT_TIMEOUT_S="${PROMPT_TIMEOUT_S:-420}"
PROGRESS_TIMEOUT_S="${PROGRESS_TIMEOUT_S:-300}"

[ -f "$ISO" ] || { echo "GATE FAIL: no such ISO: $ISO"; exit 2; }
command -v qemu-system-aarch64 >/dev/null || { echo "GATE FAIL: qemu-system-aarch64 missing"; exit 2; }
command -v xorriso >/dev/null || { echo "GATE FAIL: xorriso missing"; exit 2; }
command -v python3 >/dev/null || { echo "GATE FAIL: python3 missing"; exit 2; }

ACCEL=tcg; CPU=cortex-a76
if [ -w /dev/kvm ]; then ACCEL=kvm; CPU=host; fi

mkdir -p "$WORK"
STAGE="$WORK/stage"
GISO="$WORK/component-prompt-test.iso"
DISK="$WORK/disk.qcow2"
VARS="$WORK/VARS.fd"
SLOG="$WORK/serial0.log"
SSOCK="$WORK/serial0.sock"
SFIFO="$WORK/serial0.in"

CODE=/usr/share/AAVMF/AAVMF_CODE.no-secboot.fd
[ -f "$CODE" ] || CODE=/usr/share/AAVMF/AAVMF_CODE.fd
[ -f "$CODE" ] || { echo "GATE FAIL: no AAVMF firmware"; exit 2; }

echo "=== COMPONENT PROMPT GATE ==="
echo "  iso   : $ISO"
echo "  accel : $ACCEL"
echo "  work  : $WORK"

echo "[1/5] extracting + patching throwaway ISO (console swap ONLY — no ncz_components)"
rm -rf "$STAGE" "$GISO"
mkdir -p "$STAGE"
xorriso -osirrox on -indev "$ISO" -extract / "$STAGE" >/dev/null 2>&1 \
  || { echo "GATE FAIL: xorriso extract failed"; exit 2; }
chmod -R u+w "$STAGE"
CFG="$STAGE/boot/grub/grub.cfg"
[ -f "$CFG" ] || { echo "GATE FAIL: no boot/grub/grub.cfg in ISO"; exit 2; }
sed -i 's/console=ttyAMA2,115200/console=ttyAMA0,115200/g' "$CFG"
grep -q "console=ttyAMA0,115200" "$CFG" || { echo "GATE FAIL: console swap matched nothing"; exit 2; }
if grep -q "ncz_components=" "$CFG"; then
  echo "GATE FAIL: ncz_components= present on the shipped cmdline — this gate must exercise the prompt branch"; exit 2
fi

echo "[2/5] repacking"
xorriso -as mkisofs -r -V NCZ_MAXIMILIAN -J -joliet-long -cache-inodes \
  -e boot/grub/efi.img -no-emul-boot \
  -append_partition 2 0xef "$STAGE/boot/grub/efi.img" \
  -appended_part_as_gpt -partition_cyl_align all \
  -o "$GISO" "$STAGE" >/dev/null 2>&1
[ -f "$GISO" ] || { echo "GATE FAIL: repack failed"; exit 2; }

echo "[3/5] booting (accel=$ACCEL; d-i UI expected on serial0)"
rm -f "$DISK" "$VARS" "$SLOG" "$SSOCK" "$SFIFO"
qemu-img create -f qcow2 "$DISK" 40G >/dev/null
cp /usr/share/AAVMF/AAVMF_VARS.fd "$VARS"

qemu-system-aarch64 \
  -M virt -accel "$ACCEL" -cpu "$CPU" -smp 4 -m 6144 \
  -drive if=pflash,format=raw,unit=0,file="$CODE",readonly=on \
  -drive if=pflash,format=raw,unit=1,file="$VARS" \
  -drive file="$DISK",if=none,id=hd,format=qcow2 \
  -device nvme,drive=hd,serial=ncztest01 \
  -drive file="$GISO",if=none,id=usbstick,format=raw,readonly=on \
  -device qemu-xhci,id=xhci \
  -device usb-storage,bus=xhci.0,drive=usbstick \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0,romfile= \
  -serial unix:"$SSOCK",server,nowait \
  -serial "file:$WORK/serial1.log" -serial "file:$WORK/serial2.log" \
  -display none -no-reboot > "$WORK/qemu.log" 2>&1 &
QPID=$!

# serial tee: capture guest serial0 to $SLOG, forward bytes written to $SFIFO
python3 - "$SSOCK" "$SLOG" "$SFIFO" <<'PY' &
import socket, sys, os, select, time
sock_path, log_path, fifo_path = sys.argv[1], sys.argv[2], sys.argv[3]
s = None
for _ in range(60):
    try:
        s = socket.socket(socket.AF_UNIX)
        s.connect(sock_path)
        break
    except OSError:
        time.sleep(1)
if s is None:
    sys.exit("could not connect to " + sock_path)
if os.path.exists(fifo_path):
    os.unlink(fifo_path)
os.mkfifo(fifo_path)
fifo = os.open(fifo_path, os.O_RDONLY | os.O_NONBLOCK)
log = open(log_path, "ab", buffering=0)
while True:
    r, _, _ = select.select([s, fifo], [], [], 1)
    if s in r:
        d = s.recv(4096)
        if not d:
            break
        log.write(d)
    if fifo in r:
        d = os.read(fifo, 4096)
        if d:
            s.sendall(d)
        else:
            os.close(fifo)
            fifo = os.open(fifo_path, os.O_RDONLY | os.O_NONBLOCK)
            time.sleep(0.2)
PY
TPID=$!
cleanup() { kill "$QPID" "$TPID" 2>/dev/null || true; }
trap cleanup EXIT

fail() {
  echo; echo "GATE FAIL: $*" >&2
  echo "--- serial tail ---" >&2
  tail -c 2000 "$SLOG" 2>/dev/null | strings | tail -25 >&2 || true
  exit 1
}

check_serial_fatal() {
  if grep -aq "component prompt could not be shown" "$SLOG" 2>/dev/null; then
    fail "component prompt fell back instead of displaying"
  fi
  if grep -aq "Cannot find .* in menu" "$SLOG" 2>/dev/null; then
    fail "confmodule desync crash — the exact defect this gate exists for"
  fi
}

echo "[4/5] waiting for the component prompt (max ${PROMPT_TIMEOUT_S}s)"
t=0
until grep -aq "showing component prompt" "$SLOG" 2>/dev/null; do
  kill -0 "$QPID" 2>/dev/null || fail "qemu exited before the prompt (see $WORK/qemu.log)"
  check_serial_fatal
  t=$((t + 5)); [ "$t" -ge "$PROMPT_TIMEOUT_S" ] && fail "prompt marker never appeared in ${PROMPT_TIMEOUT_S}s"
  sleep 5
done
check_serial_fatal
# require the dialog BODY to be drawn, not just the log marker
t=0
until grep -aq "Untick to skip" "$SLOG" 2>/dev/null; do
  check_serial_fatal
  t=$((t + 5)); [ "$t" -ge 60 ] && fail "prompt marker appeared but the dialog body never rendered"
  sleep 5
done
echo "    dialog rendered on the console — pressing Enter (accept default: all components)"
sleep 2
printf '\r' > "$SFIFO"

echo "[5/5] waiting for the NEXT d-i dialog (localechooser) (max ${PROGRESS_TIMEOUT_S}s)"
t=0
until grep -aqE "Choose language|Select a language|Language:" "$SLOG" 2>/dev/null; do
  check_serial_fatal
  kill -0 "$QPID" 2>/dev/null || fail "qemu exited before the language dialog"
  t=$((t + 5)); [ "$t" -ge "$PROGRESS_TIMEOUT_S" ] && fail "no post-prompt dialog in ${PROGRESS_TIMEOUT_S}s — main-menu likely dead (the wedge)"
  sleep 5
done
check_serial_fatal

echo
echo "GATE PASS: component prompt rendered, was answered over the console, and"
echo "the installer progressed to the language dialog on a clean confmodule stream."
exit 0
