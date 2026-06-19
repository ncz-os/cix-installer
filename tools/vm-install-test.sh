#!/bin/bash
# Unattended r104 install into a KVM VM (server/Magnetar variant).
# NVMe-emulated disk so guest sees /dev/nvme0n1 (matches preseed hardcode).
# SCSI cdrom -> /dev/sr0 for d-i cdrom-detect.
VARIANT="${1:-server}"
DISK=/var/tmp/r104-test.qcow2
ISO=/var/tmp/r104.iso
LOG=/var/tmp/install-${VARIANT}.serial.log

# fresh disk each run
qemu-img create -f qcow2 "$DISK" 40G >/dev/null 2>&1

# VM-test-only passwd seeds (the shipped preseed deliberately PROMPTS for these;
# we inject via cmdline so the dry-run completes unattended without changing the ISO).
PASSWD_SEEDS="passwd/user-fullname=Test passwd/username=mini passwd/user-password=mini passwd/user-password-again=mini user-setup/allow-password-weak=true"
APPEND="auto=true priority=critical preseed/file=/cdrom/cixmini/preseed.cfg interface=auto netcfg/dhcp_timeout=120 ncz_diag=1 ncz_variant=${VARIANT} $PASSWD_SEEDS console=ttyAMA0 loglevel=4 DEBIAN_FRONTEND=text"

echo "[vm-install] variant=$VARIANT log=$LOG  $(date)"
timeout 3600 qemu-system-aarch64 \
    -machine virt,gic-version=3 -accel kvm -cpu host \
    -smp 4 -m 8192 \
    -kernel /var/tmp/vmlinuz -initrd /var/tmp/initrd.gz \
    -append "$APPEND" \
    -drive file="$DISK",if=none,id=nvme0,format=qcow2 \
    -device nvme,drive=nvme0,serial=ncz104 \
    -device qemu-xhci,id=xhci \
    -drive file="$ISO",if=none,id=usbstick,format=raw,readonly=on \
    -device usb-storage,bus=xhci.0,drive=usbstick,bootindex=1 \
    -netdev user,id=net0,hostfwd=tcp::2223-:22,hostfwd=tcp::2323-:23 -device e1000,netdev=net0,romfile= \
    -nographic -no-reboot > "$LOG" 2>&1
echo "[vm-install] qemu exited rc=$? $(date)"
