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
| **Radxa Orion O6N** | Cix Sky1 | ⚠️ **Untested, but expected to work.** Same Sky1 SoC and the same O6 board family (a minor variant); the shipping 7.0.12-cix-sky1-next kernel ships the same driver set as O6 (see [Driver support matrix — O6 / O6N](#driver-support-matrix--o6--o6n)), so we just have not confirmed it on hardware yet. **If you have an O6N: please install, test, and file issues.** |
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

The kernel that actually ships in this installer is **7.0.12-cix-sky1-next**
(`assets/kernel/edge/KVER`, patch series `next-patches/0001`–`0043` +
`2001`–`2017` in `meta-cix:linux-cix-sky1-next`) — **not** the 7.1.2-ncz2 /
`linux-cix-sky1-ncz` line referenced in an earlier draft of this table. That
7.1.x line is a separate, still-unstable fork (a prior README revision marked
it "not-working"; it still has multiple `.bak-pre-branchfix`/
`.bak-pre-compilefix` recovery files in the recipe as of 2026-06-27) and is
not what boots on real hardware today. This table describes the kernel that
is actually installed.

Sky1 boots via **ACPI, not a device tree** — `/sys/firmware/devicetree/base`
is empty on both the MS-R1 and (per operator reports) Orion O6. There is no
`sky1-orion-o6.dtb` shipped or needed; an earlier revision of this table
claimed one existed in `assets/kernel/` — it doesn't, and never has for this
kernel line.

| Subsystem | Driver | Config | O6 | O6N | Notes |
|---|---|---|---|---|---|
| **Clock** | `clk-sky1-acpi` | `=y` | ✅ | ✅ | ACPI clock infra (patch `0003`); base SoC infra in `0002`. |
| **Reset** | `reset-sky1` | `=y` | ✅ | ✅ | Reset controllers + ACPI lookup table (patch `0004`). |
| **Pinctrl** | `pinctrl-sky1` | `=y` | ✅ | ✅ | Patch `0007`. |
| **Mailbox** | `cix-mbox` | `=y` | ✅ | ✅ | ACPI support + channel lookup (patch `0005`). |
| **SCMI** | `arm-scmi` (clock + perf + power + sensor domains) | `=y` | ✅ | ✅ | ACPI boot support (patch `0006`); confirmed in `config.sky1-next` (`CONFIG_ARM_SCMI_PERF_DOMAIN=y`, `CONFIG_ARM_SCMI_POWER_DOMAIN=y`). |
| **Thermal** | `cix-thermal` + IPA + cpufreq | `=y` | ✅ | ✅ | Patch `0017`. |
| **DSP** | `cix-dsp` + `cix-dsp-rproc` | `=m` | ✅ | ✅ | Remoteproc + rpmsg (patch `0019`); confirmed loaded (`cix_dsp_rproc`) on real Sky1 hardware. |
| **Audio (HDA)** | `snd-hda-cix-ipbloq` + Realtek ALC codecs | `=m` | ✅ | ✅ | Patches `2015`–`2017`. Verified ALC269VC analog + digital + HDMI/DP on real hardware. |
| **Audio (SoC)** | `snd-soc-sky1-sound-card` + Cadence I2S + `snd-soc-sof-cix` | `=m` | ✅ | ✅ | Patch `2014`. SOF (`CONFIG_SND_SOC_SOF_CIX_TOPLEVEL=y`, `CONFIG_SND_SOC_SOF_CIX_SKY1=m`) is built but not observed loaded on real hardware — the machine driver (`snd-soc-sky1-sound-card`) handles audio directly; SOF appears to be a dormant/fallback path, not confirmed active. |
| **GPU (Mali-G720)** | `panthor` + `drm-cix` + `drm-trilin-dp-cix` (DisplayPort) | `=m` | ✅ | ✅ | Patches `0011`/`0012`. `panthor` confirmed loaded + rendering (Mali-G720-Immortalis, CSF FW); `drm-trilin-dp-cix`/`drm-trilin-dpsub` confirmed loaded (`trilin_dpsub`, `linlon_dp`) on real hardware. |
| **VPU (Linlon MVX)** | `amvx` | `=m` | ✅ | ✅ | Video codec driver (patch `0015`). The in-tree driver has a vb2 `q->lock` bug on this kernel — fixed via a validated overlay (see `post-install/81-vpu.sh`); needs `amvx` neutralized in the vendor blacklist to auto-load (fixed `cd822ed`). |
| **NPU (Zhouyi V3)** | `armchina-npu` | `=m` | ✅ | ✅ | Patch `0016`. Needs `CONFIG_ARMCHINA_NPU_ARCH_V3=y` — the Sky1 NPU reports ISA version 5 (Zhouyi V3), not 6 (V3_1); both are now enabled (fixed `053b5ce`). ⚠️ The 32-bit SMMU/IOVA DMA constraint (`2009-armchina-npu-msr1-smmu-32bit-dma-constraint.patch`) is titled and written specifically for **MS-R1** — it has not been confirmed necessary or correct for O6/O6N's SMMU topology. Treat NPU on O6/O6N as *should work*, not independently verified. |
| **Ethernet** | `r8169` (RTL8125/8126/8169) | `=y` | ✅ | ✅ | `rtl_nic` firmware shipped in installer + installed system. Confirmed `CONFIG_R8169=y` (built-in, not a module) in `config.sky1-next`. |
| **Wi-Fi** | `mt7921e` (MediaTek MT7921/MT7922) | `=m` | ✅ | ✅ | M.2 Key-E slot; confirmed loaded on real hardware. |
| **Wi-Fi (alt)** | `rtw88`/`rtw89` firmware | `=m` | ✅ | ✅ | If equipped (`rtw8852b`, `rtw8822`, etc. firmware shipped). |
| **PCIe / USB / PHY** | `pcie-cadence`, `usb-cdnsp`, `phy-cix-usbdp`, `phy-cix-pcie` | `=y` | ✅ | ✅ | Patches `0008`/`0009`/`0010`. |
| **USB Type-C** | `typec-rts5453` | — | ⚠️ | ⚠️ | Not currently loaded by default — `typec_rts5453`/`rts5453` are in `module_blacklist=` on the boot cmdline (workaround for an unrelated boot issue; see cmdline below). Present in the kernel, not active out of the box. |
| **IOMMU/SMMU** | `arm-smmu-v3` | `=y` | ✅ | ✅ | Confirmed loaded on real hardware. |
| **GPIO / I2C / DMA / PWM / Syscon / Regulator / Timer / IRQ** | Sky1 misc peripherals | mixed | ✅ | ✅ | Patch `0018` (misc peripherals) + `0021` (firmware/pinctrl ACPI gaps). |
| **SoC ACPI resource lookup** | `cix-acpi-resource-lookup` | `=y` | ✅ | ✅ | `CONFIG_CIX_ACPI_RESOURCE_LOOKUP=y` confirmed; folded into patches `0002`/`0008`, not a standalone `9007`-style patch. |

**Known gap — O6-specific deferred-probe ACPI hardening not yet ported.**
The retired 7.1.2-ncz2 line had four O6-targeted fixes (deferring the SCMI
perf-domain fwnode provider and the `pm_runtime` resume gate to
`late_initcall`, plus an ACPI power-management transition for
`clk-sky1-acpi`) intended to smooth out ACPI probe-ordering issues specific
to O6's firmware. These do **not** exist in the 7.0.12-next patch series that
actually ships — checked directly (`0039-pmdomain-scmi_pm_domain-add-fwnode-provider-for-ACPI.patch`
does not defer to `late_initcall`). If O6/O6N testing turns up deferred-probe
or SCMI-domain-ordering failures, this is the first place to look; the fix
needs to be ported forward from the 7.1.x work, not copied verbatim (that
line doesn't build cleanly as of 2026-06-27).

**What's required for O6 / O6N to boot cleanly:**

1. **Kernel 7.0.12-cix-sky1-next** (`assets/kernel/edge/`) — the LTS kernel
   (`6.18.26-cix-sky1-lts`) is also shipped as a fallback (`assets/kernel/stable/`).
2. **No separate DTB** — boot is ACPI-based; the same kernel/firmware image
   is used across MS-R1 and Orion O6/O6N.
3. **Firmware**: `rtl_nic` (RTL8125/8126), `mali_csffw.bin` (Mali-G720
   panthor), `armchina-npu` in-tree + validated overlay (NPU), `amvx`
   validated overlay (VPU).
4. **ACPI cmdline**: `acpi=force efi=noruntime arm-smmu-v3.disable_bypass=0
   clk_ignore_unused panic=30 module_blacklist=typec_rts5453,rts5453` (the
   installer adds these to the rEFInd boot entry automatically). Confirmed
   present and unchanged on a real installed system.

**O6N-specific notes:** the O6N is a minor variant of the O6 with the same
Sky1 SoC and same ACPI DSDT shape. The kernel + firmware set above is
expected to work without modification, but **has not been tested on O6N
hardware** — only the MS-R1 (extensively) and the O6 (installer/boot,
per operator report) have real validation. If you have an O6N: please
install, test, and file issues — specifically watch for the deferred-probe
gap noted above and the untested NPU IOVA constraint.

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
| `assets/cix-debs/` | Staged CIX proprietary `.deb`s (gitignored) | Also mirrored into Buildkite `ncz-os/ncz` (31 packages, see OTA channel section) |
| `assets/kernel/{stable,edge}/` | Yocto build of `meta-cix:linux-cix-sky1-{lts,next}` (gitignored) | `Image-cixmini.bin` + `modules-cixmini.tgz` + `KVER` per kernel; also has a `modules-overlay/$KVER/` subdir for validated fixup `.ko`s (see `post-install/80-npu.sh`, `81-vpu.sh`) |
| `assets/agent-stack/*` | This repo | systemd quadlets for zeroclaw/openclaw/hermes/portainer/mnemos/nemoclaw |
| `assets/branding/*` | This repo | os-release, motd, Plymouth theme, wallpapers |
| `preseed/preseed.cfg`, `preseed/late.sh` | This repo | d-i unattended preseed + late_command (pre-chroot, install-time-only) |
| `post-install/*.sh` | This repo | 40+ numbered hooks; run inside the chroot |

## Stages (post-install hooks)

`post-install/run-all.sh` runs the numbered `post-install/*.sh` hooks inside the
chroot, in three phases: required kernel/network hooks (skipped on a baked
image, where the kernel is already in the squashfs), machine-specific hooks
gated by `MACHINE_HOOKS_RE` on a baked image (apt sources, CIX proprietary
userland, GPU pin, agent stack, Python/embedkit, Claude Code, Vivaldi, NPU/VPU
overlays, rescue partition), and the bootloader/diagnostics hooks run from an
`EXIT` trap. This list goes stale fast (it has twice already) — `run-all.sh`
and the individual `post-install/NN-*.sh` files are the source of truth for
exactly what runs and in what order, not a hand-maintained summary here.

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

## OTA channel (kernel + driver updates) + persistent apt sources

Fielded devices upgrade their kernel and the proprietary CIX drivers **over
standard APT — no reinstall**. `post-install/24-apt-sources.sh` wires the
Buildkite source and refreshes the package index, deliberately early
(before any hook that installs packages, so their own dependency-resolution
steps have real, current index data to pull from). This fixes a 2026-07-05
regression: `vivaldi-stable` got stuck dpkg `iU`/half-configured on every
fresh install because its `fonts-liberation` dependency couldn't resolve.
The root cause was **not** a missing apt source — the Ubuntu archive
(main+universe+restricted+multiverse, always enabled by default, see
below) was there the whole time — it was that nothing ever ran `apt-get
update` before that dependency-resolution step needed it, compounded by
that step using `--no-download` (fixed separately in `52-vivaldi.sh`).

**Where packages live.**
- **Ubuntu archive** (main + universe + restricted + multiverse, plus
  `-updates`/`-security`/`-backports`) → `ports.ubuntu.com/ubuntu-ports`
  (arm64). Enabled by default in `/etc/apt/sources.list` on every image —
  this was never CDROM-only, despite some in-repo comments describing an
  "offline-only" doctrine; that doctrine applied to specific single-vendor
  sources (see Vivaldi below), not the base Ubuntu archive.
- **Kernels** — compiled `linux-image-cixmini-{lts,edge}` + `cixmini-boot`
  (`build/build-kernel-debs.sh`) → **Buildkite Packages** signed Debian registry
  `ncz-os/ncz`, wired by `post-install/24-apt-sources.sh`:
  `deb [signed-by=…] https://packages.buildkite.com/ncz-os/ncz/any/ any main`
- **CIX userspace drivers/runtimes** → the **same** Buildkite `ncz-os/ncz`
  registry (mirrored 2026-07-05 from `archive.cixtech.com`, the upstream CIX
  Debian repo — China-hosted, intermittently refuses connections entirely).
  31 packages, ~81MB, well under the registry's 1.5GB quota; the 5 test/dev-only
  packages that are never actually installed (`cix-unit-test`,
  `cix-npu-onnxruntime`, `cix-ltp`, `cix-gpu-test`, `cix-vpu-test` — 1.6GB
  combined) were excluded. There is no Codeberg apt source for this — an
  earlier revision of this doc described one (`post-install/91-codeberg-apt.sh`)
  that was never actually implemented in this repo.
- **Kernel source + Yocto recipes** → GitLab [`ncz-os/meta-cix`](https://gitlab.com/ncz-os/meta-cix).

The Buildkite source is GPG-signed (`signed-by`, never `trusted=yes`); the
install-media `file:///cdrom` source is stripped post-install, and the previous
GHCR/squashfs OTA (`90-ota-channel.sh`) is retired. The old "CDROM-only, no
persistent apt source" posture (r180 doctrine) is superseded for the sources
above; `52-vivaldi.sh` still neutralizes Vivaldi's own single-vendor
`repo.vivaldi.com` source specifically (a narrower, separate decision).

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
- Kernels + CIX userspace (compiled/mirrored): **Buildkite Packages** `ncz-os/ncz` — `apt upgrade` / `ncz-update` pulls new `linux-image-cixmini-{lts,edge}` and the 31 mirrored CIX proprietary packages. No Codeberg apt source exists for this (see OTA channel section above).
- Kernel source + Yocto recipes: GitLab [`ncz-os/meta-cix`](https://gitlab.com/ncz-os/meta-cix).

**Kernels:** 6.18.26-cix-sky1-lts (default, production) + 7.0.12-cix-sky1-next (edge). (7.1.2 experimental/non-working; 7.2 migration in progress.)

**Install:** unattended d-i (auto-partition, ESP + NCZRESCUE rescue partition + btrfs root), boots rEFInd. Installer runs on the proven 6.18 LTS kernel.

**Recovery:** NCZRESCUE partition with full repair toolset + automatic networking, reachable independent of the main rootfs; installer remote-diagnostics (network-console + telnet/http) on USB boot.

**MS-R1 (cixmini) driver support — 6.18 / 7.0.12:** NVMe/PCIe, USB, Ethernet/Wi-Fi, Audio, NPU (Zhouyi V3 /dev/aipu), GPU (Mali-G720 panthor renderD128, Mesa 26.1.3 panvk+rusticl; compositing off), VPU — all working.

**Reproduce:** kernels from kernel.org stable git + meta-cix patch series under Yocto ([docs/KERNEL-BUILD-YOCTO.md](docs/KERNEL-BUILD-YOCTO.md)); ISO via build/build-iso-di.sh ([docs/NEXT_ISO.md](docs/NEXT_ISO.md)).
