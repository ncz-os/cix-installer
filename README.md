# ⚠️ This is a mirror — the canonical repo lives on GitLab

### 👉 https://gitlab.com/ncz-os/cix-installer

**Source, releases, issues, merge requests, and CI all live on GitLab.** This GitHub copy is a read-only mirror and may lag. Please file issues and get releases there.

---

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

> **New in r195:** the kernel channels move forward — **7.0.12 is now the
> stable channel** and **7.2.0-rc1-ncz is the new edge channel** (6.18 LTS is
> retired from the ISO). The 7.2 edge kernel carries this cycle's real fixes:
> the VPU boot-hang fix (pm_runtime IRQ/reset ordering, matching CIX's own
> v1.0.1 driver release), a corrected RTL8127 PCIe ASPM/ClockPM quirk, the
> in-tree panthor driver removed in favor of the out-of-tree Mali DDK stack,
> and the linlondp 26q2 -Werror fixes. Kernels are now built under
> **Yocto Project 6.0 "Wrynose"**. The base image also lost ~2 GB of dead
> weight (stale test packages are no longer baked in). OTA publication of the
> new kernel pair to the apt channel follows separately. See
> [Current ISO](#current-iso--r195-ncz-os-266--official-release).

### Why NCZ-OS, when Canonical / Armbian / vendor images exist?

Fair question — the ARM single-board space has no shortage of images. NCZ-OS
is not trying to be another generic port. It is an **agentic-targeted Linux
distribution for ARM**, and the differences are the point:

- **One consistent installer across multiple (often exotic) ARM systems** —
  the same unattended installer, partitioning, boot, and recovery model on
  every supported board, instead of a different image with different
  conventions per vendor.
- **The proprietary bits actually work out of the box** — GPU, NPU, VPU,
  audio, and firmware for each system are integrated, patched where the
  vendor drops lag mainline, and validated on real hardware before release.
- **Agents, inference, and agentic memory are first-class** — the ncz agent
  stack, on-device NPU inference, and the memory substrate ship staged
  (opt-in, never running until you ask) rather than bolted on afterward.
- **Recoverability as doctrine** — every install carries a bootable rescue
  partition with self-configuring networking (DHCP + static fallback) and
  multiple access channels, because a bricked remote ARM box you cannot
  reach is the normal failure mode this project refuses to accept.

If a general-purpose image already serves you well, use it happily. NCZ-OS
exists for the case where you want ARM machines that behave like a coherent,
agent-ready fleet rather than a shelf of one-off boards — injecting some
standardization into a space that today has very little.

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

### Driver support matrix — MS-R1 / O6 / O6N

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

| Subsystem | Driver | Config | MS-R1 | O6 | O6N | Notes |
|---|---|---|---|---|---|---|
| **Clock** | `clk-sky1-acpi` | `=y` | ✅ | ✅ | ✅ | ACPI clock infra (patch `0003`); base SoC infra in `0002`. |
| **Reset** | `reset-sky1` | `=y` | ✅ | ✅ | ✅ | Reset controllers + ACPI lookup table (patch `0004`). |
| **Pinctrl** | `pinctrl-sky1` | `=y` | ✅ | ✅ | ✅ | Patch `0007`. |
| **Mailbox** | `cix-mbox` | `=y` | ✅ | ✅ | ✅ | ACPI support + channel lookup (patch `0005`). |
| **SCMI** | `arm-scmi` (clock + perf + power + sensor domains) | `=y` | ✅ | ✅ | ✅ | ACPI boot support (patch `0006`); confirmed in `config.sky1-next` (`CONFIG_ARM_SCMI_PERF_DOMAIN=y`, `CONFIG_ARM_SCMI_POWER_DOMAIN=y`). |
| **Thermal** | `cix-thermal` + IPA + cpufreq | `=y` | ✅ | ✅ | ✅ | Patch `0017`. |
| **DSP** | `cix-dsp` + `cix-dsp-rproc` | `=m` | ✅ | ✅ | ✅ | Remoteproc + rpmsg (patch `0019`); confirmed loaded (`cix_dsp_rproc`) on real Sky1 hardware (MS-R1). |
| **Audio (HDA)** | `snd-hda-cix-ipbloq` + Realtek ALC codecs | `=m` | ✅ | ✅ | ✅ | Patches `2015`–`2017`. Verified ALC269VC analog + digital + HDMI/DP on real hardware (MS-R1). |
| **Audio (SoC)** | `snd-soc-sky1-sound-card` + Cadence I2S + `snd-soc-sof-cix` | `=m` | ✅ | ✅ | ✅ | Patch `2014`. SOF (`CONFIG_SND_SOC_SOF_CIX_TOPLEVEL=y`, `CONFIG_SND_SOC_SOF_CIX_SKY1=m`) is built but not observed loaded on real hardware — the machine driver (`snd-soc-sky1-sound-card`) handles audio directly; SOF appears to be a dormant/fallback path, not confirmed active. |
| **GPU (Mali-G720)** | `panthor` + `drm-cix` + `drm-trilin-dp-cix` (DisplayPort) | `=m` | ✅ | ✅ | ✅ | Patches `0011`/`0012`. `panthor` confirmed loaded + rendering (Mali-G720-Immortalis, CSF FW) on MS-R1; `drm-trilin-dp-cix`/`drm-trilin-dpsub` confirmed loaded (`trilin_dpsub`, `linlon_dp`) on real hardware. |
| **VPU (Linlon MVX)** | `amvx` | `=m` | ✅ | ✅ | ✅ | Video codec driver (patch `0015`). The in-tree driver has a vb2 `q->lock` bug on this kernel — fixed via a validated overlay (see `post-install/81-vpu.sh`); needs `amvx` neutralized in the vendor blacklist to auto-load (fixed `cd822ed`). |
| **NPU (Zhouyi V3)** | `armchina-npu` | `=m` | ✅ | ✅ | ✅ | Patch `0016`. Needs `CONFIG_ARMCHINA_NPU_ARCH_V3=y` — the Sky1 NPU reports ISA version 5 (Zhouyi V3), not 6 (V3_1); both are now enabled (fixed `053b5ce`). ⚠️ The 32-bit SMMU/IOVA DMA constraint (`2009-armchina-npu-msr1-smmu-32bit-dma-constraint.patch`) is titled and written specifically for **MS-R1** (confirmed working there) — it has not been confirmed necessary or correct for O6/O6N's SMMU topology. Treat NPU on O6/O6N as *should work*, not independently verified. |
| **Ethernet** | `r8169` (RTL8125/8126/8169) | `=y` | ✅ | ✅ | ✅ | `rtl_nic` firmware shipped in installer + installed system. Confirmed `CONFIG_R8169=y` (built-in, not a module) in `config.sky1-next`. |
| **Wi-Fi** | `mt7921e` (MediaTek MT7921/MT7922) | `=m` | ✅ | ✅ | ✅ | M.2 Key-E slot; confirmed loaded on real hardware (MS-R1). |
| **Wi-Fi (alt)** | `rtw88`/`rtw89` firmware | `=m` | ✅ | ✅ | ✅ | If equipped (`rtw8852b`, `rtw8822`, etc. firmware shipped). |
| **PCIe / USB / PHY** | `pcie-cadence`, `usb-cdnsp`, `phy-cix-usbdp`, `phy-cix-pcie` | `=y` | ✅ | ✅ | ✅ | Patches `0008`/`0009`/`0010`. |
| **USB Type-C** | `typec-rts5453` | — | ⛔ | ⛔ | ⛔ | **Deliberately disabled — not a driver gap.** The stock `rts5453` Type-C PD driver wedges the boot (hangs on an IRQ-151 conflict) on this board; discovered the hard way (board bricking) during cmdline bring-up. `typec_rts5453`/`rts5453` are permanently in `module_blacklist=` on every boot cmdline (installer, installed system, and rescue partition alike) as a deliberate safety measure, not an oversight — see [`docs/ENGINEERING-EFFORT.md`](docs/ENGINEERING-EFFORT.md#21-the-command-line-nobody-documents). The module is present in the kernel and could in principle be re-enabled by a future patch that fixes the IRQ conflict, but that hasn't happened yet. |
| **IOMMU/SMMU** | `arm-smmu-v3` | `=y` | ✅ | ✅ | ✅ | Confirmed loaded on real hardware (MS-R1). |
| **GPIO / I2C / DMA / PWM / Syscon / Regulator / Timer / IRQ** | Sky1 misc peripherals | mixed | ✅ | ✅ | ✅ | Patch `0018` (misc peripherals) + `0021` (firmware/pinctrl ACPI gaps). |
| **SoC ACPI resource lookup** | `cix-acpi-resource-lookup` | `=y` | ✅ | ✅ | ✅ | `CONFIG_CIX_ACPI_RESOURCE_LOOKUP=y` confirmed; folded into patches `0002`/`0008`, not a standalone `9007`-style patch. |

MS-R1 is our validated test system (see **Hardware support & testing status**
above) — every ✅ in that column reflects direct, real-hardware confirmation,
not an inference from the O6/O6N columns.

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

1. Flash the ISO to a USB stick (≥8 GB):
   ```bash
   sudo bmaptool copy --bmap nclawzero-installer-cixmini.iso.bmap \
       nclawzero-installer-cixmini.iso /dev/sdX
   ```
2. Plug in a **wired Ethernet cable**, then plug the USB into the target
   (cixmini / Orion O6), power on, hit the F-key for the UEFI boot menu, pick USB
3. **Choose your disk and root filesystem.** The installer shows a real
   disk-selection screen (for multi-disk systems) followed by a filesystem
   choice — **btrfs** (default: snapshots + transparent compression) or
   **ext4** (simple, maximally robust). ZFS root is **not** supported yet.
   Both choices can be preset non-interactively via kernel cmdline
   (`ncz_disk=<dev>`, `ncz_fs=<ext4|btrfs>`) for unattended fleets.
4. d-i auto-runs preseed; ~20-30 min unattended install
5. Reboot, remove USB, target boots nclawzero from internal storage

## Architecture

The installer was redesigned around **layered squashfs images** rather than a
live debootstrap-and-apt-install at install time. The motivation was
concrete, not architectural taste: install **speed** (unpacking a pre-built,
pre-configured squashfs is far faster than debootstrap + hundreds of package
postinst scripts running on-device) and **offline reliability** (a squashfs
delta either extracts correctly or it doesn't — there's no network-dependent
package resolution mid-install to fail on a flaky link or an unreachable
mirror, which was a recurring source of install failures under the old
apt-at-install-time model).

![Architecture diagram](docs/architecture.svg)

**Both variant deltas ship on every ISO.** The rEFInd menu picks Reinhardt
(desktop) or Magnetar (server) at boot, and `preseed/extract-rootfs.sh`
overlays the matching delta onto the base. One disc, both variants.

The ISO also ships:
- CIX proprietary userspace `.deb`s, staged offline in `assets/cix-debs/`
  (~30 packages after excluding internal test/validation builds that are
  never actually installed) — dpkg-installed by `post-install/25-cix-proprietary.sh`.
  The same package set is **also** mirrored into the Buildkite `ncz-os/ncz`
  apt repo (31 packages, ~81 MB) so it can be re-pulled post-install without
  a reinstall — see [OTA channel](#ota-channel-kernel--driver-updates--persistent-apt-sources).
- Both kernels (`6.18.26-cix-sky1-lts` default + `7.0.12-cix-sky1-next` edge)
  with firmware, so a device can flip kernels without redownloading anything.
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
   module even if staged; `ncz_diag=1` enables it. Flip it right at the rEFInd menu.

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

## Rescue partition

Every install gets a dedicated 4 GiB ext4 **NCZRESCUE** partition, populated
at install time by `post-install/72-rescue-partition.sh` from a prebuilt
rescue rootfs (`build/build-rescue-rootfs.sh`, package list in
`manifests/rescue.pkgs`). It boots from its own rEFInd menu entry
("RESCUE PARTITION"), independent of the main root filesystem — if the
installed system's root (btrfs or ext4) won't boot, the rescue partition
still will.

**Login.** Root, password **`rescue`** (LAN-only; the rescue environment is
not meant to be internet-facing). Hostname `ncz-rescue`.

**Access channels:**

| Channel | Port | Notes |
|---|---|---|
| SSH (openssh, password auth) | 22 | `ssh root@<host>` |
| Dropbear (lightweight SSH) | 2222 | Alternative if openssh is misbehaving |
| Telnet | 23 | Full busybox applet shell |
| Serial console | `ttyAMA2@115200` | Direct hardware console, no network needed |

**Networking.** DHCP by default; falls back to a static IP
(`192.168.207.66/24`, gateway `192.168.207.1`) if DHCP fails, so the box is
always reachable on the fleet LAN even with no DHCP server present.

**What's on it.** A genuinely comprehensive recovery toolset (not just a
minimal shell) — cherry-picked from the SystemRescue package list and mapped
to Ubuntu 26.04 arm64:
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
  `deb [signed-by=…] https://pub-d7b784e01679403d9c70fcd23fff5b96.r2.dev any main`.
  Buildkite Packages serves over a CloudFront-backed CDN, so `apt update`/
  `apt upgrade` against this source is fast and doesn't depend on any single
  origin server staying up.
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

## Status

**26.6 (r194)** — current release. The open Mesa 26.1.3 stack is the complete
default GPU provider for **OpenGL/GLX, Vulkan, and OpenCL**, with the CIX
proprietary stack kept on disk (`.disabled`) for a future opt-in switcher.
Tested on Minisforum MS-R1 only — see **Hardware support & testing status**
above. **Reinhardt** (desktop) and **Magnetar** (server) both boot and install
from the *same* ISO — rEFInd picks the variant, both squashfs deltas ship on
every disc (see [Architecture](#architecture)).

What changed since the r147 baseline:

- **r193 — the apt kernel-upgrade promise actually works now.** r147/r192
  documented "`apt upgrade` pulls new kernels, no reinstall" — true of the
  *design*, but not of what actually happened on a running system: the
  installer staged the kernel by raw-copying files (`install -D` + `tar
  xzf`) straight into `/boot` and `/usr/lib/modules`, completely bypassing
  dpkg. `apt-cache policy linux-image-cixmini-lts` showed `Installed:
  (none)` even on a box actively running that exact kernel, so `apt
  upgrade` had nothing it thought needed upgrading — confirmed live on
  .66. Three-part fix, each verified against real apt transactions on real
  hardware:
  1. The kernel now installs via `apt-get install
     linux-image-cixmini-{lts,edge}` from the signed apt repository, so
     dpkg tracks it like any other package.
  2. The bootloader ESP-write logic (previously locked inside the
     install-time-only `70-bootloader.sh`) is now a shared script
     (`ncz-refind-refresh`) installed to `/usr/local/sbin/`, callable again
     after install — a plain `apt upgrade` needs a way to regenerate the
     rEFInd menu for the new kernel, not just install it.
  3. The `cixmini-boot` package (pulled in as a kernel dependency) has its
     own hook that fires on every kernel install/upgrade — but it wrote
     systemd-boot entries, dead code since this distro switched to rEFInd
     at r118. Redirected it to call the real refresh instead, with an apt
     hook that keeps the redirect in place across future `cixmini-boot`
     upgrades.
  A subsequent adversarial review caught a bug that would have made part 3
  never run at all (a hook-ordering gap in `run-all.sh`), plus two races
  in a combined multi-kernel/multi-package apt transaction — all fixed and
  re-verified before this release.
- **r194 — apt repository migrated to Cloudflare R2; NoMachine removed;
  quieter boot.** A community member on real hardware hit a hard install
  failure — `apt-get update` returned `403 Forbidden` fetching the kernel
  package repository (a required step). Root cause: the private Buildkite
  registry's auth file used a malformed hostname pattern, so the read token
  never actually attached to requests; making the registry public to work
  around that instead tripped a resource-limit wall on the plan tier,
  blocking downloads either way. Fixed by migrating kernel builds + CIX
  proprietary userspace to a public Cloudflare R2 bucket — no client-side
  auth, no plan-tier limits, verified end-to-end on a fresh install. Also
  this release: IPv6 nameserver fallbacks added to the installer's
  install-time DNS config (IPv4-only before); NoMachine removed entirely
  (its first-boot network install was unreliable, confirmed failing on a
  fresh install) with xrdp as the sole graphical remote-access path; and
  three services that failed or were misconfigured on every boot for no
  benefit on this hardware (`cix-audio-switch` — a vendor stub with a
  blank `ExecStart=`, `iscsid`, `apport`) are now masked at install time.
- **r192 — layered-squashfs bug sweep + dual-variant fix + apt-source hardening.**
  A day-long pass validating a fresh install end-to-end turned up and fixed
  several real bugs, none of which were cosmetic:
  - **ISO was ~3 GB bloated.** The squashfs layers were being staged twice —
    once correctly, once redundantly via a generic asset-copy step that had
    no exclusion for `assets/squashfs/`. Fixed; ISO went 7.98 GB → 5.0 GB.
  - **Server variant never actually shipped on the ISO.** `manifests/server.pkgs`
    didn't exist, so `server.squashfs` had never been built; the rEFInd menu
    offered a Magnetar boot option that silently degraded to a base-only
    install. Now built, staged, and boot-tested under KVM.
  - **`vivaldi-stable` stuck half-configured on every fresh install.** Root
    cause: a manifest inline comment corrupted the whole apt transaction,
    silently dropping `librsvg2-bin` and a handful of Vulkan/SPIR-V packages
    along with it — not a missing apt source (the Ubuntu archive was there
    the whole time). Fixed at the parser level so this class of bug can't
    recur; also fixed a stuck `needrestart` kernel-upgrade prompt that could
    hang a squashfs build indefinitely with no tty to answer it.
  - **Offline-mirror rebuilds now incremental**, not a full wipe-and-redownload
    of the ~1500-package closure every time.
  - **Kernel config gap**: the Sky1 NPU reports Zhouyi ISA version 5 (V3), but
    only `CONFIG_ARMCHINA_NPU_ARCH_V3_1` (version 6) was enabled — NPU was
    dark on a subset of installs. Both are now enabled.
  - Assorted smaller fixes: a desktop icon (Zoder) that launched a bare
    terminal instead of pointing at the project page; several install-time
    hooks (SSH, telnet console, NTP/hostname, failsafe recovery console,
    xrdp, the nspawn recovery container, the Magnetar headless
    toggle) that were present in the repo but never actually wired into the
    baked-image hook allowlist, so they silently never ran.
- **r147 — first apt-capable kernel-upgrade release.** `apt upgrade` /
  `ncz-update` pulls new kernels from Buildkite Packages — no reinstall to
  move kernels. QEMU-validated end-to-end.
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

- [`gitlab.com/ncz-os/cix-gen`](https://gitlab.com/ncz-os/cix-gen) — script-based image builder; runs from a working aarch64 system, bypasses the d-i flow. Different use case (in-place rebuild vs fresh install).
- [`gitlab.com/ncz-os/meta-cix`](https://gitlab.com/ncz-os/meta-cix) — Yocto BSP layer providing the kernel recipes (`linux-cix-sky1_6.18.26.bb` LTS, `linux-cix-sky1-next_7.0.12.bb` edge) and Cix userspace recipes this installer consumes. Kernel source itself is fetched straight from the public `kernel.org` stable tree at a pinned commit; every Sky1-specific patch is a file tracked in this layer — no separate kernel-source repo is needed to reproduce a build. See [`docs/KERNEL-BUILD-YOCTO.md`](docs/KERNEL-BUILD-YOCTO.md).


## Current ISO — r195 (NCZ-OS 26.6 — official release)

Kernel-channel refresh: **7.0.12-cix-sky1-next is now the stable channel**
and **7.2.0-rc1-ncz is the new edge channel**; the 6.18 LTS kernel is
retired from the ISO. The 7.2 edge kernel fixes a real VPU boot-hang
(pm_runtime IRQ-before-reset race — the same fix CIX shipped independently
in their v1.0.1 VPU driver), corrects the RTL8127 PCIe ASPM/ClockPM quirk
(the ACPI hardware-revision match was wrong, so the quirk could silently
never fire), removes the in-tree panthor driver from the build entirely
(the out-of-tree Mali DDK stack is the driver of record), and carries the
linlondp 26q2 -Werror fixes. Kernels are built under **Yocto Project 6.0
"Wrynose"** (openembedded-core + bitbake 2.18). base.squashfs shed ~2 GB
of dead weight (test/validation packages that the installer never installed
are no longer baked into the image). The rescue partition's self-configuring
networking (DHCP + static fallback) is verified as a release gate as of this
release. Also carries r194's changes (Cloudflare R2 apt channel, NoMachine
removal, quieter boot journal).

**Upgrade kernels & drivers with apt — no reinstall**
- Kernels + CIX userspace (compiled/mirrored): **Buildkite Packages** `ncz-os/ncz`, served over a CloudFront-backed CDN — `apt upgrade` / `ncz-update` pulls new `linux-image-cixmini-{lts,edge}` and the 31 mirrored CIX proprietary packages. No Codeberg apt source exists for this (see OTA channel section above).
- Kernel source + Yocto recipes: GitLab [`ncz-os/meta-cix`](https://gitlab.com/ncz-os/meta-cix).

**Kernels:** 7.0.12-cix-sky1-next (default, stable) + 7.2.0-rc1-ncz (edge). (6.18 LTS retired from the ISO as of r195; 7.1.2 was experimental/non-working and never shipped.)

Provenance: **7.0.12 stable** is *our* port — the raw v7.0.12 stable tag
plus our MS-R1-specific validation and fixes (SCMI, GPU, VPU, NPU, display,
audio). **7.2.0-rc1-ncz edge** goes further: mainline v7.2-rc1 plus our full
~130-patch forward-port of the CIX Sky1 BSP (tracked as individual patch
files in meta-cix), including fixes that don't exist in any vendor drop yet.

**Install:** unattended d-i (auto-partition, ESP + NCZRESCUE rescue partition), boots rEFInd. Interactive disk + root-filesystem choice — **btrfs** (default) or **ext4**; no ZFS root support yet. Installer runs on the proven 6.18 LTS kernel.

**Recovery:** NCZRESCUE partition with full repair toolset + automatic networking, reachable independent of the main rootfs; installer remote-diagnostics (network-console + telnet/http) on USB boot.

**MS-R1 (cixmini) driver support — 7.0.12 / 7.2:** NVMe/PCIe, USB, Ethernet/Wi-Fi, Audio, NPU (Zhouyi V3 /dev/aipu), GPU (Mali-G720 panthor renderD128, Mesa 26.1.3 panvk+rusticl; compositing off), VPU — all working.

**Reproduce:** kernels from kernel.org stable git + meta-cix patch series under Yocto ([docs/KERNEL-BUILD-YOCTO.md](docs/KERNEL-BUILD-YOCTO.md)); ISO via build/build-iso-di.sh ([docs/NEXT_ISO.md](docs/NEXT_ISO.md)). No separate kernel-source repo needed — meta-cix carries every Sky1-specific patch as a tracked file.


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