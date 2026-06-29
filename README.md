# cix-installer

> **🌐 Language:** English · [简体中文](README.zh-CN.md)
>
> **📚 Start here:** [AI/ML Stack Reference](docs/AI-ML-STACK.md) ([中文](docs/AI-ML-STACK.zh-CN.md)) · [How Did We Get Here — engineering post-mortem](docs/HOW-DID-WE-GET-HERE.md) ([中文](docs/HOW-DID-WE-GET-HERE.zh-CN.md)) · [Download the ISO](https://gitlab.com/ncz-os/cix-installer/-/releases/permalink/latest)

**Customized debian-installer ISO builder for the NCZ Linux
distribution.**

Produces a fully-unattended UEFI-bootable installer ISO that
partitions the target disk, debootstraps a Debian 12 base and
full-upgrades it to Ubuntu (resolute) on disk, then
layers a hardware-appropriate kernel + vendor userspace runtimes +
desktop environment + Claude Code + the (opt-in) NCZ agent stack, and
brands the system as NCZ
(Reinhardt for desktop, Magnetar for server / always-on agent
appliance).

### Two distinct layers: a working OS, and an *optional* AI layer

NCZ deliberately separates the operating system from the AI. Installing the
ISO gives you the first layer; the second is never installed or started until
you ask for it.

**1. The OS + drivers — installed and working out of the box.**
A fresh install is a complete, usable Linux desktop, with no AI required:
- Hardware enablement: the right kernel, **GPU drivers** (Mesa panvk +
  rusticl), the **NPU driver** (`/dev/aipu`), **audio** (HDMI + analog
  headphone/speaker jack), and Wi-Fi/Ethernet firmware — drivers work.
- XFCE desktop + browser, media players, fonts, archive tools — fully usable
  for ordinary, non-AI work.
- Claude Code CLI is present as a *tool*; it does not run anything on its own.

**2. The AI agents + memory substrate — optional, installed with the `ncz`
command.**
This layer is **agent-enabled but not agent-on**: the runtimes, quadlets, and
the on-device NPU embedding stack are staged and ready, but **nothing here is
installed or running until you run `ncz` in a terminal.** Nothing auto-starts at
boot or auto-pulls from the network.
- **AI agents** — `ncz agent install <name>` (`zeroclaw`, `openclaw`,
  `hermes`, `portainer`) or `ncz install nemoclaw` (NVIDIA NemoClaw).
- **MNEMOS memory substrate** (the on-device semantic memory system) —
  `ncz install mnemos`.

Until you run `ncz`, the system behaves like any normal Linux desktop.
(Earlier ISOs activated `zeroclaw` by default; current ISOs do not.)

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
- **Agent runtimes**: side-by-side selectable and **fully opt-in — none is
  installed or active by default.** Run `ncz` (or `ncz agent install <name>`)
  to install `zeroclaw`, `openclaw`, `hermes`, or `portainer`, `ncz install
  nemoclaw` for NVIDIA NemoClaw, and `ncz install mnemos` for the MNEMOS memory
  system. Nothing agentic auto-starts at boot or auto-pulls from the network.

The current build path inside `build/build-iso-di.sh` is the Cix Sky1
implementation; the architecture is the reusable scaffold.

## Hardware support & testing status

> **Read this before you flash anything.** NCZ is vendor-neutral *by
> design*, but "designed to support" is not the same as "tested on." Here
> is the honest state of hardware validation.

| Board | SoC | Status |
|---|---|---|
| **Minisforum MS-R1** (32 GB, and 64 GB "jumbo") | Cix Sky1 / CP8180 | ✅ **The only hardware we have tested on.** Every bit of validation — UEFI boot, the installer, GPU (Mesa 26.1.3 panvk + rusticl), NPU (Zhouyi embeddings + vision), audio, and the A/B kernel program — was done on this box. |
| **Radxa Orion O6** | Cix Sky1 | ✅ **Verified working.** A *different board* from the MS-R1 (its own device tree, PMIC, BIOS, and peripherals), now confirmed to install and boot. The Realtek NIC (RTL8125/8126) works out of the box — the `rtl_nic` firmware ships in both the installer and the installed system, resolving the earlier no-network regression. |
| **Radxa Orion O6N** | Cix Sky1 | ⚠️ **Untested, but expected to work.** Same Sky1 SoC and the same O6 board family (a minor variant); the 7.1.2-ncz2 kernel ships the same driver set as O6 (see [Driver support matrix — O6 / O6N](#driver-support-matrix--o6--o6n)), so we just have not confirmed it on hardware yet. **If you have an O6N: please install, test, and file issues.** |
| **Framework Cix add-in board / mainboard** | Cix Sky1 | ❌ **Untested.** On our radar; no hardware in hand. |
| **Orange Pi (Cix variants)** | Cix Sky1 | ❌ **Untested.** No hardware in hand. |
| Other Arm (RK3588/RK3576, MediaTek Genio, Snapdragon) and x86 (Intel, AMD) | — | 🗺️ Roadmap / adapter-level only — not built or tested yet. |

**What "untested" means for you:** parts of the build path are MS-R1-specific
— e.g. an ACPI SSDT override that works around the MS-R1 *factory BIOS bug*
(it omits `_HID="CIXH4010"` so the NPU cores never enumerate), firmware blob
paths, and board/device-tree quirks. On any other board it may not boot, the
NPU/GPU/VPU may not initialize, or the installer may need board-specific work.
**Testers and donated hardware are the fastest way to change a ❌ to a ✅.**

### Driver support matrix — O6 / O6N

The 7.1.2-ncz2 kernel (with NCZ patches `9008`–`9011`) supports the full CIX
Sky1 driver set on both the **Radxa Orion O6** and the **O6N** (same SoC, same
ACPI device tree, same peripherals — the O6N is a minor variant). The kernel
artifact at `assets/kernel/Image-cixmini.bin` ships a single DTB
(`sky1-orion-o6.dtb`) used by both boards.

| Subsystem | Driver | Config | O6 | O6N | Notes |
|---|---|---|---|---|---|
| **Clock** | `clk-sky1-acpi` (CIXHA010) | `=y` | ✅ | ✅ | ACPI CLKT table parser → SCMI clocks. Patch `9010` adds ACPI power mgmt. |
| **Clock** | `clk-sky1-audss` (CIXH6061) | `=y` | ✅ | ✅ | Audio subsystem clock controller; explicit D0 transition. |
| **Reset** | `reset-sky1` (CIXHA020/021) | `=y` | ✅ | ✅ | Patch `9008` adds ACPI resource lookup. |
| **Reset** | `reset-sky1-audss` | `=y` | ✅ | ✅ | Audio subsystem reset. |
| **Pinctrl** | `pinctrl-sky1` | `=y` | ✅ | ✅ | Patch `0046` adds ACPI support. |
| **Mailbox** | `cix-mbox` | `=y` | ✅ | ✅ | SCMI mailbox transport. |
| **SCMI** | `arm-scmi` (clock + perf + power + sensor domains) | `=y` | ✅ | ✅ | Protocol 0x13 perf: fwnode provider deferred to `late_initcall` (patch `9009`). |
| **Power domain** | `scmi-perf-domain` / `scmi-power-domain` | `=y` | ✅ | ✅ | Patch `0008` series; runtime gated to `late_initcall` (patch `9011`). |
| **Thermal** | `cix-thermal` + IPA | `=y` | ✅ | ✅ | Patch `0049`/`0050`/`0062`; ACPI thermal binding. |
| **DSP** | `cix-dsp` + `cix-dsp-rproc` | `=m` | ✅ | ✅ | Patch `0009`/`0020`; DSP remoteproc and IPC. |
| **Audio (HDA)** | `snd-hda-cix-ipbloq` + Realtek ALC codecs | `=m` | ✅ | ✅ | Analog + digital + HDMI/DP. Verified ALC269VC. |
| **Audio (SoC)** | `snd-soc-sky1-sound-card` + `snd-soc-sof-cix-toplevel` | `=m` | ✅ | ✅ | SOF + Cadence I2S. |
| **GPU (Mali-G720)** | `panthor` + `drm-cix` + `drm-trilin-dp-cix` | `=m` | ✅ | ✅ | Mesa 26.1.3 panvk + rusticl shipped (see `post-install/16-mesa-gpu-2613.sh`). |
| **NPU (Zhouyi V3)** | `armchina-npu` | `=m` (DKMS) | ✅ | ✅ | `ARCH_V3=y` + IOVA cap=2 (`2014-armchina-npu-cap-iova-region-32bit-bus.patch`). `/dev/aipu`. |
| **USB** | `usb-cdnsp-sky1` (CDNSP) | `=y` | ✅ | ✅ | xHCI host + gadget. Patch `0025`/`0029`/`0052`/`0060`/`0063`. |
| **USB Type-C** | `typec-rts5453` | `=y` | ✅ | ✅ | Realtek Type-C PD controller. |
| **Ethernet** | `r8169` (RTL8125/8126/8169) | `=m` | ✅ | ✅ | `rtl_nic` firmware shipped in installer + installed system. |
| **Wi-Fi** | `mt7921e` (MediaTek MT7921/MT7922) | `=m` | ✅ | ✅ | M.2 Key-E slot. |
| **Wi-Fi (alt)** | `rtw88` (Realtek 8822B/8822C/8723DE/…) | `=m` | ✅ | ✅ | If equipped. |
| **PCIe** | `pcie-cadence-host` + `pci-sky1-host-cix` + `phy-cix-pcie` | `=y` | ✅ | ✅ | M.2 + board peripherals. |
| **USB-PD PHY** | `phy-cix-usbdp` | `=y` | ✅ | ✅ | USB 3.x + DisplayPort alt-mode. |
| **IOMMU/SMMU** | `arm-smmu-v3` | `=y` | ✅ | ✅ | With Sky1 suspend/resume (patch `0036`). |
| **GPIO** | `gpio-cadence` | `=m` | ✅ | ✅ | Patch `0017` adds ACPI support. |
| **I2C** | `i2c-cadence` | `=m` | ✅ | ✅ | Patch `0019` adds ACPI support. |
| **DMA** | `dma-arm-dma350` | `=m` | ✅ | ✅ | Patch `0016` adds ACPI support. |
| **PWM** | `pwm-sky1` | `=y` | ✅ | ✅ | Patch `0028` + state-check `0043`. |
| **Syscon** | `mfd-syscon` (with ACPI) | `=m` | ✅ | ✅ | Patch `0015`/`0023`. |
| **Regulator** | `regulator-cix` | `=y` | ✅ | ✅ | Patch `0033`. |
| **Timer** | `clocksource-sky1-gpt-timer` | `=y` | ✅ | ✅ | Patch `0044`. |
| **IRQ** | `irqchip-sky1-pdc` | `=y` | ✅ | ✅ | Patch `0012`. |
| **SoC resource** | `cix-acpi-resource-lookup` (CIXA1019) | `=y` | ✅ | ✅ | `subsys_initcall`; walks RSTL/RSNL/DLKL. Patch `0007`/`9007`. |
| **ACPI USB scan** | `cix-acpi-usb-scan-handler` | `=y` | ✅ | ✅ | Patch `0027`. |
| **DST** | `cix-dst` | `=y` | ✅ | ✅ | Patch `0064`. |
| **Power management** | `pmdomain-scmi-perf` (deferred fwnode) | `=y` | ✅ | ✅ | Patch `9009` defers fwnode provider to `late_initcall`. |
| **Runtime PM gate** | `pm_runtime` global gate | `=y` | ✅ | ✅ | Patch `9011` gates `__pm_runtime_resume` until `late_initcall` to avoid deferred-probe SError. |

**What's required for O6 / O6N to boot cleanly:**

1. **Kernel 7.1.2-ncz2** with NCZ patches `9008` + `9009` + `9010` + `9011` (all
   shipped in `assets/kernel/` from `meta-cix:linux-cix-msr1` /
   `linux-cix-sky1-ncz`).
2. **DTB** `sky1-orion-o6.dtb` (single DTB covers both O6 and O6N).
3. **Firmware**: `rtl_nic` (RTL8125/8126), `mali_csffw.bin` (Mali-G720
   panthor), `armchina-npu` DKMS (NPU).
4. **ACPI cmdline**: `acpi=force efi=noruntime arm-smmu-v3.disable_bypass=0
   clk_ignore_unused panic=30 module_blacklist=typec_rts5453,rts5453` (the
   installer adds these to the rEFInd boot entry automatically).

**O6N-specific notes:** the O6N is a minor variant of the O6 with the same
Sky1 SoC, same ACPI DSDT shape, and same peripherals. The kernel + firmware
set above is expected to work without modification. The only O6N-specific
risk is firmware/NIC Wi-Fi module differences — if you hit a regression,
file an issue with `dmesg` and `lspci -nn` output.

## Quick start (build the ISO)

```bash
make
# → outputs: build/nclawzero-installer-cixmini-${VERSION}.iso
```

## Quick start (install on hardware)

> **A wired Ethernet connection is required.** The installer debootstraps the
> base system and upgrades it over the network, and Wi-Fi isn't available in
> d-i. Plug in a wired cable **before** powering on. If no link is detected the
> installer now stops with a clear "Network autoconfiguration failed" message
> (plug in a cable and Retry) instead of looping silently. Realtek NICs —
> including the Orion O6's RTL8125/8126 — work out of the box; the `rtl_nic`
> firmware ships in both the installer and the installed system.

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
  NemoClaw templates (staged only — none active by default)
- Plymouth theme (custom nclawzero splash)

So the install is offline-capable for the Cix layers and **stages** the agent
quadlets + OCI images without activating any of them; every agent (including
zeroclaw) and the MNEMOS memory system are installed on demand by the operator
via `ncz` after install.

## On-device AI: NPU embeddings & inference

The ISO ships a working **NPU embedding stack** so a freshly-installed
appliance does semantic memory at NPU latency, offline, with no setup. This is
the load-bearing AI workload for MNEMOS (the memory layer) and it is wired to be
**automatic** — the operator never picks a model or an accelerator.

### What's baked into the install

| Component | Lands at | From |
|---|---|---|
| NPU kernel driver (`armchina_npu.ko`, `/dev/aipu`) | kernel + `modules-load.d` | `assets/npu`, `80-npu.sh` |
| NPU userspace (`libnoe.so.0.6.0` + `libnoe`/`NOE_Engine` wheels) | `/usr/share/cix/lib`, `/usr/share/cix/pypi` | `cix-noe-umd 2.0.2`, `25-cix-proprietary.sh` |
| Python 3.11 venv (libnoe wheels are cp311/cp312 only) | `/opt/ncz/embed-venv` | `46-python311.sh`, `47-embedkit.sh` |
| **Embedding model** `bge-small-zh-v1.5_256.cix` (INT8, 512-dim) | `/opt/ncz/models/` | `assets/models`, `47-embedkit.sh` |
| Offline tokenizer | `/opt/ncz/models/bge-small-zh-v1.5/` | `assets/models` |
| GGUF CPU/GPU fallback | `/opt/ncz/models/` | `assets/models` |
| Operator docs (this section's deep dives) | `/usr/share/doc/ncz/` | `assets/docs`, `80-npu.sh` |

The `.cix` is the prebuilt Compass-NN artifact pulled from the Cix
`ai_model_hub` (ModelScope, 26_Q1) and **committed to this repo** so it can
never be lost on reinstall (the failure mode of cixtech/cix-linux-main#21).

### Embedding is automatic

MNEMOS embeds every memory on ingest via `embedkit.Engine.auto()`, which:

1. probes hardware, sees `libnoe` + `/dev/aipu`, selects the `npu-cix` adapter;
2. loads the `.cix` from `/opt/ncz/models/` and tokenizes offline;
3. returns the 512-dim vector for vector search.

No manual embedding step, no per-model wiring. The same `Engine.auto()` call
falls back to CPU/GPU on non-NPU silicon — the kit is vendor-agnostic. Verified
on Sky1 (`7.0.12-cix-sky1-next`): correct semantic retrieval, ~51 emb/s.

### Inference hierarchy (what runs where)

| Workload | Use | Avoid |
|---|---|---|
| Text embeddings (encoder, ≤256 tok) | **NPU** (`.cix`) | GPU compute |
| Long-doc embeddings / LLM decode / dynamic shapes | **CPU** | NPU, GPU compute |
| Vision / CNN (mobilenet, resnet, yolo) | **NPU** | GPU compute |
| Display / desktop GL/Vulkan | **GPU** (panthor) | — |

NPU = fixed-shape encoders, CPU = everything dynamic, GPU = pixels not ML.
Mali-G720 has no cooperative-matrix, so GPU ML compute is 6–47× slower than CPU
— it is wired for display only. Full per-driver matrix with numbers:
[`docs/INFERENCE_LIMITS.md`](docs/INFERENCE_LIMITS.md).

### Pulling more models

`.cix` models come prebuilt from the Cix hub (the Compass compiler is not
public). Pull a single file:

```bash
BASE="https://www.modelscope.cn/models/cix/ai_model_hub/resolve/26_Q1"
curl -fL "$BASE/models/.../bge-small-zh_256.cix" -o model.cix
```

Drop it in `assets/models/`, add a row to `assets/models/MODELS-README.md`,
rebuild. Full guide (single-file + LFS clone + custom ONNX→`.cix`):
[`docs/MODELSCOPE-MODELS.md`](docs/MODELSCOPE-MODELS.md).

### Deep-dive docs (also shipped to `/usr/share/doc/ncz/` on the appliance)

- [`docs/MNEMOS-NPU-EMBEDDINGS.md`](docs/MNEMOS-NPU-EMBEDDINGS.md) — the automatic embedding chain, I/O contract, verification commands
- [`docs/INFERENCE_LIMITS.md`](docs/INFERENCE_LIMITS.md) — full per-HW/driver capability + limits matrix
- [`docs/MODELSCOPE-MODELS.md`](docs/MODELSCOPE-MODELS.md) — pulling/compiling `.cix` models

## AI/ML stack & project history

The full guide to what AI/ML ships on the appliance, what each binary and
library is for, how to route a workload across the four compute engines
(CPU / NPU / GPU / VPU), measured performance, and how to pull new models:

- [`docs/AI-ML-STACK.md`](docs/AI-ML-STACK.md) — AI/ML stack reference
  · [简体中文 (Simplified Chinese)](docs/AI-ML-STACK.zh-CN.md)
- [`docs/HOW-DID-WE-GET-HERE.md`](docs/HOW-DID-WE-GET-HERE.md) — schedule
  post-mortem: the engineering effort behind the first full Linux distro for
  this silicon · [简体中文 (Simplified Chinese)](docs/HOW-DID-WE-GET-HERE.zh-CN.md)


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
4. `30-agents.sh` — install podman + the `ncz` CLI + stage agent quadlet templates and OCI images (no agent activated; all opt-in via `ncz`)
5. `40-claude-code.sh` — `npm install -g @anthropic-ai/claude-code`
6. `50-brand.sh` — `/etc/os-release`, motd, hostname
7. `60-plymouth.sh` — Plymouth boot splash + nclawzero theme

## Remote diagnostics (while the installer is booted)

A single, **removable, toggleable** diagnostics module gives a remote operator
full access *while the d-i installer is running*, so an install can never wedge
us out and failures are captured even with nobody watching.

> **🔑 Default login (installer only):** username **`installer`** (or **`root`**),
> password **`diags`**. Override the password at boot with
> `ncz_diag_pw=<pw>` on the kernel cmdline. (LAN-only / testing — see the
> security note below.)

| Channel | Port | Access |
|---|---|---|
| **SSH (password)** | 22 | `ssh root@<host>` — password `diags`. `network-console` + `sshd-watcher.sh` force `PasswordAuthentication yes`/`PermitRootLogin yes`; the module sets root's password so password auth actually works (no key needed). `installer@<host>` (password `diags`) also reaches the network-console menu. |
| **Telnet** | 23 | rich busybox shell (full applet farm: `vi`/`awk`/`sed`/`tar`/`less`/…) from the shipped static arm64 busybox |
| **HTTP (file pull)** | 8080 | `wget http://<host>:8080/var/log/syslog` or browse `http://<host>:8080/` for any installer file (GET-only) |
| **Remote syslog** | 5514/udp | every installer log line (plus `DEBCONF_DEBUG=5` verbose d-i output) shipped to a collector host so you get the failure without logging in |

**Toggle / removal (two independent switches).**
1. **Build switch** — `DIAG_ENABLE=0 build/build-iso-di.sh …` produces a
   **ship-clean** image: the module is not staged and `ncz_diag`/`DEBCONF_DEBUG`
   are not added to the kernel cmdline. (Default `DIAG_ENABLE=1` during bring-up.)
2. **Boot variable** — `ncz_diag=0|off` on the kernel cmdline disables the
   module even if staged; `ncz_diag=1` enables it. Flip it right at the GRUB menu.

**Tunables (kernel cmdline):**
- `ncz_diag_pw=<pw>` — root/diag password (default `diags`).
- `ncz_diag_log=<host[:port]>` — remote syslog collector (defaults to the
  build's internal dev collector on port `5514`). Point it at your own box.

**How it works.** A static arm64 busybox (`assets/diag/busybox-arm64`, with
`telnetd`/`httpd`/`syslogd`/`klogd`/`chpasswd` compiled in) ships on the CD;
`preseed/early_command` launches `preseed/diag-console.sh` in the background. The
script self-gates on `ncz_diag`, installs a full applet farm for the rich shell,
sets the root password, replaces d-i's syslogd with one that **also forwards to
the collector**, and starts telnetd + httpd — all **idempotent** (pidfile-guarded)
and self-respawning for the whole install. The base d-i initrd has none of these
(`nc`/`wget`/`tftp` only, and `sshd` only after network-console).

**Collector side.** Run `ncz-logd.sh` on your collector host: a `socat` UDP
listener on `:5514` appending to
`~/cixmini-install-logs/install-<date>.log`. `tail -f` it during an install.

**File transfer.** *Pull:* `wget http://<host>:8080/<path>`. *Push:* over SSH,
`cat local | ssh root@<host> 'cat >/tmp/x'` (httpd is GET-only).

On the **installed system**, full SSH (scp/sftp), telnet on :23
(`post-install/36-telemetry.sh`) and telemetry take over; the installer-only
consoles vanish with the d-i ramdisk.

> **Security:** the default password `diags`, unauthenticated-ish telnet root
> shell, and world-readable httpd are **LAN-only / TESTING ONLY**. Ship with
> `DIAG_ENABLE=0` (or `ncz_diag=0`) to strip the whole module in one switch.

### Installed-system access posture (defaults)

- **No diagnostic account on a running appliance.** `post-install/09-diag-account.sh`
  seeds the `magnetar` rescue account so an install / first boot can never lock
  you out, but it is **installer-only**: a first-boot oneshot
  (`nclawzero-diag-selfdestruct.service`) deletes the account and every artifact
  (sudoers drop-in, AccountsService entry, SSH keys, marker) and then removes
  itself. After the first clean boot the delivered system carries **no**
  diagnostic credentials. (If the first boot fails before it runs, the account
  is still there for rescue.)
- **Password SSH auth is enabled by default** on the installed system for
  operator convenience (`PasswordAuthentication yes`). Day-to-day login is the
  operator account you set at install time. To harden a fleet image to key-only,
  set `PasswordAuthentication no` / `PermitRootLogin prohibit-password` in
  `post-install/35-ssh.sh` and re-bake.
- **Hostname** defaults to `ncz-<mac8>` (last 8 hex of the first wired MAC) so
  every box on a LAN is uniquely named; the operator hostname (if set during
  install) always wins. See `post-install/37-ntp-hostname.sh`.

## OTA channel (kernel + driver updates)

Fielded devices upgrade their kernel and the proprietary CIX drivers **over
standard APT — no reinstall**.

**Where packages live.**
- **Kernels** — compiled `linux-image-cixmini-{lts,edge}` + `cixmini-boot`
  (`build/build-kernel-debs.sh`) → **Buildkite Packages** signed Debian registry
  `ncz-os/ncz`, wired by `post-install/92-buildkite-apt.sh`:
  `deb [signed-by=…] https://packages.buildkite.com/ncz-os/ncz/any/ any main`
- **CIX userspace drivers/runtimes** → **Codeberg** `ncz-os` Debian registry,
  wired by `post-install/91-codeberg-apt.sh`:
  `deb [signed-by=…] https://codeberg.org/api/packages/ncz-os/debian ncz main`
- **Kernel source + Yocto recipes** → GitLab [`ncz-os/meta-cix`](https://gitlab.com/ncz-os/meta-cix).

Both apt sources are GPG-signed (`signed-by`, never `trusted=yes`); the
install-media `file:///cdrom` source is stripped post-install, and the previous
GHCR/squashfs OTA (`90-ota-channel.sh`) is retired.

**How it updates.** On the device, `apt update && apt upgrade` (or
`ncz-update [--apply]`) pulls new kernel + CIX packages from the signed
registries and installs them — moving to a new kernel no longer requires a
full reinstall.

`ncz-update --status` reports the configured image and installed versions without
pulling anything.

**Why the repo is ephemeral (not a persistent `fstab` loop mount).**

- **Footprint** — a persistent loop mount would keep the 2.1 GB+ squashfs backing
  file on disk indefinitely and let its decompressed pages accumulate in the page
  cache. The repo is only needed while `apt` is reading `.debs`; on an appliance
  with modest storage/RAM we reclaim it immediately afterwards (deleting the file
  + dropping the mount makes those page-cache pages reclaimable).
- **Hygiene / trust window** — a permanently mounted `file://` source widens the
  trust surface and makes every later `apt update` depend on the mount being
  present. Pulling per-run and tearing down keeps that window minimal.
- **Determinism** — the OTA repo is a transient *build input*, not part of the
  running system. Pull → use → discard keeps the installed system reproducible and
  avoids stale indexes.

> **Trust model (two independent signatures).**
> 1. **Transport layer** — the OCI image is **cosign-signed** (`build/release-ota.sh`,
>    key in `build/keys/cosign.key`, pubkey shipped as
>    `assets/keys/ncz-ota-cosign.pub`). `ncz-update` runs `cosign verify`
>    *before* pulling/mounting and pins the verified digest, so a swapped or
>    unsigned image is rejected up front.
> 2. **Package layer** — the apt `Release` inside the squashfs is **GPG-signed**
>    and verified against the device-pinned keyring via `signed-by` (no
>    `trusted=yes`), so even a validly-transported but foreign repo can't install.
>
> Both private keys live only on the build host (`build/keys/`, gitignored) and
> never ship. The squashfs `sha256` in the image label is a tertiary
> corruption/tamper tripwire. Remaining hardening: cosign + GPG key
> rotation/expiry policy and (optionally) Rekor transparency-log inclusion. See
> `post-install/90-ota-channel.sh`, `build/build-ota-repo.sh`, and
> `build/release-ota.sh`.

## Status

**26.6 (r126)** — current release. The open Mesa 26.1.3 stack is now the
complete default GPU provider for **OpenGL/GLX, Vulkan, and OpenCL**, with the
CIX proprietary stack kept on disk (`.disabled`) for a future opt-in switcher.
Tested on Minisforum MS-R1 only — see **Hardware support & testing status**
above. Both **Reinhardt** (desktop) and **Magnetar** (server) variants build
from this tree.

What changed since the r113 baseline:

- **r126 — open Mesa is the full default; desktop + Vulkan fixed.**
  `26-gpu-default-open.sh` now demotes *every* CIX GPU component out of the
  loader paths. Previously the CIX `cix-libglvnd` `libGLX.so.0` ran a "CIX
  driver check", failed (no `mali_kbase`; panthor owns the GPU), and called
  `abort()` — taking down Xorg and crash-looping lightdm (boots looked like
  "server" with no GUI). The CIX Vulkan ICD (`mali.json`) and WSI implicit
  layer aborted `vkCreateInstance` for every app the same way. Demoting
  cixgpu-compat (GL/GLX), `mali.json`, and the WSI layer — alongside the
  existing cixgpu-pro (OpenCL) demote — makes Mesa the default everywhere:
  desktop boots straight to the XFCE greeter, `panvk` Vulkan and `rusticl`
  OpenCL both work with no env overrides.
- **r125 — rusticl OpenCL works out of the box.** Bundled the missing
  `libclang-cpp` + `libLLVMSPIRVLib` runtime libs (`$ORIGIN` RPATH) and the
  `libclc` SPIR-V into the Mesa bundle, and demoted the CIX `libOpenCL.so.1`
  that was shadowing `ocl-icd`. `clinfo` → `Mali-G720 MC10 (Panfrost)`,
  OpenCL 3.0.
- **r124 — agents are opt-in; NPU gating hardened.** All agents (including
  `zeroclaw`) now install on demand via `ncz agent install` (desktop icon +
  first-login notice) instead of auto-activating, removing the first-boot
  crash-loop. NPU SSDT injection gating was tightened so it no longer misfires
  on unidentified boards.
- **r113 — first full release** with the Mesa 26.1.3 GPU compute stack
  (panvk + rusticl), validated NPU embeddings, and the A/B kernel program
  (6.18 LTS default + 7.0.x edge).

## Sister projects

- [`gitlab.com/nclawzero/cix-gen`](https://gitlab.com/nclawzero/cix-gen) — script-based image builder; runs from a working aarch64 system, bypasses the d-i flow. Different use case (in-place rebuild vs fresh install).
- [`gitlab.com/ncz-os/meta-cix`](https://gitlab.com/ncz-os/meta-cix) — Yocto layer for the BSP (kernel + Cix userspace recipes). Provides the `linux-cix-msr1` kernel artifacts consumed here.


## Current ISO — r147 (NCZ-OS 26.6 — official release)

The first official NCZ-OS release with **apt-capable kernel upgrades** — move to a new kernel without reinstalling. QEMU-validated end-to-end (full unattended install + boot).

**Upgrade kernels & drivers with apt — no reinstall**
- Kernels (compiled): **Buildkite Packages** `ncz-os/ncz` — `apt upgrade` / `ncz-update` pulls new `linux-image-cixmini-{lts,edge}`.
- CIX userspace: **Codeberg** `ncz-os` Debian registry.
- Kernel source + Yocto recipes: GitLab [`ncz-os/meta-cix`](https://gitlab.com/ncz-os/meta-cix).

**Kernels:** 6.18.26-cix-sky1-lts (default, production) + 7.0.12-cix-sky1-next (edge). (7.1.2 experimental/non-working; 7.2 migration in progress.)

**Install:** unattended d-i (auto-partition, ESP + NCZRESCUE rescue partition + btrfs root), boots rEFInd. Installer runs on the proven 6.18 LTS kernel.

**Recovery:** NCZRESCUE partition with full repair toolset + automatic networking, reachable independent of the main rootfs; installer remote-diagnostics (network-console + telnet/http) on USB boot.

**MS-R1 (cixmini) driver support — 6.18 / 7.0.12:** NVMe/PCIe, USB, Ethernet/Wi-Fi, Audio, NPU (Zhouyi V3 /dev/aipu), GPU (Mali-G720 panthor renderD128, Mesa 26.1.3 panvk+rusticl; compositing off), VPU — all working.

**Reproduce:** kernels from kernel.org stable git + meta-cix patch series under Yocto ([docs/KERNEL-BUILD-YOCTO.md](docs/KERNEL-BUILD-YOCTO.md)); ISO via build/build-iso-di.sh ([docs/NEXT_ISO.md](docs/NEXT_ISO.md)).
