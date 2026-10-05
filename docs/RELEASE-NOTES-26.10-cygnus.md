# NCZ-OS 26.10 "Cygnus" release notes

**Release line:** 26.10
**Codename:** Cygnus
**Base:** Debian testing (Forky)
**Platforms:** CIX Sky1 (arm64) and AMD64 (including Apple T2 Macs)
**Status:** release-candidate notes. Build identifier and checksums are added at
tag time (`v26.10-r<n>`); see [Versions](#versions).

---

## Summary

NCZ-OS 26.10 "Cygnus" updates the Singularity desktop, ships 74 screensavers,
and moves both architectures to the 7.2.9 stable kernel, which is also the
installer boot kernel. CIX Sky1 (arm64) gains a non-default 7.3.0-rc6 edge
kernel; AMD64 keeps the 7.2.9 default only. The release adds installer, boot, and
clock fixes and the Cygnus release identity. Cygnus is the northern constellation
and the black hole Cygnus X-1, a fitting referent for the default Black Hole
screensaver.

## What's new

### Desktop

- **Singularity Desktop updated** to upstream `5c75e563` (build
  `20261005+u20260925.g5c75e563d10e`), arm64 and AMD64, with NCZ patches for
  wallpaper attribution position, sensors settings, Bing wallpaper preference and
  prefetch, and OCS import.
- **Native greeter.** Login uses greetd with the native Singularity greeter on
  the same labwc stack as the desktop, replacing the previous GTK greeter path.
- **Native boot splash.** The KMS-based `singularity-boot-splash` waits for a
  display mode before drawing and replaces Plymouth.
- **Screensaver settings in the shell.** Screen lock, idle timeout, display
  power-off, and animated-screensaver options are configured from a Screensaver
  page in Singularity settings.

### Screensavers

The `ncz-screensavers` package ships **74 screensavers**: 30 hyprsaver titles,
30 Shadertoy (xshadertoy) titles, 11 ported classics (cityflow, crackberg,
cubestorm, datatowers, geodesic, hexstrut, hypertorus, klein, noof, projective
plane, voronoi), and 3 home-grown titles — **Black Hole**, **Magmasimplex**, and
**Fractasia**.

- **Black Hole** remains the default and gains the Cygnus palette.
- **Magmasimplex** joins the collection: a molten-wax simulator with a live beat
  engine, optional audio sync, a photosensitivity limiter, and a Flowerchild
  dendrite mode.
- **Fractasia** gains a boundary-view picker, a 13-scheme palette library, and a
  table of effect recipes selected within the detected GPU tier.
- **Settings UI** is regrouped by style category, with search, an engine filter,
  and favourites; Black Hole gains a simple mode and still previews.
- **GPU tiers.** Each detected GPU is classified (weak / mid / strong) and
  screensavers are filtered against the class, so heavy titles do not run on
  hardware that cannot sustain them.
- **Idle and lock fixes.** The idle manager recovers from logout/login and from a
  greeter restart instead of failing permanently.

### Kernels and hardware support

Stable 7.2.9 is the default boot kernel and the installer boot kernel on every
architecture; edge 7.3.0-rc6 is a separate, non-default entry.

**Arm64 — CIX Sky1**

- Default `7.2.9-sky1-ncz` (revision r281), which also boots the installer.
- Edge `7.3.0-rc6-sky1-ncz` (r282) as a non-default entry, with Mali, NPU,
  Panthor, and VPU accelerator overlays.
- 7.2.9 fixes a DKMS-headers post-install failure that left the kernel packages
  unconfigured on upgrade from 7.2.8.

**AMD64 — T2 Macs and PCs**

- Default `7.2.9-2-t2-trixie`, the T2 kernel that carries `t2smc` and omits the
  in-kernel Apple SMC driver; booted and checked on a MacBook Pro 16,1.
- No edge 7.3.0-rc6 entry ships on AMD64. See [Known issues](#known-issues).
- Intel VA-API decode (`intel-media-va-driver`) is now in the offline desktop
  closure, so Intel integrated GPUs get hardware decode on an offline install.
- Sky1-only USB rescan and performance-mode workarounds no longer run on T2 Macs,
  removing a keyboard-enumeration race and idle CPU/thermal load.

### Installer and boot

- **Installer boots 7.2.9 on both architectures**; 7.2.8 is retired.
- **Calmer installer console.** Dialog titles carry the product, release, and
  codename plus a platform and build line; template text is ASCII; disk erase has
  an explicit review and confirmation; hostname and component dialogs run just
  before partitioning, so there is no blank console between them.
- **Visible heartbeat.** The installer heartbeat banner is written to the
  displayed console as well as the diagnostic consoles.
- **rEFInd** uses a 3-second timeout and a quiet console, keeping the firmware
  framebuffer until the desktop takes over.
- **Time corrected before TLS is needed.** A Phase-0 hook sets the clock from a
  plain-HTTP time source ahead of the first package fetch, and the RTC sync waits
  for a real NTP sync before writing the hardware clock. Boards whose RTC starts
  years in the past no longer boot each fresh install with a stale clock.
- **First-boot health report** records any failed systemd units after first boot.
- **GPU health check** runs at boot and fails loudly if a machine with a GPU falls
  back to software rendering.

### Fixes

- Boot hygiene removes the failed units and the repeated btrfs `nodelalloc`
  message seen on every boot.
- Sky1 HDMI/DisplayPort audio autoswitch picks the connected display sink and
  falls back to analog across boards.
- Wallpaper rotation and provider fixes (Bing, OCS, artist packs), including the
  preferred-market setting and login-time prefetch.

## Known issues

- **No AMD64 edge kernel.** The 7.3.0-rc6 AMD64 kernel was built and validated
  (it carries the revert of an upstream PCIe AER change that powered T2 MacBooks
  off within seconds), but the AMD64 edge boot entry is not part of this release.
  The AMD64 default remains 7.2.9-2-t2-trixie.
- **Cygnus visual theme not applied.** The Cygnus colour tokens, theme files, and
  rEFInd theme are in the source tree but are not wired into the image build. The
  release identity (name, version, codename) is applied; the full theme and the
  Cygnus wallpapers are not yet shipped.
- **T2 installer keyboard.** On T2 Macs the internal keyboard is inactive during
  the installer; use a USB keyboard. It works normally on the installed system.
- **Uneven hardware validation.** Only one T2 Mac model has been installed and
  booted by the project; Radxa Orion O6 is user-reported rather than tested
  in-house; the Orange Pi 6 and MetaComputing Framework mainboard are untested.
  See [Supported hardware](#supported-hardware).

## Upgrading and installing

- Existing systems on 7.2.8 move to the 7.2.9 stable kernel; 7.2.8 is retired.
  Boot entries update on the next kernel install.
- Systems on the 7.3.0-rc5 edge kernel move to 7.3.0-rc6 on arm64. AMD64 systems
  have no edge entry.
- Installed systems use the live Debian mirror; the build uses a pinned snapshot
  for reproducibility. A shipped system is not frozen to the build snapshot.
- Sky1 boards require Radxa Orion EFI 1.3.1 or newer. Older firmware
  under-enumerates the board's USB and is out of scope.

## Supported hardware

Arm64 — CIX Sky1:

- **Minisforum MS-R1** (32 GB and 64 GB) — verified: UEFI boot, installer, Mali
  GPU, NPU, VPU, audio, networking.
- **Radxa Orion O6N** (48 GB) — verified: install, boot, Mali GPU, NPU, VPU,
  audio, 2.5 GbE.
- **Radxa Orion O6** — reported working by users; not directly tested.
- **Orange Pi 6 (CIX variant)** and **MetaComputing CP8180 Framework mainboard** —
  same SoC, not yet tested.

AMD64:

- **Apple T2 Macs, 2017–2020** — one model (2019 MacBook Pro, AMD Navi GPU)
  tested for install, GPU acceleration, first-boot networking, and HiDPI console.
  The internal keyboard is inactive during the installer only.
- **Pre-T2 Intel Macs, roughly 2012–2017** — expected to work through the generic
  UEFI path; not yet install-tested.
- **Generic UEFI Intel/AMD PCs** — solid confidence 2014 and newer, lightly
  tested.

GPU compute floors: AMD ROCm roughly 2016+, NVIDIA CUDA Kepler+, Intel
oneAPI/Level-Zero roughly Skylake+. A working install does not imply a working
compute stack.

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
