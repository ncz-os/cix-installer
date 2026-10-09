# NCZ-OS 26.10 rescue environment

This is the dedicated `NCZRESCUE` partition: a self-contained Debian Forky
rootfs built by `build/build-rescue-rootfs.sh` from the release's pinned
snapshot. It exists for inspecting and repairing an installed system.

## Operating boundaries

Use read-only diagnostics first. Keep changes reversible and record exact
targets. Never flash, repartition, format, or overwrite a device without
explicit operator authorization. Never delete a working kernel or rescue
entry. Telnet remains enabled for LAN-only lockout recovery.

## Kernel and platform

The rootfs archive is intentionally kernel-free. During installation,
`post-install/72-rescue-partition.sh` installs the SAME pinned kernel as the
main system, with the release's rescue command line. There is no separate
7.0/7.2/LTS or edge kernel channel in this release.

The authoritative inputs are `assets/kernel/KERNEL-POLICY` and the per-arch
kernel manifests/KVER sidecars. Inspect `uname -r`, `/proc/cmdline`, the
actual rEFInd configuration and installed module directories; do not infer a
kernel version or physical board from this document.

On Apple T2 systems, rescue keeps `amdgpu` because the AMD GPU drives the
panel. On Sky1, rescue blacklists accelerator modules but does not blacklist
the display controller. Use the actual per-arch policy, not a blanket
`nomodeset` or GPU blacklist.

Kernel modules reside under `/usr/lib/modules/<kver>`. `/lib` is a symlink to
`usr/lib`. There is no universal DTB or console argument for both
architectures: preserve the command line generated for the target.

## Boot and disks

The installed bootloader is rEFInd, not GRUB. Its removable-media fallback is
`EFI/BOOT/BOOTAA64.EFI` on arm64 or `EFI/BOOT/BOOTX64.EFI` on amd64.
Inspect the mounted ESP's real configuration before changing selection.
The rescue partition has its own root filesystem; the same-kernel rescue
entry against the main root is a distinct recovery route.

The installer requires the operator to select and confirm its target disk.
Never assume a device name, NVMe slot or partition number. Identify the ESP,
`NCZRESCUE` partition and main root with `lsblk -f` and `blkid`; main
installations use btrfs.

## LAN access

The builder configures telnet on port23, OpenSSH on22 and, when available,
Dropbear on2222. Root's rescue-only break-glass password is `rescue`.
These services are for the192.168.207.0/24 LAN, not public exposure.

Networking attempts DHCP on carrier NICs with a bounded timeout. A separate
fallback service uses `192.168.207.199/24`, gateway192.168.207.1, only when no
global IPv4 address exists. The fallback is NOT the production cixmini
address192.168.207.66. Check for address conflicts before manual assignment.

Serial gettys for ttyAMA0/ttyAMA2 are device-driven rather than statically
enabled; absent UARTs must not block boot. On other platforms inspect the
actual available console instead of enabling a nonexistent device.

## Recovery helpers

- `ncz-rescue-fixlib <mounted-root>` preserves a clobbered real `lib`
  directory and restores the usrmerge symlink.
- `ncz-rescue-chroot <identified-root-device>` mounts an ext4/btrfs root,
  binds the required virtual filesystems and opens a shell.
- `ncz-rescue-net` attempts DHCP; `ncz-rescue-net-fallback` implements the
  independently ordered static fallback.

Never extract a kernel/modules tarball with `tar -C /` into a live root.
Inspect archive layout first and preserve usrmerge symlinks. Do not overwrite
an ESP or restore an old whole-ESP backup over unrelated newer changes.

The toolset includes filesystem, block-device, network and boot diagnostics.
Their presence is not permission to mutate a disk. Use the running system's
actual state as evidence; this document does not certify hardware acceptance.
