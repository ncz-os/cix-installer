#!/bin/bash
# qemu-test.sh — boot the cix-installer ISO in qemu-aarch64 with edk2
# UEFI firmware. Faster iteration than reflashing USB sticks.
#
# Limits: qemu-aarch64 software-emulates Cix Sky1 hardware as a generic
# aarch64 board. The Cix kernel won't fully boot (no Sky1 PCIe / DRM
# driver targets), but everything UP TO kernel handoff (UEFI, GRUB,
# d-i preseed, partman, debootstrap, base apt) IS testable.
#
# This is enough to validate the preseed + post-install pipeline; the
# kernel-side hardware bits stay testable on real MS-R1 only.
#
# 2026-07-28: restored real visibility into the d-i menu/console. The
# 2026-07-27 headless-display fix (20731d1) swapped `-display gtk,gl=off`
# for `-display none` to stop crashing over SSH (no DISPLAY/X11) -- correct
# for that bug, but it silently removed the ONLY channel that ever showed
# d-i boot progress (every prior "dozens of working installers" run relied
# on that GTK window). No serial-console compensation was added at the same
# time, so headless runs since then have shown nothing after the GRUB
# banner -- easy to mistake for a hang. This add-back is TWO independent,
# additive fixes, neither touches the ISO or its shipped kernel cmdline:
#   1. -vnc + a real virtio-gpu-pci framebuffer + periodic QMP screendumps
#      to $SCREENSHOT_DIR, so d-i's actual on-screen menu is inspectable
#      headless (open the .ppm files, or point a VNC client at the printed
#      port) without requiring X11 forwarding.
#   2. -serial stdio was ALREADY present in every version; it only became
#      useful once earlycon/console=ttyAMA0 is also present on the booted
#      kernel cmdline. That change is intentionally NOT made here or to the
#      shipped ISO -- earlycon=pl011,<addr> does a raw early MMIO probe
#      before any device-tree/ACPI validation, and unconditionally baking a
#      QEMU-only physical address into the real product cmdline risks
#      touching something unrelated on real Sky1 hardware. Use
#      qemu-test-console-patch.sh to produce a QEMU-only *copy* of the ISO
#      with earlycon added, and pass THAT copy to this script, when kernel-
#      level (not just d-i-menu-level) serial visibility is needed.
#
# 2026-07-28 (second fix, same day): the ISO used to be attached as a SCSI
# CD-ROM (-device scsi-cd). Once (1)+(2) above restored real visibility,
# d-i's cdrom-detect stage failed outright: "Your installation media
# couldn't be mounted" -> Retry dialog -> silently parks forever (looked
# identical to a hang again). Root cause: CONFIG_BLK_DEV_SR (the sr_mod
# SCSI-CDROM driver) is NOT built into the Sky1 kernel -- confirmed absent
# from the config from before ANY of this session's thinning work, so this
# was never a regression. It's absent because real deployment has never
# used a CD-ROM: the ISO is dd'd/Ventoy'd to a USB flash drive and boots
# through usb-storage + the generic block layer, never through sr_mod at
# all. Attaching the ISO as usb-storage here instead of scsi-cd matches
# that real deployment path exactly (both are read-only whole-disk block
# devices carrying the same ISO9660 filesystem) and needs no kernel change.

set -euo pipefail

# 2026-08-12: the ISO used to hang off -device usb-ehci. The Sky1 kernel is
# XHCI-ONLY -- CONFIG_USB_EHCI_HCD, OHCI and UHCI are all unset, only
# USB_XHCI_HCD=y and USB_XHCI_PCI=y, because the real hardware is XHCI. Behind
# an EHCI controller the USB bus never enumerated, the ISO's block device never
# appeared, and d-i reported "No device for installation media was detected" --
# which was d-i telling the truth about a machine this kernel cannot drive.
# A harness bug, not an image bug. qemu-xhci matches the real boot path.
#
# NOTE: do NOT put comments inside the qemu invocation below. It is a single
# command continued with trailing backslashes, so a '#' line there is not a
# comment -- the words become qemu arguments, and the run dies with a
# misleading error about a missing romfile.

ISO="${1:-}"
[ -z "$ISO" ] && { echo "usage: $0 <path/to/installer.iso>"; exit 1; }
[ ! -f "$ISO" ] && { echo "ERROR: $ISO not found"; exit 1; }

# Look for edk2 firmware in standard locations
EDK2_CODE=""
for f in /usr/share/AAVMF/AAVMF_CODE.fd \
         /usr/share/edk2-armvirt/aarch64/QEMU_EFI.fd \
         /opt/homebrew/share/qemu/edk2-aarch64-code.fd \
         /usr/share/edk2/aarch64/QEMU_EFI.fd; do
    [ -f "$f" ] && EDK2_CODE="$f" && break
done
[ -z "$EDK2_CODE" ] && { echo "ERROR: edk2-aarch64 firmware not found"; exit 1; }

DISK="${ISO%.iso}-target.qcow2"
if [ ! -f "$DISK" ]; then
    echo "[qemu] creating 30G qcow2 target disk: $DISK"
    qemu-img create -f qcow2 "$DISK" 30G
fi

VARSTORE="${ISO%.iso}-vars.fd"
if [ ! -f "$VARSTORE" ]; then
    echo "[qemu] creating UEFI varstore: $VARSTORE"
    truncate -s 64m "$VARSTORE"
fi

# QEMU_TEST_ACCEL=tcg|kvm forces the accelerator; unset means auto-detect.
#
# WHY THIS EXISTS (2026-08-11): every historically SUCCESSFUL install run here
# used TCG -- not by choice, but because /dev/kvm on this host came up owned by
# group _chrony instead of kvm, so the auto-detect below always failed. Fixing
# that permission silently switched all future runs to `-enable-kvm -cpu host`,
# which hands the guest a real Sky1 core instead of an emulated generic one.
# That is a materially different test, and it must be selectable rather than a
# side effect of a device node's group.
QEMU_TEST_ACCEL="${QEMU_TEST_ACCEL:-auto}"

# Accelerate with KVM when running on real aarch64 hardware with /dev/kvm
# access (e.g. cixmini, O6N) -- TCG software-emulates the CPU otherwise,
# which is dramatically slower for a full d-i/partman/debootstrap/apt run.
# -cpu host is only valid under KVM (1:1 passthrough); -cpu max is the
# TCG equivalent (emulate the best available virtual CPU) and is what's
# needed for cross-arch hosts (e.g. an x86_64/macOS dev box) where KVM
# can't apply at all.
ACCEL_ARGS=(-cpu max)
if [ "$QEMU_TEST_ACCEL" = "kvm" ] || { [ "$QEMU_TEST_ACCEL" = "auto" ] && [ "$(uname -m)" = "aarch64" ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; }; then
    echo "[qemu] KVM available on $(uname -m) host -- accelerating"
    ACCEL_ARGS=(-enable-kvm -cpu host)
else
    echo "[qemu] no usable KVM (host=$(uname -m)) -- falling back to TCG (slower)"
fi

# VNC display number: bind to the first free port from 5999 up, headless-safe
# (no DISPLAY/X11 needed -- a VNC client is optional, screendumps work either
# way). QMP socket drives periodic `screendump` captures of the same
# framebuffer so a fully unattended run still leaves visual evidence.
VNC_DISPLAY="${QEMU_TEST_VNC_DISPLAY:-1}"
QMP_SOCK="${ISO%.iso}-qmp.sock"
rm -f "$QMP_SOCK"

SCREENSHOT_DIR="${ISO%.iso}-screenshots"
mkdir -p "$SCREENSHOT_DIR"
rm -f "$SCREENSHOT_DIR"/*.ppm

echo "[qemu] booting $ISO with $EDK2_CODE"
echo "[qemu] VNC: 127.0.0.1:$((5900 + VNC_DISPLAY)) (display :$VNC_DISPLAY) -- screendumps -> $SCREENSHOT_DIR"

qemu-system-aarch64 \
    -M virt \
    "${ACCEL_ARGS[@]}" \
    -smp 4 -m 4096 \
    -drive if=pflash,format=raw,readonly=on,file="$EDK2_CODE" \
    -drive if=pflash,format=raw,file="$VARSTORE" \
    -drive if=virtio,file="$DISK",format=qcow2 \
    -drive if=none,id=isousb,format=raw,file="$ISO",readonly=on \
    -device qemu-xhci,id=usb0 \
    -device usb-storage,bus=usb0.0,drive=isousb,removable=on \
    -boot d \
    -netdev user,id=net0 \
    -device virtio-net-pci,netdev=net0,romfile= \
    -device virtio-gpu-pci \
    -display none \
    -vnc "127.0.0.1:${VNC_DISPLAY}" \
    -qmp "unix:${QMP_SOCK},server,nowait" \
    -serial stdio &
QEMU_PID=$!

# Periodic QMP screendump in the background -- best-effort: if the QMP
# socket never appears (older qemu, permissions) this just quietly does
# nothing, it never fails the boot test itself.
(
    n=0
    for _ in $(seq 1 60); do
        [ -S "$QMP_SOCK" ] && break
        sleep 1
    done
    [ -S "$QMP_SOCK" ] || exit 0
    while kill -0 "$QEMU_PID" 2>/dev/null; do
        n=$((n + 1))
        printf '{"execute":"qmp_capabilities"}\n{"execute":"screendump","arguments":{"filename":"%s/frame-%03d.ppm"}}\n' \
            "$SCREENSHOT_DIR" "$n" | timeout 5 socat - "UNIX-CONNECT:${QMP_SOCK}" >/dev/null 2>&1 || true
        sleep 5
    done
) &
SNAPSHOT_PID=$!

wait "$QEMU_PID" || true
kill "$SNAPSHOT_PID" 2>/dev/null || true
rm -f "$QMP_SOCK"

SHOT_COUNT=$(find "$SCREENSHOT_DIR" -name '*.ppm' 2>/dev/null | wc -l | tr -d ' ')
echo "[qemu] captured $SHOT_COUNT screendump(s) in $SCREENSHOT_DIR"
