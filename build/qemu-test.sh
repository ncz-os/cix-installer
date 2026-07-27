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

set -euo pipefail

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

# Accelerate with KVM when running on real aarch64 hardware with /dev/kvm
# access (e.g. cixmini, O6N) -- TCG software-emulates the CPU otherwise,
# which is dramatically slower for a full d-i/partman/debootstrap/apt run.
# -cpu host is only valid under KVM (1:1 passthrough); -cpu max is the
# TCG equivalent (emulate the best available virtual CPU) and is what's
# needed for cross-arch hosts (e.g. an x86_64/macOS dev box) where KVM
# can't apply at all.
ACCEL_ARGS=(-cpu max)
if [ "$(uname -m)" = "aarch64" ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    echo "[qemu] KVM available on $(uname -m) host -- accelerating"
    ACCEL_ARGS=(-enable-kvm -cpu host)
else
    echo "[qemu] no usable KVM (host=$(uname -m)) -- falling back to TCG (slower)"
fi

echo "[qemu] booting $ISO with $EDK2_CODE"
exec qemu-system-aarch64 \
    -M virt \
    "${ACCEL_ARGS[@]}" \
    -smp 4 -m 4096 \
    -drive if=pflash,format=raw,readonly=on,file="$EDK2_CODE" \
    -drive if=pflash,format=raw,file="$VARSTORE" \
    -drive if=virtio,file="$DISK",format=qcow2 \
    -drive if=none,id=cd,format=raw,file="$ISO",readonly=on \
    -device virtio-scsi-pci,id=scsi0 \
    -device scsi-cd,drive=cd \
    -boot d \
    -netdev user,id=net0 \
    -device virtio-net-pci,netdev=net0 \
    -display none \
    -serial stdio
