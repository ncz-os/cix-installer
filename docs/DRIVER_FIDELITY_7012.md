# CIX 7.0.12 Driver Fidelity — Validated Fixes (cixmini)

Live-validated on the `.66` reference board. The fixes below apply to our
`7.0.12-cix-sky1-next` build. As of NCZ-OS 26.7, this is the **secondary /
emergency fallback** kernel channel ("stable" in the rEFInd menu) — **7.2**
(`linux-cix-sky1-ncz`) is the primary/default channel, and **6.18 LTS** is
the deep-rescue kernel on its own dedicated rescue partition. (Earlier in
the project 6.18 LTS was the shipped default and 7.0.12 was the "edge"/beta
build in a two-kernel A/B scheme — that framing is superseded by the
current three-tier channel model; see the top of the top-level `README.md`.)
There is no `7.0.12-cix-sky1-main` recipe -- that name doesn't exist in
meta-cix; don't look for it. These are the changes required for full driver
bring-up **on the 7.0.12 channel specifically** — the 7.2 primary channel
uses a different GPU driver (`mali_kbase`, not `panthor`) and its own patch
series; see `kernel-source/SOURCE.md` and the README's "7.2 (Mali) GPU
driver notes".

## NPU (ArmChina Zhouyi V3)
- **Kernel config**: `CONFIG_ARMCHINA_NPU_ARCH_V3=y` REQUIRED. Shipped config had only `ARCH_V3_1=y` -> `unidentified hardware version number: 5`, probe fail. With V3=y -> `AIPU detected: zhouyi-v3`, `/dev/aipu` live. Fixed in meta-cix (`config.sky1-next`, commit `053b5ce`) as of 2026-07-04, but the kernel binary/config staged in cix-installer (`assets/kernel/edge/config-7.0.12-cix-sky1-next`, dated 2026-06-17) predates that fix -- the edge kernel needs a rebuild from current meta-cix HEAD before this fix is actually reflected in a shipped ISO. NPU has tested working regardless in the interim (V3_1 alone appears sufficient in practice on the hardware tested so far), but don't assume the staged config matches meta-cix until that rebuild happens.
- **Patch**: `assets/kernel/patches/2014-armchina-npu-cap-iova-region-32bit-bus.patch` caps `iova_region` 6->2. NPU bus is 32-bit (bus_dma_limit=0xc0000000, patch 2009); only ~2GB IOVA fits, so region idx2 failed. Cap removes the failure.
- **Overlay (no-rebuild stopgap)**: `assets/kernel/modules-overlay/7.0.12-cix-sky1-next/armchina_npu.ko` (vermagic 7.0.12-cix-sky1-next, ARCH_V3 + iova=2). post-install drops to `/lib/modules/$KVER/updates/` + depmod.
- **Memory**: NPU uses the IOMMU scatter path, NOT CMA. ~2GB IOVA is a HARD ceiling (32-bit address bus) regardless of RAM/CMA.

## GPU driver A/B follow-up (mali_kbase port, EXPERIMENTAL, not shipping)
An out-of-tree mali_kbase port for this kernel (same driver that ships as
the validated default on the 7.2 channel) lives at
`assets/kernel/mali-70012/` — DKMS-packaged, `AUTOINSTALL="no"`, **not**
wired into any post-install hook. Builds clean and no longer crashes the
board (two real NULL-pointer-deref panics were found via live insmod
testing on cixmini and fixed — see that directory's README + provenance
patch), but probe never completes on this kernel (`-EPROBE_DEFER` forever
on the "perf" SCMI power-domain attach, confirmed non-transient via
`/sys/kernel/debug/devices_deferred`) — no `/dev/mali0`, not GPU-functional.
panthor (below) remains the sole validated GPU driver for this channel;
the mali_kbase port is parked for future root-causing, not a replacement.

## GPU (Mali-G720 / panthor)
- **Firmware**: REQUIRES `/lib/firmware/arm/mali/arch12.8/mali_csffw.bin` (panthor probes arch-versioned path). Staged at `assets/sky1-firmware/arm/mali/arch12.8/`. -> `renderD128` live.
- **panvk Vulkan compute recipe**: mesa from ports.ubuntu (resolute); ICD `panfrost_icd.json`; DISABLE CIX WSI implicit layer (`VK_LOADER_LAYERS_DISABLE=VK_LAYER_window_system_integration`); user in `render` group; `XDG_RUNTIME_DIR` set. Validated: benchncnn ran ~30 models on Mali-G720.
- **GPU compute stack (shipped)**: from-source **Mesa 26.1.3** under `/opt/mesa-26.1.3`, redirected as the system Vulkan (panvk) + OpenCL (rusticl) provider (`post-install/16-mesa-gpu-2613.sh`). Stock 26.0.3 panvk couldn't run GPU compute (`VK_ERROR_OUT_OF_DEVICE_MEMORY`, 16-entry buffer cap) and shipped no GPU OpenCL. 26.1.3: A/B-validated +20.6% prefill / +12.9% decode (llama.cpp Vulkan), rusticl FP16 ~3.6 TFLOPS.
- **Desktop compositing — DISABLED by default (xfwm4 `use_compositing=false`)**: on the `7.0.x` kernel the zink/kopper GL compositor **cannot create an X11 swapchain** (`zink: could not create swapchain`), even with stock panvk; panvk advertises the X11 WSI surface extensions but swapchain creation fails. xfwm4 treats that GL init failure as fatal and exits → session with no window manager. `post-install/20-desktop.sh` ships a system-wide `xfwm4.xml` with compositing off; KMS/GL/Vulkan otherwise work and the GPU stays free for compute. Re-enable once zink+panvk X11 WSI is fixed upstream.

## CMA
- Default 32MB untuned. Use `cma=256M` boot param (VPU headroom). NPU does NOT use CMA. `cma=2G` FAILS (DMA zone is only 2GB).

## Console
- `loglevel=4` suppresses boot messages. Set `loglevel=7` in boot entry for visible boot kernel messages.

## Audio — WORKING
- A sound card **is** registered on the current kernel: `card 0: cix-ipbloq-hda`
  (Realtek **ALC269VC** codec) exposes Analog + Digital **playback and capture**
  devices (`aplay -l` / `arecord -l`). Verified on `.66` (`7.0.12-cix-sky1-next`).
- The earlier "no sound card registered" state was the `-next` bring-up before the
  HDA fix landed. The enabling change is the analog-HDA path plus
  `2017-ALSA-hda-cix-ipbloq-Fix-ACPI-reset-clock-resource-name` (see
  `ENGINEERING-EFFORT.md` §3.2); HDMI/DP audio (`snd_soc_hdmi_codec`) also works.
