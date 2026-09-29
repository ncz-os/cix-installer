# NCZ-OS 26.7 "Maximilian"
## CIX Sky1 (CP8180) Edge AI Appliance

> **Note:** this file is a short orientation summary of the `assets/` staging
> tree; it is not currently copied onto the ISO or the installed system by
> any build/post-install script (checked — no `assets/README.md` reference
> in `build/` or `post-install/`). For the authoritative, actively-maintained
> description of NCZ-OS — hardware support matrix, driver stack, kernel
> channels, desktop, AI/ML stack, and release status — see the top-level
> [`README.md`](../README.md). This file previously contained content that
> had drifted badly out of sync with reality (a fictional "MNEMOS v6.0 /
> PostgreSQL+pgvector" description, wrong CPU core pinning, and an XFCE/
> single-kernel framing); it has been corrected below to match the current
> architecture, but treat the top-level README as the source of truth.

Welcome to **NCZ-OS 26.7**, a specialized Linux distribution built to unlock
the CIX Sky1 / CP8180 architecture (used in the Minisforum MS-R1 and the
Radxa Orion O6 / O6N) as a turnkey AI + orchestration edge platform.

### What is included?

This ISO is a universal boot medium. At boot you choose:
* **Reinhardt (Desktop):** **Singularity Desktop** — a native-Wayland,
  Mali-GPU-accelerated desktop (labwc/wlroots). X11/XFCE has been fully
  removed, not kept as a fallback.
* **Magnetar (Server):** a headless, container-optimized edge server.

### Kernel channels

Three channels ship: **7.2** (primary/default — `mali_kbase` GPU driver),
**7.0.12-cix-sky1-next** (secondary/emergency fallback — in-tree `panthor`
GPU driver), and **6.18.26-cix-sky1-lts** (deep-rescue, on its own dedicated
rescue partition). See the top-level README's kernel-tiering callout.

### Hardware support

* **NPU (ArmChina Zhouyi V3):** in-tree `armchina_npu` driver + `cix-noe-umd
  2.0.2` userspace. Runs prebuilt `.cix` graphs (vision, embeddings) — see
  [`docs/MNEMOS-NPU-EMBEDDINGS.md`](../docs/MNEMOS-NPU-EMBEDDINGS.md).
* **GPU (Mali-G720 MC10):** on the primary 7.2 channel, the CIX `mali_kbase`
  blob DDK provides hardware GLES/EGL/OpenCL via `libmali` (no Vulkan yet).
  On the 7.0.12 fallback channel, the in-tree `panthor` driver + Mesa
  panvk (Vulkan)/rusticl (OpenCL) is used instead.
* **CPU (12-core Armv9, big.LITTLE):** 8× Cortex-A720 "big" cores + 4×
  Cortex-A520 "little" cores (logical CPUs 2-5 on the reference board — see
  [`docs/AI-ML-STACK.md`](../docs/AI-ML-STACK.md) §6.4 for the exact mapping
  and the always-on-agent core-affinity policy).
* **Wireless & audio:** MediaTek MT7921/MT7922 Wi-Fi firmware, ALSA/HDA
  audio (analog + HDMI/DP) — work out of the box.

### AI stack

MNEMOS is the agentic memory substrate; on-device embeddings run
automatically on the NPU via `embedkit.Engine.auto()` — see
[`docs/MNEMOS-NPU-EMBEDDINGS.md`](../docs/MNEMOS-NPU-EMBEDDINGS.md) for the
real architecture (there is no local PostgreSQL/pgvector deployment on the
appliance itself). zeroclaw and other agents are opt-in, installed via the
`ncz` CLI — nothing agentic is active by default.

### Post-install: deploying agents and MNEMOS

To keep the base OS footprint light, agent frameworks are not auto-installed
from the ISO. Once booted and online:

**Desktop:** use the `ncz agent install <name>` flow (see the top-level
README's "Two distinct layers" section) or the desktop launcher, where
present.

**Command line (either variant):**
```bash
ncz agent install zeroclaw   # or: openclaw, hermes, portainer
ncz install mnemos           # MNEMOS memory substrate
ncz install nemoclaw         # NVIDIA NemoClaw
```

---
*Built for the NCZ Fleet (2026).*
