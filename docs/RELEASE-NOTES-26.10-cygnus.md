# NCZ-OS 26.10 "Cygnus" release notes

**Release line:** 26.10
**Codename:** Cygnus
**Base:** Debian testing (Forky)
**Platforms:** CIX Sky1 (arm64) and AMD64 (including Apple T2 Macs)
**Status:** release-candidate notes for the 26.10 line. The build identifier and
image checksums are added when the image is tagged (`v26.10-r<n>`); see
[Versions](#versions).

---

## Summary

NCZ-OS 26.10 "Cygnus" updates the Singularity desktop, ships a refreshed
screensaver collection of 74 titles, and moves both architectures to the 7.2.9
stable kernel. 7.2.9 is also the installer boot kernel on both architectures. On
CIX Sky1 (arm64) the release adds a separate, non-default 7.3.0-rc6 edge kernel;
AMD64 keeps the 7.2.9 default only. The release carries installer, boot, and
clock fixes, and the new Cygnus release identity.

The name Cygnus is the constellation in the northern sky and the black hole
Cygnus X-1, a fitting referent for the Black Hole screen that is the default
screensaver.

## What's new

### Desktop

- **Singularity Desktop updated** to upstream `5c75e563` (build
  `20261005+u20260925.g5c75e563d10e`), built for arm64 and AMD64, with the NCZ
  patch series for wallpaper attribution position, sensors settings, Bing
  wallpaper preference and prefetch, and OCS import.
- **Native greeter.** Login uses greetd with the native Singularity greeter on
  the same labwc session as the desktop, replacing the previous GTK greeter
  path.
- **Native boot splash.** The boot splash is the KMS-based
  `singularity-boot-splash`, which waits for a display mode before drawing. It
  replaces Plymouth on this platform.
- **Screensaver settings in the shell.** Screen lock, idle timeout, display
  power-off, and the animated-screensaver options are configured from a
  Screensaver page in Singularity settings.

### Screensavers

The `ncz-screensavers` package ships **74 screensavers**:

- 30 from the **hyprsaver** set.
- 30 from the **Shadertoy** (xshadertoy) set, including the home-grown
  **Neon Horizon** scene.
- 11 **ported classics** (cityflow, crackberg, cubestorm, datatowers, geodesic,
  hexstrut, hypertorus, klein, noof, projective plane, voronoi) as native GLES3
  programs.
- 3 **home-grown** titles: **Black Hole**, **Magmasimplex**, and **Fractasia**.

Highlights:

- **Black Hole** remains the default saver and gains the Cygnus palette
  (magenta and cyan on violet-black).
- **Magmasimplex** joins the collection: a molten-wax simulator with a live beat
  engine, optional audio sync, a photosensitivity limiter, and a Flowerchild
  dendrite mode.
- **Fractasia** gains a boundary-view picker, a 13-scheme palette library, and a
  table of effect recipes selected within the detected GPU tier.
- **Settings UI** is regrouped by style category, with search, an engine filter,
  and favourites; Black Hole gains a simple mode and still previews.
- **GPU tiers.** Each detected GPU is classified (weak / mid / strong) and
  screensavers are filtered and configured against the class so heavy titles do
  not run on hardware that cannot sustain them.
- **Idle and lock fixes.** The idle manager recovers from logout/login and from
  a greeter restart instead of failing permanently.

### Kernels and hardware support

The kernel channel policy for 26.10 is: **stable 7.2.9 is the default boot
kernel and the installer boot kernel on every architecture; edge 7.3.0-rc6 is a
separate, non-default entry.**

#### Arm64 — CIX Sky1

- Default: `7.2.9-sky1-ncz` (package revision r281), which also boots the
  installer.
- Edge: `7.3.0-rc6-sky1-ncz` (r282) as a non-default entry, with its Mali, NPU,
  Panthor, and VPU accelerator overlays.
- The 7.2.9 arm64 kernel fixes a DKMS headers post-install failure that left the
  kernel packages unconfigured on upgrade from 7.2.8.

#### AMD64 — T2 Macs and PCs

- Default: `7.2.9-2-t2-trixie`, the T2 kernel that carries `t2smc` and omits the
  in-kernel Apple SMC driver. It was booted and checked on a MacBook Pro 16,1.
- No edge 7.3.0-rc6 entry ships on AMD64. See [Known issues](#known-issues).
- Intel VA-API decode (`intel-media-va-driver`) is now part of the offline
  desktop package closure, so Intel integrated GPUs get hardware decode on an
  offline install.
- Sky1-only USB rescan and performance-mode workarounds no longer run on T2
  Macs, which removes a keyboard-enumeration race and idle CPU/thermal load.

### Installer and boot

- **Installer boots 7.2.9 on both architectures**; 7.2.8 is retired.
- **Branded, calmer installer console.** Dialog titles carry the product,
  release, and codename, plus a platform and build line; all installer template
  text is ASCII; the disk-erase step has an explicit review and confirmation
  dialog; the hostname and component dialogs run just before partitioning so
  there is no blank console between them.
- **Visible progress heartbeat.** The installer heartbeat banner is written to
  the displayed console as well as the diagnostic consoles.
- **rEFInd** uses a 3-second timeout and a quiet console, keeping the firmware
  framebuffer until the desktop takes over.
- **Time is corrected before anything needs TLS.** A Phase-0 hook sets the clock
  from a plain-HTTP time source ahead of the first package fetch, and the RTC
  sync now waits for a real NTP sync before writing the hardware clock. On
  boards whose RTC starts years in the past, this stops each fresh install from
  booting with a stale clock.
- **First-boot health report** records any failed systemd units after first
  boot.
- **GPU health check** runs at boot and fails loudly if a machine with a GPU
  falls back to software rendering.

### Fixes

- Boot hygiene removes the failed units and the repeated btrfs `nodelalloc`
  message that appeared on every boot.
- Sky1 HDMI/DisplayPort audio autoswitch selects the connected display sink and
  falls back to analog correctly across boards.
- Wallpaper rotation and provider fixes (Bing, OCS, artist packs), including the
  preferred-market setting and login-time prefetch.
- NVIDIA EGL runtime packages are installed for Turing-and-newer AMD64 GPUs so
  PRIME offload can select the NVIDIA GPU on Wayland.

## Known issues

- **No AMD64 edge kernel.** The 7.3.0-rc6 AMD64 kernel was built and validated
  (it carries the revert of an upstream PCIe AER change that powered T2 MacBooks
  off within seconds), but the AMD64 edge boot entry is not part of this release.
  The AMD64 default remains 7.2.9-2-t2-trixie.
- **Cygnus visual theme is not applied.** The Cygnus colour tokens, theme files,
  and rEFInd theme are present in the source tree but are not wired into the
  image build. The release identity (name, version, codename) is applied; the
  full magenta/cyan theme and the Cygnus wallpapers are not yet shipped.
- **T2 installer keyboard.** On T2 Macs the internal keyboard is not responsive
  during the Debian installer; use a USB keyboard for the install. The internal
  keyboard works normally on the installed system.
- **Hardware validation is uneven.** Only one T2 Mac model has been installed
  and booted by the project. Radxa Orion O6 is user-reported rather than tested
  in-house, and the Orange Pi 6 and the MetaComputing Framework mainboard are
  not yet tested. See [Supported hardware](#supported-hardware).

## Upgrading and installing

- Existing systems on 7.2.8 move to the 7.2.9 stable kernel; 7.2.8 is retired.
  Boot entries update on the next kernel install.
- Systems on the 7.3.0-rc5 edge kernel move to 7.3.0-rc6 on arm64. AMD64 systems
  have no edge entry.
- Installed systems use the live Debian mirror; the build uses a pinned snapshot
  for reproducibility. A shipped system is not frozen to the build snapshot.
- The installer requires Radxa Orion EFI 1.3.1 or newer on Sky1 boards. Older
  firmware under-enumerates the board's USB and is out of scope.

## Supported hardware

Arm64 — CIX Sky1:

- **Minisforum MS-R1** (32 GB and 64 GB) — verified working: UEFI boot,
  installer, Mali GPU, NPU, VPU, audio, and networking.
- **Radxa Orion O6N** (48 GB) — verified working: install, boot, Mali GPU,
  NPU, VPU, audio, and 2.5 GbE.
- **Radxa Orion O6** — reported working by users; not directly tested by the
  project.
- **Orange Pi 6 (CIX variant)** and **MetaComputing CP8180 Framework mainboard** —
  same SoC, not yet tested.

AMD64:

- **Apple T2 Macs, 2017–2020** — one model (2019 MacBook Pro, AMD Navi GPU)
  tested for install, GPU acceleration, first-boot networking, and HiDPI
  console. The internal keyboard is inactive during the installer only.
- **Pre-T2 Intel Macs, roughly 2012–2017** — expected to work through the
  generic UEFI path; not yet install-tested.
- **Generic UEFI Intel/AMD PCs** — solid confidence 2014 and newer, lightly
  tested by the project.

GPU compute floors: AMD ROCm roughly 2016 and newer (GCN4/Polaris), NVIDIA CUDA
Kepler and newer, Intel oneAPI/Level-Zero roughly Skylake and newer. A working
install does not imply a working compute stack.

## Versions

| Component | Arm64 (Sky1) | AMD64 (T2 / PC) |
|---|---|---|
| NCZ-OS | 26.10 Cygnus | 26.10 Cygnus |
| Base | Debian testing (Forky), snapshot `20260927T203404Z` | same |
| Stable kernel (default, installer) | `7.2.9-sky1-ncz` (r281) | `7.2.9-2-t2-trixie` |
| Edge kernel (non-default) | `7.3.0-rc6-sky1-ncz` (r282) | not shipped |
| Desktop | Singularity `20261005+u20260925.g5c75e563d10e` | same |
| Screensavers | `ncz-screensavers` 0.8.6 (74 titles) | same |
| Build identifier | `v26.10-r<n>` (pending) | `v26.10-r<n>` (pending) |
