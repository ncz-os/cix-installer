<p align="center">
  <img src="assets/branding/logo/ncz.png" alt="NCZ-OS" width="120">
</p>

<p align="center">
  <img src="docs/screenshots/26.10/00-hero.jpg" alt="NCZ-OS 26.10 Cygnus" width="900">
</p>

<h1 align="center">NCZ-OS</h1>
<p align="center"><em>Debian for Arm64 (CIX Sky1) and AMD64 (Intel/AMD PCs and Apple T2 Macs) — with working GPU, VPU and NPU drivers</em></p>

> ### NCZ-OS 26.10 "Cygnus" (images of 2026-10-13)
>
> **[Download from the Releases page](https://github.com/ncz-os/cix-installer/releases)** (one release: the current images)
> · [Release notes](docs/releases/26.10-cygnus-20261013.md)
> · [Hardware tested](#hardware-support--testing-status)
> · [Documentation index](docs/INDEX.md)
>
> | Image | For | Kernel |
> |---|---|---|
> | `ncz-os-arm64-20261013-d395bb2d.img` | CIX Sky1 boards (Radxa Orion O6N, Minisforum MS-R1) | `7.3.0-rc7-sky1-ncz` |
> | `ncz-os-amd64-20261013-d395bb2d.img` | Intel/AMD PCs and Apple T2 Macs | `7.3.0-rc7-t2-ncz` |
>
> | Image | sha256 of the `.img` |
> |---|---|
> | arm64 | `f6de9e4f830fd5d450b1e00654cc9341aae1a5ca070bc66f9a5a76b3ca3ba4a7` |
> | amd64 | `7f23dcde01bd1aac9aae4bd7cee2ec87392a94d782002e8abea7f28653886851` |
>
> Each image is a raw GPT disk image, split into parts on the release page
> (GitHub limits files to 2 GiB). Put the parts of your architecture, its
> `PARTS-<arch>.sha256` and `SHA256SUMS-<arch>` (on older releases
> `PARTS.sha256` and `SHA256SUMS`) and [`ncz-join-image.sh`](tools/ncz-join-image.sh) in one folder and run
> `sh ncz-join-image.sh arm64` (or `amd64`): it checks every part, joins and
> unpacks them and checks the finished `.img`. It never writes to a disk. Then
> write the `.img` to a drive of at least 16 GB — see
> [Quick start (install on hardware)](#quick-start-install-on-hardware).
>
> Both images are built on a release-candidate kernel (7.3.0-rc7). Back up
> anything you care about before you install.

## Why NCZ-OS exists

Our objective is to build the most modern, hardware-exploitative Linux
distribution possible for Arm64 and x86 systems — while extending those
same advantages to legacy but still-useful hardware, such as Apple T2
Macs and x86 PCs from 2012 onward, that can no longer migrate to modern
operating systems from Apple and Microsoft.

We aim to meaningfully reduce the e-waste pile by giving these
still-capable systems new life and purpose in the age of agentic systems
and generative AI — real, current kernel and driver work, not a
frozen-in-time legacy distro.

# cix-installer

> **🌐 Language:** English · [简体中文](README.zh-CN.md)
>
> **📚 Start here:** [Documentation index](docs/INDEX.md) · [26.10 release notes](docs/releases/26.10-cygnus-20261013.md) · [Design rationale — why it is built this way](docs/DESIGN-RATIONALE.md) · [AI/ML Stack Reference](docs/AI-ML-STACK.md) ([中文](docs/AI-ML-STACK.zh-CN.md)) · [Source releases](docs/SOURCE-RELEASES.md) · [Download the image](https://github.com/ncz-os/cix-installer/releases)

**The installer and image build for the NCZ-OS Linux distribution.**

`make image` produces a bootable **raw GPT installer image**
(`ncz-os-<arch>-<date>-<sha>.img`) for **two first-class target
architectures** that share one build pipeline and one userland:

- **Arm64 — CIX Sky1** (Radxa Orion O6N, Minisforum MS-R1). Native Mali-G720
  GLES (Panthor Vulkan as an experimental boot entry), Zhouyi V3 NPU, Linlon
  VPU — all driven by CIX DKMS accelerator modules on top of the NCZ Sky1
  kernel.
- **AMD64 — Intel/AMD PCs and Apple T2 Macs.** Standard Intel/AMD/NVIDIA
  drivers wired at install time from each vendor's real, signed apt
  repository; on T2 Macs, the NCZ T2 kernel plus Apple firmware and audio
  configuration from the AdityaGarg8 `t2-ubuntu-repo`.

The installer runs the **upstream Debian Installer (d-i)**, taken from the
Debian Testing netinst image and pinned by content hash per architecture
(`manifests/base.pin`). NCZ customisations are applied at the **assembly
layer** — the installer boots our kernel instead of Debian's, a few grafted
udebs and NCZ dialogs, the squashfs payload, and a rEFInd ESP — not by
hand-patching d-i itself. The installer extracts a pre-built **Debian Testing
(Forky)** system (`release.conf`) with the hardware-appropriate kernel, vendor
userspace, the Singularity desktop and the opt-in NCZ agent stack, and brands
it as NCZ-OS. See [Architecture](#architecture).

> **Current release: NCZ-OS 26.10 "Cygnus"** — the Singularity
> desktop (labwc/wlroots) in the Cygnus theme, one kernel per image:
>
> | | Sky1 (Arm64) | Intel/AMD PCs and T2 Macs (AMD64) |
> |---|---|---|
> | **Kernel** | `7.3.0-rc7-sky1-ncz` (build r289) | `7.3.0-rc7-t2-ncz` (package `7.3.0-rc7-2`) |
>
> The default, installer and rescue boot entries all boot that one kernel; the
> rescue entry blacklists the GPU/accelerator drivers
> (`assets/kernel/KERNEL-POLICY`). The 7.2 line and the old "edge" channel
> are retired. 7.3.0-rc7 is a **release candidate**; it will be replaced by
> 7.3.0 final.
>
> **Release notes:** [26.10 "Cygnus"](docs/releases/26.10-cygnus-20261013.md) ·
> [Download from the Releases page](https://github.com/ncz-os/cix-installer/releases)

> ### Remote access defaults
>
> NCZ-OS is built for **home users, hobbyists and lab benches**, and its
> defaults reflect that: **telnet (port 23)**, a failsafe root console on
> **2323**, SSH with password auth and root login, and a recovery container
> that takes **its own IP on your LAN**. They exist so a board you have just
> broken is still reachable — several of these machines are headless with no
> usable serial console.
>
> On a home LAN behind a router we do not consider this a meaningful exposure.
> **In an enterprise, on a shared network, or on anything with a routable
> address, turn it off** — one command, below.
>
> **→ [docs/REMOTE-ACCESS.md](docs/REMOTE-ACCESS.md)** — exactly what is
> enabled, why, and how to disable each part.

## What's in 26.10 "Cygnus"

- **Singularity desktop** (labwc/wlroots, native Wayland) in the **Cygnus
  theme** — magenta and cyan on violet-black (`branding/cygnus/`), with a
  Cygnus wallpaper set and boot-menu theme. Every window has minimize,
  maximize and close buttons by default, system-wide.
- **First-login tour** of the desktop, the wallpapers and artist packs, the
  online wallpaper sources and the screensavers (plus, on Sky1, hardware video
  decoding in Chromium). It opens a few seconds after the first login, before
  the quote of the day, the firewall notice and the update notice (they wait
  until the tour is closed, at most 90 seconds), and runs once per user; to see
  it again, delete `~/.local/state/ncz/tour-seen` and log in again. The tour
  runs at idle CPU priority with animations off, so it does not heat the
  machine while it is open.
- **Screensavers:** NCZ Screensavers 0.8.16 (settings plugin 0.3.25) with 74
  savers, including the Black Hole (the default, in the Cygnus palette),
  Fractasia and Magmasimplex. Choose and preview them in Settings →
  *Screensaver and Lock*. Heavy savers are best on a stronger GPU.
- **Lock screen over a live screensaver.** The saver and the lock start
  together after 5 minutes idle; the password prompt appears only on the first
  key press, click or pointer movement. Behind the lock the saver runs at
  30 fps and full resolution (15 fps on battery, on a weak GPU and on T2
  MacBooks; adjustable in Settings) and keeps animating until you touch the
  machine. When the prompt appears the saver is paused on its current frame,
  and it continues from there if the prompt is left alone for a minute. A
  thermal guard pauses it while the machine is hot.
  (Pause-on-prompt, the 30 fps / auto-15 fps policy and the 60 s prompt
  timeout require ncz-screensavers 0.8.16+ with shell patch 0024; the plugin
  and payload hashes for that are staging placeholders until the unified
  payload rebuild — see `post-install/lib/ncz-screensavers-plugin.lock`.)
- **Login screen that matches the lock screen** (greetd with the native
  Singularity greeter), at the panel's native resolution on T2 MacBooks.
- **Wallpapers:** Artist Packs (NCZ, Cygnus, Alex Jay Brady, Brandon Perlow,
  Singularity) rotating every 10 minutes, plus Bing and OCS online sources —
  see [Artist packs](#artist-packs) below.
- **Browsers:** on Sky1, Chromium NCZ Sky1 Edition (default) with hardware
  video decode for H.264, VP9 and AV1, plus Google Chrome and Vivaldi; on
  amd64, Vivaldi (default) and Google Chrome.
- **Sky1:** Mali GPU driver by default with Panthor as an experimental boot
  entry, VPU hardware video decode (verified on the Radxa Orion O6N and MS-R1), the
  NPU runtime, and automatic HDMI/DP audio switching.
- **Apple T2 Macs:** a kernel with Apple T2 support (tested on
  MacBookPro16,1), a CPU package power cap
  ([docs/T2-POWER-CAP.md](docs/T2-POWER-CAP.md)), the T2 fan/SMC drivers, and Apple Wi-Fi/Bluetooth firmware and
  audio configuration fetched from the t2-ubuntu-repo at first boot.
- **Updates and recovery:** an NCZ-OS update manager, a rescue boot entry on
  the same kernel, a rescue partition (wired ports use DHCP) and a live
  recovery container with its own SSH host keys per device (see
  [docs/REMOTE-ACCESS.md](docs/REMOTE-ACCESS.md)). No SSH keys are
  preinstalled; `~/.ssh/authorized_keys` is left to you.
- **Accessibility:** braille displays are supported on the installed system
  after `sudo apt install brltty`; the installer itself has no braille support
  ([docs/ACCESSIBILITY.md](docs/ACCESSIBILITY.md)).
- **Agent stack (opt-in):** `ncz install mnemos`, `ncz install zoder` and
  `ncz agent install <name>` set up MNEMOS, zoder and the agent runtimes end
  to end ([docs/NCZ-AGENT-STACK.md](docs/NCZ-AGENT-STACK.md)).

What changed since Preview 1 (2026-10-12) is listed in the
[release notes](docs/releases/26.10-cygnus-20261013.md#changes-since-preview-1).

### Artist packs

26.10 ships two Artist Packs of original work contributed to NCZ-OS by their
artists: **[Brandon Perlow](https://www.artstation.com/brandonperlow)**
(`ncz-wallpapers-brandon-perlow` 1.0, 7 images) and
**[Alex Jay Brady](https://www.artstation.com/boac)**
(`ncz-wallpapers-alex-jay-brady` 1.0, 8 images). Pick them in the desktop's
Artist Packs chooser or let them rotate. The artwork belongs to the artists; it
is contributed for distribution with NCZ-OS; separate reuse needs the artist's
permission (the licence is not yet recorded). The screenshots in this README show it, with credit, only as
it appears in the desktop.

## Screenshots

All screenshots are from NCZ-OS 26.10 images.

### Artist packs

<p align="center"><em>Artwork © the artists, contributed for distribution with NCZ-OS and shown here, with credit, as it appears on the desktop. Separate reuse needs the artist's permission (the licence is not yet recorded).</em></p>

<p align="center">
  <img src="docs/screenshots/26.10/artist-showcase-brandon-perlow-nimbus.jpg" alt="Desktop with a wallpaper by Brandon Perlow" width="820">
</p>
<p align="center"><em>A wallpaper by [Brandon Perlow](https://www.artstation.com/brandonperlow), from his Artist Pack, applied to the desktop (signature and links are part of the artwork).</em></p>

<p align="center">
  <img src="docs/screenshots/26.10/artist-showcase-brandon-perlow-cthulhu.jpg" alt="Desktop with a wallpaper by Brandon Perlow" width="820">
</p>
<p align="center"><em>Another wallpaper by [Brandon Perlow](https://www.artstation.com/brandonperlow) from the same pack.</em></p>

<p align="center">
  <img src="docs/screenshots/26.10/artist-showcase-alex-jay-brady-ringworld.jpg" alt="Desktop with a wallpaper by Alex Jay Brady" width="820">
</p>
<p align="center"><em><i>Anti-stellar projectiles penetrate a braided ringworld</i> by [Alex Jay Brady](https://www.artstation.com/boac), from his Artist Pack.</em></p>

<p align="center">
  <img src="docs/screenshots/26.10/artist-showcase-alex-jay-brady-galaxies.jpg" alt="Desktop with a wallpaper by Alex Jay Brady" width="820">
</p>
<p align="center"><em><i>Galaxies exiting the Universe</i> by [Alex Jay Brady](https://www.artstation.com/boac).</em></p>

<p align="center">
  <img src="docs/screenshots/26.10/08-tour-artists.jpg" alt="First-login tour slide about the artist wallpaper sets" width="820">
</p>
<p align="center"><em>The first-login tour introduces the wallpaper sets: NCZ, Cygnus, Alex Jay Brady and Brandon Perlow.</em></p>

### Wallpaper sources

<p align="center">
  <img src="docs/screenshots/26.10/04-wallpaper-search.jpg" alt="Settings search for wallpaper" width="820">
</p>
<p align="center"><em>Searching Settings for "wallpaper" lists every wallpaper page: Current Wallpaper, Explore Wallpaper Sources, Rotate Wallpapers, Dynamic Wallpaper, Artist Packs and the Wallpaper Manager.</em></p>

<p align="center">
  <img src="docs/screenshots/26.10/05-wallpaper-sources.jpg" alt="Wallpapers page with Bing photographs" width="820">
</p>
<p align="center"><em>The Wallpapers page: Explore Wallpaper Sources shows the Bing daily photographs to browse and apply, with rotation, wallpaper info and Dynamic Wallpaper settings below.</em></p>

<p align="center">
  <img src="docs/screenshots/26.10/09-tour-online-wallpapers.jpg" alt="First-login tour slide about online wallpapers" width="820">
</p>
<p align="center"><em>The two built-in online sources: Bing, and the OCS networks (pling.com, opendesktop.org, kde-look.org).</em></p>

### Screensavers

<p align="center">
  <img src="docs/screenshots/26.10/06-screensaver-and-lock.png" alt="Screensaver and Lock settings pane" width="820">
</p>
<p align="center"><em>Settings → Screensaver and Lock: the Screensaver and Lockscreen page chooses the screensaver, idle timers, screen lock and display power-off.</em></p>

<p align="center">
  <img src="docs/screenshots/26.10/13-saver-blackhole.jpg" alt="Black Hole screensaver" width="820">
</p>
<p align="center"><em>Black Hole, the default saver, in the Cygnus palette.</em></p>

<p align="center">
  <img src="docs/screenshots/26.10/14-saver-magmasimplex.jpg" alt="Magmasimplex screensaver" width="820">
</p>
<p align="center"><em>Magmasimplex (best on a stronger GPU).</em></p>

<p align="center">
  <img src="docs/screenshots/26.10/15-saver-fractasia.jpg" alt="Fractasia screensaver" width="820">
</p>
<p align="center"><em>Fractasia.</em></p>

### Lock screen

<p align="center">
  <img src="docs/screenshots/26.10/12-lock-screen.png" alt="Lock screen with the password card" width="820">
</p>
<p align="center"><em>The lock screen after a key press: clock and password card over the blurred wallpaper. (`ncz` is the installer's default user name.)</em></p>

<p align="center">
  <img src="docs/screenshots/26.10/11-tour-lock.jpg" alt="First-login tour slide about the lock screen" width="820">
</p>
<p align="center"><em>The tour explains the lock screen: the saver plays for a few seconds, then holds still; the password prompt appears on the first touch.</em></p>

### First-login tour

<p align="center">
  <img src="docs/screenshots/26.10/07-tour-welcome.png" alt="Welcome slide of the first-login tour" width="820">
</p>
<p align="center"><em>The welcome slide of the 14-slide first-login tour.</em></p>

<p align="center">
  <img src="docs/screenshots/26.10/10-tour-screensavers.jpg" alt="First-login tour slide about screensavers" width="820">
</p>
<p align="center"><em>The screensaver slide: 74 savers in eight categories.</em></p>

### Desktop

<p align="center">
  <img src="docs/screenshots/26.10/01-desktop.png" alt="NCZ-OS desktop with the Cygnus wallpaper" width="820">
</p>
<p align="center"><em>The desktop with the default Cygnus wallpaper, top panel and dock.</em></p>

<p align="center">
  <img src="docs/screenshots/26.10/02-launcher.png" alt="Application launcher" width="820">
</p>
<p align="center"><em>The application launcher.</em></p>

<p align="center">
  <img src="docs/screenshots/26.10/03-settings-main.png" alt="Settings app main page" width="820">
</p>
<p align="center"><em>Settings, with the build identification in the panel.</em></p>

### Why this exists, and why it is built this way

Short version: NCZ-OS targets ARM systems whose GPU, VPU and NPU are the point
— not a board-support layer with a desktop bolted on, and not a lightweight
desktop ported to new silicon.

Every non-obvious decision here (the GPU stack, the codec path, dropping
X/XFCE for Singularity, the base distribution, the initramfs, the release
cadence) was made against a measurement on real Sky1 hardware. Those decisions
and their evidence are written up in full:

**→ [docs/DESIGN-RATIONALE.md](docs/DESIGN-RATIONALE.md)**

Claims there are tagged MEASURED, DECIDED or OPEN, so you can re-litigate them
on evidence rather than taste.

## Vendor-neutral by design

NCZ is **vendor-neutral by design and intent.** Goal: support every
Arm silicon system shipping in the marketplace and every mainstream
x86 platform, when sample hardware is obtainable for validation.

**Current shipping targets (both are first-class — shared build pipeline,
shared desktop, shared agent stack):**

- **Arm64 — CIX Sky1 / CP8180** — **Radxa Orion O6N** and **Minisforum
  MS-R1**, both tested on real hardware. This is where the CIX proprietary
  userspace (`libmali`, NOE, VPU firmware) and the four DKMS accelerator
  modules (`mali_kbase`, `panthor`, `amvx`, `aipu`) are wired in. Other Sky1
  boards (Orange Pi 6, the MetaComputing Framework mainboard) are untested.
  The repo name reflects history; the
  project scope does not.
- **AMD64 — Apple T2 Mac** — the Intel Macs with the T2 coprocessor
  (MacBookPro 15,x/16,x and MacBookAir 8,x/9,1, 2018–2020, among others);
  only the MacBookPro16,1 has been tested. Detection is by PCI `106b:1801` — Apple's own T2 bridge
  device ID, the same identifier `t2linux`'s `linux-t2-patches` keys off
  of (verified directly in the
  `9001-ACPI-x86-Apple-T2-systems-need-early-CPU-offlining.patch` source).
  On a T2 Mac, NCZ-OS wires `apple-bce`, `applesmc`, HID and APFS in-tree
  (our own `7.3.0-rc7-t2-ncz` kernel) and pulls Apple firmware + audio config
  from AdityaGarg8's real, signed `t2-ubuntu-repo` at first boot.
- **AMD64 — generic x86-64 PC** — same build, same userland, no CIX
  stack. The same image boots a normal Intel/AMD desktop or server; the
  vendor-specific accelerator repos (NVIDIA CUDA, AMD ROCm, Intel
  OpenVINO) wire automatically based on `lspci -nn` PCI-class detection
  in `post-install/54-gpu-accel.sh`. A machine with no discrete GPU is
  a silent no-op.

**Architecture policy, both directions:**

- **Arm roadmap**: Radxa Qualcomm-platform boards (Snapdragon + Hexagon
  NPU), Rockchip RK3588 / RK3576 family, MediaTek Genio, Apple Silicon
  (kit-only, not OS), and any Arm SoC shipping in volume that we can
  sample.
- **x86 roadmap**: keep AMD64 as a real first-class architecture; no
  arch-guards or fast paths that assume Arm64. The build takes
  `ARCH=arm64|amd64`; the AMD64 package manifests
  (`manifests/installer-base-amd64.pkgs`, `desktop-amd64.pkgs`,
  `rescue-amd64.pkgs`) are committed alongside the Arm64 originals, and
  `make parity` checks that both builds carry every common fix.
- **Embedding inference**: handled by `embedkit`
  (`post-install/47-embedkit.sh`) — a vendor-agnostic Python kit that auto-detects the highest-tier accelerator (NPU >
  GPU > CPU) at runtime. Same `Engine.auto()` call works on every
  silicon path. On x86 the NPU tier falls back to OpenVINO (Intel),
  ROCm (AMD), or CUDA (NVIDIA) depending on what the install hook found.
- **Agent runtimes**: side-by-side selectable and **fully opt-in — none is
  installed or active by default.** Run `ncz` (or `ncz agent install <name>`)
  to install `zeroclaw`, `openclaw`, `hermes`, or `portainer`, and `ncz install
  nemoclaw` for NVIDIA NemoClaw. Nothing agentic auto-starts at boot or
  auto-pulls from the network.

The build is a **staged pipeline** with one entrypoint,
`build/build-image.sh` (see [Building an image](#quick-start-build-the-installer-image)):
it builds the `base` / `desktop` / `desktop-hotfix` squashfs layers from the
package lists in `manifests/*.pkgs`, assembles them with the pinned Debian
Installer substrate, our kernel and a rEFInd ESP into the final `.img`, and
gates the result on provenance and a KVM install. The stages are listed under
[The build pipeline](#the-build-pipeline).

d-i itself stays stock; the NCZ grafts are the targeted payload that has to
ship in the initrd (the patched `debootstrap-udeb` stub that drives the
install-time branch, the NCZ installer dialogs, the kernel and hardware-initrd
overlays), shipped as ordinary files and udebs rather than a patched d-i
source tree.

## Hardware support & testing status

> **Read this before you flash anything.** NCZ is vendor-neutral *by
> design*, but "designed to support" is not the same as "tested on." This is
> the honest state of hardware validation for **26.10 "Cygnus"**
> (kernel `7.3.0-rc7`, a release candidate). Anything not listed as tested
> below has not been booted by us on this release.

### Supported GPUs and tested machines (26.10)

NCZ-OS 26.10 ships drivers for **AMD, NVIDIA and Intel GPUs on amd64**, **Arm Mali on CIX Sky1 (vendor Mali stack by default, open Panthor driver also available)**, and the **CIX Sky1 NPU and VPU**. Machines we ran it on:

| Machine | CPU | GPU (driver) | Tested |
|---|---|---|---|
| Radxa Orion O6N | CIX P1 (Sky1) | Arm Mali (vendor Mali; Panthor available) + NPU + VPU | Installed, desktop, video (VPU hardware decode) and audio playback |
| Minisforum MS-R1 | CIX P1 (Sky1) | Arm Mali (vendor Mali; Panthor available) + NPU + VPU | Installed, desktop, video (VPU hardware decode) and audio playback |
| Radxa Orion O6 | CIX P1 (Sky1) | Arm Mali (vendor Mali) + NPU + VPU | Desktop, applications and display mode switching confirmed by a community tester (installed from an earlier release and updated with the fixed desktop library) |
| MacBookPro16,1 (two units) | Core i9-9980HK, Core i7-9750H | AMD Radeon Pro 5300M/5500M class (Navi 14, `amdgpu`) + Intel UHD 630 (`i915`) | Installed, boots to desktop |
| ASUS ROG GU502LV laptop | Core i7-10750H | NVIDIA GeForce RTX 2060 Mobile (proprietary `nvidia`) + Intel UHD 630 (`i915`) | Installed, boots to desktop |
| HP OmniDesk desktop | Core Ultra 7 265 | Intel integrated graphics (Xe-LPG, `i915`) | Installed, boots to desktop |
| Dell Inspiron 5521 (2013) | Core i7-3537U | Intel HD Graphics 4000 (`i915`) | Installed, runs the desktop |
| Mac mini 2011 (Macmini5,1) | Core i5-2415M | Intel HD Graphics 3000 (`i915`) | Installed, desktop works (hardware-accelerated graphics) |

Other GPUs and boards are untested. Video and audio playback and VPU hardware video decode were verified on the Sky1 boards; hardware video decode on other GPUs depends on the driver.

"Installed, boots to desktop" means the machine was installed from the
release image and reached the desktop; it does not mean every device on it was
exercised. Not covered by these tests: suspend on Sky1, audio and video
playback on amd64, CUDA, and every machine not in the table.

### Arm64 — CIX Sky1 boards

| Board | SoC | Status |
|---|---|---|
| **Radxa Orion O6N** | Cix Sky1 / CP8180 | ✅ **Tested on 26.10** — installed, desktop, video (VPU hardware decode) and audio playback. Our main development and test board. Realtek NICs (RTL8125/8126) work out of the box via the `rtl_nic` firmware shipped in the installer and the installed system. |
| **Minisforum MS-R1** (32 GB, and 64 GB "jumbo") | Cix Sky1 / CP8180 | ✅ **Tested on 26.10** — installed, desktop, video (VPU hardware decode) and audio playback. Its factory firmware omits the NPU `_HID`; the build adds an ACPI SSDT override (see below). |
| **Radxa Orion O6** | Cix Sky1 | ✅ **Confirmed working** by a community tester on 26.10 — desktop, applications and display mode switching stable after updating the desktop library (`libgtk4-layer-shell0` 1.3.0-1+ncz20261013, delivered by `apt upgrade`). A different board from the Radxa Orion O6N with the same SoC, kernel and drivers. Not yet tested by us on a fresh install of the 26.10 image. |
| **MetaComputing AI PC** — Arm mainboard for Framework Laptop 13 | Cix Sky1 / CP8180 | ⏳ **Untested, but the same SoC.** The kernel, GPU/VPU/NPU drivers and userspace should carry over; the unknowns are laptop-specific — panel/eDP, battery and thermals, lid/suspend, and the Framework EC. **No hardware in hand — testers welcome.** |
| **Orange Pi 6** (Cix variant) | Cix Sky1 | ⏳ **Untested.** Same SoC; not yet booted by us. |

Sky1 boards need **Radxa Orion EFI 1.3.1 or later** (or the vendor's
equivalent); see [docs/SUPPORTED-FIRMWARE.md](docs/SUPPORTED-FIRMWARE.md).

### AMD64 — Intel/AMD PCs and Apple T2 Macs

> The amd64 image is one build for three different classes of hardware. Each
> has its own constraints; this is not one blanket "x86 support" claim.

| Class | Window | Status |
|---|---|---|
| **T2 Macs** | **2018 – 2020** (plus the 2017 iMac Pro) | ⚠️ **One model tested: MacBookPro16,1** (two units) — installed, boots to desktop. The installer boots the NCZ T2 kernel; keep a USB keyboard at hand in case the internal keyboard does not respond during the install. The image sets a CPU package power cap on these machines ([docs/T2-POWER-CAP.md](docs/T2-POWER-CAP.md)). No other T2 model (iMac, Mac mini, MacBook Air, other MacBook Pro years) has been installed or booted. |
| **Pre-T2 Intel Macs** | **~2011 – 2017** | ⚠️ **One model tested: Mac mini (2011, Macmini5,1, Intel HD 3000)** — installed, desktop works with hardware-accelerated graphics. Other pre-T2 Macs are untested; older Broadcom Wi-Fi chips may need firmware that is not on the image. |
| **Generic PC (UEFI, Intel/AMD)** | solid confidence **2014+**, likely works **2012+** | ⚠️ **Lightly tested:** an HP OmniDesk desktop (Core Ultra 7 265, Intel Xe-LPG) and an ASUS ROG GU502LV laptop (NVIDIA GeForce RTX 2060 Mobile, proprietary driver) were installed and boot to the desktop, and a 2013 Dell Inspiron 5521 (Intel HD 4000) was installed and runs the desktop. Debian Testing (Forky) itself supports this range; other boards have not been booted by us. |

**GPU compute is a narrower window than "the base OS boots."** A working
install does not imply working ROCm/CUDA/oneAPI — the compute stacks have
their own, tighter hardware floors:

| Vendor | Compute stack | Realistic floor | Notes |
|---|---|---|---|
| **AMD** | ROCm (open `amdgpu` + Mesa RADV/RadeonSI — no proprietary alternative) | **~2016+** (GCN4/Polaris and newer) | `gfx1010`/`1011`/`1012` parts (Navi 1x, such as the Radeon Pro 5300M/5500M in the MacBookPro16,1) need `HSA_OVERRIDE_GFX_VERSION=10.3.0`; applied automatically by `post-install/54-gpu-accel.sh`. |
| **NVIDIA** | Proprietary driver and CUDA installed per GPU family at install time ([docs/CUDA-DYNAMIC-INSTALL.md](docs/CUDA-DYNAMIC-INSTALL.md)) | **2012+ / solid 2014+** (Kepler and newer); pre-Kepler falls back to nouveau, no CUDA | The proprietary driver was installed on an ASUS ROG GU502LV (RTX 2060 Mobile) on 26.10; CUDA itself was not tested. |
| **Intel** | oneAPI / Level-Zero (open `i915` + Mesa) | **~2015+** (Skylake-class iGPU and newer) | |

**NPU support on x86 is bleeding-edge only (2023+)** — Intel AI Boost / AMD
XDNA-class silicon. Treat it as best-effort, not a support commitment.

### Board-specific parts of the build

Parts of the build path are **per-board-specific** — e.g. an ACPI SSDT
override that works around the MS-R1 *factory BIOS bug* (it omits
`_HID="CIXH4010"` so the NPU cores never enumerate, Sky1-only), the T2 patch
series (`apple-bce`, `applesmc`, `bcm5974`; amd64-only, gated on PCI
`106b:1801` and DMI), firmware blob paths, and board quirks. On any other
board it may not boot, the NPU/GPU/VPU may not initialize, or the installer
may need board-specific work. **Testers and donated hardware are the fastest
way to change a ⏳ to a ✅.**

### Driver support matrix — Sky1 (ARM64)

> **Which kernel is this table about?** NCZ-OS 26.10 ships **one**
> Sky1 kernel, `7.3.0-rc7-sky1-ncz` (build r289;
> the pin is `assets/kernel/sky1-manifest.json`). The default, installer and
> rescue boot entries all boot it; the 7.2 line and the old "edge" channel are
> gone. Most rows below were first measured on the 7.2 kernel of 26.7 and
> re-checked at the system level on 7.3.0-rc7 on the Radxa Orion O6N and MS-R1.
>
> **Both GPU drivers ship.** `mali_kbase` (CIX vendor DDK, `cix-gpu-kmd`) is
> the default and provides GLES 3.2 and OpenCL via `libmali`. `panthor`
> (mainline open driver, `panthor-cix`, the Vulkan/PanVK path) is installed
> alongside it and selectable. Both are blacklisted in
> `/etc/modprobe.d/ncz-gpu-drivers.conf` so neither binds by accident; switch
> with `ncz-gpu-select`. See
> [GPU driver notes](#gpu-drivers-and-boot-options).

Sky1 boots via **ACPI, not a device tree** — `/sys/firmware/devicetree/base`
is empty on both the MS-R1 and the Radxa Orion O6N. The kernel build also produces a
`sky1-orion-o6.dtb`, but the boards boot via ACPI and do not need it.

| Subsystem | Driver | Config | MS-R1 | Radxa Orion O6N | Notes |
|---|---|---|---|---|---|
| **Clock** | `clk-sky1-acpi` | `=y` | ✅ | ✅ | ACPI clock infra (patch `0003`); base SoC infra in `0002`. |
| **Reset** | `reset-sky1` | `=y` | ✅ | ✅ | Reset controllers + ACPI lookup table (patch `0004`). |
| **Pinctrl** | `pinctrl-sky1` | `=y` | ✅ | ✅ | Patch `0007`. |
| **Mailbox** | `cix-mbox` | `=y` | ✅ | ✅ | ACPI support + channel lookup (patch `0005`). |
| **SCMI** | `arm-scmi` (clock + perf + power + sensor domains) | `=y` | ✅ | ✅ | ACPI boot support (patch `0006`); `CONFIG_ARM_SCMI_PERF_DOMAIN=y`, `CONFIG_ARM_SCMI_POWER_DOMAIN=y`. |
| **Thermal** | `cix-thermal` + IPA + cpufreq | `=y` | ✅ | ✅ | Patch `0017`. |
| **DSP** | `cix-dsp` + `cix-dsp-rproc` | `=m` | ✅ | ✅ | Remoteproc + rpmsg (patch `0019`); confirmed loaded (`cix_dsp_rproc`) on real Sky1 hardware (MS-R1). |
| **Audio (HDA)** | `snd-hda-cix-ipbloq` + Realtek ALC codecs | `=m` | ✅ | ✅ | Patches `2015`–`2017`. Verified ALC269VC analog + digital + HDMI/DP on real hardware (MS-R1). |
| **Audio (SoC)** | `snd-soc-sky1-sound-card` + Cadence I2S + `snd-soc-sof-cix` | `=m` | ✅ | ✅ | Patch `2014`. SOF (`CONFIG_SND_SOC_SOF_CIX_TOPLEVEL=y`, `CONFIG_SND_SOC_SOF_CIX_SKY1=m`) is built but not observed loaded on real hardware — the machine driver (`snd-soc-sky1-sound-card`) handles audio directly; SOF appears to be a dormant/fallback path, not confirmed active. |
| **GPU (Mali-G720)** | `mali_kbase` (default) **and** `panthor`, both DKMS; `drm-cix` + `drm-trilin-dp-cix` (DisplayPort) | DKMS | ✅ | ✅ | **Both drivers ship**, both blacklisted, one selected via `ncz-gpu-select`. Default `mali_kbase` measured on the Radxa Orion O6N: Mali-G720-Immortalis, 10 cores, **OpenGL ES 3.2 / EGL 1.5**, desktop accelerated. `panthor` is the mainline/Vulkan path. Display: `trilin_dpsub` + `linlon_dp` confirmed, DP up to 4K60. |
| **VPU (Linlon MVX)** | `amvx` via `cix-vpu-driver` (DKMS) | DKMS | ✅ | ✅ | Measured on the Radxa Orion O6N: **Linlon v5276, 4 cores**. Decode H.263/H.264/HEVC/MPEG-2/MPEG-4/VP8/VP9/AV1; hardware encode H.264/HEVC/VP8/VP9 confirmed via `ffmpeg` V4L2 mem2mem. Requires the 16 `*.fwb` codec blobs staged by `post-install/12-sky1-firmware.sh`. |
| **NPU (Zhouyi V3)** | `aipu` via `cix-npu-driver-dkms` 6.2.0 | DKMS (`CONFIG_ARMCHINA_NPU=n`) | ✅ | ✅ | Measured on **both** the Radxa Orion O6N and MS-R1: `nomic-embed-text-v1.5_256.cix` at **95.5 ms** per 256-token embed, deterministic across runs, `aipu` IRQ count advancing. The in-tree `armchina-npu` driver is superseded by the 26Q2-SDK DKMS driver. Requires a model package (`ncz-model-nomic-embed`); models are not in the image. |
| **Ethernet** | `r8169` (RTL8125/8126/8169) | `=y` | ✅ | ✅ | `rtl_nic` firmware shipped in installer + installed system. `CONFIG_R8169=y` (built-in, not a module). |
| **Wi-Fi** | `mt7921e` (MediaTek MT7921/MT7922) | `=m` | ✅ | ✅ | M.2 Key-E slot; confirmed loaded on real hardware (MS-R1). |
| **Wi-Fi (alt)** | `rtw88`/`rtw89` firmware | `=m` | ✅ | ✅ | If equipped (`rtw8852b`, `rtw8822`, etc. firmware shipped). |
| **PCIe / USB / PHY** | `pcie-cadence`, `usb-cdnsp`, `phy-cix-usbdp`, `phy-cix-pcie` | `=y` | ✅ | ✅ | Patches `0008`/`0009`/`0010`. |
| **USB Type-C (data)** | `xhci-hcd`, `usb-cdnsp` | `=y` | ✅ | ✅ | **Works.** The Type-C ports carry USB data normally — a USB-C drive attached to a Radxa Orion O6N enumerates and works on 7.2. Data goes through the xHCI/Cadence USB controller, which is entirely independent of the PD driver in the row below. |
| **USB Type-C (Power Delivery)** | `rts5453` (built-in) | `CONFIG_TYPEC=y` | ✅ | ✅ | **Works.** Measured on the Radxa Orion O6N: the driver binds (`rts5453 i2c-CIXH200D:00: port 0: register partner`), `/sys/class/typec/port0` reports `usb_power_delivery_revision 3.0`, `usb_typec_revision 1.2`, `power_role [source]`, `vconn_source yes`. **Note:** `module_blacklist=typec_rts5453,rts5453` still appears on the boot cmdline and is **inert** — the driver is built in, and `module_blacklist` only affects loadable modules. It is a leftover from an earlier kernel where the driver reportedly hung boot on an IRQ-151 conflict; that does not reproduce on 7.2. |
| **IOMMU/SMMU** | `arm-smmu-v3` | `=y` | ✅ | ✅ | Confirmed loaded on real hardware (MS-R1). |
| **GPIO / I2C / DMA / PWM / Syscon / Regulator / Timer / IRQ** | Sky1 misc peripherals | mixed | ✅ | ✅ | Patch `0018` (misc peripherals) + `0021` (firmware/pinctrl ACPI gaps). |
| **SoC ACPI resource lookup** | `cix-acpi-resource-lookup` | `=y` | ✅ | ✅ | `CONFIG_CIX_ACPI_RESOURCE_LOOKUP=y` confirmed; folded into patches `0002`/`0008`, not a standalone `9007`-style patch. |

The MS-R1 column reflects real-hardware confirmation carried forward from
earlier kernel lines. The Radxa Orion O6N column was validated on the 7.2 kernel and
again, at the system level, on 7.3.0-rc7 — see
[Hardware support & testing status](#hardware-support--testing-status). Treat
the marks as "confirmed at the system level" rather than independently
re-verified driver-by-driver on every kernel.

**Boot requirements.** Boot is ACPI-based; there is no DTB, and the same
kernel and firmware set serves the MS-R1 and the Radxa Orion O6N alike (and the Radxa Orion O6, confirmed by a community tester). The firmware that
must be present is `rtl_nic` (RTL8125/8126), `mali_csffw.bin` (Mali-G720), the
NPU firmware consumed by the `aipu` DKMS module, and the VPU firmware consumed
by `amvx`. The installer writes the ACPI kernel command line into the rEFInd
entry automatically:

```
acpi=force efi=noruntime arm-smmu-v3.disable_bypass=0 clk_ignore_unused panic=30
```

### GPU drivers and boot options

NCZ-OS ships **two GPU drivers** and lets you pick one at boot. Both are
installed; neither loads automatically.

| Boot entry | Driver | Provides | Status |
|---|---|---|---|
| **NCZ-OS** (default) | `mali_kbase` — CIX vendor DDK | OpenGL ES 3.2, EGL 1.5, OpenCL via `libmali` | Validated on real Radxa Orion O6N and MS-R1 hardware. This is what the desktop runs on. |
| **NCZ-OS (Panthor)** | `panthor` — mainline open driver | Vulkan and OpenCL via Mesa PanVK / rusticl | Experimental on Sky1. |

Both drivers claim the same device, so `/etc/modprobe.d/ncz-gpu-drivers.conf`
blacklists **both**. The boot entry decides which one is bound, and
`ncz-gpu-select` switches an installed system without a reinstall.

**What each costs you.** `mali_kbase` gives the accelerated desktop but
exposes **no Vulkan entrypoint** — `libmali` has none. `panthor` is the route
to Vulkan and is where the ecosystem is heading, but on Sky1 it is still
working through enumeration: the board boots via ACPI rather than device tree,
and mainline panthor has no `.acpi_match_table`.

Neither is going away. Shipping only the vendor blob would leave the
distribution with no open successor; shipping only panthor would mean a
desktop that does not accelerate today.

### Every accelerator driver is a DKMS module

This is a deliberate rule, not an accident of packaging:

| Accelerator | DKMS package | Module |
|---|---|---|
| GPU (default) | `cix-gpu-kmd` | `mali_kbase` |
| GPU (alternate) | `panthor-cix` | `panthor` |
| VPU | `cix-vpu-driver` | `amvx` |
| NPU | `cix-npu-driver-dkms` | `aipu` |

**Why DKMS rather than in-tree.** A kernel upgrade rebuilds a DKMS module
against the new kernel. An in-tree module that ships as a prebuilt binary is
locked to one `vermagic` and silently stops loading the moment the kernel
moves — you get a booting system with a dead accelerator and no obvious cause.

It also decides conflicts predictably. Where an in-tree driver and an
out-of-tree one both match the same hardware, DKMS installs to
`updates/dkms/`, which `depmod` prefers, so the intended driver wins rather
than whichever the kernel happened to build. The in-tree `armchina_npu` is
disabled outright (`CONFIG_ARMCHINA_NPU=n`) for the same reason: the vendor's
26Q2 SDK driver is newer than the in-tree one and must not be shadowed by it.

The corresponding source for every one of these is published — see
[docs/SOURCE-RELEASES.md](docs/SOURCE-RELEASES.md).

## Quick start (build the installer image)

> **Use the release image unless you are developing NCZ-OS.** Building is
> heavy (hours, tens of GB of scratch) and needs a native Linux build host per
> architecture (x86-64 for amd64, aarch64 for arm64).
>
> **Honest limitation:** a full image build is **not reproducible from
> public sources alone.** Besides this repository and the public Debian
> snapshot archive, the build consumes 44 pre-staged, gitignored inputs pinned
> by sha256 in [`manifests/build-inputs.tsv`](manifests/build-inputs.tsv) (the
> CIX vendor packages and Sky1 firmware, the recovery and rescue root
> filesystems, the wallpaper packages, patched libdrm and Chromium builds),
> the pinned Debian netinst substrate (`manifests/base.pin`; the weekly image
> it names has since been replaced upstream) and the kernel build
> (`assets/kernel/`). Only 6 of the 44 inputs can be fetched publicly with the
> exact pinned bytes: `build/stage-build-inputs.sh --arch <arch> --public`
> downloads them (CPython 3.11, `uv`, `ncz-screensavers`) and lists the rest as
> internal-only. Without the others the build stops at its input checks. All
> GPL source, including both kernels, is public; see
> [docs/SOURCE-RELEASES.md](docs/SOURCE-RELEASES.md) for the per-input table.

**The one entrypoint** runs every stage in a fixed order — preflight,
substrate, staged inputs, desktop sources, offline apt mirror, input
provenance, squashfs layers, image assembly, image provenance, the KVM install
gate, receipt and archive — with a log per stage (table:
[The build pipeline](#the-build-pipeline)):

```bash
build/build-image.sh --arch amd64 --full --no-publish   # or --arch arm64
```

The header of `build/build-image.sh` documents every stage, the `--respin` /
`--rebuild-*` / `--only-image` scopes and the options. Always pass
`--no-publish`: without it the last stage tries to copy the result to the
project's own image store. Re-running the command is safe: each run works in
its own run directory, and `--respin` reuses layers whose inputs are unchanged.

**Stage 2 on its own** (assemble the image from layers you already built):

| Step | Command | What it produces |
|---|---|---|
| Squashfs layers | `bash build/build-squashfs-layers.sh [base\|desktop\|hotfix\|all]` | `base` / `desktop` / `hotfix` squashfs layers under `assets/squashfs/` — what the installer extracts to disk. |
| Assemble | `make image ARCH=<arm64\|amd64>` | `build/ncz-os-<arch>-<YYYYMMDD>-<short-sha>.img` plus a `.sha256` — a raw GPT image with a rEFInd ESP (`NCZESP`) and an ext4 payload partition (`NCZDATA`). |
| Assemble + gate | `make image-verified ARCH=<arch>` | The same image, then the raw-GPT install-and-boot gate (`build/kvm-install-gate-gpt.sh`). |

The Debian Installer substrate is the Debian Testing netinst for the same
architecture (`UPSTREAM_ISO ?= debian-testing-$(ARCH)-netinst.iso`), checked
against the hash pinned in `manifests/base.pin`. The kernel comes from the
pinned NCZ build: `assets/kernel/sky1-manifest.json` (Sky1) or
`assets/kernel/amd64-stable/` (amd64). `make parity` runs the static
dual-architecture checks.

**Site settings.** The tooling hardcodes no store mount point or build host. Each
build host sets them once through environment variables or one-line files under
`~/.config/ncz/` (for example `NCZ_BUILD_INPUTS_DIR` or
`~/.config/ncz/build-inputs-dir`); see
[docs/BUILD-SITE-CONFIG.md](docs/BUILD-SITE-CONFIG.md) for the full list. Without
them the build still runs from an already-staged tree, and
`build/stage-build-inputs.sh --public` needs none of them.

### Build-host prerequisites

- A Debian 13+ Linux host with `git`, `make`, `python3`, `mksquashfs` /
  `unsquashfs`, `mkfs.ext4`, `sgdisk`, `tar`, `zstd`, `dpkg-deb`, plus either
  rootful `podman` (container builds) or `rsync` and `mformat`; QEMU with
  `/dev/kvm` for the KVM gate. The preflight stage of `build/build-image.sh`
  checks these and refuses to build on a tmpfs.
- `acpica-tools` (arm64) — provides `iasl`, which compiles
  `assets/npu/ssdt-npucre.asl` into the early-initramfs SSDT CPIO that fixes
  the Minisforum MS-R1's missing `_HID="CIXH4010"` on the NPU compute cores.
  `make npu-ssdt-check` (`build/npu-ssdt-gate.sh`) verifies the result:

  ```bash
  sudo apt install -y acpica-tools
  ```

The MS-R1 NPU is invisible to the kernel without this override (no
`CIXH4010:00..02` platform devices → no `/dev/aipu`). With the override in the
initramfs, the dmesg on an MS-R1 shows
`armchina CIXH4000:00: sky1_npu_probe: NPU core num is 3 → AIPU KMD (v6.2.0)
probe start... → AIPU detected: zhouyi-v3` and all three cores enumerate.
The `.asl` source is committed at `assets/npu/ssdt-npucre.asl`; it is compiled
to `.aml` by `build/build-npu-ssdt.sh` and delivered into the initramfs as an
uncompressed early CPIO by a dracut module / initramfs-tools hook, board-gated
so O6/O6N are untouched. See `docs/NPU-SSDT-DELIVERY.md` for the mechanism,
the gating table, and what still needs hardware confirmation.

### What differs for AMD64

- `ARCH=amd64` routes through the AMD64 package manifests
  (`manifests/installer-base-amd64.pkgs`, `desktop-amd64.pkgs`,
  `rescue-amd64.pkgs`).
- The kernel is the pinned `linux-image-7.3.0-rc7-t2-ncz` package
  (`assets/kernel/amd64-stable/KVER`, `PKGVERSION`); it serves T2 Macs and
  generic PCs alike, and it is also the installer's boot kernel.
- The CIX DKMS accelerator hooks (`post-install/80-npu.sh`, `81-vpu.sh`,
  `82-mali-gpu.sh`, `83-panthor-gpu.sh`) are no-ops on AMD64; the hook lists
  `post-install/hooks.list.amd64` and `hooks.list.sky1-arm64` say which hooks
  run on which architecture.
- `post-install/54-gpu-accel.sh` wires the matching GPU vendor's real apt
  repo (NVIDIA / AMD ROCm / Intel) from `lspci -nn` PCI-class detection —
  additive per vendor found.
- `post-install/55-t2-firmware.sh` and `56-t2-dkms.sh` run only on T2
  hardware (PCI `106b:1801`); no-ops on generic PCs.
- `post-install/21-flatpak-arch-filter.sh` filters the Flathub remote to the
  running architecture (`aarch64` / `x86_64`).

### Validating the NPU SSDT wiring (Arm64 / Sky1 specific)

A fast standalone check that the assets/npu/ tree is consistent (the .asl
source compiles, the .cpio is present, the CPIO is in uncompressed newc
format, the inner AML is a valid SSDT) — no full image build required:

```bash
# Regenerate the CPIO from the committed .asl if it is missing or stale,
# then run every check:
bash build/npu-ssdt-gate.sh --regen

# Or, after a successful build, just verify without regenerating:
bash build/npu-ssdt-gate.sh

# Self-test the gate itself (runs 6 cases in an isolated temp tree, never
# touches the production assets/npu/). Needs iasl. Use to validate the
# gate before relying on it.
bash build/npu-ssdt-gate.sh --self-test

# Same checks, wired as Make targets so CI / build hosts can `make` them:
make npu-ssdt-check           # production-tree validation
make npu-ssdt-check regen=1   # allow the gate to auto-rebuild missing CPIO
make npu-ssdt-selftest        # self-test the gate (6 isolated cases)
```

The gate exits 0 on PASS and 1 on FAIL with an explicit remediation per
failure mode (missing .asl, missing .cpio, bad magic, missing entry,
unrecognised inner AML signature, or missing iasl). AMD64 builds do not need
it — there is no MS-R1 NPU on x86 hardware.

## Quick start (install on hardware)

> **Connect wired Ethernet before powering on.** Wi-Fi is not available in the
> installer, and with no link detected the installer stops with "Network
> autoconfiguration failed" (plug in a cable and Retry) rather than looping
> silently.
>
> The base system itself comes off the image, so there is no network-dependent
> package resolution mid-install to fail on a flaky link or an unreachable
> mirror. That is not the same as fully offline: some post-install steps do use
> apt, and a few optional components (for example the NVIDIA driver) fetch from
> the network. Those are the parts a bad link degrades — not the install itself.

1. **Get the image.** Download the parts for your architecture from the
   [Releases page](https://github.com/ncz-os/cix-installer/releases),
   then join, unpack and check them (needs `zstd`):

   ```bash
   sh ncz-join-image.sh arm64        # or amd64
   ```

   [`tools/ncz-join-image.sh`](tools/ncz-join-image.sh) checks every part
   against `PARTS-<arch>.sha256`, joins and unpacks them, and checks the finished
   `.img` against `SHA256SUMS-<arch>` (older releases: `PARTS.sha256` and
   `SHA256SUMS`). It never writes to a disk, and it is safe to
   re-run: it leaves the parts in place and will not overwrite an existing
   `.img` unless you pass `-f`. To do it by hand:
   `sha256sum -c PARTS-<arch>.sha256`, then
   `cat ncz-os-<arch>-<date>-<sha>.img.zst.part-* | zstd -d -o ncz-os-<arch>-<date>-<sha>.img`,
   then compare `sha256sum ncz-os-<arch>-<date>-<sha>.img` with `SHA256SUMS-<arch>`.
   An image you build yourself has a `.sha256` beside it instead.

2. **Write it to a USB drive of at least 16 GB** (the image is 7.6 GB; writing
   erases the drive). Balena Etcher works on any OS. On Linux, copy the raw GPT
   image to the **whole device** (`/dev/sdX`), not a partition (`/dev/sdX1`):

   ```bash
   sudo dd if=ncz-os-<arch>-<date>-<sha>.img of=/dev/sdX \
        bs=4M status=progress oflag=direct conv=fsync
   sync
   ```

   On macOS, run `diskutil unmountDisk /dev/diskN` first, then use
   `/dev/rdiskN` (note the `r`) as the target, without `oflag=direct`.

   > **This step destroys everything on the target drive, and `dd` writes to
   > whatever you point it at, without asking.** Check the device name first:
   > run `lsblk` (Linux) or `diskutil list` (macOS) with the drive unplugged and
   > again with it plugged in, and use the entry that appeared. Naming the wrong
   > device destroys that disk. Repeating the write to the right drive is
   > harmless (it just rewrites the same image).

   > **Install from a USB drive only.** Write the image to a USB stick or USB
   > disk, boot from it, and choose the internal disk as the target. Writing
   > the image to the internal NVMe, an SD card or eMMC and installing from
   > there is not supported. Why: the installer only trusts USB for its
   > installation media, which keeps media detection predictable, and it means
   > the disk the board booted from is never the disk the installer erases.

3. **Boot it.** Plug the USB drive into the target — a Sky1 board
   (Radxa Orion O6N or Minisforum MS-R1) for the arm64 image, or an Intel/AMD
   PC or T2 Mac for the amd64 image — power on, and pick the drive from the UEFI boot menu. On
   a Mac, hold Option (⌥) at power-on. The installer's own rEFInd menu offers
   **Install** (default), **Install (expert)** and **Rescue mode**.

   The installer boots the NCZ kernel on both architectures, including the T2
   kernel on T2 Macs. Keep a USB keyboard at hand in case a Mac's internal
   keyboard does not respond during the install.

4. **Answer the installer.** It asks for your country (which sets language,
   time zone and keyboard together), a username and password (root login is
   off), which optional components to install (desktop, recovery container,
   rescue partition — all on by default), and the target disk and root
   filesystem: **btrfs** (default: snapshots and transparent compression) or
   **ext4**. The hostname is generated for you (`ncz-…`) and can be edited.
   ZFS root is not supported. For unattended installs these can be preset on
   the kernel command line (`ncz_disk=`, `ncz_fs=ext4|btrfs`, `ncz_region=`,
   `ncz_components=`, `ncz_hostname=`, `ncz_username=`, `ncz_unattended=1`;
   see `preseed/`).

5. The installer erases the disk (after a review screen), installs and
   reboots. Remove the drive; the installed system boots into rEFInd and then
   the Singularity login screen. The first login starts a short tour of the
   desktop.

The installed disk gets a 2 GB ESP, a 4 GB rescue partition (optional) and
the root filesystem. Realtek NICs, including the RTL8125/8126 on the Radxa Orion O6N, work out
of the box; the `rtl_nic` firmware ships in both the installer and the
installed system.

### Troubleshooting the install

- **"NCZ-OS installer: no USB installation drive found".** The installer did
  not find the image on a USB drive. This is what you see when the image was
  written to an internal NVMe, SD card or eMMC, or the stick is not detected.
  The screen lists any image it found on an internal disk (that disk is never
  offered as a target), picks up a USB drive plugged in within 10 seconds, and
  offers **R** to rescan the USB ports, **S** for a shell and **B** to reboot. Write the image to a USB stick, plug it in (the install
  continues on its own) or reboot from it.
- **Collecting logs for a bug report.** Choose **Save debug logs** in the
  installer main menu, or open a shell (Alt-F2) and copy `/var/log/syslog` to
  a USB stick. Alt-F4 shows the installer log live; Alt-F3 shows the
  diagnostics console with the remote login details
  ([docs/REMOTE-ACCESS.md](docs/REMOTE-ACCESS.md)). Please include the image
  file name and its `sha256sum`, the step that failed, and on the installed
  system the output of `lsblk -f` and `sudo efibootmgr -v`.
- **The installer uses rEFInd, not GRUB.** d-i's own GRUB and systemd-boot
  steps are skipped; the installer writes rEFInd to the ESP itself. A GRUB
  prompt on the target machine comes from another OS or an older boot entry.

### Boot menu on the installed system

| Entry | arm64 (Sky1) | amd64 |
|---|---|---|
| Default | **7.3 Mali (Default)** — desktop on the CIX Mali driver | **7.3 (Default)** |
| Experimental GPU | **7.3 Panthor (Experimental)** — open `panthor` driver, Vulkan via Mesa | — |
| Console | **7.3 Console** — no desktop, all accelerators | **7.3 Console** |
| Rescue | **7.3 Rescue / No Accelerators (Console)** — same kernel, GPU/VPU/NPU drivers blacklisted | **7.3 Rescue / No Accelerators (Console)** — same kernel, discrete GPU/compute drivers blacklisted (on T2 Macs `amdgpu` is kept, because it drives the panel) |
| Rescue partition | **Rescue Partition (Console)** — boots the separate rescue system | same |

Entries are generated by `assets/refind/ncz-refind-refresh.sh` (arm64) and
`assets/refind/ncz-refind-refresh-amd64.sh` (amd64), and regenerated when the
kernel is upgraded.

## Architecture

NCZ-OS ships as a **raw GPT disk image** (`ncz-os-<arch>-<date>-<sha>.img`),
one per architecture: **amd64** (Intel/AMD PCs and Apple T2 Macs) and
**arm64** (CIX Sky1 boards). There is no ISO. The image carries a stock Debian
Installer plus a pre-built, layered squashfs payload, so an install unpacks a
finished system instead of running debootstrap and hundreds of package
postinst scripts on the device. The reasons are install **speed** and
**offline reliability**: the base system comes off the image, so there is no
network-dependent package resolution mid-install to fail on a flaky link or an
unreachable mirror.

![Architecture diagram](docs/architecture.svg)

### What is on the image

| Partition | Contents |
|---|---|
| 1 — `NCZESP` (EFI system partition, FAT) | rEFInd with the installer menu (**Install**, **Install (expert)**, **Rescue mode**), the NCZ kernel, and the Debian Installer initrd with the NCZ preseed and dialogs (`build/iso/build-refind-esp.py`, `build/iso/patch-initrd-t2-kernel.py`). |
| 2 — `NCZDATA` (ext4) | `/ncz-payload/`: the `base`, `desktop` and `desktop-hotfix` squashfs layers with their overlay manifests, a static `unsquashfs`, and the install-time assets (kernel, firmware, packages for the post-install hooks, the rescue and recovery-container root filesystems, the screensaver plugin). `/dists` + `/pool`: the offline apt mirror the install uses. |

The layers stack like an overlay: `base.squashfs` is a Debian Testing
(`forky`) root filesystem with the NCZ kernel and firmware;
`desktop.squashfs` is a delta holding the desktop package set; and
`desktop-hotfix.squashfs` is a delta holding the Singularity desktop runtime
(`/opt/singularity`).

### How an install works

The installer is the **stock Debian Installer** from the Debian Testing netinst
for each architecture, pinned by content hash (`manifests/base.pin`). There is
no hand-patched d-i source tree in this repository; d-i's BusyBox init,
hardware detection, partman and udeb resolver are the upstream ones. The NCZ
delta is applied when the image is assembled:

- **our kernel** replaces Debian's installer kernel, with its modules in the
  installer initrd (`build/iso/patch-initrd-t2-kernel.py`). The image carries
  exactly one kernel, see [docs/ONE-KERNEL.md](docs/ONE-KERNEL.md);
- NCZ dialogs for region, user, optional components and disk + root filesystem
  (`preseed/*.sh`), with the preseed baked into the initrd;
- a `debootstrap` stub in `debootstrap-udeb`
  (`build/iso/patch-debootstrap-stub.py`): when d-i runs debootstrap, the stub
  extracts the squashfs layers onto the target disk instead;
- the `NCZDATA` payload partition and the rEFInd ESP that boots the installer.

After the layers are on disk, `post-install/run-all.sh` runs the numbered
`post-install/*.sh` hooks inside the target chroot, with apt pointed at the
offline mirror on the image. `post-install/hooks.list.amd64` and
`post-install/hooks.list.sky1-arm64` list which hooks run on which
architecture. A few optional components (for example the NVIDIA driver) fetch
from the network; the base install does not.

The installed disk gets an EFI system partition (2 GB), the optional
`NCZRESCUE` rescue partition (4 GB, ext4) and the root filesystem: **btrfs**
(default) or **ext4**.

### The installed system

- **One kernel**, Linux 7.3: `7.3.0-rc7-sky1-ncz` (Sky1 build r289) on arm64
  and `7.3.0-rc7-t2-ncz` on amd64, which serves T2 Macs and generic PCs alike.
  The default, console and rescue boot entries all use it (see
  [Boot menu on the installed system](#boot-menu-on-the-installed-system)).
- **Singularity desktop**, native Wayland on labwc, with the greetd-based
  Singularity greeter and a KMS boot splash in place of Plymouth. There is no
  X11 desktop session; Xwayland is kept for X applications.
- **Screensavers and lock screen** from `ncz-screensavers`; the screensaver
  starts first and the session locks after it (`post-install/59-ncz-screensavers-pkg.sh`,
  `post-install/63-ncz-idle-lock-order.sh`).
- **Minimize, maximize and close buttons** on every window by default, for
  every user (`post-install/65-ncz-titlebar-buttons.sh`).
- **Rescue partition**: a separate rescue system with its own boot entry that
  still boots when the main root filesystem does not. It uses DHCP and offers
  SSH and telnet by design (see [Rescue partition](#rescue-partition)).
- **Recovery container** (`ncz-recovery`, optional): a systemd-nspawn
  container with its own userland and SSH, built from the recovery root
  filesystem (`post-install/38-recovery-container.sh`).
- **The `ncz` utility** and staged agent quadlets: zeroclaw plus optional
  OpenClaw, Hermes and NemoClaw templates, none active by default. Agents are
  installed on demand with `ncz` (see [The `ncz` utility](#the-ncz-utility)).
- **Updates** from the NCZ apt repository, including the CIX proprietary
  userspace packages on arm64 (reviewed ledger `manifests/vendor-debs.tsv`,
  installed by `post-install/25-cix-proprietary.sh`); see
  [OTA channel](#ota-channel-kernel--driver-updates--persistent-apt-sources).

**NCZ-OS ships ONE build.** There is no separate desktop and server image,
and no variant picker. What used to be the "Magnetar" server variant is now
simply a **console boot entry** on the same image
(`systemd.unit=multi-user.target`) — same packages, the GUI is just not
started. `ncz desktop off` does the same thing on a running system, and
`ncz desktop on` reverses it.

### The build pipeline

`build/build-image.sh --arch amd64|arm64` is the one entrypoint (`make
release-image ARCH=<arch>` calls it). It runs these stages in a fixed order,
with a log per stage in its run directory. Provenance runs on the inputs
before the long stages, so a bad input fails in minutes rather than after the
layer build.

| # | Stage | What it does | Where it lives |
|---|---|---|---|
| 00 | `preflight` | Checks the host, free disk, tools and privileges, refuses to build on a tmpfs, and checks the substrate and determinism pins. | `build/build-image.sh`, `build/check-substrate-pin.sh`, `build/gen-base-pin.sh --check` (`manifests/determinism.pin`) |
| 10 | `refresh-substrate` | `--substrate refresh`: fetches the newest Debian Testing netinst, verifies its signature and rewrites `manifests/base.pin`. `--substrate pinned`: restores and checks the pinned netinst. | `build/refresh-substrate.sh`, `build/stage-substrate.sh`, `build/check-substrate-pin.sh` |
| 20 | `stage-inputs` | Stages the checksum-pinned build inputs, the kernel and the screensaver plugin. | `build/stage-build-inputs.sh` (`manifests/build-inputs.tsv`), `build/stage-amd64-kernel.sh`, `build/stage-arm64-assets.sh`, `build/stage-screensaver-plugin.sh` |
| 30 | `refresh-sources` | Resolves the Singularity desktop sources (`--sources latest`) or reproduces the committed pins (`--sources pinned`), then builds or stages the desktop payload package. | `build/refresh-singularity-sources.sh`, `build/stage-singularity-payload.sh` (`manifests/singularity-payload.tsv`), `build/build-singularity.sh`, `build/build-singularity-deb.sh` |
| 40 | `offline-mirror` | Builds the offline apt closure that goes on the image. | `make offline-mirror` |
| 50 | `provenance-inputs` | Every package that will enter the image must have exactly one origin: the pinned Debian snapshot, an NCZ build, or a reviewed vendor package. No Debian kernel may be present. | `build/check-forky-provenance.sh`, `build/verify-no-debian-kernel.sh` |
| 60 | `layers` | Builds and checks the `base`, `desktop` and `desktop-hotfix` squashfs layers. | `build/layers-preflight.sh`, `build/build-squashfs-layers.sh all` (desktop packages via `build/build-role-delta-mkosi.sh`), `build/check-layers.sh`; package lists in `manifests/*.pkgs` |
| 70 | `image` | Assembles the raw GPT image from the substrate, the kernel, the layers and the offline mirror. | `make image` → `build/build-installer-image.sh`, `build/iso/{import-substrate,patch-initrd-t2-kernel,patch-debootstrap-stub,stage-ncz-payload,build-refind-esp,write-usb-image}.py` |
| 80 | `provenance-gate` | The same origin and one-kernel checks over the finished image. | `build/check-forky-provenance.sh --image` |
| 90 | `kvm-gate` | Phase 1 runs an unattended install from a throwaway copy of the image in KVM; phase 2 boots the installed disk and fails on unexpected failed units; then the installer console UI is checked. | `build/kvm-install-gate-gpt.sh`, `build/kvm-installer-ui-check.sh` |
| 95 | `receipt` | Writes the run metadata and gate summary (not part of the image bytes). | `run-metadata.json` in the run directory |
| 99 | `archive` | Copies the image to the archive set by `NCZ_IMAGE_ARCHIVE`, only when both gates passed in this run. Skipped with `--no-publish`. | [docs/BUILD-SITE-CONFIG.md](docs/BUILD-SITE-CONFIG.md) |

Scopes such as `--respin`, `--rebuild-desktop`, `--components` and
`--only-image` reuse cached layers whose inputs are unchanged; the header of
`build/build-image.sh` documents them. The script never tags, publishes to an
apt repository, flashes or reboots anything.

## On-device AI: NPU embeddings & inference

> **Scope: Arm64 / CIX Sky1.** The CIX Zhouyi V3 NPU stack below is
> Sky1-only (no NPU on T2 Macs, no NPU on the generic x86-64 path).
> On AMD64 the equivalent accelerator tier is whatever
> `post-install/54-gpu-accel.sh` detected — Intel OpenVINO, AMD ROCm or NVIDIA
> CUDA — and `embedkit.Engine.auto()` falls back to those adapters in the
> same priority order (NPU > GPU > CPU) it uses on Sky1.

Every Sky1 install carries the NPU **runtime**: the `aipu` DKMS driver
(`/dev/aipu`, `post-install/80-npu.sh`), the CIX `libnoe` userspace
(`post-install/25-cix-proprietary.sh`), and a Python 3.11 venv with `embedkit`
at `/opt/ncz/embed-venv` (`post-install/46-python311.sh`, `47-embedkit.sh`).

**Models are not in the default image.** A model is between 75 MB and several
GB and most installs never need one, so embedding models install from apt
(`ncz-model-nomic-embed`). Once a `.cix` model
is present, `ncz-npu-embed.service` serves OpenAI-style embeddings from the
NPU on `127.0.0.1:8081` ([Embeddings on the NPU](#embeddings-on-the-npu)).

### Inference hierarchy (what runs where)

| Workload | Use | Avoid |
|---|---|---|
| Text embeddings (encoder, ≤256 tok) | **NPU** (`.cix`) | GPU compute |
| Long-doc embeddings / LLM decode / dynamic shapes | **CPU** | NPU, GPU compute |
| Vision / CNN (mobilenet, resnet, yolo) | **NPU** | GPU compute |
| Display / desktop GL | **GPU** | — |

NPU = fixed-shape encoders, CPU = everything dynamic, GPU = pixels not ML.
Mali-G720 has no cooperative-matrix, so GPU ML compute is 6–47× slower than CPU
— it is wired for display only. Full per-driver matrix with numbers (measured
on earlier kernels): [`docs/INFERENCE_LIMITS.md`](docs/INFERENCE_LIMITS.md).

### Pulling more models

`.cix` models come prebuilt from the CIX hub on ModelScope (or can be compiled
with the CIX Compass toolchain). Pull a single file:

```bash
BASE="https://www.modelscope.cn/models/cix/ai_model_hub/resolve/26_Q1"
curl -fL "$BASE/models/.../bge-small-zh_256.cix" -o model.cix
```

Full guide (single-file, LFS clone, custom ONNX→`.cix`):
[`docs/MODELSCOPE-MODELS.md`](docs/MODELSCOPE-MODELS.md). Using the NPU from
Python, with a worked example: [`docs/NPU-USAGE-GUIDE.md`](docs/NPU-USAGE-GUIDE.md).

## AI/ML stack & project history

The full guide to what AI/ML ships on the appliance, what each binary and
library is for, how to route a workload across the four compute engines
(CPU / NPU / GPU / VPU), measured performance, and how to pull new models:

- [`docs/AI-ML-STACK.md`](docs/AI-ML-STACK.md) — AI/ML stack reference
  · [简体中文 (Simplified Chinese)](docs/AI-ML-STACK.zh-CN.md)
- [`docs/INDEX.md`](docs/INDEX.md) — every document in the repository


## Inputs

| Path | Source | Notes |
|---|---|---|
| `assets/cix-debs/` | Staged CIX proprietary and NCZ-built `.deb`s (gitignored), checked against `manifests/vendor-debs.tsv` and `manifests/ncz-packages.tsv` | Partly in the public NCZ apt repository (21 of the 37 vendor packages and 5 of the 58 NCZ-built rows have the pinned sha256 there; see docs/SOURCE-RELEASES.md) |
| `assets/kernel/mainline` → Sky1 kernel | Yocto build of `meta-cix:linux-cix-sky1-ncz` (build r289, `7.3.0-rc7-sky1-ncz`), pinned in `assets/kernel/sky1-manifest.json`; the release name is in `assets/kernel/mainline.release`; `build/link-kernel-mainline.sh` links `assets/kernel/mainline` to it under the site kernel-staging pool (`NCZ_YOCTO_SHARED_DIR`) — the link is gitignored and is left out of the image layers | the kernel `Image`, the modules tarball and `KVER`, plus a `modules-overlay/$KVER/` subdir for the rebuilt accelerator `.ko`s (see `post-install/80-npu.sh`, `81-vpu.sh`, `82-mali-gpu.sh`). Older dated kernel dirs in `assets/kernel/` are not used by the build. |
| `assets/kernel/amd64-stable/` → amd64 kernel | `linux-image-7.3.0-rc7-t2-ncz` `7.3.0-rc7-2`, built from [`linux-t2-ncz`](https://gitlab.com/ncz-os/linux-t2-ncz), pinned by `KVER` / `PKGVERSION` and `assets/kernel/amd64-stable-manifest.json` | Staged by `build/stage-amd64-kernel.sh`; there is no amd64 edge channel. |
| `assets/agent-stack/*` | This repo | systemd quadlets for the optional agent runtimes (all opt-in) |
| `assets/branding/*` | This repo | os-release, motd, wallpapers, rEFInd banner/icons |
| `preseed/preseed.cfg`, `preseed/late.sh` | This repo | d-i unattended preseed + late_command (pre-chroot, install-time-only) |
| `post-install/*.sh` | This repo | ~90 numbered hooks; run inside the chroot. `post-install/hooks.list.amd64` and `hooks.list.sky1-arm64` list which run per architecture |

## Stages (post-install hooks)

`post-install/run-all.sh` runs the numbered `post-install/*.sh` hooks inside the
chroot, in three phases: required kernel/network hooks (skipped on a baked
image, where the kernel is already in the squashfs), machine-specific hooks
gated by `MACHINE_HOOKS_RE` on a baked image (apt sources, CIX proprietary
userland, GPU pin, agent stack, Python/embedkit, developer tools, Vivaldi, NPU/VPU
overlays, rescue partition), and the bootloader/diagnostics hooks run from an
`EXIT` trap. This list goes stale fast (it has twice already) — `run-all.sh`
and the individual `post-install/NN-*.sh` files are the source of truth for
exactly what runs and in what order, not a hand-maintained summary here.

## Remote diagnostics (while the installer is booted)

A single, **removable, toggleable** diagnostics module gives a remote operator
full access *while the d-i installer is running*, so an install can never wedge
us out and failures are captured even with nobody watching.

> **Login (installer only):** `root` (or `installer` for the network-console
> menu) / `rescue` — the same documented login as the rescue partition. The
> installer shows it in its boot banner on every console
> (`diagnostics login: root / rescue`), on the last line of every NCZ dialog and
> on the progress screen; it is gone once the installed system boots. Set your
> own with `ncz_diag_pw=<pw>` on the kernel command line, or turn the module off
> with `ncz_diag=0`. For a trusted LAN only — see the security note below and
> **[docs/RECOVERY-LOGINS.md](docs/RECOVERY-LOGINS.md)**.

| Channel | Port | Access |
|---|---|---|
| **SSH** | 22 | `ssh root@<host>` with the diagnostics login. `network-console` + `sshd-watcher.sh` force `PasswordAuthentication yes`/`PermitRootLogin yes`; the module sets root's login so no key is needed. `installer@<host>` also reaches the network-console menu. |
| **Telnet** | 23 | rich busybox shell (full applet farm: `vi`/`awk`/`sed`/`tar`/`less`/…) from the shipped static busybox (`assets/diag/busybox-arm64` / `busybox-amd64`) |
| **HTTP (file pull)** | 8080 | `wget http://<host>:8080/var/log/syslog` or browse `http://<host>:8080/` for any installer file (GET-only) |
| **Remote syslog** (opt-in) | 5514/udp | with `ncz_diag_log=<host[:port]>` on the kernel command line, every installer log line is forwarded to a collector you run; off by default |

**Turning it off.** The module is **on by default** in the installer images.
Put `ncz_diag=0` (or `off`) on the installer's kernel command line — edit the
entry at the rEFInd menu — to disable it for that boot.

**Tunables (kernel cmdline):**
- `ncz_diag_pw=<pw>` — root/diag login (default: `rescue`, see [docs/RECOVERY-LOGINS.md](docs/RECOVERY-LOGINS.md)).
- `ncz_diag_log=<host[:port]>` — remote syslog collector (port defaults to
  `5514`). Unset means no forwarding at all.

**How it works.** A static busybox (Debian forky `busybox-static`, with
`telnetd`/`httpd`/`syslogd`/`klogd`/`mkpasswd`) ships in the installer; the preseed launches
`preseed/diag-console.sh` in the background. The script self-gates on
`ncz_diag`, installs a full applet farm for the rich shell, sets the root
password, optionally forwards syslog to the collector, and starts telnetd +
httpd — all **idempotent** (pidfile-guarded) and self-respawning for the whole
install.

**Collector side.** Run `build/ncz-logd.sh` on your collector host: a `socat`
UDP listener on `:5514` appending to a dated log file in your home directory.
`tail -f` it during an install.

**File transfer.** *Pull:* `wget http://<host>:8080/<path>`. *Push:* over SSH,
`cat local | ssh root@<host> 'cat >/tmp/x'` (httpd is GET-only).

On the **installed system**, full SSH, telnet on :23
(`post-install/36-telemetry.sh`) and the other defaults in
[docs/REMOTE-ACCESS.md](docs/REMOTE-ACCESS.md) take over; the installer-only
consoles vanish with the d-i ramdisk.

> **Security:** the published login (`root` / `rescue`), the telnet root shell and the
> world-readable httpd are **for a trusted LAN only**. Boot the installer with
> `ncz_diag=0` on any network you do not control.

### Installed-system access posture (defaults)

- **Password SSH auth is enabled by default** on the installed system for
  convenience (`PasswordAuthentication yes`, `PermitRootLogin yes`,
  `post-install/35-ssh.sh`). Day-to-day login is the account you create in the
  installer. To harden an image to key-only, change those two settings.
- **Telnet (23), the failsafe root console (2323) and the `ncz-recovery`
  container** are also on by default — see
  [docs/REMOTE-ACCESS.md](docs/REMOTE-ACCESS.md) for what each is and how to
  turn it off.
- **Hostname** defaults to a generated `ncz-…` name so every box on a LAN is
  uniquely named; a hostname set during install always wins.

## Rescue partition

Every install gets a dedicated 4 GB ext4 **NCZRESCUE** partition (unless you
deselect it in the installer's component list), populated
at install time by `post-install/72-rescue-partition.sh` from a prebuilt
rescue rootfs (`build/build-rescue-rootfs.sh`, package list in
`manifests/rescue.pkgs` / `rescue-amd64.pkgs`). It boots from its own rEFInd
menu entry ("Rescue Partition (Console)"), independent of the main root filesystem — if the
installed system's root (btrfs or ext4) won't boot, the rescue partition
still will.

**Login.** `root` / `rescue`, the published break-glass default defined in
`build/build-rescue-rootfs.sh` (LAN-only; the rescue environment is not meant
to be internet-facing — change it with `passwd` after first use). Hostname
`ncz-rescue-<mac suffix>`. How to connect, change and reset it:
[docs/RECOVERY-LOGINS.md](docs/RECOVERY-LOGINS.md).

**Access channels:**

| Channel | Port | Notes |
|---|---|---|
| SSH (openssh, password auth) | 22 | `ssh root@<host>` |
| Dropbear (lightweight SSH) | 2222 | Alternative if openssh is misbehaving |
| Telnet | 23 | Full busybox applet shell |
| Serial console (Sky1) | `ttyAMA0` / `ttyAMA2` @115200 | Direct hardware console, no network needed |

**Networking.** DHCP only, on every network port that has a link
(`build/build-rescue-rootfs.sh`). There is no static-address fallback: if no
DHCP server answers, use the local console (or the serial console on Sky1).

**What's on it.** A genuinely comprehensive recovery toolset (not just a
minimal shell) — cherry-picked from the SystemRescue package list and mapped
to Debian Forky:
- **Filesystems** — btrfs-progs (the actual root fs), e2fsprogs, xfsprogs,
  f2fs-tools, ntfs-3g, exfatprogs, dosfstools, squashfs-tools.
- **Disk/partition** — full `util-linux` (fdisk/lsblk/blkid/wipefs), parted,
  gdisk, nvme-cli, smartmontools, lvm2, mdadm, cryptsetup.
- **Imaging / data recovery** — `ddrescue` (gddrescue), `testdisk` +
  `photorec`, fsarchiver, partclone.
- **Networking** — full iproute2/net-tools stack, tcpdump, socat, netcat,
  iperf3, sshfs, nfs-common, cifs-utils, rclone.
- **Hardware / boot diagnostics** — pciutils, usbutils, dmidecode, lshw,
  efibootmgr, `refind` itself (to repair the main system's `refind.conf`
  from the rescue side), kexec-tools.
- **Kernel/module/initrd repair** — the specific class of failure this
  partition exists for: kmod, initramfs-tools, cpio, device-tree-compiler,
  kpartx, binutils. Two purpose-built helpers ship in `/usr/local/sbin/`:
  `ncz-rescue-fixlib` (repairs a wedged usr-merge `/lib` symlink — the
  failure mode from a botched `tar -C /` extraction) and
  `ncz-rescue-chroot <device>` (mounts a target root + binds `/dev`/`/proc`/
  `/sys` and drops into a repair chroot in one command).
- **Shell/scripting** — vim, nano, tmux, mc, python3, jq.

`/AGENTS.md` on the rescue rootfs documents system facts, the boot model, and
step-by-step recovery procedures for an operator (or an agent) landing in
this environment cold.

## OTA channel (kernel + driver updates) + persistent apt sources

Installed systems upgrade their kernel and the proprietary CIX drivers **over
standard APT — no reinstall**. `post-install/24-apt-sources.sh` wires the
Buildkite source and refreshes the package index **before any hook that
installs packages**, so every later dependency-resolution step works against
a current index.

**Where packages live.**
- **Debian archive** — `https://deb.debian.org/debian`, suite **forky**
  (Debian Testing), components `main contrib non-free non-free-firmware`.
  Written by `post-install/23-base-apt-sources.sh` to
  `/etc/apt/sources.list.d/ncz-base.sources` (deb822, signed by
  `debian-archive-keyring.gpg`) from the values in `release.conf`. That hook
  also removes `/etc/apt/sources.list` and any Ubuntu source files, so Ubuntu
  is never left as a live fallback. The image is *built* from a pinned
  snapshot.debian.org timestamp, but installed systems follow the live archive
  so `apt update` keeps working.
- **NCZ packages** — kernels (the Sky1 kernel and boot-glue packages on Sky1,
  `linux-image-7.3.0-rc7-t2-ncz` on amd64), the CIX userspace drivers and
  runtimes, and NCZ's own packages, from the signed **Buildkite Packages**
  registry `https://packages.buildkite.com/ncz-os/ncz/any/` (a Cloudflare R2
  mirror is written but disabled as a fallback). `post-install/24-apt-sources.sh`
  wires it, and an apt pin keeps NCZ and Debian packages separate so an NCZ
  package can never silently replace a Debian one of the same name, or the
  reverse.
- **Kernel source + Yocto recipes** → GitLab
  [`ncz-os/meta-cix`](https://gitlab.com/ncz-os/meta-cix) (Sky1) and
  [`ncz-os/linux-t2-ncz`](https://gitlab.com/ncz-os/linux-t2-ncz)
  (amd64); see [docs/SOURCE-RELEASES.md](docs/SOURCE-RELEASES.md).

The NCZ source is GPG-signed (`signed-by`, never `trusted=yes`); the
install-media source is stripped post-install, and the old GHCR/squashfs OTA
(`90-ota-channel.sh`) is retired. `52-vivaldi.sh` neutralizes Vivaldi's own
`repo.vivaldi.com` source.

**How it updates.** On the desktop, the **NCZ-OS update manager**
(`ncz-update-manager`, with a session notifier and `ncz-update-check`;
`post-install/50-update-manager.sh`) shows and applies pending updates. From a
shell, `sudo apt update && sudo apt upgrade` does the same. Moving to a new
kernel does not require a reinstall; the rEFInd menu is rebuilt by
`ncz-refind-refresh` (`assets/refind/`).

## Upstream contributions

> **Scope: Arm64 / CIX Sky1.** Everything in this section was produced on
> Sky1 silicon (Mali-G720, Linlon V5276, the CIX VA-API driver stack) and
> does not apply to the AMD64 / T2 or generic-x86 paths — those go
> through `post-install/54-gpu-accel.sh` (vendor apt repos) and the
> standard Mesa / FFmpeg / Chromium / Firefox stack without CIX-specific
> patches.

Work that started here and went upstream, or is staged to. None of it is
NCZ-specific: the defects are in shared code, so the fixes belong with
their projects rather than in a distribution patch pile.

### Browser and codec: hardware video decode

Getting hardware video decode working in a browser on this silicon took six
patches to the CIX VA-API driver, plus patches to FFmpeg, Firefox and Chromium.
Every one of the four underlying defects failed **silently** — nothing logged
an error — which is why the work is written up with the evidence rather than
just the fix:

- **[docs/HW-VIDEO-DECODE-STATUS.md](docs/HW-VIDEO-DECODE-STATUS.md)** — what
  works, measured by looking at the rendered picture rather than at a proxy
  signal. H.264 1080p and VP9 720p decode in hardware in Chromium (renderer
  CPU ~27% → ~3.5% on H.264). AV1 is blocked on the VA-API route, but decodes in
  hardware through the V4L2 decoder in the NCZ Chromium build.
- **[docs/upstream-patches/cix-vaapi/](docs/upstream-patches/cix-vaapi/)** —
  the six VA-API patches. Without them browser hardware decode does not work
  on this platform at all.
- **[docs/upstream-patches/ffmpeg/](docs/upstream-patches/ffmpeg/)**,
  **[firefox/](docs/upstream-patches/firefox/)**,
  **[chromium/](docs/upstream-patches/chromium/)** — V4L2 M2M decoder support,
  AV1 plumbing and timestamp handling.
- **[docs/upstream-patches/cix-vaapi-repro/](docs/upstream-patches/cix-vaapi-repro/)**
  — standalone C reproducers, so a driver author can confirm each defect
  without building a browser.

### Singularity desktop

- **Sensors panel plugin** — hardware sensor discovery and classification for
  Sky1, which presents five bare ACPI thermal zones (`TZB0`, `TZB1`, `TZM0`,
  `TZM1`, `TZGT`) with no labels rather than the labelled SCMI chip other
  platforms expose. Includes temperature-proximity matching and limit
  provenance so a reading is attributed to the right device.
- **Network interface widget** — enumerate **every** Ethernet port, connected
  or not, with detected chipset and link capability (2.5 GbE and so on) rather
  than only active connections.
- **Layer-shell and session fixes** — surface re-creation behaviour validated
  on real Sky1 hardware, plus a GSettings schema fix for a missing key that
  aborted the process on startup (a missing key is a `SIGABRT`, not an
  exception).
- **Platform detection** — identifying CIX Sky1 by its ACPI hardware IDs
  (`CIXH*`) rather than by DMI vendor strings, which report the board vendor
  and not the SoC.

## The `ncz` utility

`ncz` is the operator CLI installed at `/usr/local/bin/ncz`. It is the intended
front door for the things this image does that a stock Debian does not.

| Command | What it does |
|---|---|
| `ncz status` | System summary: `ncz` version, build variant, kernel, default systemd target, NPU and GPU presence, and MNEMOS / embedder / zeroclaw / zoder rows. Start here. |
| `ncz desktop on` \| `off` \| `status` | Switch between graphical and headless. `off` sets `multi-user.target`, so the next boot is headless; SSH and networking stay up. Reversible. Reboot after `off` to leave the graphical login screen. |
| `ncz models` | List embedding models present in `/opt/ncz/models` — `.cix` graphs for the NPU, `.gguf` for CPU/GPU. |
| `ncz models pull` | Download the host-side embedder model (nomic-embed-text-v1.5 Q8_0 GGUF, sha256-verified) to `/opt/ncz/models`. |
| `ncz install mnemos` | Install and start the MNEMOS memory server (REST + OpenAI-compatible API on `:5002`, MCP on `:5004`). |
| `ncz install zeroclaw` \| `zoder` | Install the ZeroClaw agent gateway, or the zoder CLI. |
| `ncz install nemoclaw` | Start the NVIDIA NemoClaw sandbox runtime. |
| `ncz agent ...` | Manage the optional agent runtimes (zeroclaw, openclaw, hermes, portainer). |
| `ncz version`, `ncz help` | Version and usage. |

Nothing under `ncz install` or `ncz agent` is installed or running by default.
They are opt-in, and nothing agentic starts at boot or pulls from the network
on its own.

### `ncz install mnemos`, `ncz install zeroclaw`, `ncz install zoder`

```bash
sudo ncz install mnemos     # MNEMOS: REST + OpenAI-compatible API on :5002, MCP on :5004
sudo ncz install zeroclaw   # ZeroClaw agent gateway on :42617
sudo ncz install zoder      # zoder CLI, checksum-verified
sudo ncz status             # service rows, embedder backend and model
```

`ncz install mnemos` deploys [MNEMOS](https://gitlab.com/ncz-os/mnemos) as a
rootful podman **quadlet** with a persistent SQLite volume. It installs
offline-first: a bundled OCI image is loaded with `podman load` when present,
and the quadlet uses `Pull=never`; a pull of
`ghcr.io/ncz-os/mnemos-enterprise:latest` (or `MNEMOS_IMAGE`) happens only when
no bundled image is found, with 3 retries and a clear offline diagnostic.
Embeddings are computed in-process on the CPU (nomic-embed-text-v1.5, 768
dimensions) on both architectures; the Sky1 NPU embedder is opt-in
(`NCZ_MNEMOS_NPU=1`). The install writes a per-install audit token, an MCP
token and an API key for a default admin user to `/etc/nclawzero/`:

```bash
. /etc/nclawzero/mnemos.env
curl -H "Authorization: Bearer $MNEMOS_API_TOKEN" http://127.0.0.1:5002/stats
```

Every install is **idempotent**: re-running it keeps the existing quadlet,
tokens and data. Stop/remove steps and the MCP client setup are in
[`docs/NCZ-AGENT-STACK.md`](docs/NCZ-AGENT-STACK.md).

### Embeddings on the NPU

On Sky1, embeddings do not have to be computed on the CPU.
`ncz-npu-embed.service` runs a small embedding server on `:8081` that speaks the
OpenAI `POST /v1/embeddings` shape, backed by the Zhouyi V3 NPU through
`libnoe`:

| | |
|---|---|
| Model | `nomic-embed-text-v1.5_256.cix` (INT16, 256-token window) |
| Dimensions | **768** |
| Pooling | mean, declared per model rather than assumed |
| Endpoint | `http://127.0.0.1:8081/v1/embeddings`, plus `/health` and `/v1/models` |

```bash
curl -s localhost:8081/health
curl -s localhost:8081/v1/embeddings \
     -H 'content-type: application/json' \
     -d '{"input":"hello"}' | head -c 120
```

**Models are not in the image.** They are installed from apt
(`ncz-model-nomic-embed`) or fetched with `ncz models pull`, which keeps the
image small and the model licensing separable. If no `.cix` graph is present the
service stays disabled and says so rather than failing at query time.

One warning worth repeating: **the dimension must match the store.** Pointing a
768-dim server at a database populated at 512 dims does not error, it silently
poisons retrieval. Change the model, rebuild the vectors.

## Live recovery: the `ncz-recovery` container

NCZ-OS ships two recovery paths, and they solve different failures.

The **rescue partition** is *cold*. Using it means rebooting into it, which
means a working bootloader and usually someone at the console. It cannot help
you while the machine is up.

The **`ncz-recovery` container** is *live*. It is a `systemd-nspawn` container
that starts at boot alongside the OS, and it is what you actually reach for when
a running system breaks:

- It gets **its own IP address on your LAN** via MACVLAN on the host uplink, so
  it appears as a separate host and is reachable even when the host's own
  networking or `sshd` is broken.
- It mounts the **host root read-write at `/host`**, so it can repair the real
  filesystem in place.
- It runs with `PrivateUsers=no`, so container root *is* host root. Without
  that, host files appear as `nobody` and `/host` is effectively read-only —
  which is the difference between a recovery tool and a demo.
- It carries its own userspace, so it survives the failure that motivated all
  of this: a host whose `/usr/lib` has been destroyed and where every dynamically
  linked binary, `sshd` included, refuses to run.

It supplants the cold partition for most real failures. The partition stays for
what the container cannot survive — a kernel that will not boot, a destroyed
ESP, a failing disk.

### Using it

```bash
machinectl list          # ADDRESSES column shows the container IP
ssh root@<container-ip>  # published default login, see docs/REMOTE-ACCESS.md
chroot /host             # a full shell on the host system
```

The default login is a published break-glass value (defined in
`build/build-mgmt-rootfs.sh`), and you should change it on any network you do
not control. Note what this container is: a
root shell with read-write access to the host root, on its own LAN address. It
is the most privileged surface in the image, deliberately so.

```bash
# turn it off entirely
sudo systemctl disable --now systemd-nspawn@ncz-recovery.service
```

See [`docs/REMOTE-ACCESS.md`](docs/REMOTE-ACCESS.md) for the full default-access
posture and how to harden it.

## Sister projects

- [`gitlab.com/ncz-os/cix-gen`](https://gitlab.com/ncz-os/cix-gen) — script-based image builder; runs from a working aarch64 system, bypasses the d-i flow. Different use case (in-place rebuild vs fresh install).
- [`gitlab.com/ncz-os/meta-cix`](https://gitlab.com/ncz-os/meta-cix) — Yocto BSP layer providing the Sky1 kernel recipes (26.10: `linux-cix-sky1-ncz_7.3-rc7.bb`, build r289) and the CIX userspace recipes this installer consumes. Kernel source is fetched from the public `kernel.org` tree at a pinned commit; every Sky1-specific patch is tracked in this layer. The in-repo [`kernel-source/`](kernel-source/SOURCE.md) drop vendors the shipped r289 recipe, patches and as-built config, and [`ncz-os/linux-cix`](https://gitlab.com/ncz-os/linux-cix) tag `kernel-sky1-7.3.0-rc7-r289-src` holds the complete patched tree (see [docs/SOURCE-RELEASES.md](docs/SOURCE-RELEASES.md)).
- [`gitlab.com/ncz-os/linux-t2-ncz`](https://gitlab.com/ncz-os/linux-t2-ncz) — corresponding source of the amd64 kernel (`7.3.0-rc7-t2-ncz` in 26.10, tag `v7.3.0-rc7-t2-ncz-2`): mainline v7.3-rc7 plus [`t2linux`](https://github.com/t2linux/linux-t2-patches)'s `linux-t2-patches` series (apple-bce, applesmc, HID, APFS, bcm5974) and our T2 fixes. One kernel serves T2 Macs and generic PCs. T2 firmware wiring lives upstream in [`AdityaGarg8/t2-ubuntu-repo`](https://adityagarg8.github.io/t2-ubuntu-repo/) (the apt source `55-t2-firmware.sh` wires at first boot). NCZ-OS does not vendor a fork of either; we consume the upstream series and ship the staged Debian-built `.deb`s.


## Releases

Current and past release notes live in **[`docs/releases/`](docs/releases/)**.
The latest is **[26.10 "Cygnus"](docs/releases/26.10-cygnus-20261013.md)** (images of 2026-10-13); they
are published on the [Releases page](https://github.com/ncz-os/cix-installer/releases), which holds the one current release. The earlier
[26.10 Preview 1](docs/releases/26.10-cygnus-preview1.md) notes (2026-10-12)
are kept for reference.

Earlier releases (26.7 "Maximilian" and before) are archived in
[`docs/RELEASE-HISTORY.md`](docs/RELEASE-HISTORY.md). Every document in the
repository is listed in the [documentation index](docs/INDEX.md).

## Acknowledgements

NCZ-OS is assembled almost entirely out of other people's work. What
follows is roughly the order that work is stacked in, from the kernel
upward.

### Linus Torvalds and the kernel community

The obvious debt first: without the kernel, none of this exists. The Sky1
enablement here (in 26.10, one consolidated port patch plus 20 numbered
patches; in 26.7, a 176-patch series) sits on top of work by thousands of people
over three decades, and the fact that a vendor series *can* be carried,
rebased and published this way is a property of how that project is run.

A less obvious one, and worth stating plainly because this distribution is
built by one person with AI pair-tooling: Torvalds' position on AI-assisted
development has been pragmatic where a lot of the industry has been
performative. His summary — *"AI is just a tool, like any other tool we use.
And AI is clearly a useful tool"* — and his rejection of the framing that
Linux is an "anti-AI project"
([lore.kernel.org](https://lore.kernel.org/linux-media/CAHk-=wi4zC+Ze8e+p3tMv8TtG_80KzsZ1syL9anBtmEh5Z40vg@mail.gmail.com/))
set a norm that matters: **judge the patch, not the tool that produced it.**

He also made the sharper point that documentation requirements do not solve
the actual problem — *"the AI slop people aren't going to document their
patches as such"* — which is correct, and which is why the discipline in this
repository is measurement rather than disclosure. Every capability claim here
is backed by a workload on real hardware, and where something was not measured
the document says so. That is the standard the work should be held to,
regardless of what produced it.

### The Yocto Project and the Linux Foundation

The Sky1 kernel is built with **[the Yocto Project](https://www.yoctoproject.org/)**
— BitBake, OpenEmbedded and `poky`, with the CIX enablement carried as a
`meta-cix` layer. The patch series, its `SRC_URI` ordering, the defconfig
and the reproducible deploy artifacts all live in that model. It is what made
the 26.7 176-patch vendor series rebasable across four upstream bases by one person
rather than a team, and what makes the corresponding source we publish actually
correspond.

**[The Linux Foundation](https://www.linuxfoundation.org/)** hosts and sustains
Yocto, along with much of the surrounding ecosystem this distribution depends
on. That infrastructure is easy to take for granted precisely because it works;
a project this size could not carry it alone.

### CIX Technology

The **CIX** SDK, the Sky1 kernel patch series, and the vendor userspace
(`libmali`, the NPU/VPU stacks) are what make this hardware programmable at
all. Their work upstreaming Sky1 support into mainline Linux — the CIX P1
(SKY1) SoC series — matters beyond this project: it is the difference between
a board that needs a vendor tree forever and one that eventually just boots a
distribution kernel.

Worth saying plainly: a Chinese silicon vendor pushing its enablement upstream,
publishing an SDK, and engaging with the community is not the default in this
industry, and their commitment to open source has visibly improved over the
period we have been building on it.

### Jianfeng Liu (`amazingfate`)

**[Jianfeng Liu](https://github.com/amazingfate)**, Armbian maintainer, whose
patches and packaging work across ARM platforms — and on Sky1 specifically —
saved this project a great deal of independent rediscovery. If you have run
Armbian on an ARM SBC in the last few years, you have used his work.

### Singularity — Mirko Brombin and the singularityos-lab project

The desktop is **[Singularity](https://github.com/singularityos-lab)**, created
by **Mirko Brombin**. Replacing XFCE/X11 with it is the single change that made
an accelerated desktop possible on this silicon, because Singularity is
labwc/wlroots and reaches Mali GLES natively rather than through Xwayland.

Mirko has also taken changes back the other way. Those are listed under
[Upstream contributions](#upstream-contributions) rather than here, since they
are our work rather than a debt we owe.

### Also

- **Radxa** — the Radxa Orion O6N, our primary development and validation board.
- **Minisforum** — the MS-R1, the board this project started on.
- **Debian** — for treating ARM as a first-class architecture, which is why
  NCZ-OS is built on Forky.
- **Mesa, wlroots and labwc** — the open graphics and compositor stack the
  Panthor path depends on.
- **The t2linux community** — for maintaining the `linux-t2-patches` series
  that makes booting a T2 Mac on mainline Linux possible at all.
  AdityaGarg8's `t2-ubuntu-repo` (real WiFi/BT firmware via `apple-firmware-script`,
  `apple-t2-audio-config`) is what makes the AMD64/T2 NCZ-OS install reach a
  usable desktop instead of a console. The two real T2 MacBooks we boot-tested
  on are thanks to that work, not ours.
- **Apple's own Asahi Linux alumni** — `get-apple-firmware`'s macOS-CDN
  firmware fetcher is the Asahi-derived tooling the T2 firmware hook calls;
  without it, the T2 path has no WiFi/BT firmware at all.

### And Rachel

My wife, who has put up with this hobby — the boards on the kitchen table, the
fan noise, the "just one more build" at two in the morning — since the day it
started. None of the above happens without that patience.

## Build infrastructure & partners

Continuous integration and package distribution for this project are generously
supported by our open-source infrastructure partners:

- **[GitLab](https://gitlab.com/)** — canonical source hosting and CI pipelines
  (format / lint / test gates), via the
  [GitLab for Open Source](https://about.gitlab.com/solutions/open-source/) program.
- **[Buildkite](https://buildkite.com/)** — CI/CD orchestration with hosted macOS
  and Linux agents, and our APT package registry host
  (`packages.buildkite.com/ncz-os/ncz`), via the
  [Buildkite Open Source](https://buildkite.com/pricing) program.

Thank you to both for backing open-source software.
