# NCZ-OS RESCUE ENVIRONMENT — AGENTS.md

You are an agent (or operator) running inside the **NCZ-OS dedicated rescue
partition**. This is a self-contained Ubuntu (resolute / 26.04) arm64 rootfs on
its own partition (`NCZRESCUE`), booted via the **LTS kernel**
(`6.18.26-cix-sky1-lts`) with the NPU/GPU/VPU/KMS module blacklist, completely
independent of the main system root. Your job here is to **inspect, repair, and
restore** a broken install. This file is the source of truth for system facts.

Keep it factual. If you change the system, prefer reversible actions and log
what you did.

---

## 1. Hardware / platform

- **SoC:** CIX Sky1 (CP8180), arm64. NPU ~30 TOPS, Arm Mali-G720 GPU, Arm Linlon VPU.
- **Boards in fleet:**
  - **Minisforum MS-R1** (test rig `cixmini`, e.g. `192.168.207.66`). Note: the
    MS-R1 has **more than one NVMe slot** — never assume a single fixed disk.
  - **Radxa Orion O6** (Realtek RTL8125/8126 NIC via `r8169`).
- **Boot firmware:** UEFI. Sky1/MS-R1 firmware often **cannot persist NVRAM EFI
  variables**, so boot relies on the removable-media fallback
  `EFI/BOOT/BOOTAA64.EFI` on the ESP.
- **Console video:** firmware `efifb`/`simplefb` only. Do **not** add `nomodeset`
  and do not let a KMS driver seize the panel during recovery, or you get a
  black screen.

---

## 2. Kernels

| Channel | Version string | Notes |
|---|---|---|
| stable / LTS (default) | `6.18.26-cix-sky1-lts` | all drivers working; production default |
| edge / next (BETA) | `7.0.12-cix-sky1-next` | newer; main-system BETA channel only |
| rescue pin | `<lts>-rescue` | independent pinned copy of LTS for the rEFInd "rescue" menuentry |

- r130.5: this rescue partition boots the **LTS `6.18.26-cix-sky1-lts`** kernel
  with the NPU/GPU/VPU/KMS `module_blacklist` (the same safe set as the rEFInd
  "rescue" pin) so device startup is quiet and reliable — a recovery env should
  be boring, not exercise edge silicon. It still ships `btrfs` + the Sky1
  storage/NIC drivers in-tree so it can mount modern roots.
- Boot is **ACPI-driven** (`acpi=force`). There is **no DTB** in the boot path.
- Kernel modules live at `/usr/lib/modules/<kver>/` (usrmerge). `/lib` is a
  **symlink** to `usr/lib` — see section 6.

Working Sky1 kernel cmdline (LTS base; the rescue partition additionally appends
the NPU/GPU/VPU/KMS module_blacklist for a quiet recovery boot):
```
loglevel=4 console=tty0 console=ttyAMA2,115200 acpi=force arm-smmu-v3.disable_bypass=0 audit_backlog_limit=8192 clk_ignore_unused keep_bootcon panic=30 module_blacklist=typec_rts5453,rts5453
```
- `arm-smmu-v3.disable_bypass=0` is **required** for NVMe + NIC DMA. Without it,
  no disk and no network.
- `module_blacklist=typec_rts5453,rts5453` works around the MS-R1 IRQ-151 wedge.

---

## 3. Drivers / modules

- **NPU:** `armchina_npu` (CIX Zhouyi). Creates `/dev/aipu`. ACPI IDs
  `CIXH4000:00` (device) + `CIXH4010:0[012]` (3 cores). Userspace: `cix-noe-umd`.
- **GPU:** `panthor` (Mali-G720, Sky1 ACPI patch). Mesa/Vulkan stack on the main system.
- **Display/DRM:** `linlon-dp`, `trilin-dpsub`, `cix_virtual`.
- **VPU:** Sky1 video codec driver (Linlon).
- **NIC:** mainline `r8169` (RTL8125/8126); `rtl_nic` firmware required for the O6.

The "SAFE rescue" menuentry (rescue.target on a pinned LTS, separate from this
partition) blacklists all of: `armchina_npu,panthor,mali,bifrost,cix_vpu,linlon_vpu,trilin_drm,trilin_dpsub,linlondp,linlondp_drv,cix_display`.

---

## 4. Boot model (the installed/main system)

- **Bootloader:** **rEFInd** (switched from systemd-boot at r118 by operator
  preference; NOT GRUB). The `refind` package in this rescue toolset can repair
  the installed system's `refind.conf`.
- rEFInd ships as a binary `refind_aa64.efi` installed to the firmware
  removable-media fallback path **`/boot/efi/EFI/BOOT/BOOTAA64.EFI`** (Sky1/MS-R1
  firmware often cannot persist NVRAM EFI vars, so the fallback path is the
  reliable boot route).
- The menu is defined by **manual `menuentry` blocks** in a single
  **`/boot/efi/EFI/BOOT/refind.conf`** (`scanfor manual`,
  `scan_all_linux_kernels false`). Kernels/initrds are staged on the ESP root as
  `/boot/efi/vmlinuz-*` + `/boot/efi/initrd.img-*`; each `menuentry` references
  them as `loader /vmlinuz-...` + `initrd /initrd.img-...`.
- Default via `default_selection "<token>"` (substring of the entry title; edge
  when staged, else stable). `timeout 10`. `resolution max` forces a graphical
  GOP mode so the NCZ-OS 26.6 banner + icons paint (else rEFInd goes text-only).
- Entries (when all present):
  - `…· stable` — LTS 6.18
  - `…· edge`   — NEXT 7.0.x (default/BETA)
  - `…· rescue` — rescue.target on a pinned LTS copy, **shared** production root
  - `…· RESCUE PARTITION` — **this** environment: edge kernel, own `root=PARTUUID`
- Root is referenced by `root=PARTUUID=...` (not subvol, not /dev path).
- **WARNING:** the installer's `70-bootloader.sh` **wipes and rewrites**
  `refind.conf` + the staged ESP `vmlinuz-*` on every install. Hand-edits to
  `refind.conf` do not survive a reinstall.

### Force a known-good default
```sh
# from this rescue env, with the main ESP mounted at /mnt/esp:
sed -i 's/^default_selection .*/default_selection "stable"/' \
    /mnt/esp/EFI/BOOT/refind.conf
```

---

## 5. Access (LAN-only, 192.168.207.0/24)

- **telnet:** TCP **23** (lockout-prevention backup console). Root login allowed.
- **dropbear SSH:** TCP **2222**.
- **OpenSSH:** TCP **22**, `PermitRootLogin yes`, `PasswordAuthentication yes`.
- **Serial console:** `ttyAMA2` @ **115200** (matches `console=ttyAMA2,115200`).
- **Rescue root password:** `rescue` (this rescue rootfs only; change/disable
  before any public distribution).
- **Network:** DHCP on all wired NICs at boot; **static fallback
  `192.168.207.66/24`, gateway `192.168.207.1`** if DHCP fails
  (`ncz-rescue-net.service`).
- **Loghost (main fleet):** `192.168.207.22` (ARGOS).

---

## 6. CRITICAL pitfall — the usrmerge `/lib` symlink

On a usrmerge rootfs, `/lib`, `/bin`, `/sbin` are **symlinks** into `/usr`.
The dynamic linker is `/lib/ld-linux-aarch64.so.1` (-> `/usr/lib/...`). If `/lib`
gets replaced by a **real directory** (classic cause: `tar xzf modules.tgz -C /`
where the tarball has a top-level `lib/`), the linker disappears and **every
dynamically linked binary fails to exec** — sshd children die, `depmod` fails,
the box looks "alive" (pings, kernel up) but you cannot log in. This is the exact
incident this rescue env was built to fix.

### Repair
From this rescue env, with the broken root mounted at `<MNT>`:
```sh
ncz-rescue-fixlib <MNT>
```
This preserves the clobbered dir as `lib.broken.<timestamp>`, copies its contents
into `usr/lib`, and restores `/lib -> usr/lib`.

### Never re-cause it
When installing kernel modules into a root, ALWAYS:
```sh
tar xzf modules-cixmini.tgz -C <root>/usr --keep-directory-symlink   # lands in usr/lib/modules
```
NEVER `tar -C <root>` (or `-C /`) for a tarball that contains a top-level `lib/`.

---

## 7. Recovery toolset (highlights)

Filesystems: `btrfs-progs` `e2fsprogs` `xfsprogs` `f2fs-tools` `ntfs-3g` `exfatprogs` `dosfstools`.
Block/partition: `fdisk`/`sfdisk`/`lsblk`/`blkid`/`wipefs` (util-linux), `parted`, `gdisk`, `nvme-cli`, `smartctl`.
Imaging/recovery: `ddrescue`, `testdisk`/`photorec`, `fsarchiver`, `partclone`.
Net/diag: `ip`, `tcpdump`, `nmap`-class via `mtr`, `ethtool`, `socat`, `nc`, `curl`, `wget`, `rsync`, `sshfs`, `nfs`/`cifs`.
Boot repair: `efibootmgr`, `efivar`, `refind`, `kexec` (chainload a good kernel without a full reboot).
Editors/util: `vim`, `nano`, `mc`, `tmux`, `jq`, `lsof`, `strace`, `python3`.

### Helpers baked into this env
- `ncz-rescue-fixlib <root-mountpoint>` — repair the usrmerge `/lib` symlink.
- `ncz-rescue-chroot <device>` — mount a target root (+ bind mounts) and drop
  into a chroot shell; auto-unmounts on exit.
- `ncz-rescue-net` — DHCP all NICs, static `192.168.207.66/24` fallback.

---

## 8. Disk layout produced by the r130 installer

GPT, three partitions on the chosen disk:
- **p1 ESP** (~1 GiB, fat32) — rEFInd (`BOOTAA64.EFI` + `refind.conf`) + staged kernels/initrds.
- **p2 rescue** (~4 GiB, ext4, label `NCZRESCUE`) — **this** rootfs.
- **p3 root** (rest, **btrfs**) — the main NCZ-OS system, mounted at `/`.

The r130 installer no longer auto-wipes a fixed disk: the operator **selects and
confirms** the target disk (the MS-R1 has multiple NVMe slots, so a hardcoded
target was unsafe). The main root is **btrfs**; this rescue partition is ext4,
and `btrfs-progs` ships in this toolset so the rescue env can mount/repair the
btrfs main root.

### Mount the main root from here
```sh
ncz-rescue-chroot /dev/nvme0n1p3        # or whatever lsblk shows as the btrfs root
# ... or manually (root is btrfs, ESP is p1):
mount -t btrfs /dev/nvme0n1p3 /mnt && mount /dev/nvme0n1p1 /mnt/boot/efi
```
