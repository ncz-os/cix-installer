# cix-installer

**Customized debian-installer ISO builder for the NCZ Linux
distribution.**

> ### 📥 Download the ISO
> **Release ISOs live on GitLab:**
> **https://gitlab.com/ncz-os/cix-installer/-/releases**
>
> GitHub hosts the source mirror only — there are no release artifacts here.
> If a link sent you to GitHub Releases, use the GitLab releases page above.

Produces a fully-unattended UEFI-bootable installer ISO that
partitions the target disk, debootstraps Ubuntu 25.10 questing,
layers a hardware-appropriate kernel + vendor userspace runtimes +
desktop environment + Claude Code + the NCZ agent stack (`zeroclaw`
default-active; `openclaw`, `hermes`, `portainer`, and `nemoclaw`
opt-in), and brands the system as NCZ
(Reinhardt for desktop, Magnetar for server / always-on agent
appliance).

## Vendor-neutral by design

NCZ is **vendor-neutral by design and intent.** Goal: support every
Arm silicon system shipping in the marketplace and every mainstream
x86 platform, when sample hardware is obtainable for validation.

- **Current proof-of-concept target**: Cix Sky1 / CP8180 (Minisforum
  MS-R1 and successors). This is where the build path is most
  exercised and where the offline-capable proprietary-userspace layer
  is wired in. The repo name reflects history; the project scope does
  not.
- **Arm roadmap**: Radxa Orion O6 / O6N (Sky1, different board),
  Radxa Qualcomm-platform boards (Snapdragon + Hexagon NPU), Rockchip
  RK3588 / RK3576 family, MediaTek Genio, Apple Silicon (kit-only,
  not OS), and any Arm SoC shipping in volume that we can sample.
- **x86 roadmap**: parallel build path, both **Intel** (CPU + iGPU +
  NPU via OpenVINO 2026.x) and **AMD** (Ryzen / XDNA NPU / ROCm) as
  first-class targets. The build script already takes
  `--platform=x86_64`; only adapter-level work is gated.
- **Embedding inference**: handled by `mnemos-embedkit`
  (https://github.com/mnemos-os/mnemos-embedkit) — vendor-agnostic
  Python kit that auto-detects the highest-tier accelerator (NPU >
  GPU > CPU) at runtime. Same `Engine.auto()` call works on every
  silicon path.
- **Agent runtimes**: side-by-side selectable. `zeroclaw` is active by
  default; operators opt in to `openclaw`, `hermes`, and `portainer`
  with `ncz agent install`, or to NVIDIA NemoClaw with
  `ncz install nemoclaw`.

The current build path inside `build/build-iso-di.sh` is the Cix Sky1
implementation; the architecture is the reusable scaffold.

## Quick start (build the ISO)

```bash
make
# → outputs: build/nclawzero-installer-cixmini-${VERSION}.iso
```

## Quick start (install on hardware)

> **Wired Ethernet is required.** This is a netinstall — d-i fetches the base
> system over the network and Wi-Fi is not available in the installer. Plug a
> wired Ethernet cable into the target **before** powering on. If no link is
> detected, the installer stops with a clear "Network autoconfiguration failed"
> message (plug in a cable and choose Retry); it no longer loops silently.
> Realtek NICs (incl. the Orion O6's RTL8125/8126) are supported out of the box
> — the `rtl_nic` firmware ships in both the installer and the installed system.

1. Flash the ISO to a USB stick (≥4 GB):
   ```bash
   sudo bmaptool copy --bmap nclawzero-installer-cixmini.iso.bmap \
       nclawzero-installer-cixmini.iso /dev/sdX
   ```
2. Plug in a **wired Ethernet cable**, then plug the USB into the target
   (cixmini / Orion O6), power on, hit the F-key for the UEFI boot menu, pick USB
3. d-i auto-runs preseed; ~20-30 min unattended install
4. Reboot, remove USB, target boots nclawzero from internal storage

## Architecture

```
┌────────────────────────────────────────────────────────────────┐
│                  nclawzero-installer-cixmini.iso               │
│                                                                │
│  ┌─────────────────────────┐    ┌───────────────────────────┐  │
│  │  Debian d-i base ISO    │    │  Custom assets layer      │  │
│  │  (debian-12-netinst-    │    │  - preseed.cfg            │  │
│  │   arm64.iso)            │    │  - post-install/*.sh      │  │
│  │  - UEFI bootloader      │    │  - assets/cix-debs/*.deb  │  │
│  │  - kernel + initrd      │    │  - assets/kernel/*        │  │
│  │  - debootstrap          │    │  - assets/agent-stack/*   │  │
│  │  - partman              │    │  - assets/branding/*      │  │
│  │  - tasksel              │    │  (extracted to /target    │  │
│  │  - apt                  │    │   during late_command)    │  │
│  └─────────────────────────┘    └───────────────────────────┘  │
└────────────────────────────────────────────────────────────────┘
```

The ISO ships its own copy of:
- 37 Cix proprietary `.debs` (~1.9 GB) — closed-source userspace
- `linux-cix-msr1` kernel binary + modules tarball (~640 MB)
- Quadlet definitions for zeroclaw plus optional OpenClaw, Hermes, and
  NemoClaw templates
- Plymouth theme (custom nclawzero splash)

So the install is offline-capable for the Cix layers and ships only the
default zeroclaw activation path; optional agent runtimes are pulled by
the operator after install.

## Inputs

| Path | Source | Notes |
|---|---|---|
| `assets/cix-debs/` | `dpkg-repack` of stock Cix Debian (gitignored) | 37 closed-source `.debs` |
| `assets/kernel/Image-cixmini.bin` + `modules-cixmini.tgz` | Yocto build of `meta-cix:linux-cix-msr1` (gitignored) | Our kernel artifacts |
| `assets/agent-stack/*` | `meta-cix/recipes-nclawzero/agent-stack/files/` | systemd quadlets (committed) |
| `assets/branding/*` | This repo | os-release, motd, Plymouth theme |
| `preseed/preseed.cfg` | This repo | d-i unattended preseed |
| `post-install/*.sh` | This repo | numbered hooks run in chroot at install end |

## Stages (post-install hooks)

`/target/usr/local/lib/cix-installer/` runs these in order via `preseed/late_command`:

1. `00-cix-proprietary.sh` — `dpkg -i` 37 Cix `.deb` files
2. `10-our-kernel.sh` — install `linux-cix-msr1` kernel binary + modules
3. `20-desktop.sh` — apt install GNOME + chromium + gnome-remote-desktop
4. `30-agents.sh` — install podman + zeroclaw default quadlet + optional agent templates
5. `40-claude-code.sh` — `npm install -g @anthropic-ai/claude-code`
6. `50-brand.sh` — `/etc/os-release`, motd, hostname
7. `60-plymouth.sh` — Plymouth boot splash + nclawzero theme

## Status

**v0** — scaffolding + first-pass preseed + first-pass post-install. Iterating.

## Sister projects

- [`gitlab.com/nclawzero/cix-gen`](https://gitlab.com/nclawzero/cix-gen) — script-based image builder; runs from a working aarch64 system, bypasses the d-i flow. Different use case (in-place rebuild vs fresh install).
- [`gitlab.com/nclawzero/meta-cix`](https://gitlab.com/nclawzero/meta-cix) — Yocto layer for the BSP (kernel + Cix userspace recipes). Provides the `linux-cix-msr1` kernel artifacts consumed here.
