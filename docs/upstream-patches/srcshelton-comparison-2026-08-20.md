# Stuart Shelton cix-sources — content-level comparison vs our 7.2 series

**Date:** 2026-08-20
**Comparison method:** For each Stuart patch, the files (`diff --git a/...`) it
touches are intersected with the files our 197 patches touch. No-overlap in
that intersection is the primary signal of a genuine gap; overlaps are then
classified by reading the commit message / first body paragraph and (where
ambiguous) comparing the diff hunks. Filename/number-based matching was
specifically avoided because both series derive from the same vendor base
but have drifted in their internal numbering.

**Series under comparison:**

| Source | Path | Patch count |
|---|---|---|
| Ours | `kernel-source/linux-cix-sky1-ncz/linux-cix-sky1-ncz-7.2/patches-7.2/` | 197 |
| Stuart, generic/cross-version | `sys-kernel/cix-sources/files/` (top-level) | 44 |
| Stuart, 7.2.x-specific | `sys-kernel/cix-sources/files/7.2.x/` | 83 |
| Stuart, total | | **127** |

**Headline numbers:**

- 35 Stuart patches touch **zero files** we patch → primary candidate list
  for "what he has that we don't".
- 90 patches share at least one file path with our series. Of those, ~15 are
  clear real equivalents (driver imports both series have, both touch
  `drivers/acpi/thermal.c`, both drop `hda_cix_ipbloq`, etc.), the rest are
  file-path coincidence on large subsystems (`drivers/gpu/drm/cix/*`,
  `drivers/soc/cix/*`, `drivers/pmdomain/arm/*`).
- 3 patches in the "no file overlap" set actually have a keyword match in our
  patches — flagged below as **`keyword-only`**, not zero-evidence gaps.

> **One thing this comparison cannot distinguish:** Stuart's 7.2.x dir holds
> ~80 patches that are all "audited / hardened / forward-port" re-derivations
> of the same vendor trees we independently carried in (1)-(83). Those have
> very high file overlap with our series by construction — both patches touch
> the same `drivers/soc/cix/cix-acpi-resource-lookup.c`, both touch the same
> `drivers/clk/cix/sky1-clkt.c`, etc. The diff *content* differs
> (Stuart's is an audit, ours is the vendor carry + forward-port). This is
> not a "gap" — it's two independent passes over the same vendor code. See
> §2 below.

---

## 1. Stuart's patches with no real content-level equivalent in ours

These are the actual "what does he have that we don't" list, ordered by
what I read as approximate strategic significance. Confidence is **high** if
the file path is in a subsystem we clearly don't touch at all; **medium** if
there is a related-but-different patch of ours touching a nearby file.

### 1.1 New features and infrastructure

| Stuart patch | Confidence | What it does (one line) | Files / functions |
|---|---|---|---|
| `20070-resctrl-mpam-expose-proportional-bandwidth.patch` | **high** | Adds MPAM memory-bandwidth proportional stride (MBW_PROP) for Sky1 — substantive `fs/resctrl/` + `drivers/resctrl/` core feature, with arm64 MPAM docs | `fs/resctrl/*`, `drivers/resctrl/*`, `Documentation/arch/arm64/mpam.rst` |
| `70150-drm-support-up-to-64-planes.patch` | **high** | Widens core `drm_crtc_state.plane_mask` from `u32` to `u64` so CIX Linlon's >32 planes don't alias | `drivers/gpu/drm/drm_atomic.c`, `include/drm/drm_crtc.h`, `include/drm/drm_plane.h` |
| `0026-btb-typec-rts5453-add-audited-driver.patch` (real name: `0026-usb-typec-rts5453-add-audited-driver.patch`) | n/a — **real match** | adds Realtek RTS5453 Type-C PD driver | (this one is in §2) |
| `72000-media-cix-import-armcb-isp-driver.patch` | n/a — **real match** | imports armcb ISP driver | (this one is in §2) |
| `70990-media-cix-import-and-integrate-mvx-vpu-driver.patch` | n/a — **real match** | imports mvx vpu driver | (this one is in §2) |

### 1.2 Substantive single-file core patches (no equivalent in ours)

| Stuart patch | Confidence | What it does | Files |
|---|---|---|---|
| `30125-acpi-table-upgrade-add-disable-and-exclude-options.patch` | **high** | Adds `acpi_table_upgrade=off` and `acpi_table_upgrade_exclude=` kernel cmdline knobs (debug helpers; useful for bisecting CIX firmware quirks) | `drivers/acpi/tables.c` |
| `40042-platform-acpi-resolve-named-irq-resources.patch` | **high** | Bounded fix for `platform_get_irq_byname()` returning -ENOENT when an ACPI IRQ resource exists but its GSI hasn't been mapped yet (observed CIX runtime failure) | `drivers/base/platform.c` |
| `40046-acpi-demote-cix-sky1-ecam-duplicate-reservations.patch` | **high** | Tightens the ACPI reservation-conflict message to suppress it for the specific CIX Sky1 PNP0C02 ECAM-window duplicate-resource case; uses `acpi_platform_list` (CIXTEK/SKY1EDK2). **Different approach from ours** — see §3.1 | `drivers/acpi/scan.c` |
| `40093-pci-cix-enable-root-port-io-window-assignment.patch` | **high** | PCI core patch: allow Sky1 root ports (vendor 0x17cd, device 0x0100) to allocate downstream bridge I/O windows when the parent bus has a valid I/O aperture. Endpoints with small legacy I/O BARs currently fail assignment | `drivers/pci/probe.c` |
| `30196-power-opp-accept-acpi-only-configurations.patch` | **high** | In `_allocate_opp_table()` treat `-EOPNOTSUPP` from `dev_pm_opp_of_find_icc_paths()` as success on `!IS_ENABLED(CONFIG_OF)` builds | `drivers/opp/core.c` |
| `30195-firmware-arm-scmi-use-rational-perf-frequency-conversion.patch` | **high** | Preserves full rational perf-level frequency scale across OPP round-trip (no integer-Hz truncation in the sustained_freq/sustained_perf ratio). **Note:** our 0183-genpd-cix-dedupe-power-domain-opp-table.patch touches a different function in the same file for a different bug — both should be considered, see §3.2 | `drivers/firmware/arm_scmi/perf.c` |
| `20065-cacheinfo-share-global-firmware-ids-across-levels.patch` | **high** | Adds PPTT/cacheinfo infrastructure so firmware-allocated IDs can be shared across cache levels; needed for correct topology on ACPI systems with sparse PPTT (Sky1 firmware) | `drivers/acpi/pptt.c`, `drivers/base/cacheinfo*`, plus KUnit |
| `20050-topology-has-missing-cpufreq-ref.patch` | **high** | Fixes `topology_set_freq_scale()` warning on early ACPI boot (`capacity_freq_ref=0` when `cppc_cpufreq` does fast switch before init_cpu_capacity_callback runs). Keeps the arch-topology cpufreq policy notifier registered on ACPI and uses policy max_freq to fill the missing reference | `drivers/base/arch_topology.c` |
| `20060-acpi-processor-clarify-ignore-ppc-module-parameter.patch` | **high** | Documents / clarifies the `ignore_ppc` module parameter behaviour in `processor_perflib.c` | `drivers/acpi/processor_perflib.c` |
| `10050-bpf-gate-struct-ops-on-kallsyms.patch` | **high** | Kconfig gate: makes `CONFIG_BPF_STRUCT_OPS` depend on `KALLSYMS`/`KALLSYMS_ALL` because struct_ops providers resolve their CFI stubs through kallsyms (BPF subsystem pre-condition, not Sky1-specific) | multiple Kconfig files |
| `10070-kconfig-separate-expert-and-debug-policy.patch` | **medium** | Decouples `CONFIG_EXPERT` from `CONFIG_DEBUG_KERNEL` (currently they're bound together in `init/Kconfig`); unrelated to Sky1 but a long-standing source of confusing Kconfig errors | `init/Kconfig`, `mm/Kconfig.debug` |
| `10010-arm64-stub-fdt-enable-kexec-file.patch` | **medium** | Companion to a Stuart generic patch (10000-arm64-stub-fdt.patch) that creates a stub FDT on ACPI-only boots; this turns on `kexec_file` for the stub-FDT path so kexec works on ACPI-only systems | `arch/arm64/Kconfig`, `drivers/of/Makefile`, `include/linux/of.h` |
| `10020-lld-timer-of-table-end-warning.patch` | **medium** | Suppresses noisy `ld.lld` warning around the timer-OF table end-of-list sentinel | `drivers/clocksource/timer-probe.c` |
| `90098-pstore-ramoops-parse-firmware-node-properties.patch` | **medium** | Teach `pstore/ramoops` to read its config from a firmware node as well as from the platform device, so it works on ACPI enumerated systems where the conventional lookup misses | `fs/pstore/ram.c` |

### 1.3 Realtek RTL8126 driver suite (8 patches)

Stuart has a self-contained RTL8126 driver block. Ours uses whatever mainline
ships — we don't carry an in-tree copy.

| Stuart patch | What it does |
|---|---|
| `80030-net-realtek-import-r8126-driver.patch` | Imports the Realtek RTL8126 10.018.00 vendor driver as an in-tree driver (~890 KB) |
| `80031-net-realtek-r8126-prefer-performance-core-irqs.patch` | Bias RTL8126 IRQ affinity to higher-capacity cores on ARM64 |
| `80032-net-realtek-r8126-remove-vendor-engineering-interfaces.patch` | Strip raw register, PCI-config, PHY, EEPROM-write, procfs, sysfs, debugfs interfaces |
| `80033-net-realtek-r8126-remove-unused-tail-pointer-reader.patch` | Remove the now-dead tail-pointer reader post 80032 |
| `80035-net-realtek-r8126-demote-routine-reset-message.patch` | Demote the routine-reset message that fires on every normal resume |
| `80000-pci-rtl8126-disable-unreadable-vpd-quietly.patch` | Quietly disable VPD on RTL8126 endpoints whose VPD reads are unusable (Orion O6 quirk) |

> **Decision point for operator:** whether to carry the vendor driver
> in-tree at all. If our media stack already has a working RTL8126 path via
> upstream `r8169`/`r8125` + something, the in-tree import is large surface
> for marginal gain.

### 1.4 Board/quirk specific (Orion O6 / Sky1)

| Stuart patch | Confidence | What it does | Files |
|---|---|---|---|
| `80010-rtw89-disable-hw-rfkill-polling-on-orion-o6.patch` | **high** | Disable rtw89 hardware-RF-kill polling on Orion O6 (likely the same issue behind `bt-fw-rst-gpio` workarounds) | `drivers/net/wireless/realtek/rtw89/core.c` |
| `80020-rtw89-check-acpi-dsm-before-evaluating.patch` | **high** | Guard rtw89 ACPI DSM evaluation behind an explicit DSM-support check | `drivers/net/wireless/realtek/rtw89/acpi.c` |
| `80015-bluetooth-btrtl-return-register-read-error.patch` | **high** | Tiny correctness: `btrtl` should propagate register-read error instead of returning success | `drivers/bluetooth/btrtl.c` |
| `80025-cadence-macb-add-sky1-firmware-matches.patch` | **medium** | Extend `macb_main.c` firmware-compat list to recognise Sky1 MAC IDs | `drivers/net/ethernet/cadence/macb_main.c` |
| `90040-hwmon-cix-add-safe-acpi-fan-control.patch` | **high** | New `drivers/hwmon/cix-fan.c` ACPI-driven hwmon fan driver — if we ever expose board fan telemetry through hwmon this is the path | `drivers/hwmon/cix-fan.c`, `drivers/hwmon/{Kconfig,Makefile}` |
| `90050-arm64-cix-add-radxa-orion-board-profiles.patch` | **medium** | Adds `arch/arm64/Kconfig.platforms` entries and `drivers/platform/arm64/` Radxa-Orion config knobs. We have `0041-arm64-add-model-name-for-Cix-Sky1-Soc.patch` (just the model name); Stuart's adds the full board profile. | `arch/arm64/Kconfig.platforms`, `drivers/platform/arm64/*` |

### 1.5 Logging / cosmetic demotes inside the vendor tree

| Stuart patch | Confidence | What it does | Files |
|---|---|---|---|
| `70120-drm-cix-demote-internal-tbu-noop-logs.patch` | **high** | `dp_connect_iommu()`/`dp_disconnect_iommu()` in `dp_dev.c`: demote `"Connect mmu without internal TBU!"` from `DRM_WARN` to `DRM_DEBUG_DRIVER` (the code path is intentionally a no-op when the block lacks a TBU). Our `0067-drm-cix-replace-linlon-dp-dptx-with-cixtech-2026q2-o.patch` re-derives the whole driver from cixtech 2026q2 — same file ends up in ours, but we did not add this specific demote | `drivers/gpu/drm/cix/linlon-dp/hw/dp_dev.c` |

### 1.6 armcb ISP driver port to 7.2

| Stuart patch | Confidence | What it does | Files |
|---|---|---|---|
| `72010-media-cix-harden-armcb-isp-platform-subdevices.patch` | **high** | Imports and hardens the armcb-isp media stack (97 KB across 20 files: V4L subdevs, DMA, ISP core, sensor/actuator glue) | `drivers/media/platform/cix/armcb-isp/**` |
| `72030-media-cix-port-isp-to-linux-7.2.patch` | **medium** | 7.2 string.h fixup for the imported armcb-isp (`strncpy` → `strscpy`, add `<linux/string.h>`). **Same intent as our `0128-media-cix-add-linux-string.h-includes-7.2-build-fix.patch` but for a different driver:** ours fixes mvx, Stuart's fixes armcb-isp. Both apply cleanly and are independent | `drivers/media/platform/cix/armcb-isp/isp/armcb_v4l2_core.c` |

### 1.7 SOF/backlight/lifetime

| Stuart patch | Confidence | What it does | Files |
|---|---|---|---|
| `0023-sound-sof-clean-up-debugfs-lifetime.patch` | **medium** | SOF publishes devm-managed MMIO through debugfs before firmware boot; the MMIO is freed on probe failure, leaving a stale debugfs pointer. Clean up debugfs lifetime | `sound/soc/sof/core.c`, `sound/soc/sof/debug.c`. **Coincidental keyword match** with our `0018-sound-soc-add-cix-sof-driver.patch` — different fix. |
| `0067-backlight-pwm-add-safe-firmware-node-support.patch` | **medium** | `pwm_bl.c`: add safe firmware-node backing so backlight can probe on ACPI (Sky1 PWM backlight panel) | `drivers/video/backlight/pwm_bl.c` |

> `0018` (our SOF driver) was replaced by `0070-ASoC-HDA-cix-replace-SOF-machine-ipbloq-with-cixtech` and `0073-HDA-drop-vendor-hda_cix_ipbloq` later in our series; Stuart's
> audit re-derives the SOF glue from scratch. Both series have the upstream
> sound/soc/sof/ code path but at different lifecycle stages.

### 1.8 Lists of Stuart patches that ARE real matches but worth noting briefly

These are listed here only to acknowledge them — see §2 for the full match list.

- `0026-usb-typec-rts5453-add-audited-driver.patch` ↔ `0022-typec-add-rts5453-driver.patch` + `0118-usb-typec-restore-rts5453-Sky1-driver.patch` (both have it; our copy is from a different vendor tree).
- `70990-media-cix-import-and-integrate-mvx-vpu-driver.patch` ↔ `0126-media-cix-add-Sky1-video-codec-VPU-driver.patch` + related (both have the mvx driver).
- `72000-media-cix-import-armcb-isp-driver.patch` ↔ no equivalent — we don't carry armcb-isp.

---

## 2. Stuart's patches that DO have a real equivalent in ours

These confirm the methodology finds real matches (and aren't gaps).
Format: `stuart_file.patch` ↔ our most-equivalent patches.

### 2.1 Clean file-path match — same file, same intent

| Stuart patch | Our equivalent | Notes |
|---|---|---|
| `0001-mailbox-cix-add-audited-acpi-support.patch` | `0001-mailbox-add-acpi-support-to-cix-mailbox-driver.patch` | both add ACPI probe path to `drivers/mailbox/cix-mailbox.c` |
| `0002-acpi-cix-resolve-legacy-graph-references.patch` | `0002-acpi-Add-a-property-reference-count-interface.patch` | both augment `drivers/acpi/property.c` for CIX graph resolution |
| `0004-clk-scmi-add-audited-acpi-publication.patch` | `0003-clk-clk-scmi-register-clkdev-for-acpi.patch` | both publish SCMI clocks via firmware-node lookup |
| `0005-clk-cix-add-audited-sky1-support.patch` | `0004-clk-add-cix-clk-driver.patch` (+ 0065 replace) | both add Sky1 clk controllers; ours + replace in 0065 |
| `0006-reset-cix-add-audited-sky1-support.patch` | `0005-reset-add-cix-reset-driver.patch` (+ 0087 restore) | both add Sky1 reset providers |
| `0007-soc-cix-harden-acpi-resource-lookup-driver.patch` | `0006-soc-add-cix-acpi-resource-lookup-driver.patch` (+ 0064, 0066) | same driver; ours is upstream carry + 0064 fix, Stuart's is an audit |
| `0008-pmdomain-add-audited-acpi-scmi-support.patch` | `0077-pmdomain-add-acpi-support-to-cix-soc` + 0078 + 0082 + 0088 | both add SCMI-perf ACPI support; ours is split into several forward-ports |
| `0009-remoteproc-cix-sky1-add-audited-hifi5-support.patch` | `0007-remoteproc-add-cix-dsp-remoteproc-driver.patch` (+ 0066) | both add HiFi5 remoteproc; ours from vendor, Stuart's audited |
| `0012-irqchip-cix-sky1-pdc-add-audited-wake-domain.patch` | `0009-irqchip-add-cix-sky1-pdc-driver.patch` | both add `irq-sky1-pdc.c` |
| `0013-sound-hda-cix-add-audited-sky1-support.patch` | `0010-sound-hda-add-cix-ipbloq-hda-driver.patch` (+ 0073 drop + 0070 replace) | all three series files exist; Stuart's audited, ours vendor carry + drop + replace |
| `0016-dma-arm-dma350-add-audited-cix-support.patch` | `0013-dma-arm-dma350-add-acpi-support-for-cix-soc.patch` | both add ACPI support to arm-dma350 |
| `0017-gpio-cadence-add-audited-cix-sky1-support.patch` | `0014-gpio-add-acpi-support-to-cadence-driver.patch` | both add ACPI support to gpio-cadence |
| `0019-i2c-cadence-add-audited-acpi-support.patch` | `0016-i2c-add-acpi-support-for-cadence-driver.patch` | both add ACPI support to i2c-cadence |
| `0021-sound-soc-cix-sky1-add-audited-sof-support.patch` | `0018-sound-soc-add-cix-sof-driver.patch` (+ 0019 + 0070 + 0073) | both add SOF; ours: vendor + drop-vendor + replace |
| `0024-phy-cix-add-audited-usbdp-combo-phy.patch` | `0021-phy-add-cix-phy-driver.patch` (+ 0068 replace) | both add cix phy |
| `0025-usb-cdns3-add-audited-sky1-platform-support.patch` | `0026-add-cix-vendor-pci-driver.patch` + cdns3 family (0029, 0113, 0115, 0116) | both bring up cdns3 on Sky1 |
| `0027-soc-cix-arbitrate-acpi-usb-models.patch` | `0023-soc-add-cix-acpi-usb-scan-handler.patch` | both add `CIX_ACPI_USB_SCAN` Kconfig + handler; **direct re-derivation** |
| `0044-pwm-sky1-harden-lifecycle-and-state-validation.patch` | `0024-pwm-add-pwm-support-for-CIX-SoC.patch` + 0036 + 0158 | same driver; ours is vendor + 2 fixes |
| `0048-pinctrl-sky1-add-audited-acpi-support.patch` | (we don't carry a pinctrl driver — we use whatever firmware exports) | ours is a real gap |
| `30130-acpi-scope-cix-scmi-sta-quirk.patch` | `0122-acpi-sta_quirk-add-cixh4010-npu-cores.patch` + `0124-acpi-sta_quirk-tighten-hidden-Sky1-SCMI-NPU-child.patch` | both tighten `drivers/acpi/sta_quirk.c` SCMI child matching — see §3.3 |
| `30030-scmi-demote-unsupported-fastchannel-fallback.patch` | `0178-firmware-arm-scmi-quiet-fastchannel-fallback-noise.patch` | same intent; ours also covers `perf.c` |
| `30128-acpi-thermal-retain-downstream-improvements.patch` | (no equivalent — feature) | Stuart adds `_STR` labels for hwmon — see §3.4 |
| `30129-thermal-cix-add-safe-ipa-support.patch` | `0042-add-cix-thermal-ipa-driver.patch` + 0043 + 0051 + 0069 | ours is the full IPA stack from cixtech; Stuart's is the audited safe variant |
| `0060-acpi-thermal-bind-devfreq-cooling-devices-safely.patch` | `0050-ACPI-thermal-bind-devfreq-cooling-devices-via-devfre.patch` | same intent, different helper — see §3.5 |
| `40056-soc-cix-add-safe-bus-performance-domain-driver.patch` | `0052-add-cix_dst-driver.patch` | both add bus-perf devfreq consumer — see §3.6 |
| `70140-drm-cix-fix-gcc15-clang21-w1-findings.patch` | `0081-drm-cix-fix-6.6-7.2-API-drift-in-linlon-dp-dptx.patch` | both fix drm/cix for 7.2 — see §3.7 |
| `70130-drm-cix-retain-safe-display-improvements.patch` | `0067-drm-cix-replace-linlon-dp-dptx-with-cixtech-2026q2-o.patch` | both touch drm/cix for 7.2 |
| `1009-drm-cix-fix-build-warnings.patch` | `0081-drm-cix-fix-6.6-7.2-API-drift-in-linlon-dp-dptx.patch` | both are drm-cix 6.6→7.2 hygiene, different focus |
| `70200-drm-panthor-declare-scmi-perf-softdep.patch` | (no equivalent — one-liner softdep) | real (small) gap; see §3.8 |

### 2.2 Real matches that the file-overlap test caught but require explanation

A handful of Stuart patches overlap with one of our **large** replace patches
(`0066-soc-cix-replace-with-cixtech-2026q2-platform-ACPI-su.patch`,
`0067-drm-cix-replace-linlon-dp-dptx-with-cixtech-2026q2-o.patch`,
`0069-thermal-cix-replace-IPA-drivers-with-cixtech-2026q2.patch`). The file
overlap is genuine — we both modify `drivers/soc/cix/*`,
`drivers/gpu/drm/cix/*`, `drivers/thermal/cix/*` — but the audit relationship
is the reverse of "duplicate":

- **Our 0066/0067/0069** are wholesale re-imports of `cixtech/cix-linux-main`
  2026q2 vendor drops that replace earlier versions we carried.
- **Stuart's 0007/0008/0009/0011/etc.** are re-audits of the same cixtech
  vendor tree against the upstream Linux 7.2 baselines, with whatever
  hardening/cleanups Stuart's `kconfig_update.py` and audit pass decided to
  apply.

So both series share a vendor source but produce divergent tree states. The
right framing is not "we should port Stuart's audit" but "we should compare
both final trees for changes the other kept". This is where the file-overlap
matrix starts to have *signal*: any file touched by Stuart but not by our
replace is a candidate change.

---

## 3. Anything surprising — patches where the approaches genuinely differ

These are the cases where both Stuart and we have clearly identified the
same problem and written **substantially different fixes**. The right
action is to read both carefully before deciding; one may be more correct
than the other, or both may be valid depending on context.

### 3.1 PCI ECAM duplicate-reservation message: `40046` (Stuart) vs `0099` (ours)

**Same underlying problem:** cixmini BIOS 1.0 firmware re-describes the PCI
ECAM windows through `PNP0C02 UID 0`, generating a noisy
`acpi_enforce_resources`-style duplicate-resource message at boot, and the
native `pci-sky1-acpi` driver can hang on early firmware.

**Stuart's fix** (in `drivers/acpi/scan.c`, upstream-friendly):

```c
static const struct acpi_platform_list cix_sky1_platforms[] = {
    {"CIXTEK", "SKY1EDK2", 0, ACPI_SIG_DSDT, all_versions},
    ...
};
```

- Uses upstream infrastructure `acpi_platform_list` for the CIXTEK/SKY1EDK2
  ID match
- Demotes only the duplicate-resource message when the conflict is named
  PCI ECAM; other conflicts retain the generic warning
- No firmware version string consulted

**Our fix** (in `drivers/pci/controller/cadence/pci-sky1-acpi.c`, our driver):

```c
static bool sky1_acpi_detected;
sky1_pcie_native=off  // reverts to standard ACPI PNP0A08/ECAM path
```

- Adds a runtime `sky1_pcie_native=off` cmdline knob that drops our native
  driver and falls back to standard ACPI PCI enumeration
- No ACPI core changes; the duplicate-resource message still fires (just on
  a different enumeration path)

**Assessment:** Stuart's is the upstream-correct fix (no driver-side knob,
ACPI core demotes the message). Ours is the pragmatic "give up and use
standard" workaround. If the boot hang is truly resolved by going to
standard ECAM, then ours is also correct for our production firmware;
Stuart's is the patch to actually upstream. See §1.2 entry for `40046`.

### 3.2 SCMI perf-level frequency math: `30195` (Stuart) vs `0183` (ours)

**Both files:** `drivers/firmware/arm_scmi/perf.c`. Both touch the same
top-level functions but at different call sites.

**Stuart 30195:** fix the frequency-math itself — store sustained_freq in Hz
and convert non-indexing perf levels with the original ratio, so OPP
frequencies round-trip to the levels firmware advertised.

**Our 0183 (genpd-cix-dedupe-power-domain-opp-table):** fix duplicate-OPP
registration when two firmware DVFS levels resolve to the same frequency
(Sky1 GPU perf table advertises 800 MHz twice).

These are different bugs. We should consider both. Our 0183 would lose its
duplicate-OPP skip if Stuart's 30195 were applied first (the duplicate
freqs would be deduped earlier in the OPP math), but the OPP-core log noise
won't disappear because firmware still publishes two levels at one freq.

**Recommendation:** take Stuart's 30195 wholesale + keep our 0183; the OPP
core log path Stuart doesn't touch still fires.

### 3.3 SCMI/NPU `_STA=0` un-hide scope tightening: `30130` (Stuart) vs `0122`+`0124` (ours)

Both modify `drivers/acpi/sta_quirk.c` to scope the `_STA=0` force-enable
quirk more tightly.

**Stuart 30130:** parent HID match tightened to `CIXHA006` (SCMI controller)
only, and only child ACPI HIDs `CIXHA008`/`CIXHA009`. Also self-disables
when firmware already reports nonzero `_STA`.

**Our 0122+0124:** match by parent HID + child ACPI name (`DVFS`/`CLKS`
for SCMI, `CRE0-2` for NPU) + parent.uid == 0. Also handles the case where
the child `_HID` is unevaluated because `_STA=0` masks it.

Both are correct in different ways. Ours uses ACPI *names* (more stable
across firmware), Stuart uses ACPI *HIDs* (more robust against HID
misdescription). Ours handles the unevaluated-HID corner case explicitly;
Stuart's `self-disable on nonzero _STA` is something ours does not have.

**Recommendation:** both should be present; ours' child-name match can fall
back to Stuart's child-HID match. Both real, neither obsoletes the other.

### 3.4 ACPI thermal `_STR` as hwmon labels: `30128` (Stuart, no equivalent)

Stuart adds `_STR` description to `acpitz` hwmon labels — without this,
Linux 7.2+ collapses all ACPI thermal zones into a single hwmon device
`acpitz` with no per-zone label. Ours does not have this; on Sky1 + Linux
7.2, hwmon will show a single `acpitz` device with `temp1_input` only and
no way to distinguish GPU_top/btm/AVE/SOC sensors by name. **Real gap.**

### 3.5 ACPI thermal bind devfreq cooling: `0060` (Stuart) vs `0050` (ours)

Same intent, different fix path:

**Stuart 0060:** uses `devfreq_cooling_get_device()` helper (already
exists in `linux/devfreq_cooling.h`) to walk back from cooling-device to
the underlying `struct device`, then `ACPI_COMPANION()` of that.

**Our 0050:** walks `dfc->devfreq->dev.parent->fwnode` to find the ACPI
companion, and for that moves `struct devfreq_cooling_device` from
`drivers/thermal/devfreq_cooling.c` into `include/linux/devfreq_cooling.h`
to be visible.

Both work. Stuart's is the cleaner upstream path (uses an exposed helper).
Ours was written before we noticed the helper exists. **Recommendation:**
take Stuart's 0060 over ours.

### 3.6 Sky1 bus-performance-domain driver: `40056` (Stuart) vs `0052-add-cix_dst-driver.patch` (ours)

Both register the Sky1 CI-700 / multimedia-fabric SCMI perf domains as
devfreq consumers. Differences:

| | Stuart 40056 | Our 0052 |
|---|---|---|
| Source | Audited, written from spec | Vendor carry + 631 KB blob |
| Validation | Validates nonzero, strictly-increasing freq + SCMI level before publishing | Unknown — vendor passthrough |
| Runtime PM | Holds balanced reference during state transitions | Vendor implementation |
| Polling | Bounded poll during transitions + restoration, never publishes preceding freq as completed | Vendor implementation |
| Default governor | `userspace` (no auto load) | Vendor default |

**Recommendation:** read both. If our 0052 already works (it appears to be
the production driver), the upgrade to Stuart's audited variant is a code
quality improvement, not a feature add. Worth the diff if `dst` driver is
to be upstreamed.

### 3.7 DRM/CIX 7.2 hygiene: `70140` + `70135` (Stuart) vs `0081` (ours)

Stuart's `70140` is a focused GCC15/Clang21 W=1 + `drm_atomic_state` →
`drm_atomic_commit` rename patch, plus kernel-doc fixups. Ours `0081` is
the broad 6.6→7.2 API drift patch (same rename, plus MST, fbdev, panel,
format-info, etc.).

Stuart's `70135` removes unsafe engineering interfaces wholesale (the
fixed-MMIO `cix_display.c`, mutable sysfs production controls, presilicon
HDCP test interface). Ours doesn't do this audit; `0186` only strips
pre-silicon EMU/FPGA dead code from our `pci-sky1-cix` driver and a few
vendored PHY paths.

Stuart's combined approach (single-purpose API rename + wholesale
engineering-interface strip) is cleaner than ours (broad API drift + small
narrow dead-code strips). **Worth considering for any upstream-submission
branch.**

### 3.8 Panthor SCMI softdep: `70200` (Stuart, no equivalent)

```c
#if IS_ENABLED(CONFIG_ARCH_CIX) && IS_MODULE(CONFIG_ARM_SCMI_PERF_DOMAIN)
MODULE_SOFTDEP("pre: scmi_perf_domain");
#endif
```

We rely on the module-load ordering to come out right naturally. On
Orion O6 with `panthor` built as a module and `scmi_perf_domain` as a
module, if the load order is reversed, panthor probes before SCMI perf
domain is up. This is a real, small, low-risk patch we should take.

### 3.9 ECTZ zero-temperature filter: `30127` (Stuart, no equivalent)

A board-scoped filter for the Orion O6 ECTZ sensor's invalid zero-temp
samples — adds retry+last-good-temp tracking specifically for that sensor.
Stuart explicitly notes it's overlay-created, not generic. We don't have
this; if the ECTZ sensor on our boards reads 0 K at boot, this would help.

---

## Appendix A — Patches in this comparison

### A.1 No file overlap in ours (35) — full list

```
0023-sound-sof-clean-up-debugfs-lifetime.patch
0067-backlight-pwm-add-safe-firmware-node-support.patch
10010-arm64-stub-fdt-enable-kexec-file.patch
10020-lld-timer-of-table-end-warning.patch
10050-bpf-gate-struct-ops-on-kallsyms.patch
10070-kconfig-separate-expert-and-debug-policy.patch
20050-topology-has-missing-cpufreq-ref.patch
20060-acpi-processor-clarify-ignore-ppc-module-parameter.patch
20065-cacheinfo-share-global-firmware-ids-across-levels.patch
20070-resctrl-mpam-expose-proportional-bandwidth.patch
30125-acpi-table-upgrade-add-disable-and-exclude-options.patch
30195-firmware-arm-scmi-use-rational-perf-frequency-conversion.patch
30196-power-opp-accept-acpi-only-configurations.patch
40042-platform-acpi-resolve-named-irq-resources.patch
40046-acpi-demote-cix-sky1-ecam-duplicate-reservations.patch
40093-pci-cix-enable-root-port-io-window-assignment.patch
50030-net-bridge-warn-for-missing-netfilter-on-first-device.patch
50130-spi-cadence-add-audited-cix-acpi-support.patch
70120-drm-cix-demote-internal-tbu-noop-logs.patch
70150-drm-support-up-to-64-planes.patch
72010-media-cix-harden-armcb-isp-platform-subdevices.patch
72030-media-cix-port-isp-to-linux-7.2.patch
80000-pci-rtl8126-disable-unreadable-vpd-quietly.patch
80010-rtw89-disable-hw-rfkill-polling-on-orion-o6.patch
80015-bluetooth-btrtl-return-register-read-error.patch
80020-rtw89-check-acpi-dsm-before-evaluating.patch
80025-cadence-macb-add-sky1-firmware-matches.patch
80030-net-realtek-import-r8126-driver.patch
80031-net-realtek-r8126-prefer-performance-core-irqs.patch
80032-net-realtek-r8126-remove-vendor-engineering-interfaces.patch
80033-net-realtek-r8126-remove-unused-tail-pointer-reader.patch
80035-net-realtek-r8126-demote-routine-reset-message.patch
90040-hwmon-cix-add-safe-acpi-fan-control.patch
90050-arm64-cix-add-radxa-orion-board-profiles.patch
90098-pstore-ramoops-parse-firmware-node-properties.patch
```

### A.2 Of the 35, "feature" vs "fix" split

- **Real new features / new drivers** (worth deciding whether to take):
  `20070` (MPAM), `70150` (64 planes), `0026` (rts5453 — actually matched),
  `72000` (armcb-isp), `70990` (mvx — actually matched),
  `90040` (hwmon fan), `90050` (Radxa board profile), `80030-80035`
  (RTL8126 in-tree).
- **Generic infrastructure additions** (most useful as upstream
  contributions): `30125`, `40042`, `40093`, `30196`, `30195`, `20065`,
  `20050`, `20060`, `10050`, `10070`, `10010`, `10020`, `90098`.
- **Board-specific fixes / quirks**: `80010`, `80020`, `80015`, `80025`,
  `30127` (ECTZ), `90040` (fan), `90050` (Orion profile).
- **Cosmetic demotes inside vendor code**: `70120`.
- **ISP-to-7.2 build fix**: `72030`.
- **SOF/backlight infrastructure**: `0023`, `0067`.

### A.3 What I deliberately did NOT deep-dive

- The 83-patch 7.2.x dir is largely a per-driver audit pass that re-derives
  the same vendor trees we carry. The file overlap is by construction; the
  diff content differs in hardening level, not in intent. Listing these
  case-by-case in this report would just repeat §2.1.
- Stuart's 71600/71630/71520/etc. armchina-npu block is a single
  in-tree drop. We have `0136-armchina-npu-drop-irqf-oneshot.patch` and a
  vendor carry in `0052-add-cix_dst-driver.patch`. Same driver, different
  scale of work. Not useful to deep-dive without the full diff body.
- The 80000-80035 Realtek block has 6 patches but is one conceptual unit
  (vendor driver import + hardening). Whether to take it at all is the
  only meaningful decision; the individual patches are mechanical.

---

## Sources

- Our patch series: `~/work/cix-installer/kernel-source/linux-cix-sky1-ncz/linux-cix-sky1-ncz-7.2/patches-7.2/` (197 files).
- Stuart's generic/cross-version:
  <https://github.com/srcshelton/gentoo-ebuilds/tree/master/sys-kernel/cix-sources/files> (44 patches).
- Stuart's 7.2.x-specific:
  <https://github.com/srcshelton/gentoo-ebuilds/tree/master/sys-kernel/cix-sources/files/7.2.x> (83 patches).
- GitHub `contents` API used to enumerate; `raw.githubusercontent.com` used
  to fetch patch content.