# NCZ-OS RESCUE ENVIRONMENT — AGENTS.md

You are an agent (or operator) running inside the **NCZ-OS dedicated rescue
partition**. This is a self-contained Ubuntu (resolute / 26.04) arm64 rootfs on
its own partition (`NCZRESCUE`), booted via the **edge kernel**, completely
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
| edge / next (BETA) | `7.0.12-cix-sky1-next` | newer; **this rescue env runs the edge kernel** |
| rescue pin | `<lts>-rescue` | independent pinned copy of LTS for `cixmini-rescue.conf` |

- This rescue partition boots **edge `7.0.12-cix-sky1-next`** so it exercises the
  same silicon the main edge channel uses, and it has `btrfs` + the Sky1 display
  stack in-tree (the old 6.18 rescue USB lacked btrfs — that is why it could not
  mount modern roots).
- Boot is **ACPI-driven** (`acpi=force`). There is **no DTB** in the boot path.
- Kernel modules live at `/usr/lib/modules/<kver>/` (usrmerge). `/lib` is a
  **symlink** to `usr/lib` — see section 6.

Working Sky1 kernel cmdline (edge base):
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

The "SAFE rescue" entry (`cixmini-rescue.conf`, separate from this partition)
blacklists all of: `armchina_npu,panthor,mali,bifrost,cix_vpu,linlon_vpu,trilin_drm,trilin_dpsub,linlondp,linlondp_drv,cix_display`.

---

## 4. Boot model (the installed/main system)

- **Bootloader:** **systemd-boot** (NOT GRUB, NOT rEFInd). `refind` exists in
  this rescue toolset only as a repair utility.
- ESP mounted at `/boot/efi` (vfat). Loader entries are BLS Type #1 `.conf`
  files in `/boot/efi/loader/entries/`. Kernels/initrds are staged on the ESP as
  `/boot/efi/vmlinuz-*` + `/boot/efi/initrd.img-*`.
- Default entry + timeout in `/boot/efi/loader/loader.conf` (`default <entry>`).
  Menu order via `sort-key`.
- Entries (when all present):
  - `cixmini-stable`     (`1-stable`, default, LTS)
  - `cixmini-edge+3-0`   (`2-edge`, BETA, 3-try boot-count rollback)
  - `cixmini-rescue`     (`3-rescue`, rescue.target on a pinned LTS, shared root)
  - `cixmini-rescuepart` (`4-rescuepart`, **this** environment, own root=PARTUUID)
- Root is referenced by `root=PARTUUID=...` (not subvol, not /dev path).
- **WARNING:** the installer's `70-bootloader.sh` **wipes and rewrites all**
  `loader/entries/*.conf` + `vmlinuz-*` on every install. Hand-edits to loader
  entries do not survive a reinstall.

### Force a known-good default
```sh
# from this rescue env, with the main ESP mounted at /mnt/esp:
printf 'default cixmini-stable\ntimeout 5\n' > /mnt/esp/loader/loader.conf
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
- **p1 ESP** (~2 GiB, fat32) — systemd-boot + up to 4 kernels/initrds.
- **p2 rescue** (~4 GiB, ext4, label `NCZRESCUE`) — **this** rootfs.
- **p3 root** (rest, ext4) — the main NCZ-OS system, mounted at `/`.

The r130 installer no longer auto-wipes a fixed disk: the operator **selects and
confirms** the target disk (the MS-R1 has multiple NVMe slots, so a hardcoded
target was unsafe). The main root is **ext4** (not btrfs); this rescue toolset
nonetheless carries `btrfs-progs` for foreign/older roots.

### Mount the main root from here
```sh
ncz-rescue-chroot /dev/nvme0n1p3        # or whatever lsblk shows as the ext4 root
# ... or manually:
mount /dev/nvme0n1p3 /mnt && mount /dev/nvme0n1p1 /mnt/boot/efi
```
