# NCZ kernel patch delta (CIX Sky1)

These are the **NCZ-authored** patches applied on top of CIX's official
mainline patch set (76 patches, `git am --3way`, published 2026-06-17 for
v7.0 + v6.18 LTS). They cover hardware bring-up that the official set does
not yet handle on the Minisforum **MS-R1** / Orion **O6** boards. Numbering
follows the `2xxx` (NCZ) band of our kernel build tree.

| Patch | Subsystem | What it fixes |
|---|---|---|
| `2009-armchina-npu-msr1-smmu-32bit-dma-constraint.patch` | NPU / IOMMU | MS-R1 NPU address bus is 32-bit. Without it the IOMMU hands out IOVAs at `0x700000000` (35-bit) which the NPU truncates, causing SMMU faults on every DMA. Forces the 32-bit `bus_dma_limit`. |
| `2014-armchina-npu-cap-iova-region-32bit-bus.patch` | NPU / IOMMU | Caps `iova_region` 6 to 2. With the 32-bit bus (2009) only ~2GB of IOVA fits, so region idx2 (`dma_alloc_attrs`) failed and spammed the boot log. Depends on 2009. |
| `2017-ALSA-hda-cix-ipbloq-Fix-ACPI-reset-clock-resource-na.patch` | Audio (HDA) | Under ACPI boot the mainline cix-ipbloq HDA controller never bound (`-ENOENT` on the unnamed reset/clk). Requests the named `hda` reset + `sysclk`/`clk48m` clocks so the analog card (ALC269VC) registers. HDMI/DP audio already worked. |

Not a patch, but required alongside these: kernel config
`CONFIG_ARMCHINA_NPU_ARCH_V3=y` (the shipped config only set `ARCH_V3_1`,
giving `unidentified hardware version number: 5` and a probe failure).

See `docs/DRIVER_FIDELITY_7012.md` and `docs/ENGINEERING-EFFORT.md` for the
full bring-up history.
