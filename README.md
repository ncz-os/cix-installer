# cix-installer

**English** · [中文](README.zh-CN.md)

**Customized debian-installer ISO builder for the NCZ Linux
distribution.**

> ### 📥 Download the ISO
> **Latest release (always current):**
> **https://gitlab.com/ncz-os/cix-installer/-/releases/permalink/latest**
>
> That permalink is idempotent — it always 302-redirects to the newest
> release, so it never goes stale. All releases:
> https://gitlab.com/ncz-os/cix-installer/-/releases
>
> GitHub hosts the source mirror only — there are **no** release artifacts
> there (`/releases` 404s). Always download from the GitLab links above.

Produces a fully-unattended UEFI-bootable **netinstall** ISO (~380 MB)
that partitions the target disk, debootstraps Ubuntu 26.04 "resolute"
arm64 over the network, layers a hardware-appropriate kernel + vendor
userspace runtimes + desktop environment + Claude Code + the NCZ agent
stack (`zeroclaw` default-active; `openclaw`, `hermes`, `portainer`,
and `nemoclaw` opt-in), and brands the system as NCZ. A single ISO
offers both flavours at the boot menu:

- **Reinhardt** — Desktop (XFCE)
- **Magnetar** — Server / always-on agent appliance (headless)

The shipping kernel is `linux-cix-sky1-next` **7.0.12** (the "edge"
line, cross-built with the Yocto/`nclawzero` toolchain). Realtek NICs —
including the Radxa Orion O6's RTL8125/8126 — work out of the box: the
`rtl_nic` firmware ships in both the installer and the installed
system.

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
│  │  Debian d-i substrate   │    │  Custom assets layer      │  │
│  │  (debian-13 trixie      │    │  - preseed.cfg            │  │
│  │   netinst arm64;        │    │  - post-install/*.sh      │  │
│  │   bookworm fallback)    │    │  - assets/kernel/edge/*   │  │
│  │  - UEFI / systemd-boot  │    │  - assets/firmware/*      │  │
│  │  - our kernel + initrd  │    │  - assets/sky1-firmware/* │  │
│  │  - debootstrap          │    │  - assets/agent-stack/*   │  │
│  │  - partman              │    │  - assets/branding/*      │  │
│  │  - apt (ports.ubuntu)   │    │  (extracted to /target    │  │
│  │                         │    │   during late_command)    │  │
│  └─────────────────────────┘    └───────────────────────────┘  │
└────────────────────────────────────────────────────────────────┘
```

As a netinstall, the base system is debootstrapped from
`ports.ubuntu.com` at install time (hence the wired-Ethernet
requirement). The ISO itself ships only what can't be fetched from a
canonical mirror:
- `linux-cix-sky1-next` 7.0.12 kernel `Image` + modules tarball
  (`assets/kernel/edge/`)
- `rtl_nic` (Realtek NIC) + Sky1 SoC firmware (`assets/firmware/`,
  `assets/sky1-firmware/`)
- Quadlet definitions for zeroclaw plus optional OpenClaw, Hermes, and
  NemoClaw templates
- mnemos-embedkit + branding (Plymouth theme, os-release, motd)

The Cix proprietary userspace (`cix-noe-umd`, `libnoe`) is pulled from
`archive.cixtech.com` after the base bootstrap. Only the default
zeroclaw activation path is enabled; optional agent runtimes are pulled
by the operator after install.

## Inputs

| Path | Source | Notes |
|---|---|---|
| `assets/kernel/edge/Image-cixmini.bin` + `modules-cixmini.tgz` + `KVER` | Yocto/`nclawzero` build of `linux-cix-sky1-next` (gitignored) | 7.0.12 edge kernel artifacts |
| `assets/firmware/rtl_nic/*.fw` | upstream linux-firmware (committed) | Realtek NIC firmware (Orion O6) |
| `assets/sky1-firmware/*` | `Sky1-Linux/sky1-firmware` | GPU / DSP / VPU / Wi-Fi SoC blobs |
| `assets/agent-stack/*` | This repo | systemd quadlets (committed) |
| `assets/branding/*` | This repo | os-release, motd, Plymouth theme |
| `preseed/preseed.cfg` | This repo | d-i unattended preseed |
| `post-install/*.sh` | This repo | numbered hooks run in chroot at install end |

## Stages (post-install hooks)

`late.sh` copies the payload to `/target/usr/local/lib/cix-installer/`
and `run-all.sh` runs the numbered hooks in chroot in phases — Phase 1
(required) must succeed; Phase 2 (optional) hooks log failures but never
abort; the bootloader + diagnostics always run via an EXIT trap. Key
hooks:

- `09-diag-account.sh` — create the rescue/diag login before anything else
- `10-our-kernel.sh` *(required)* — install the `linux-cix-sky1-next` kernel + modules
- `12-sky1-firmware.sh` *(required)* — install Sky1 SoC + `rtl_nic` firmware to `/lib/firmware`
- `20-desktop.sh` / `48-magnetar-variant.sh` — XFCE desktop (Reinhardt) or headless server toggle (Magnetar)
- `30-agents.sh` — podman + zeroclaw default quadlet + optional agent templates
- `40-claude-code.sh` — `npm install -g @anthropic-ai/claude-code`
- `47-embedkit.sh` — mnemos-embedkit venv + NPU adapter
- `50-brand.sh` / `60-plymouth.sh` — os-release, motd, boot splash
- `70-bootloader.sh` — systemd-boot entries (always runs via EXIT trap)

## Status

**Shipping — v26.6** (Reinhardt / Magnetar netinstall). Actively
iterating; see `NEXT-RELEASE.md` and `RELEASE-NOTES-*.md`.

## Sister projects

- [`gitlab.com/ncz-os/cix-gen`](https://gitlab.com/ncz-os/cix-gen) — script-based image builder; runs from a working aarch64 system, bypasses the d-i flow. Different use case (in-place rebuild vs fresh install).
- [`gitlab.com/ncz-os/meta-cix`](https://gitlab.com/ncz-os/meta-cix) — Yocto layer for the BSP (kernel + Cix userspace recipes). Provides the `linux-cix-sky1-next` kernel artifacts consumed here.
