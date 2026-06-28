# Kernel build policy — Yocto is the single authoritative build system

> **All NCZ-OS / CIX Sky1 kernels are built ONLY from the Yocto tree (`meta-cix`).**
> No hand-rolled `git apply`, no `/tmp` one-off compiles, no loose module tarballs.
> This is what we ship and what we tell downstream consumers (Radxa O6, GitHub #32):
> *"Use Yocto — Yocto is our build system,"* and we can prove it builds from clean.

## Authoritative source

- **Tree:** `~/yocto-docker` on **ARGOS** (the designated Yocto host; heavy compiles never run on STUDIO).
  - Layers: `meta-cix`, `meta-nclawzero`, `meta-openembedded`, `poky`.
- **Kernel recipes** (current + legacy):
  - **Current (O6 / O6N):** `meta-cix/recipes-kernel/linux-cix-sky1-ncz/linux-cix-sky1-ncz_7.1.2.bb`
    - `LINUX_VERSION = 7.1.2`, `PV = 7.1.2+ncz`, `KBRANCH = linux-7.1.y`,
      `SRCREV_kernel = 03e2778d1f11de9260543f969e9e888a1c2bf830` (linux-stable v7.1.2).
    - Build dir: `build-cix-ncz71`.
    - Patches (74 cixtech + 11 NCZ): `files/patches-7.1/0001..0074` (cixtech forward-ports)
      + `9001..9011` (NCZ fixes for ACPI boot on MS-R1 / O6 / O6N).
    - **NCZ ACPI patches (required for all CIX Sky1 boards — MS-R1, O6, O6N):**
      - **`9008-reset-sky1-restore-acpi-support.patch`** — `reset-sky1` explicit MMIO
        resource lookup for ACPI (first SError fix).
      - **`9009-pmdomain-scmi-perf-defer-fwnode-provider.patch`** — defer SCMI perf
        domain fwnode provider to `late_initcall` (avoids premature consumer
        attach / genpd `runtime_resume` crash).
      - **`9010-clk-sky1-acpi-fix-acpi-power-management.patch`** — `clk-sky1-acpi`
        ACPI power management (D0 transition + `pm_runtime` activation in probe).
      - **`9011-pm-runtime-gate-until-late-initcall.patch`** — global gate on
        `__pm_runtime_resume` until `late_initcall` sets `cix_system_ready`; the
        most robust fix for the deferred-probe SError pattern (crashes in
        `deferred_probe_work_func` when a consumer's `runtime_resume` calls
        `regmap_read` on unready syscon MMIO).
  - **Legacy:** `meta-cix/recipes-kernel/linux-cix-sky1-next/linux-cix-sky1-next_7.1.bb`
    - `LINUX_VERSION = 7.1.0`, `PV = 7.1.0+sky1-next`, `KBRANCH = master`,
      `SRCREV_kernel = 8cd9520d35a6c38db6567e97dd93b1f11f185dc6`.
    - Build dir: `build-cix`. Still works on MS-R1 / O6 but lacks the 9011 gate;
      superseded by the ncz recipe.
- **Build container:** `crops/poky:ubuntu-22.04` (BitBake 2.8.1), `~/yocto-docker` bind-mounted at `/workdir`.

## How to build (the only sanctioned path)

```bash
# on ARGOS (current NCZ build)
cd ~/yocto-docker
source poky/oe-init-build-env build-cix-ncz71
bitbake -c cleansstate linux-cix-sky1-ncz      # force from-clean patch+compile
bitbake linux-cix-sky1-ncz                       # full build (kernel + modules + DTB)
```

A plain `bitbake linux-cix-sky1-ncz` is enough for incremental changes: editing
`SRC_URI`/patches changes the `do_patch` signature, so BitBake re-runs
patch+compile+deploy automatically. Use `cleansstate` when you need an
authoritative from-clean build (release artifacts). For a single-kernel
recompile after editing patches: `bitbake linux-cix-sky1-ncz -c compile -f`
(re-compiles only; deploy artifacts must be refreshed manually — see Deploy
below).

> **ARGOS is production — never oversubscribe.** The 7.1.2-ncz2 build is ~2 min
> incremental, ~25 min from-clean. Max ONE heavy background job at a time.

## Deploy output (the only artifacts we trust)

```
~/yocto-docker/build-cix-ncz71/tmp/deploy/images/cixmini/
    Image--7.1.2+ncz0+03e2778d1f-r0-cixmini-<ts>.bin   # kernel (50.6 MB)
    modules--7.1.2+ncz0+03e2778d1f-r0-cixmini-<ts>.tgz # /usr/lib/modules tree
    sky1-orion-o6--7.1.2+ncz0+03e2778d1f-r0-cixmini-<ts>.dtb  # single DTB
```

The DTB filename is `sky1-orion-o6.dtb` and is shared by both the **Radxa Orion
O6** and the **O6N** (same SoC, same peripherals). The MS-R1 is built in a
separate build dir (`build-cix-msr1`) using the `cixmsr1` machine.

## Handoff to the installer

`cix-installer` consumes the Yocto deploy output — it does **not** build kernels.
Stage the deploy artifacts into `cix-installer/assets/kernel/` as
`Image-cixmini.bin` + `modules-cixmini.tgz` (+ `KVER` marker), then bake the ISO.

For the 7.1.2-ncz2 kernel, the typical handoff is:
```bash
cp ~/yocto-docker/build-cix-ncz71/tmp/deploy/images/cixmini/Image--*.bin \
   ~/cix-installer-build/cix-installer/assets/kernel/Image-cixmini.bin
cp ~/yocto-docker/build-cix-ncz71/tmp/deploy/images/cixmini/modules--*.tgz \
   ~/cix-installer-build/cix-installer/assets/kernel/modules-cixmini.tgz
echo "7.1.2-ncz2" > ~/cix-installer-build/cix-installer/assets/kernel/KVER
```

Then `cd ~/cix-installer-build/cix-installer && make` to rebuild the ISO with
the new kernel.

## Deploying to a target safely (lesson from 2026-06-26)

Never `tar -C /` a modules tarball: on a usrmerge rootfs that clobbers the
`/lib -> usr/lib` symlink and orphans `ld-linux` → the box wedges every boot.
Extract modules with `--keep-directory-symlink` into `/usr`, then `depmod` +
`update-initramfs`. Keep a known-good kernel as the bootloader default.

## RETIRED — do not use (consolidated into Yocto)

- `~/cix-7.1-ncz-work/` + `build-7013.sh` — manual git tree with `git apply
  --reject` and `SUBLEVEL=` editing. **Replaced by the recipe patch series.**
- `~/modules-7.1.0*.tar.gz`, `~/ARCHIVE-*/...artifacts-7.1-rc7-*` — hand-built
  artifacts. **Replaced by the Yocto deploy dir.**
- Any `/tmp` one-off Docker kernel compiles. **Use the recipe above.**

These are archived for history only; new work goes through the recipe.

## Naming: every kernel we build is an NCZ kernel

**Rule (operator directive 2026-06-26):** any kernel we build *or modify* is an
**NCZ kernel** — regardless of whose patches, BSP, or DKMS modules are
incorporated. CIX did not build these kernels; **we** did.

- The label `cix-sky1-official` is **banned** — it falsely implies CIX built or
  blessed the kernel. Do not use `-official` for any variant.
- NCZ builds carry an NCZ-branded localversion (`-ncz`). The SoC id `cix-sky1`
  may remain as a hardware descriptor, but ownership/branding is NCZ.
- Applies to the consolidated `linux-cix-sky1-next` recipe, all deploy
  artifacts, and all rEFInd menuentries.

## NCZ kernel patches — the 9008 / 9009 / 9010 / 9011 series

These four patches are the **difference between a CIX Sky1 board that boots
cleanly and one that hard-panics with SError during ACPI bring-up**. They are
in the `9001..9011` range of `meta-cix/recipes-kernel/linux-cix-sky1-ncz/linux-cix-sky1-ncz-7.1.1/patches-7.1/`
and are applied automatically by the recipe.

| Patch | File | What it fixes |
|---|---|---|
| `9008` | `reset-sky1-restore-acpi-support.patch` | `reset-sky1` explicit MMIO resource lookup for ACPI. Without it, `reset-sky1` fails to get its register block under ACPI and `pm_runtime_resume` touches unready MMIO → SError. **First SError.** |
| `9009` | `pmdomain-scmi-perf-defer-fwnode-provider.patch` | Defer SCMI perf domain fwnode provider to `late_initcall`. Without it, consumers attach to genpd early and `genpd->runtime_resume` crashes when the clock/reset tree is still settling. |
| `9010` | `clk-sky1-acpi-fix-acpi-power-management.patch` | `clk-sky1-acpi` (CIXHA010) ACPI power management — explicit `acpi_device_set_power(D0)` + `pm_runtime` activation in probe, matching the `clk-sky1-audss` pattern. |
| `9011` | `pm-runtime-gate-until-late-initcall.patch` | Global gate on `__pm_runtime_resume` until `late_initcall` sets `cix_system_ready`. Prevents the deferred-probe SError pattern where a consumer's `runtime_resume` calls `regmap_read` on unready syscon MMIO. **Most robust fix for vendor kernels with many CIX drivers.** |

**Crash signature that 9011 prevents** (captured on `.66` at t=0.515s, 7.1.2-ncz2 #1 PREEMPT):
```
el1h_64_error_handler+0xc/0x78
__regmap_has_tag_bits+0x48/0x60
regmap_read+0x44/0x98
__pm_runtime_resume+0x48/0xc0
rpm_resume+0x14/0x40
__rpm_callback+0x44/0x120
driver_probe_device+0x44/0x120
Workqueue: events_unbound deferred_probe_work_func
```

**How to verify the gate is active at boot:**
```bash
dmesg | grep cix_pm
# expected: "cix_pm: system ready - pm_runtime callbacks enabled"
```

If this line appears, the gate opened correctly after `late_initcall`. If the
board still crashes before this line prints, the crash is in a code path that
bypasses `__pm_runtime_resume` (rare; would need a different fix).

MNEMOS: `mem_1782522729057_42600b`.
