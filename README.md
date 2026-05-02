# cix-installer

**Customized Debian Installer ISO builder for the nclawzero distro on
Cix Sky1 / CP8180 hardware** (Minisforum MS-R1 and successors).

Produces a fully-unattended UEFI-bootable installer ISO that, on boot,
partitions the target disk, installs Debian Bookworm arm64 base, layers
our `linux-cix-msr1` kernel + Cix proprietary userspace + GNOME desktop
+ nclawzero agent stack (`zeroclaw`, `openclaw`, `hermes`, `claude-code`),
and brands the system as nclawzero.

## Quick start (build the ISO)

```bash
make
# → outputs: build/nclawzero-installer-cixmini-${VERSION}.iso
```

## Quick start (install on hardware)

1. Flash the ISO to a USB stick (≥4 GB):
   ```bash
   sudo bmaptool copy --bmap nclawzero-installer-cixmini.iso.bmap \
       nclawzero-installer-cixmini.iso /dev/sdX
   ```
2. Plug into target (cixmini), power on, hit F-key for UEFI boot menu, pick USB
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
- Quadlet definitions for the 4-agent stack
- Plymouth theme (custom nclawzero splash)

So the install is fully offline-capable for the agent + Cix layers; only
the Debian base packages need network access during install.

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
4. `30-agents.sh` — install podman + 3 quadlets + nclawzero-load-agent-images service
5. `40-claude-code.sh` — `npm install -g @anthropic-ai/claude-code`
6. `50-brand.sh` — `/etc/os-release`, motd, hostname
7. `60-plymouth.sh` — Plymouth boot splash + nclawzero theme

## Status

**v0** — scaffolding + first-pass preseed + first-pass post-install. Iterating.

## Sister projects

- [`gitlab.com/nclawzero/cix-gen`](https://gitlab.com/nclawzero/cix-gen) — script-based image builder; runs from a working aarch64 system, bypasses the d-i flow. Different use case (in-place rebuild vs fresh install).
- [`gitlab.com/nclawzero/meta-cix`](https://gitlab.com/nclawzero/meta-cix) — Yocto layer for the BSP (kernel + Cix userspace recipes). Provides the `linux-cix-msr1` kernel artifacts consumed here.
