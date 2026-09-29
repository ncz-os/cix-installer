# Installer boot timeline and UX findings, 2026-09-29

Scope: three operator reports from the real O6N install of `ncz-os-arm64-20260929-28a868c.img`, plus the
defects found while chasing them. Everything below was measured under KVM on ULTRA (aarch64 host, native
KVM, virtio disk and network, UEFI AAVMF) unless it says otherwise. Nothing here was measured on the
O6N itself; the section "Only the real O6N can show" lists what is inferred.

## 1. Boot timeline (seconds after qemu start; tool: `build/boot-timeline.py`)

The harness boots the image exactly as shipped (only the unattended answers and one serial console are
appended to the Install entry), records `(time, serial log size)` every 0.2 s and maps markers back to wall
clock. The rEFInd/GRUB menu timeout is left as shipped.

| marker | 28a868c (as reported) | 3fc79c3 (09-28 image) | ISO 2026.09.25 (GRUB) | fixed image |
|---|---|---|---|---|
| firmware hands over to the boot manager | 5.6 | 5.6 | 5.8 | 5.6 |
| boot manager launches the kernel | 15.8 (menu wait 10.2) | 15.8 (10.2) | GRUB timeout 10 | 8.8 (3.2) |
| d-i initrd up (syslogd) | 17.6 | 17.4 | - | 10.6 |
| early_command diagnostics banner | 20.0 | 19.4 | 19.8 | 14.2 |
| "Loading additional components" | 24.0 | 24.2 | - | 19.2 |
| first hardware-detection screen | 31.2 | 31.2 | - | 27.2 |
| "Partitions formatting" | 50.3 | 50.1 | - | 46.3 |
| "Installing the base system" | 51.3 | 51.3 | - | 47.3 |
| "Select and install software" | 86.3 | 87.5 | - | - |
| late.sh starts | 92.1 | 93.1 | - | - |
| reboot | 399.6 | 317.1 | - | - |

Also measured: an install with the guest network restricted (`-netdev user,restrict=yes`, "offline")
completed (late.sh at 75 s, reboot at 470 s), so the media installs without internet.

### Finding A: "boot screen to d-i is much longer than the ISOs"

* Under KVM the raw-GPT image and the ISO-era installer reach the same point at the same time (d-i
  diagnostics banner at 19.4 to 20.0 s versus 19.8 s), and the raw image is smaller (44 MB initrd versus
  164 MB). Pipeline structure is NOT what is slower.
* What is measurably different in the shipped Install entry: (1) rEFInd `timeout 10` is 10.2 of the ~24 s
  before d-i draws anything; (2) the entry has no `quiet`/`loglevel`, so the kernel printed **415 lines /
  29 KB** to the console before d-i started, where the ISO entry ran `loglevel=4` (Linux version is
  KERN_NOTICE, so it printed nothing). On the O6N that text is drawn by fbcon on a high-resolution
  framebuffer without acceleration; on top of USB probing, NVMe, PCIe and GPU messages it will be larger than
  in KVM.
* Fixed: rEFInd `timeout 3` (measured menu wait 3.2 s), Install entry `quiet loglevel=3
  vt.global_cursor_default=0 consoleblank=0` (kernel console lines before d-i: 415 to 0). Net effect under KVM:
  d-i banner 20.0 to 14.2 s, first screen 31.2 to 27.2 s.
* Cannot be measured under KVM: rEFInd text-mode switching, reading 91 MB of kernel and initrd from a USB
  stick, real NIC link negotiation (`netcfg/dhcp_timeout=120`; early_command waits up to 25 s for a wired
  carrier, 3 s when no PCI ethernet exists), and real device probing.

### Finding B: "transition blanks the screen, then shows d-i again"

Operator: directly after the three-component choice.

* No VT switch exists in the installer scripts (no `chvt`, `openvt`, `setterm`, `deallocvt`, `fbset`).
* Sequence right after the chooser: anna retrieves and installs about 285 udebs, then hw-detect runs and
  udev coldplugs. The installer kernel (`config-7.2.8-sky1-ncz`) has `CONFIG_FB_EFI=y`,
  `CONFIG_DRM_SIMPLEDRM` **not set**, `CONFIG_DRM_LINLONDP=m`, `CONFIG_DRM_TRILIN_DPSUB=m`,
  `CONFIG_DRM_FBDEV_EMULATION=y`, `FRAMEBUFFER_CONSOLE_DEFERRED_TAKEOVER` not set, and the initrd
  `modules.alias` maps `acpi*:CIXH50C0:*` to `linlon_dp`. The console is efifb until a DRM driver loads; when
  `linlon_dp`/`trilin_dpsub` load, DRM re-modesets the panel and fbcon re-attaches: the screen goes blank and
  newt redraws d-i. The operator's own module list (`amvx`, `trilin_dpsub`, `linlon_dp`) is consistent with it.
* Fix: the arm64 Install and Expert entries add `linlon_dp,trilin_dpsub` to `module_blacklist`, so the
  firmware framebuffer stays the console for the whole install. The installed system boots with its own
  cmdline (70-bootloader.sh) and loads them normally. Rescue is unchanged.
* Not reproducible under KVM (no Sky1 display controller). To confirm on the O6N without touching the
  install: in the installer's dmesg look for `linlon` or `fb: switching to` near the blank; with the
  blacklist the line must not appear.
* Also removed: raw `[ncz]`/`[ncz components]`/`[ncz chooser]`/`[diag]` progress lines echoed over the newt UI on
  VT1 and /dev/console (the likely cause of the display "corruption at the top"); they now go to VT3 and the
  serial diag console, and only ABORT/FATAL/ERROR reach VT1. The default diagnostics password is no longer
  printed on screen.

### Finding C: "a 7.1 kernel is copied during preseed"

* The running installer kernel is ours: `Linux version 7.2.8-sky1-ncz`.
* The medium's pool is the Debian netinst substrate's: 38 udebs for `7.1.8+deb14.1` and 39 for
  `7.2.6+deb14`. anna retrieves `linux-base-7.1.8+deb14.1-arm64-di` (a dependency meta-udeb) among ~285 udebs.
  base-installer finds Debian kernels and does not install one (`kernel/skip-install` true); the installed
  system contains no Debian kernel (only `7.2.8-sky1-ncz`, plus the baked `7.3.0-rc3-sky1-ncz`).
* The initrd holds `/lib/modules/7.2.6+deb14-arm64` (960 modules, 15.7 MB) next to ours (198 modules,
  39.9 MB). Neither Debian tree can load into 7.2.8-sky1-ncz (vermagic), so both are dead weight, not a
  functional problem. Removing the initrd copy means repacking the base initrd segment for ~6 MB compressed;
  not done. Recommended follow-up if the initrd size matters.

## 2. Install errors traced to root cause

| symptom | root cause | fix |
|---|---|---|
| `Package 'sudo' has no installation candidate`, `Unable to locate package installation-report` / `popularity-contest` | the media apt index is generated from the offline mirror's seed closure only; those three packages were absent from it although their debs sit in the substrate pool | `manifests/install-extra.pkgs` seeds them; the gate asserts sudo is installed and the sudo group has a member |
| hostname `ncz-20e7bc` instead of an IAU name | the installer computed a suggestion, then d-i **reloaded the media preseed**, resetting `netcfg/get_hostname` to `ncz-setup` (seen=true); first boot then used a MAC-hex fallback. With `priority=critical` d-i also never shows its own hostname question | one generator (`preseed/ncz-hostname-gen.sh`), a CRITICAL `ncz/hostname` question for interactive installs, the choice saved in `/tmp/.ncz-hostname` and re-applied on the second early_command run; the gate requires `^ncz-[a-z]{1,8}-[0-9]{4}$` |
| kernel package `+r258` although `r277` was staged | `build-kernel-debs.sh` had `BUILD_REV=r258` as a constant | derived from the staged directory name; an older override is refused |
| `ldconfig.service` failed on first boot | `Renaming of /etc/ld.so.cache~ ... failed`; the boot clock still read the image build date so systemd judged /etc older than /usr and raced another cache rebuild | one final `ldconfig` in late.sh, `/etc/.updated` and `/var/.updated` stamped ahead, `SuccessExitStatus=1` backstop |
| singularity plugin patches missing on the installed system | `20-desktop.sh` dpkg -i'd the last `ncz-singularity-desktop` found in `/cdrom/pool/main` and `assets/cix-debs`; the copy baked into base.squashfs was an older build with the same version string and replaced the fresh hotfix layer | payload copy consulted last, mirror takes the deb from `assets/cix-debs` |
| Bing daily timer missing | `45-wallpaper-rotator` runs while the desktop layer is built (it is skipped at install), so a new hook needs a desktop layer rebuild | layers rebuilt (`build-squashfs-layers.sh all`) |
| installer used the network during "install" | base-installer rewrites the target sources to `deb.debian.org` after the debootstrap stub pinned `file:///cdrom`, then runs `apt-get update` (16.7 MB) and an upgrade of 54 packages (28 MB) in the target; the KVM guest has internet so it takes seconds, on a slow link it is minutes of silent progress bar | NOT fixed. Restricting the guest network (`--offline`) shows the install still completes. Recommended: make `50mirror` and the base-installer source rewrite honor the pin, or block network during install |

## 3. What KVM verified, and what only the O6N can show

Verified under KVM: the timeline numbers above; the installer boots and installs with the new options (quiet,
3 s menu, blacklist accepted); unattended and interactive-simulated hostname behavior (stubbed debconf, sh,
dash and the installer's busybox ash); the installed system's hostname, sudo, first-boot failed-unit report,
wallpaper helper smoke run, all accelerator/package assertions.

Only the real O6N can show: whether the blank is really the `linlon_dp`/`trilin_dpsub` DRM takeover and that
the blacklist removes it; real-hardware boot duration and console drawing time; the interactive hostname
dialog on a monitor; VPU/NPU/GPU function; screensaver rendering; sensors colors with a hot reading.
