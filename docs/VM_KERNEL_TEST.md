# VM Kernel Testing (native aarch64 KVM)

Test new kernels in a VM **before** swapping the metal kernel, so the cixmini's
metal 7.0.12-cix-sky1-next always stays as a working rescue.

## Hosts

- **ARGOS** (192.168.207.22, x86_64, 20c): kernel cross-builds, ISO builds, git.
  aarch64 guests here run under **TCG** (slow) — use only if `.66` is busy.
- **cixmini .66** (aarch64, 12c, 59 GB free): has `/dev/kvm` (CPU boots at EL2).
  Native-KVM aarch64 guests — **primary VM kernel-test host**.

## One-shot boot smoke test

`tools/kvm-smoke.sh <vmlinuz> <initrd> [seconds]` boots a kernel diskless under
KVM (`-machine virt,gic-version=3 -accel kvm -cpu host`) and prints the serial
log. gzip-wrapped arm64 `vmlinuz` is auto-extracted to a raw Image.

Proven 2026-06-17 on `.66`: 7.0.12 boots, `smccc: KVM: hypervisor services
detected`, `arch_timer ... (virt)` — KVM acceleration confirmed. (`rdinit=/bin/true`
exits immediately; that's expected for a diskless smoke test.)

```bash
sudo bash tools/kvm-smoke.sh /boot/vmlinuz-7.0.12-cix-sky1-next \
                             /boot/initrd.img-7.0.12-cix-sky1-next 22
```

## Full boot-to-userspace test

For a real boot test, attach a rootfs (qcow2 or the ISO) instead of `rdinit`:
```bash
qemu-system-aarch64 -machine virt,gic-version=3 -accel kvm -cpu host \
  -smp 4 -m 8192 -kernel <Image> -initrd <initrd> \
  -append "root=/dev/vda2 console=ttyAMA0 rw" \
  -drive if=virtio,file=rootfs.qcow2,format=qcow2 \
  -nic user -nographic
```

## Rescue invariant

NEVER let a VM test modify `.66`'s metal `/boot`. The VM reads kernel images
read-only; rootfs images are separate qcow2 files. Metal 7.0.12 = rescue, always.
