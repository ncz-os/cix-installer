# NCZ 26.5 r78 "Reinhardt-Magnetar" — Netinstall Unified Desktop/Server ISO

**Release date:** 2026-05-07
**Codename:** Reinhardt (Desktop) + Magnetar (Server) on a single bootable netinstall ISO
**Kernel:** linux-cix-sky1-next 7.0.3 (NEXT-only — no LTS sibling shipped)
**Userspace:** Ubuntu 25.10 questing arm64, debootstrap'd from `ports.ubuntu.com/ubuntu-ports` at install time
**Hardware:** Cix Sky1 / CP8180 (Minisforum MS-R1; Radxa Orion O6 — community verification in progress, see Sky1-Linux #29)
**ISO size:** ~615 MB (down from r74's 3.9 GB / r75's 8.8 GB full mode — netinstall mode skips the offline rootfs + embedded mirror)
**SHA256:** `aca9be17537176f61a49efa855d40d4ec19c3236930fd04ea5a910927408e0f3`
**Wired Ethernet required at install** — `d-i netcfg` does not handle wireless cleanly in this build path.

---

## Headline

**A single boot ISO now offers a Desktop-or-Server choice at GRUB.** Same hardware, same kernel, same install pipeline — different first-boot behavior. Reinhardt is the XFCE-on-7.0.3 desktop appliance; Magnetar is the headless agent server. Operator picks at the GRUB menu; the rest is automatic.

The full embedding kit (`mnemos-embedkit` + `cix-noe-umd 2.0.2` + `bge-small-zh-v1.5_256.cix` NPU model + `bge-small-zh-v1.5-q8_0.gguf` CPU/Vulkan fallback) is baked into both flavors — `Engine.auto()` returns the Cix Zhouyi V3 NPU adapter on first boot.

## What's new in r78

### 1. Unified GRUB chooser (Desktop / Server / Rescue)

The GRUB menu now offers three entries:

- **Install NCZ "Reinhardt" — Desktop (XFCE)** — full graphical install. Default if no key is pressed.
- **Install NCZ "Magnetar" — Server (headless, agent appliance)** — same install pipeline, but `48-magnetar-variant.sh` applies the headless toggle (mask getty@tty1, force tty2 console, NoMachine remote-access path, defensive SSH enable).
- **SAFE — rescue shell (LTS, no install)** — emergency busybox+bash on the LTS kernel. Unchanged from r74-r75.

Implementation:
- `build/build-iso-di.sh` step 5 — replaces single Install entry with Desktop+Server pair, both passing `ncz_variant=desktop|server` on the kernel cmdline.
- `preseed/late.sh` — captures `ncz_variant` from `/proc/cmdline` after the source dir is selected; writes `/target/usr/local/lib/cix-installer/BUILD_VARIANT` so the existing 48-magnetar-variant.sh hook reads it on first boot.

### 2. mnemos-embedkit baked at install time

New `post-install/47-embedkit.sh` lays down:

- `/opt/ncz/embed-venv/` — Python 3.13 system venv with `mnemos-embedkit` + `llama-cpp-python` + `libnoe` (Cix NPU userspace binding).
- `/opt/ncz/models/bge-small-zh-v1.5_256.cix` — INT8-quantized NPU model (Compass NN AOT-compiled).
- `/opt/ncz/models/bge-small-zh-v1.5-q8_0.gguf` — Q8 GGUF CPU/Vulkan fallback (sha256 `5a88d266...`).
- `/usr/local/bin/embedkit-bench` + `embedkit-doctor` — symlinks into PATH.

`embedkit.Engine.auto()` returns the `npu-cix` adapter on Cix Sky1 hardware (via `/dev/aipu` + `libnoe` probe).

Reference benchmark on .66 (NCZ Magnetar reference appliance):

| Engine | rec/sec | p50 |
|---|---|---|
| Cix Zhouyi V3 NPU (INT8 .cix) | 54.86 | 14.6 ms |
| Cix Sky1 12-core ARM CPU (Q8 GGUF) | 12.03 | 100 ms |

Cross-platform numbers live in the `mnemos-os/mnemos-embedkit` repo at `benches/results.md` — consumer 8 GB dGPU (CUDA), Apple M1 Max + M3 Pro Metal, Intel NUC15 Pro CPU, bigpi Pi 5, zeropi Pi 4, all on the same `bge-small-zh-v1.5` model.

### 3. Post-install pipeline lint pass

Repo-wide shellcheck `-S warning` clean across `post-install/`, `build/`, and `preseed/`. Fixes:

- **`56-icon-theme.sh` real bug** — `\$ASSETS` literal-escape was always evaluating to the literal string `$ASSETS/NCZ`, so the NeXT-style black-hole trash icon never installed since r74. Now installs correctly.
- `33-ntp-hostname.sh` — `for iface in $(ls /sys/class/net)` replaced with shell glob.
- `25-cix-proprietary.sh` — `cd "$ASSETS"` made fail-loud; intentional `ls | grep` patterns annotated.
- `70-bootloader.sh` (post-install + build) — quoted command substitution in `blkid -o value $(findmnt ...)`.
- `preseed/extract-rootfs.sh` — POSIX-portable variable scoping in busybox-sh d-i context.

### 4. Brand consistency

Icon theme directory + dconf db filename + `index.theme` `Name=` field all reconciled to `NCZ` (was inconsistent NCX/NCZ across files since r74). Brand-rename cleanup completed.

## Verified hardware

- Minisforum MS-R1 (Cix Sky1, 64 GB) — primary target, install + boot verified
- Radxa Orion O6 — SAME-BSP claim; community verification pending
- Framework 13 ARM mainboard — community verification pending

## Install instructions

`dd` the ISO to a USB stick (8 GB minimum) and boot the target machine with USB priority above NVMe. The first boot drops you at the GRUB chooser:

```
Install NCZ "Reinhardt" — Desktop (XFCE)         <-- arrow-key, Enter
Install NCZ "Magnetar" — Server (headless)
SAFE — rescue shell
```

Pick Desktop for a workstation install, Server for an agent appliance. Install takes ~15-30 min on Sky1.

After install:

```bash
embedkit-doctor          # verify embedkit + adapters available
embedkit-bench           # smoke-test the canonical bench (writes /tmp/<host>-summary.json)
ncz install mnemos       # MNEMOS appliance install (Magnetar variant default)
```

## Compatibility

- **Magnetar from r75 -> r78** — direct upgrade path: re-flash the new ISO, reinstall. No in-place upgrade today (the rootfs path doesn't support it).
- **Reinhardt from r74 -> r78** — same.
- **embedkit Python package** — first appliance ship; no prior version on the box.

## Cross-references

- `mnemos-os/mnemos-embedkit` — the standalone kit (Apache-2.0).
- `mnemos-os/mnemos` — the canonical MNEMOS server (kit's reference consumer).
- `nclawzero/cix-installer` — this repo, the installer build pipeline.

---

*This release is the union of the r75 Magnetar work + the r76 netinstall design + the r78 unified-chooser implementation. Netinstall mode (sub-500 MB ISO via ports.ubuntu.com debootstrap) remains queued for r78 — see `docs/R76-NETINSTALL-DESIGN.md`.*
