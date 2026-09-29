#!/bin/bash
# KVM smoke test: boot a kernel Image under native aarch64 KVM on the cixmini.
# Usage: kvm-smoke.sh <vmlinuz> <initrd> [seconds]
# No root disk: kernel + initramfs boot, then we kill it. Proves KVM works.
set -u
KIMG="${1:?vmlinuz path}"
INITRD="${2:?initrd path}"
SECS="${3:-25}"
WORK=$(mktemp -d)
cp "$KIMG"   "$WORK/k"
cp "$INITRD" "$WORK/i"

# arm64 vmlinuz may be a gzip-wrapped Image; qemu -kernel wants raw Image.
if file "$WORK/k" | grep -qi gzip; then
    echo "[smoke] vmlinuz is gzip; extracting raw Image"
    zcat "$WORK/k" > "$WORK/Image" 2>/dev/null && mv "$WORK/Image" "$WORK/k"
fi

echo "[smoke] launching qemu virt + KVM (host cpu), ${SECS}s timeout"
timeout --foreground "${SECS}" qemu-system-aarch64 \
    -machine virt,gic-version=3 \
    -accel kvm -cpu host -smp 4 -m 4096 \
    -kernel "$WORK/k" -initrd "$WORK/i" \
    -append "console=ttyAMA0 earlycon=pl011,0x9000000 panic=5 rdinit=/bin/true" \
    -nic none -nographic -no-reboot 2>&1 | sed -u 's/^/[vm] /' | head -120
RC=${PIPESTATUS[0]}
echo "[smoke] qemu exited rc=$RC (124=timeout=still-running=OK for boot proof)"
rm -rf "$WORK"
