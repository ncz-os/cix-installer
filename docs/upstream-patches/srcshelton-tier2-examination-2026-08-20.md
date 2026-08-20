# Stuart Shelton CIX Sky1 Tier 2 patch examination

Date: 2026-08-20

Scope: read-only examination of the six Tier 2 Stuart Shelton patches named by
the operator. I fetched and read the real patch bodies from
`srcshelton/gentoo-ebuilds`, read the prior comparison report, inspected our
patch series, and dry-ran the six patches against a disposable Linux 7.2 source
tree in `/tmp`.

Applicability method: I downloaded pristine Linux 7.2 into `/tmp/linux-7.2`,
copied it to `/tmp/linux-7.2-cix-ours-4158652`, and applied our patch stack
there until the first unrelated mechanical failure:
`0136-media-cix-vpu-deassert-rcsu-reset.patch` failed against
`drivers/media/platform/cix/dev/mvx_dev.c`. None of our patches, including the
failed/later ones, touch the six Tier 2 target paths except an unrelated
`drivers/hwmon/scmi-hwmon.c` change, so the target-file state is effectively
clean 7.2 plus our non-overlapping additions. Each of the six Stuart patches
passes `git apply --check --whitespace=nowarn` on both pristine Linux 7.2 and
the disposable partially-applied tree. No builds were run.

## Summary recommendation

| Patch | Mechanical apply | Recommendation |
|---|---:|---|
| `20065-cacheinfo-share-global-firmware-ids-across-levels.patch` | clean | Port, but treat as generic cacheinfo/PPTT behavior and keep KUnit coverage |
| `20070-resctrl-mpam-expose-proportional-bandwidth.patch` | clean | Needs more design thought before porting |
| `90040-hwmon-cix-add-safe-acpi-fan-control.patch` | clean | Port with minor integration review |
| `90050-arm64-cix-add-radxa-orion-board-profiles.patch` | clean | Do not port as-is; either skip or rewrite to our config policy |
| `40046-acpi-demote-cix-sky1-ecam-duplicate-reservations.patch` | clean | Port as a logging/resource-reservation quirk, but do not replace `sky1_pcie_native=off` with it |
| `40093-pci-cix-enable-root-port-io-window-assignment.patch` | clean | Port, preferably after targeted review of Sky1 root-port I/O-window programming |

## 1. `20065-cacheinfo-share-global-firmware-ids-across-levels.patch`

Patch size from `git apply --numstat`: 163 insertions, 33 deletions across
`drivers/acpi/pptt.c`, `drivers/base/cacheinfo.c`,
`drivers/base/cacheinfo_internal.h`, `drivers/base/test/*`, and
`include/linux/cacheinfo.h`.

What it changes:

- In `drivers/acpi/pptt.c:update_cache_properties()`, PPTT v3 cache IDs are no
  longer marked only with `CACHE_ID`; they are marked with
  `CACHE_ID | CACHE_ID_GLOBAL`.
- In `drivers/acpi/pptt.c:find_acpi_cache_level_from_id()`, the function no
  longer returns on the first matching cache ID. It scans all CPUs and all
  cache levels, returning the highest level where the ID appears. This makes a
  heterogeneous topology deterministic when the same physical cache is reported
  as different relative levels from different CPUs.
- In `drivers/base/cacheinfo.c`, the private
  `cache_leaves_are_shared()` helper becomes exported-to-local-test
  `cacheinfo_cache_leaves_are_shared()` via a new
  `drivers/base/cacheinfo_internal.h`.
- Cache sharing comparison now first rejects type mismatches. If both leaves
  have `CACHE_ID | CACHE_ID_GLOBAL`, matching IDs identify the same physical
  cache even when `level` differs. If IDs are not explicitly global, the old
  same-level requirement remains.
- The repeated same-level/type prefiltering in
  `cache_shared_cpu_map_setup()` and `cache_shared_cpu_map_remove()` moves into
  the shared helper.
- Adds KUnit tests for global IDs crossing levels, level-local IDs not crossing
  levels, mismatched IDs, mismatched cache types, only-one-global cases, and
  `CACHE_ID_GLOBAL` without `CACHE_ID`.

Risk if ported:

This is shared kernel topology code, not CIX-only code. Any ACPI/PPTT platform
with PPTT v3 cache IDs will now have those IDs treated as globally unique
across levels. That is probably the intended ACPI interpretation for firmware
allocated IDs, but if another firmware reused PPTT cache IDs per level, this
could over-merge shared CPU maps. The KUnit tests reduce risk for the helper,
but they do not validate real firmware tables.

The change is not obviously risky for locking or ordering: it does not add new
state or new locks, and it preserves the same per-CPU cacheinfo iteration. The
semantic change is the risk.

Applicability:

Applies cleanly. Our patch series does not touch these files. No adaptation is
needed mechanically.

Recommendation:

Port. This is a small, coherent infrastructure fix for the exact kind of sparse
or heterogeneous PPTT topology Sky1 firmware appears to expose. Keep the KUnit
test file in the port, and mark the patch as generic ACPI/cacheinfo behavior,
not a CIX-only quirk.

## 2. `20070-resctrl-mpam-expose-proportional-bandwidth.patch`

Patch size from `git apply --numstat`: 290 insertions, 45 deletions across
Arm MPAM docs, resctrl docs, x86 resctrl stubs, MPAM core, MPAM KUnit tests,
`fs/resctrl/*`, and `include/linux/resctrl.h`.

What it changes:

- Documents a new resctrl mount option, `mbw_prop`, and a new schema,
  `MB_PROP`, for Arm MPAM memory-bandwidth proportional stride.
- Adds `RDT_RESOURCE_MBW_PROP` to `enum resctrl_res_level`.
- Extends `struct resctrl_membw` with `reset_val`, and changes
  `resctrl_get_default_ctrl()` for range schemas to return `reset_val` instead
  of always returning `max_bw`. Existing x86 MBA setup now initializes
  `reset_val = max_bw`; MPAM `MB_PROP` initializes `reset_val = 0`.
- Adds architecture hooks:
  `resctrl_arch_control_enabled()`,
  `resctrl_arch_get_mbw_prop_enabled()`, and
  `resctrl_arch_set_mbw_prop_enabled()`. x86 implements these as unsupported
  stubs for `mbw_prop`.
- In `drivers/resctrl/mpam_devices.c`, programs `MPAMCFG_MBW_PROP_EN` and
  `MPAMCFG_MBW_PROP_STRIDEM1` from a new `mpam_config.mbw_prop` field instead
  of always writing zero to MBW_PROP when the feature exists.
- Adds `mpam_class.mbw_prop_enabled`, resets all PARTIDs to stride zero when
  enabling, and resets the class when disabling.
- Generalizes MPAM bandwidth-control selection from `mpam_resctrl_pick_mba()`
  to `mpam_resctrl_pick_mbw(feature, rid)`, selecting classes for both
  `MB`/`MBW_MAX` and `MB_PROP`.
- Adds `MB_PROP` as a range schema named `"MB_PROP"` with min 0, max
  `BIT(bwa_wd) - 1`, granularity 1, and reset value 0.
- Updates `resctrl_arch_get_config()` and `resctrl_arch_update_one()` to read
  and write `mpam_feat_mbw_prop`. Non-zero writes emit a `pr_warn_once()` about
  limited observed benefit in published Sky1 tests.
- In `fs/resctrl`, makes several MBA/SMBA special cases generic over
  `RESCTRL_SCHEMA_RANGE`, adds `info/*/max_bandwidth`, parses the new
  `mbw_prop` mount option, excludes disabled architecture controls from
  schemata creation, disables MBW_PROP on unmount/disable, and shows
  `,mbw_prop` in mount options when enabled.
- Adds MPAM KUnit tests for MBW_PROP register encoding, zero-value update, and
  resctrl control initialization.

Risk if ported:

This is the broadest Tier 2 patch. It changes common `fs/resctrl` behavior and
public resctrl data structures, and it touches x86 resctrl code even though x86
does not support the new feature. The `reset_val` conversion is especially
important: it is a generic behavior change for all range schemas, not just
MPAM. Stuart handles x86 MBA by setting `reset_val = max_bw`, but every future
or downstream range resource must now remember to initialize it correctly.

The mount-option enable/disable path also changes ordering: `rdt_enable_ctx()`
enables MBW_PROP after CDP and MBA Mbps handling, and on failure only unwinds
MBA Mbps/CDP state. That looks reasonable, but it is core resctrl lifecycle
code and should be reviewed like a subsystem feature, not a board quirk.

Applicability:

Applies cleanly. Our patch series does not touch these files.

Recommendation:

Needs more design thought before porting. It is probably useful if we intend to
carry a serious MPAM/resctrl stack, but it is a new ABI surface
(`mount -o mbw_prop`, `MB_PROP`, `max_bandwidth`) and a generic resctrl
behavior change. I would not roll this into the installer kernel as a routine
Sky1 enablement patch without separate subsystem-level review and a decision
that we actually want to expose this ABI.


> **OPERATOR DECISION (2026-08-20): DO NOT PORT NOW.** Verified live on O6N
> (192.168.207.3): `/sys/firmware/acpi/tables/` has NO `MPAM` entry
> (full list: APIC, CSRT, DBG2, DSDT, FACP, FPDT, GTDT, IORT, MCFG, PCCT,
> PPTT, SDEI, SSDT1, SSDT2) -- Sky1 firmware on this board does not publish
> MPAM MSC topology at all, so resctrl/MPAM cannot function here regardless
> of the code-risk assessment above. No `mpam` dmesg lines, no `mpam*`
> cmdline params either.
>
> The VPU-4K-decode-bandwidth-contention justification was raised and
> examined: 4K30 decode bandwidth (~1-2 GB/s) is trivial against Sky1 DDR
> capacity, and the failure mode MPAM would fix (VPU memory transactions
> starved by concurrent CPU/GPU traffic) requires the VPU's own DMA master to
> be MPAM-taggable at the interconnect (a device-side MSC + PARTID
> assignment, NOT the `fs/resctrl` mount-option surface this patch adds) --
> unverified whether Sky1's MPAM topology (on boards where it exists at all)
> even covers the VPU path. Current dev boards (64GB, 48GB) show no memory
> pressure signal to investigate further.
>
> Revisit when the incoming 16GB Orange Pi board arrives: capacity (16GB) is
> a proxy signal for "cheaper tier, possibly narrower/slower DDR interface"
> but does not by itself imply bandwidth contention -- capacity pressure
> (allocation/reclaim) and bandwidth pressure (what MPAM addresses) are
> different mechanisms. Check that board's ACPI tables for an MPAM entry and
> its actual DDR interface spec before reconsidering.

> **ADDENDUM (2026-08-20, from Stuart Shelton directly): real justification is
> cache isolation, not VPU bandwidth -- the original bandwidth theory above is
> superseded.** Stuart's own words: "It's workload-dependent, but does show
> real-world (rather than just theoretical) gains which are quite impressive,
> in situations where all cores are under load and any housekeeping tasks on
> the A520 cores shouldn't cause unnecessary cache-evictions on the A720
> cores. I have cgroups defined to enforce housekeeping vs. workload so it's
> great for me, but I've not benchmarked it for stock situations (especially
> where the firmware performance data misleads the scheduler about the core
> capabilities)."
>
> So the mechanism is: Sky1 is A720 (perf) + A520 (efficiency) big.LITTLE.
> Under load, housekeeping work scheduled onto A520 cores can evict A720
> workload cache lines it shouldn't touch. MPAM lets cgroups partition
> cache/bandwidth so housekeeping can't do that -- a real, observed win in
> HIS deployment, which uses explicit cgroup housekeeping/workload splits we
> do not currently run. He explicitly has NOT benchmarked the stock
> (no-custom-cgroups) case, and separately flags that Sky1 firmware
> performance data can mislead the scheduler about core capabilities --
> a known firmware quirk worth checking independent of MPAM.
>
> **This does not change the DO-NOT-PORT-NOW verdict.** The blocker is still
> hardware: O6N publishes no `MPAM` ACPI table, so resctrl/MPAM cannot
> function here regardless of which justification is correct. What it DOES
> change: the reason to revisit is no longer "wait for a memory-constrained
> board," it's "find out whether Stuart's board/firmware exposes an MPAM
> table ours doesn't, and whether we'd need explicit housekeeping/workload
> cgroups (which we don't currently define) to see any benefit at all."
> Follow-up worth asking Stuart: which board/firmware revision he's running,
> and whether `/sys/firmware/acpi/tables/` on his system actually has an
> `MPAM` entry -- if it doesn't either, the gain he's measuring may be
> coming from a different mechanism than the resctrl MSC/PARTID path this
> patch adds, and that needs to be understood before porting.

If ported, port it as a feature branch item, keep the tests, and review at
least:

- Whether `RESCTRL_SCHEMA_RANGE` is the right generic discriminator for all
  places changed from MBA/SMBA-specific checks.
- Whether `reset_val` is initialized for every range resource we can build.
- Whether `mbw_prop` must be mutually exclusive with all CDP modes, including
  L2 CDP, not just the global MPAM `cdp_enabled` condition.

## 3. `90040-hwmon-cix-add-safe-acpi-fan-control.patch`

Patch size from `git apply --numstat`: 423 insertions across
`drivers/hwmon/Kconfig`, `drivers/hwmon/Makefile`, and new
`drivers/hwmon/cix-fan.c`.

What it changes:

- Adds `CONFIG_SENSORS_CIX_FAN`, a tristate ACPI hwmon driver.
- Registers `drivers/hwmon/cix-fan.o`.
- Adds a platform driver matching ACPI HID `CIXHA024`.
- On probe, requires ACPI methods `GFPW`, `SFPW`, `SFAT`, and `SFPF`.
- Detects firmware PWM format by inspecting private EC method
  `\_SB.EC0.GFPW` only for its argument count:
  no-argument Radxa firmware uses a 0..128 scale with `0xff` failure sentinel;
  generic two-argument firmware uses 0..100 with `0xffffffff` failure sentinel.
  Actual control calls go through the public `CIXHA024` wrapper methods.
- Exposes only hwmon PWM attributes:
  `pwm1`/`hwmon_pwm_input` and `pwm1_enable`/`hwmon_pwm_enable`.
- Maps `pwm_enable` to standard hwmon semantics:
  0 full speed/uncontrolled via `SFPF`, 1 manual via `SFPW`, 2 automatic via
  `SFAT`.
- Keeps `pwm_enable` unknown until a successful write because firmware has no
  reliable mode query; reading it before then returns `-ENODATA`.
- Serializes firmware calls and cached mode with a mutex.
- Validates ACPI return object type, failure sentinels, duty range, and
  optional integer status returns.

Risk if ported:

Runtime scope is narrow: it only probes ACPI devices with HID `CIXHA024` and
only exposes PWM control through hwmon. It does not touch generic fan or ACPI
thermal behavior. The main risks are board/firmware contract risks:

- The hard-coded `\_SB.EC0.GFPW` introspection path assumes the EC method name
  and namespace are stable on all target firmware.
- `pwm_enable=1` forces `SFPW(100, 0, 0)` immediately, which may change the
  fan to manual full duty before userspace writes a preferred PWM value.
- There is no actual mode readback; the driver reports only the last
  successfully written mode.

Applicability:

Applies cleanly. Our patch series currently has CIX EC/fan platform support in
`drivers/soc/cix/acpi/cix-fan-mode.c` from patch `0066`, but it does not add
this hwmon driver path. There is a config-policy hint in our
`thin_config_stage*.py` that already references `CONFIG_SENSORS_CIX_FAN`, so
this appears anticipated.

Recommendation:

Port with minor integration review. The driver is well scoped and much safer
than exposing vendor EC controls directly. Before enabling it by default, check
whether the existing `drivers/soc/cix/acpi/cix-fan-mode.c` can race or fight
with this hwmon driver over the same firmware methods. If both can write fan
mode, either make the relationship explicit or enable only one default control
surface.

## 4. `90050-arm64-cix-add-radxa-orion-board-profiles.patch`

Patch size from `git apply --numstat`: 190 insertions across
`arch/arm64/Kconfig.platforms`, `drivers/platform/arm64/Kconfig`, and new
`drivers/platform/arm64/Kconfig.radxa`.

What it changes:

- Adds an `ARCH_CIX`-scoped `Radxa Orion board profiles` menu with board
  selectors `CIX_RADXA_ORION_O6` and `CIX_RADXA_ORION_O6N`.
- Adds a firmware-interface choice between `CIX_RADXA_ORION_ACPI` and
  `CIX_RADXA_ORION_DT`, defaulting to ACPI when ACPI is available and DT when
  OF is available.
- Sources a new `drivers/platform/arm64/Kconfig.radxa`.
- Adds grouped preset buckets:
  `CIX_RADXA_ESSENTIAL`,
  `CIX_RADXA_OPTIONAL_IO`,
  `CIX_RADXA_OPTIONAL_PLATFORM`,
  `CIX_RADXA_OPTIONAL_DISPLAY`,
  `CIX_RADXA_OPTIONAL_ACCELERATORS`, and
  `CIX_RADXA_OPTIONAL_AUDIO`.
- These buckets mostly use `imply` to pull in expected Orion drivers while
  preserving dependency handling and user overrides. One notable exception is
  `select PINCTRL_SKY1 if CIX_RADXA_ORION_ACPI`.
- The preset list covers serial, SMMU, OPP/suspend/NVMe, ACPI button/fan/thermal,
  CPPC cpufreq, CIX thermal, Realtek NIC choices (`R8126` for O6, `R8169` for
  O6N), OP-TEE, XHCI, CIX mailbox/SCMI/clock/resource/USB scan/bus-perf, CIX
  USB/DP PHY, RTS5453 Type-C, the new `SENSORS_CIX_FAN` for O6 ACPI, CIX DRM,
  Panthor, PWM/backlight, NPU, ISP/VPU, and CIX audio.

Risk if ported:

This is Kconfig policy, not runtime code. The direct runtime regression risk is
low unless the selected/implied defaults change our actual configs. The
integration risk is high because the symbol set reflects Stuart's tree, not
exactly ours:

- `CIX_ACPI_RESOURCE_LOOKUP` and `CIX_ACPI_USB_SCAN` are removed/reworked by our
  later `0066` platform replacement, but the names still appear in older
  patches and thin-config scripts. A blind preset may imply dead or stale
  symbols depending on final patch order.
- `VIDEO_CIX_ARMCB_ISP` is not in our current carried stack according to the
  prior comparison; implying it would be a no-op or a confusing policy promise
  unless we also import the ISP stack.
- Our audio stack was replaced by `0070`, which removed
  `SND_SOC_SKY1_SOUND_CARD` and builds through `SND_SOC_CIX`; this preset still
  mentions both Stuart-era and vendor-era names.
- We already maintain explicit `config-7.2-lean-msr1-o6n.defconfig` and
  thin-config policy. Adding an in-kernel board preset creates a second policy
  surface that can drift.

Applicability:

Applies cleanly because it adds new Kconfig menu content and does not overlap
our patches mechanically. Clean apply does not mean semantic integration is
clean.

Recommendation:

Do not port as-is. Either skip it and keep board policy in our defconfig/thin
config pipeline, or rewrite it specifically against our final symbol set and
our O6N/MS-R1 installer profile goals. If rewritten, avoid `select` except for
true hard dependencies; use `imply`/defconfig for policy.

## 5. `40046-acpi-demote-cix-sky1-ecam-duplicate-reservations.patch`

Patch size from `git apply --numstat`: 75 insertions in
`drivers/acpi/scan.c`.

What it changes:

- Adds `#include <linux/string.h>`.
- Adds
  `acpi_scan_has_exact_cix_sky1_ecam_resources(struct acpi_device *adev,
  struct list_head *resource_list)`.
- That helper returns true only when:
  - `acpi_match_platform_list()` matches DSDT OEM ID/table ID
    `CIXTEK`/`SKY1EDK2`;
  - the ACPI device is exactly `PNP0C02` UID 0;
  - all enabled memory resources in that device match either one combined
    ECAM window `0x20000000-0x2fffffff` or the exact five-window split:
    `0x20000000-0x21ffffff`,
    `0x23000000-0x24ffffff`,
    `0x26000000-0x27ffffff`,
    `0x29000000-0x2affffff`,
    `0x2c000000-0x2fffffff`;
  - no other enabled memory resource is present.
- In `acpi_scan_claim_resources()`, computes this helper once after
  `acpi_dev_get_resources()`.
- For matching CIX ECAM resources, it no longer calls
  `request_mem_region()` directly. It allocates a `struct resource`, then calls
  `request_resource_conflict(&iomem_resource, r)` so it can inspect the
  conflicting owner.
- If the only failure is a conflict whose name is exactly `"PCI ECAM"`, it
  emits a `dev_dbg()` "Skipped duplicate PCI ECAM reservation" instead of the
  generic `dev_info()` "Could not reserve".
- All nonmatching devices/resources and all other conflicts keep the existing
  behavior.

Risk if ported:

This touches generic ACPI motherboard resource reservation code, but the new
behavior is tightly scoped. The exact platform match plus exact PNP0C02 UID and
exact resource windows make accidental non-CIX impact unlikely.

The subtle risk is in the alternate allocation path for matching resources:
it allocates a resource object manually, calls `request_resource_conflict()`,
and frees it on conflict. If there is no conflict, the object is kept and then
has `IORESOURCE_BUSY` cleared just like `request_mem_region()` results. That
matches the existing reservation pattern closely enough. If firmware changes
one ECAM segment or adds an extra resource, the helper returns false and the
old diagnostic remains.

Relationship to our `sky1_pcie_native=off` workaround:

This patch is not a replacement for our PCI enumeration workaround.

Our active patches `0099-pci-sky1-acpi-standard-ecam-mode-knob.patch` and
`0101-pci-sky1-acpi-block-cixh2020-standard-mode.patch` change the Sky1 PCI
ACPI scan-handler behavior:

- `sky1_pcie_native=off` lets `PNP0A08` fall through to the standard
  ACPI/ECAM host path.
- In that standard mode, `CIXH2020` is claimed without creating a platform
  device, preventing the vendor native driver from probing and resetting live
  firmware-configured links.

Stuart's `40046` does neither of those things. It only demotes one duplicate
resource-reservation message after PCI ECAM has already reserved the window.
It does not block or allow `PNP0A08`, does not block `CIXH2020`, and cannot by
itself prevent the native driver reset path that our `0101` commit describes.

So the prior comparison's "upstream-correct fix vs our workaround" framing is
only partly right. Stuart's patch is upstream-correct for the duplicate ECAM
reservation diagnostic. Our knob is a production workaround for a different
functional failure: choosing the standard ECAM path and preventing native
`CIXH2020` side effects on firmware-configured links. Replacing our workaround
with `40046` would risk returning to the native-driver hang/SError failure mode.

Applicability:

Applies cleanly. Our patch series does not touch `drivers/acpi/scan.c`.

Recommendation:

Port as a narrow ACPI logging/resource-reservation quirk, but do not remove or
default-change `sky1_pcie_native=off` behavior because of it. Treat the two as
complementary:

- `40046` fixes noisy duplicate PNP0C02 ECAM reservations.
- `sky1_pcie_native=off`/`0101` controls the functional PCI host path and
  prevents native CIXH2020 reset on firmware-initialized links.

If we later prove the native Sky1 PCIe driver is safe on the firmware we ship,
then the `sky1_pcie_native` workaround can be revisited. `40046` is not that
proof.

## 6. `40093-pci-cix-enable-root-port-io-window-assignment.patch`

Patch size from `git apply --numstat`: 33 insertions in `drivers/pci/probe.c`.

What it changes:

- Adds `pci_bridge_has_parent_io_window(struct pci_dev *dev)`, which iterates
  parent bus resources and returns true when any resource has type
  `IORESOURCE_IO`.
- Adds `pci_bridge_is_cix_sky1_root_port(struct pci_dev *dev)`, true only for
  devices on the root bus with vendor `0x17cd` and device `0x0100`.
- In `pci_read_bridge_windows()`, if the normal bridge I/O capability probe
  reports no I/O window (`io == 0`), the patch adds a CIX-only fallback:
  when the bridge is a Sky1 root port and its parent bus already has an I/O
  aperture, set `bridge->io_window = 1`, set `bridge->io_window_1k = 0`, log a
  `pci_info()`, and call `pci_read_bridge_io()` so normal PCI resource sizing
  and assignment can program a downstream bridge I/O window.

Before/after behavior:

- Before: if Sky1 firmware left a root-port bridge I/O window disabled, Linux
  treated the bridge as having no assignable I/O window. Endpoints with legacy
  I/O BARs could fail assignment even when the root bus had a valid translated
  I/O aperture.
- After: for Sky1 root ports only, the bridge is considered capable of an
  assignable I/O window when the parent root bus has an I/O aperture.

Risk if ported:

This is PCI core code, but the behavior change is gated by exact root-port
vendor/device IDs and root-bus position, plus parent I/O aperture presence.
Non-CIX hardware should not see the fallback.

The subtle risk is that the patch intentionally overrides the usual "I/O base
register did not appear writable" inference. It assumes Sky1 root ports have
standard bridge I/O base/limit registers even though firmware leaves the window
disabled. If that assumption is wrong on any Sky1 firmware/port variant, Linux
may try to size/program a bridge I/O window that hardware does not decode
correctly. The parent-aperture check limits this to systems where ACPI already
gave Linux translated I/O space.

Applicability:

Applies cleanly. Our patch series does not touch `drivers/pci/probe.c`.

Recommendation:

Port, with a short commit note tying it to observed Sky1 endpoints with legacy
I/O BAR assignment failures. The scope is narrow enough for the installer
kernel, and the failure it fixes is plausible with the standard ECAM path we
use. I would keep the exact ID gate and parent-aperture guard; do not broaden
this into a generic bridge quirk.

## Mechanical apply details

All six pass:

```text
git apply --check --whitespace=nowarn <patch>
```

against both `/tmp/linux-7.2` and the disposable partially-applied
`/tmp/linux-7.2-cix-ours-4158652`.

The six patches add or modify:

```text
20065: drivers/acpi/pptt.c, drivers/base/cacheinfo.c,
       drivers/base/cacheinfo_internal.h, drivers/base/test/*,
       include/linux/cacheinfo.h
20070: Documentation/arch/arm64/mpam.rst,
       Documentation/filesystems/resctrl.rst,
       arch/x86/kernel/cpu/resctrl/*, drivers/resctrl/*,
       fs/resctrl/*, include/linux/resctrl.h
40046: drivers/acpi/scan.c
40093: drivers/pci/probe.c
90040: drivers/hwmon/Kconfig, drivers/hwmon/Makefile,
       drivers/hwmon/cix-fan.c
90050: arch/arm64/Kconfig.platforms, drivers/platform/arm64/Kconfig,
       drivers/platform/arm64/Kconfig.radxa
```
