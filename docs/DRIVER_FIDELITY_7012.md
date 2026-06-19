# CIX 7.0.12 Driver Fidelity — Validated Fixes (cixmini)

Live-validated on .66 (7.0.12-cix-sky1-next). These are the changes required for full driver bring-up.

## NPU (ArmChina Zhouyi V3)
- **Kernel config**: `CONFIG_ARMCHINA_NPU_ARCH_V3=y` REQUIRED. Shipped config had only `ARCH_V3_1=y` -> `unidentified hardware version number: 5`, probe fail. With V3=y -> `AIPU detected: zhouyi-v3`, `/dev/aipu` live.
- **Patch**: `assets/kernel/patches/2014-armchina-npu-cap-iova-region-32bit-bus.patch` caps `iova_region` 6->2. NPU bus is 32-bit (bus_dma_limit=0xc0000000, patch 2009); only ~2GB IOVA fits, so region idx2 failed. Cap removes the failure.
- **Overlay (no-rebuild stopgap)**: `assets/kernel/modules-overlay/7.0.12-cix-sky1-next/armchina_npu.ko` (vermagic 7.0.12-cix-sky1-next, ARCH_V3 + iova=2). post-install drops to `/lib/modules/$KVER/updates/` + depmod.
- **Memory**: NPU uses the IOMMU scatter path, NOT CMA. ~2GB IOVA is a HARD ceiling (32-bit address bus) regardless of RAM/CMA.

## GPU (Mali-G720 / panthor)
- **Firmware**: REQUIRES `/lib/firmware/arm/mali/arch12.8/mali_csffw.bin` (panthor probes arch-versioned path). Staged at `assets/sky1-firmware/arm/mali/arch12.8/`. -> `renderD128` live.
- **panvk Vulkan compute recipe**: mesa from ports.ubuntu (resolute); ICD `panfrost_icd.json`; DISABLE CIX WSI implicit layer (`VK_LOADER_LAYERS_DISABLE=VK_LAYER_window_system_integration`); user in `render` group; `XDG_RUNTIME_DIR` set. Validated: benchncnn ran ~30 models on Mali-G720.

## CMA
- Default 32MB untuned. Use `cma=256M` boot param (VPU headroom). NPU does NOT use CMA. `cma=2G` FAILS (DMA zone is only 2GB).

## Console
- `loglevel=4` suppresses boot messages. Set `loglevel=7` in boot entry for visible boot kernel messages.

## Audio — BROKEN (pending)
- `no sound card registered`. patch 2013 (DPTX audio) present but ASoC machine driver not binding. Under investigation (see DRIVER_FIRMWARE_INVENTORY.md).
