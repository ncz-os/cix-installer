# Linux 7.3: what NCZ-OS should adopt, and what can break us

Status: research, docs only (2026-10-06). No kernel was built and no config was changed for this document.
Context: one unified 7.3 kernel line for T2 Macs and generic amd64 PCs, and for Sky1 (arm64). No 7.2.x line ships.

## Basis

- **Source tree:** mainline `v7.3-rc6` = `a90ee4305c4a5df72c11b31dacfdc76e00fcf78a`, compared against
  `v7.2` = `8d3ae59288f1e7d58d76558a6ee96d533bc5019f` (18,224 non-merge commits, 438 merges). The pull-request
  bodies were read from the merge commits, and individual claims were checked against the tree with
  `git show/grep/log` at `v7.3-rc6`.
- **Our configs:**
  - amd64 7.3: `7.3.0-rc6-1-t2-edge-aerfix` (kernel staging `amd64-t2-rc6-20261004`, T2 series at amd64-kernel-t2 `2b693f2`)
  - amd64 shipping: `7.2.9-2-t2-trixie` (amd64-kernel-t2 `reference/shipping/config-7.2.9-2-t2-trixie`)
  - Sky1 7.3: `7.3.0-rc6-sky1-ncz` (staging `r282-7.3.0-rc6-sky1-ncz-20261004`)
  - Sky1 shipping: `7.2.8-sky1-ncz` (`assets/kernel/r277-7.2.8-sky1-ncz-20260927/`)

  Below, "amd64" and "Sky1" mean the two rc6 configs unless a 7.2 config is named.
- **Release notes:** https://kernelnewbies.org/Linux_7.3 , https://www.phoronix.com/review/linux-73-features ,
  and the Phoronix per-subsystem articles cited inline. LWN merge-window articles were paywalled at the time of
  writing, so the pull-request bodies in the tree were used in their place.
- **Evidence tags.** Every claim carries one of:
  - **[src]**: verified in source at `v7.3-rc6`; the commit sha or `path` is given.
  - **[notes]**: from release notes or the pull-request text; the URL or merge sha is given.
  - **[inferred]**: reasoning about our hardware or configs that has not been tested on hardware.

## Summary

### Top adoptions

| # | Adoption | Platforms | Change | Effort |
|---|---|---|---|---|
| 1 | Carry the narrow **AER ANFE quirk (9011)** for the T2 Secure Enclave instead of the full **9010 revert**, keep a 9010 flavour as fallback, and send 9011 to linux-pci. Upstream has not touched `aer.c` since `eddba19b8b5f` (ANFE support); none of the three rc PCI fix pulls touch it [src]. | T2 | patch carry | S, upstreaming M |
| 2 | **Suspend-hang diagnostics:** `DPM_WATCHDOG=y` with the new `DPM_WATCHDOG_ENABLED=n` (`dca82e209e`) [src], a built-in pstore backend, and `pm.dpm_watchdog_enabled=1` only on test boot entries. A hung suspend then leaves a stack in pstore instead of a dark machine. | T2, Sky1 | Kconfig + cmdline | S |
| 3 | **Sky1 BTF:** move from `DEBUG_INFO_NONE=y` to DWARF + `DEBUG_INFO_BTF=y` (pahole in the Yocto build). This unblocks sched_ext, CO-RE eBPF tools, HID-BPF struct_ops and `BINFMT_MISC_BPF`, all already working on amd64. | Sky1 | Kconfig + build dep | M |
| 4 | **Boot framebuffer and panic screen:** `DRM_EFIDRM=y`, `FB_EFI=n` (amd64 also `DRM_VESADRM=y`, `FB_VESA=n`) so drm_panic works before the GPU driver loads. Also, `DRM_PANIC_SCREEN="qr_code"` currently does nothing: the QR mode `depends on DRM_PANIC && RUST` and Rust is off, so the screen falls back to the "user" message [src: `drivers/gpu/drm/Kconfig:101-103`, `drm_panic.c:880-894`]. Use `"kmsg"` so a panic shows the log. | all | Kconfig | S config, M test |
| 5 | **Free wins to keep:** btrfs direct I/O about 2x and fsync/log-commit speedups on our btrfs root (`e9b7b9d9e7`, `5093038fc2`); amdgpu skips the noirq reset when gmux has parked the dGPU (`eadb85cca1`, new in rc6); hid-apple keeps the T2 keyboard backlight across resume (`2b5d1495bd`); HDA HDMI jack resync after suspend (`c0933934d5`); MGLRU executable protection and zswap batch writeback (`6f34b4126b`) [src]. | all | none (pin rc6 or later) | none |
| 6 | **Unify config policy across the two arches** (one kernel line, two `.config` files): `MODVERSIONS` (amd64 n, Sky1 y), module signing (amd64 y, Sky1 n), lockdown LSM (amd64 y, Sky1 n), module compression (amd64 XZ, Sky1 none), squashfs zstd (amd64 y, **Sky1 n**), EROFS (amd64 m, Sky1 n) [src: configs]. | all | Kconfig | S to M |
| 7 | **Driver coverage for the unified kernel:** `RTW89_8922DE=m` (new in 7.3, off on both); `MT7921U`/`MT7925U=m` on Sky1; `NTFS_FS_WOF_COMPRESSION=y` on amd64 (new in 7.3); `CGROUP_DMEM=y` on amd64 (7.3 adds dmem cgroup VRAM eviction for amdgpu) [src]. | all | Kconfig + firmware | S |

### Top breakage risks

| # | Risk | Severity | Fix |
|---|---|---|---|
| 1 | **T2 power cut from AER ANFE** if neither 9010 nor 9011 is carried: MacBookPro16,1 loses power about 17 s into boot on plain 7.3-rc6 (9010 patch header evidence). | **High** | carry 9011, keep a 9010 fallback flavour |
| 2 | **Sky1 VPU (amvx) dma-buf import.** `DMABUF_DEBUG` now really defaults to y on `DEBUG_KERNEL` kernels (`143755bdab`) and is `=y` in the Sky1 rc4 and rc6 configs. With it on, importers get an sg_table copy with `length=0` and `page=NULL`; only the DMA address and length are kept [src: `drivers/dma-buf/dma-buf.c:884-912`]. amvx counts pages with `for_each_sg_page()` (`assets/kernel/vpu/src/driver/if/mvx_mmu.c:401-447`), so an imported dma-buf maps as zero pages [src for the code path; runtime effect inferred]. | **High** | `DMABUF_DEBUG=n` on Sky1 now; port amvx to `for_each_sgtable_dma_page()` |
| 3 | **amdgpu ASPM decision changed for Navi14 behind its internal AMD switch** (`4e0d6f2876`, rc1; companion `04de4007d3`, rc4). This is a dGPU link-power behaviour change on exactly the hardware where a vanishing dGPU cuts system power [src; T2 impact inferred]. | Medium | add an `amdgpu.aspm=0` arm to the T2 7.3 test matrix |
| 4 | **PCI PM changes:** Root Ports on non-x86 may now enter D3 (`d4c79b63d8`), which affects the Sky1 Cadence ports. ASPM is now programmed on every function of a multi-function device (`733cd811b3`), which includes the T2 BCE/Secure Enclave pair [src; impact inferred]. | Medium | Sky1 fallback `pcie_port_pm=off` or DT `aspm-no-l1ss`; record LnkCtl in T2 boot telemetry |
| 5 | **Config-gate drift and silent no-ops:** 37 Kconfig symbols removed or renamed. `PROC_SYSCTL` is folded into `SYSCTL` (`8d75c338f0`) [src], `ARM64_WORKAROUND_REPEAT_TLBI` became `_SYNC`, `HAVE_GENERIC_VDSO` became `VDSO_DATASTORE`, and so on. The T2 config gate fails against the 7.2.9 reference, and any fragment or `#ifdef` that uses an old name silently does nothing. | Medium | regenerate the 7.3 reference config / allowed-deltas |
| 6 | **Unreviewed default flips on Sky1:** upstream made about 150 Qualcomm clock drivers default-on (`5c38f9b7df`, `6b150572bb`), and the Sky1 config has `ARCH_QCOM=y` (also HISI and MEDIATEK), so they were built in silently [src]. | Medium | `ARCH_QCOM=n` etc.; review n-to-y gains on every rc bump |
| 7 | **Out-of-tree module breakage (third-party DKMS):** kthreads now start in a private nullfs, so `filp_open`/`kern_path` from a kthread or workqueue fails; `struct acpi_driver` is removed (`541b293ab1`) [src]. Our modules are clean (see the DKMS audit below). | Medium for third parties, low for us | release-note it |

## Recommended options that are currently off

| Symbol | amd64 rc6 | Sky1 rc6 | Recommendation | Section |
|---|---|---|---|---|
| `DPM_WATCHDOG` (+`DPM_WATCHDOG_ENABLED=n`) | n | n | y, enable per test boot entry | PM |
| `EFI_VARS_PSTORE` | m | n | y on amd64, so watchdog panics are captured | PM |
| `ZSWAP_SHRINKER_DEFAULT_ON` | n | n | y if zswap is the chosen strategy (do not stack zswap and zram) | MM |
| `DEBUG_INFO_BTF` | y | absent (`DEBUG_INFO_NONE=y`) | Sky1: y | eBPF |
| `SCHED_CLASS_EXT` | y | absent | Sky1: y after BTF | sched |
| `DRM_EFIDRM` / `FB_EFI` | n / y | n / y | y / n | DRM |
| `DRM_VESADRM` / `FB_VESA` | n / y | n/a | y / n | DRM |
| `DRM_PANIC_SCREEN` | `"qr_code"` (ineffective) | `"qr_code"` (ineffective) | `"kmsg"` | DRM |
| `CGROUP_DMEM` | n | n | amd64 y | DRM |
| `SQUASHFS_ZSTD` | y | **n** | Sky1 y (our layers are zstd squashfs) | storage |
| `SQUASHFS_DECOMP_MULTI_PERCPU`, `SQUASHFS_FILE_DIRECT` | y, y | n, n | Sky1 y | storage |
| `EROFS_FS` | m | n | Sky1 m | storage |
| `RTW89_8922DE` | n | n | m | wifi |
| `MT7921U`, `MT7925U` | m | n | Sky1 m | wifi |
| `NTFS_FS_WOF_COMPRESSION` | n | n (`NTFS_FS=n`) | amd64 y | storage |
| `HID_MAGICMOUSE` | m | n | Sky1 m (external Apple trackpads) | HID |
| `MODVERSIONS` | **n** | y | amd64 y (DKMS ABI safety net) | modules |
| `SECURITY_LOCKDOWN_LSM` | y | n | Sky1 y (at `LOCK_DOWN_KERNEL_FORCE_NONE`) | security |
| `MODULE_SIG` | y | n | pick one policy | security |
| `BOOT_CONFIG` / `CMDLINE_FROM_BOOTCONFIG` | n / absent | n / n/a | optional, amd64 only | boot |

Options to turn **off**: `DMABUF_DEBUG` on Sky1 (y today; see risk 2), and `ARCH_QCOM`, `ARCH_HISI`, `ARCH_MEDIATEK` on Sky1.

All config states above are **[src: configs]**, read from the two rc6 configs listed under Basis.

---

## 1. PCI, AER, ASPM

### 1.1 AER Advisory Non-Fatal Errors, and our 9010 revert / 9011 quirk
- **What changed:** `eddba19b8b5f` "PCI/AER: Support Advisory Non-Fatal Errors" unmasks ANFE and routes
  Uncorrectable-reported-as-Correctable errors through recovery and logging. The same pull also reworked AER logging:
  agent and layer per error (`1017599755`, `9247e45c00`), the error source logged once (`8446e1147f`), and the TLP log
  printed only for unmasked errors (`a8bf2dd750`). It also allows DPC on all Downstream Ports [src: merge `570f7e331f5f`,
  `drivers/pci/pcie/aer.c`].
- **Upstream status at rc6:** `git diff eddba19b8b v7.3-rc6 -- drivers/pci/pcie/aer.c` is empty, and none of the PCI
  fix pulls (`ef31d04b6d8a`, `fddfc3ec3179`, `d2dbe503fd80`) touch AER [src]. No public report of the T2 power cut
  was found [inferred].
- **Does 9010 still apply?** Yes. Its `aer.c` hunks target an identical file, and later `pci.h` changes do not touch
  `struct aer_err_info` [src]. Per the patch's own evidence, plain rc6 cuts power at 16.7 s; rc6 plus the revert stays up.
- **Change needed:** prefer 9011, which keeps ANFE masked only on the T2 Secure Enclave function `106b:1802`. Keep a
  flavour that carries 9010 until 9011 has been tested on a second T2 model (MBP15,x, MBA, Mac mini, iMac). Send 9011
  to linux-pci, where a device quirk is acceptable and a revert is not.
- **Risk:** high without either patch; low with 9011 on MacBookPro16,1, but untested on other T2 models [inferred].
  **Effort:** S (carry), M (upstreaming).

### 1.2 ASPM programmed on every function of multi-function devices; DT ASPM masks
- **What changed:** `733cd811b3` and `75a3b50ad9` apply ASPM disable/restore to every function of a multi-function
  device. `eacf92a29a` adds the DT properties `aspm-no-l0s`, `aspm-no-l1` and `aspm-no-l1ss` [src].
- **Benefits / impact:** the T2 bridge is multi-function (BCE `106b:1801`, Secure Enclave `106b:1802`), so link-control
  writes now hit both functions. This is a new write path on the device behind our power-cut history [inferred].
  Sky1 DT boots can mask ASPM states per port without a kernel patch.
- **Change needed:** none in config. Record `lspci -vv` LnkCtl (read-only) for the BCE/SEP in T2 boot telemetry. On Sky1,
  use `aspm-no-l1ss` in a DT overlay rather than `pcie_aspm=off` if L1SS misbehaves. **Risk:** medium on T2 [inferred].
  **Effort:** S.

### 1.3 D3 for Root Ports on non-x86; portdrv on service-less ports; WAKE#
- **What changed:** `d4c79b63d8` allows D3 for native-hotplug Root Ports on non-x86. Portdrv now binds ports with no
  AER/PME/DPC/hotplug services so they can runtime-suspend (merge `56948ac2a2`). `071e245ab7` adds PCIe WAKE# from DT [src].
- **Benefits:** idle power on the Sky1 NVMe, NIC and Wi-Fi slots [inferred]. **Risk:** medium on Sky1. Root Ports newly
  entering D3 is a classic source of devices disappearing after resume, and the Sky1 root ports (`17cd:0100`) already
  have a history. Fallback: `pcie_port_pm=off`. x86 is unchanged. **Effort:** S (test only).

### 1.4 rc-cycle PCI fixes worth knowing
- `PCI: Fix BAR resize for devices on a root bus` (amdgpu ReBAR), and `x86/PCI: Disable enhanced atomics on AMD
  NBIO 7.7 and 7.11` (silent DMA corruption on Ryzen 7040/8040/AI 300). Both are in rc6, so nothing to do
  [src: merges `fddfc3ec3179`, `d2dbe503fd80`].

## 2. System sleep, runtime PM, ACPI, platform

### 2.1 PM core
- **What changed:**
  - `dca82e209e` adds `CONFIG_DPM_WATCHDOG_ENABLED`: the watchdog is built in, off by default, and enabled at boot with
    `pm.dpm_watchdog_enabled=1`.
  - `058c1ac0e6` renames the PM-core module-parameter prefix from `main.` to `pm.`.
  - `cb258d651d` unblocks runtime PM when device prepare fails.
  - `eef1d74bf8` lets drivers recover from a failed runtime resume.
  - `41112a787f` (rc5) fixes a hibernation preallocation deadlock, a 7.2 regression.

  [src: `kernel/power/Kconfig:261-300`, merges `a5778046a025`, `4ba51ef66a77`]
- **Benefits:** suspend hangs are the main open T2 problem (BCE, gmux, dGPU). The runtime-PM unblock fixes target the
  same pattern that patches 9504 (touchbar) and 9507 (HDA) work around [inferred].
- **Change needed:** see the options table. Grep boot entries for any `main.dpm_*` parameter (none known).
  **Risk:** low with the watchdog off by default. **Effort:** S.

### 2.2 ACPI
- **What changed:** `struct acpi_driver` is eliminated (`541b293ab1`; `acpi_bus_register_driver()` and
  `module_acpi_driver()` are gone). `beaff265a4` sets `power.no_pm` on all `acpi_device` objects. CPPC register-access
  overhead is cut, and arm64 gets a paired FFH feedback-counter read (`9aa7df5205`) [src: merges `0d508f1745b5`, `3382bfbca58c`, `344be13211d0`].
- **Benefits:** Sky1 runs cpufreq through `ACPI_CPPC_CPUFREQ=m` on ACPI boots, so each frequency change gets cheaper
  [src for config; benefit inferred]. Ship the 7.3 `linux-cpupower`, which has the generic CPPC view.
- **Our exposure:** none of our DKMS modules or T2 patches use `struct acpi_driver` or `acpi_device_name/class()` [src: grep].
  **Watch:** T2 ACPI devices whose PM went through the ACPI companion (gmux, ACPI backlight) after the `power.no_pm` change [inferred].

### 2.3 cpufreq, cpuidle, thermal
- intel_pstate gets HWP init consolidation, plus an rc6 fix to the `cpufreq_update_pressure()` max_freq fallback that
  restores pre-7.2 scheduler capacity behaviour [src: merge `100638f0f016`]. intel_idle gains ACPI `_LPI` support.
  amd-pstate dynamic EPP becomes an `energy_performance_preference` mode, and **`amd_dynamic_epp=` and the `dynamic_epp`
  sysfs file are removed** (`32692fcf61`) [src; notes: https://www.phoronix.com/news/Linux-7.3-AMD-Per-Core-Dynamic].
  Neither of our repos references them [src: grep].
- Thermal: a step_wise fix for stale mitigation votes (rc5). step_wise is the governor on both arches, and this matters
  for fanless MacBook Airs and Sky1 boards [src: `b9dbb658e210`; benefit inferred].

### 2.4 Apple x86 platform drivers
- Upstream `applesmc` moved to `hwmon_device_register_with_info()` (`94f5081d35`) [src]. Keep `SENSORS_APPLESMC=n`
  (t2smc DKMS replaces it) and keep that check in the config gate. `apple-gmux` and vga_switcheroo have no commits in
  v7.2..rc6 [src]. 9001 (early CPU offlining for T2 resume) is still not upstream, so keep carrying it [src].

## 3. Scheduler and power

- **cgroup "flatten the pick":** cgroup scheduling moves to a single runqueue with weight-distribution modes. The knob
  lives in sched debugfs and is not a stable ABI (`kernel/sched/debug.c:637`). There are also latency fixes for
  short-slice tasks and an asymmetric-capacity cluster fix [src; notes: https://kernelnewbies.org/Linux_7.3]. Sky1 is
  asymmetric (`SCHED_CLUSTER=y`, `ENERGY_MODEL=y`), so the cluster fix applies directly [inferred]. This is the largest
  CFS change of the cycle. Benchmark Sky1 desktop latency on 7.2.8 against 7.3 before claiming a win.
  **Risk:** medium [inferred].
- **sched_ext:** hierarchical sub-schedulers, bandwidth-limited rescue of starved tasks, an NMI-safe abort path,
  **`scx_bpf_cpu_rq()` removed**, and the CPU-topology helper gained a size argument in rc4 [src: merges `11260c335ec6`,
  `7cdf91542e1e`]. amd64 can offer scx (scx_lavd/bpfland) as an opt-in profile, but only with an `scx` userspace release
  built for the 7.3 ABI. Sky1 needs BTF first (see 9.2).

## 4. Memory management

- **What changed:**
  - MGLRU protects mapped executable folios after first use.
  - zswap writes back in batches in `shrink_memcg()` (`6f34b4126b`), and the global shrinker is fixed for `MEMCG=n`.
  - Block-swap I/O is batched through `swap_iocb`, with a pluggable `swap_ops`.
  - `zs_free()` lock contention is reduced.
  - zram gets OOB and parameter-validation fixes only.
  - New opt-in sysctl: `vm.panic_on_unrecoverable_memory_failure`.

  [src: merges `ed3b875bea55`, `18fbf5151d2c`]
- kernelnewbies lists "zswap per-cgroup proactive writeback", but no new cgroup interface exists in rc6. Treat it as
  unconfirmed [src, negative check].
- **Our state:** `ZSWAP=y`, `ZSWAP_DEFAULT_ON=n`, `LRU_GEN_ENABLED=y` on both. Installs use zram swap
  (`post-install/93-zram-swap.sh`, zstd, 50% of RAM). Keep zram as the single compressed-swap strategy; only flip
  `ZSWAP_SHRINKER_DEFAULT_ON` if a variant moves to zswap with a disk swapfile [inferred]. **Effort:** S.

## 5. Boot, EFI, initramfs, arm64 core

- **EFI:** runtime-service calls are bounded by `EFI_RTS_TIMEOUT`. A wedged firmware call now disables EFI runtime
  services instead of hanging the kernel. The Apple `properties_header` size is bounds-checked (`eb01ffabeb`)
  [src: merge `388b607d107c`]. Both help T2: Apple EFI device properties feed gmux, i915 and Thunderbolt, and busy-NVRAM
  `SetVariable` stalls now degrade gracefully [inferred].
- **bootconfig to cmdline (x86 only):** `CMDLINE_FROM_BOOTCONFIG` renders the `kernel` subtree of an embedded bootconfig
  into the cmdline before `parse_early_param()` [src: `init/Kconfig:1586-1620`]. This could bake mandatory T2
  parameters into the image so an edited bootloader entry cannot drop them. Bootconfig values win over the bootloader,
  so only bake parameters that must never vary. **Optional, effort M.**
- **arm64:** an `arch_freq_get_on_cpu()` truncation fix makes Sky1 `scaling_cur_freq` and `/proc/cpuinfo` MHz
  trustworthy [notes: merge `c5adb6c8a26d`]. `ARM_SDEI_NMI` (new) and BBML3 need firmware support we do not have.
  The `ARM64_WORKAROUND_BROKEN_AMU_CONSTCNT` erratum is compiled in but inert on A720/A520 [src].

## 6. Graphics and display

### 6.1 amdgpu (T2 Radeon Pro 5300M/5500M, Vega)
- **The switcheroo-parked dGPU no longer resets in noirq suspend** (`eadb85cca1`, first in rc6). Before this, a gmux-off
  Radeon made every system suspend fail with -EINVAL. It was tested on MacBookPro11,5 [src]. This is exactly the
  configuration that patch 2009 (gmux switch-to-iGPU at probe) creates. Pin rc6 or later and validate S3 with the dGPU
  parked [inferred].
- **ASPM decided on the host link** (`4e0d6f2876`, rc1; `04de4007d3`, rc4): when the GPU sits behind an AMD internal
  switch, the root-port to switch-upstream link decides ASPM [src]. Navi14 in MBP16,x has that topology [inferred]. Add
  an `amdgpu.aspm=0` test arm (cmdline only).
- **Runtime PM and switcheroo exclude Thunderbolt-attached or removable dGPUs** (`c52feb4365`, `8587d48d69`) [src].
  eGPU stability improves; the internal T2 dGPU should be unaffected unless firmware marks its port external-facing
  [inferred].
- **SMU11 PPT defaults come from the driver PPTable** (`25f4a46b0c`), user PPT limits are restored after reset
  (`cf9fa4d4d0`), and power sensors use milliwatts internally (`757ba0790b`) [src]. Our 6001 (Apple SMU limits) and 6002
  (UCLK DPM deferral) apply cleanly on rc6, but a clean apply does not prove the behaviour holds. Compare hwmon
  `power1_cap*` against 7.2.9 [inferred]. **Risk:** medium.
- **New connector "color format" property** (RGB/YCbCr 444/422/420), amdgpu first [src: `drm_connector.c`; notes:
  https://www.phoronix.com/news/Linux-7.3-DRM-Color-Format]. It needs compositor support.
- **dmem cgroup eviction** for amdgpu/xe/nouveau via TTM (`747c4bb450`, `bd4f284df0`) [src; notes:
  https://www.phoronix.com/news/Linux-7.3-DRM]. Enable `CGROUP_DMEM` on amd64.

### 6.2 i915 (Intel T2 Macs, iGPU panel)
- eDP AUX backlight no longer requires `AUX_ENABLE_CAP` (`7d594b24c9`) [src]. If Intel T2 panels advertise only the
  SET cap, the backlight path may change; the knob is `i915.enable_dpcd_backlight=` [inferred].
- DP link configuration moved to a link-caps API (`4074974b71`, `bbf51a67d1`) [src]. Our 2008 (MBP15,1 4-lane quirk)
  applies with offsets and `intel_ddi_a_force_4_lanes()` still exists, but the code that consumes it changed underneath,
  so re-test it. 7001 (BIOS fb takeover) applies unchanged and could go upstream as a one-line change to the newly
  extracted `bios_fb_ok()` (`b2a2c62040`) [src].
- The PSR, ALPM, Panel Replay and DC3CO work in 7.3 targets display version 30 and later. T2 Macs are gen9.5, so it
  does not apply [src: `git log -- drivers/gpu/drm/i915/display`].

### 6.3 Boot framebuffer and drm_panic
- `SYSFB_SIMPLEFB` is deprecated in favour of efidrm/vesadrm (`cc79eaf8ee`); simpledrm gains stride and panel-size
  validation [src]. Both our configs still use `FB_EFI=y`, `FB_SIMPLE=y` and `DRM_EFIDRM=n` [src: configs].
- `DRM_PANIC_SCREEN="qr_code"` is set on both, but `DRM_PANIC_SCREEN_QR_CODE` needs `RUST` (off on both), so the
  dispatcher falls back to the static "user" screen [src: `drivers/gpu/drm/Kconfig:101-103`, `drm_panic.c:880-894`].
  `"kmsg"` shows the log tail and is more useful for T2 early-boot and power-cut triage [inferred].
- **Change needed:** `DRM_EFIDRM=y`, `FB_EFI=n` (amd64 also `DRM_VESADRM=y`, `FB_VESA=n`), `DRM_PANIC_SCREEN="kmsg"`,
  keep `DRM_FBDEV_EMULATION=y`. Test Plymouth, the console, and the gmux iGPU/dGPU handover. **Risk:** medium (early
  console). **Effort:** S config, M test.

### 6.4 Sky1 GPU (Mali-G720 class): Panthor and kbase
- In-tree Panthor reaches driver 1.9: sparse mappings (`12cf826bf1`), GPU page sizes exposed to userspace (`6c1427fd03`),
  firmware bounds hardening, and a vm_bind overlap check. It already names arch 12.0 "Mali-G720(-Immortalis)", but it
  still has **no ACPI path**; it matches only `mediatek,mt8196-mali`, `rockchip,rk3588-mali` and
  `arm,mali-valhall-csf` [src: `drivers/gpu/drm/panthor/panthor_hw.c:147-151`, `git grep -i acpi drivers/gpu/drm/panthor` empty].
- Our `assets/kernel/panthor` fork is at driver 1.8 plus Sky1 glue and builds on rc6. Re-fork it from the 7.3 tree to pick
  up the 1.9 UAPI and hardening. `DRIVER_GEM_GPUVA` is removed in 7.3 (`21fcb222f0`), and the fork's 7.3 variant
  already drops the flag while 7.2.7 panicked at probe without it, so one fork tree cannot serve both. Under the 7.3-only
  decision, retire the 7.2 overlays [src]. **Effort:** M (re-fork), L (upstream ACPI glue so the fork can go).
- Tyr (the Rust Mali CSF driver) gains a firmware parser, MCU boot and a VM, but its Kconfig still says "may not be
  functional" and `depends on RUST` [src]. Watch only.
- Mali kbase DKMS: builds on rc6. Its build log has about 120 repeats per header of `'counted_by' attribute directive
  ignored`; a Kbuild flag fix would make real warnings visible [src: r282 build log].

### 6.5 accel/NPU and media/VPU
- No new accel drivers in 7.3 (`drivers/accel/` has the same driver set) [src]. The armchina NPU (`aipu.ko`) is a misc
  device and builds on rc6. It must become a `DRIVER_COMPUTE_ACCEL` driver only if we ever upstream it [inferred].
- V4L2 gains ISP statistics validation and HEVC/AV1 tile-count bounds for hantro/rkvdec/mediatek [notes: merges
  `f4cdf7ca9a1f`, `d5d6c9d244c6`]. Nothing for the Sky1 VPU, which uses the out-of-tree stateful `amvx`; `VIDEO_LINLON`
  is not upstream [src]. **See the dma-buf risk (summary, risk 2).**

## 7. Audio, Bluetooth, Wi-Fi, HID, USB/Thunderbolt

### 7.1 HID and input (T2)
- hid-apple restores the keyboard backlight after the T2 re-enumerates the keyboard on resume (`2b5d1495bd`, Cc stable) [src].
- **ABI rename:** the T2 butterfly-keyboard backlight LED goes from `apple::kbd_backlight` to `:white:kbd_backlight`
  (`42b31c80e4`) [src]. cix-installer has no references to the old name [src: grep]. Saved systemd-backlight state is
  keyed by name, so brightness resets once on first boot [inferred]. Check t2linux tooling (for example tiny-dfr) for
  hard-coded names.
- hid-magicmouse re-enables multitouch from `.reset_resume` (`4253fe22b1`) [src]. Whether that helps the internal T2
  trackpad bound through our 4004 is unproven [inferred].
- Input core: devices must be fully ready before events flow, handler start is deferred until open, and state resyncs on
  uninhibit [notes: merge `1be05c6afb`]. This helps lid-inhibit handling across suspend [inferred].
- HID-BPF hardening (`3afefbfe55` and others) makes udev-hid-bpf a credible future home for small Apple quirks such as
  5001 [src; migration inferred].
- **Still needed and not upstream in rc6:** 4001, 4003, 4004, 5001, 9504. All apply on rc6 [src: rc6 apply gate].

### 7.2 Audio
- HDA force-resumes the codec if an acomp ELD notify arrived during suspend, fixing HDMI audio that stayed "unplugged"
  (`c0933934d5`) [src]. Our 9507 (direct-complete with a powered-off dGPU) is still needed: `azx_prepare()` still
  forbids it (`sound/hda/controllers/intel.c:1023`), and the two changes do not conflict textually [src]. Add a "plug
  HDMI during suspend" case to the hardware checklist.
- Sky1 `SND_HDA_CIX_IPBLOQ` was already in 7.2; 7.3 only restricts it to 64-bit [src: `2a611c4a1c`].
- Optional generic-amd64 coverage: `SND_HDA_SCODEC_AW88399` (+`_I2C`) [notes: https://www.phoronix.com/news/Linux-7.3-Sound].

### 7.3 Bluetooth
- hci_bcm4377 extends the reserved-PHY quirk to BCM4378 (Apple-silicon part) (`aec6a8d80e`) [src]. Whether BCM4377 on T2
  has the same behaviour is a test item. 9002 (Broadcom adv-type bits, BCM4364B3) is a different field and still needed [src].
- MediaTek: MT7922/MT7925 remote wakeup disabled on Ryzen (`dcaf83ead1`), btmtk reset fixes, MT7920 firmware declared [src].

### 7.4 Wi-Fi
- brcmfmac (T2): DPP, msgbuf flowring ID validation, a lost 802.1x TX-completion fix, and the cfg80211 ROC/mgmt_tx cookie
  becoming an input (`914781c728`) [src]. 9503 (missing D3 ACK on BCM4377) is still needed: `pcie.c:2650` still sends
  `D3_INFORM` unconditionally [src].
- mt76: MT7928 via mt7925, mt7925 hung-bus handling, and a mt7921 PCIe AER handler "to prevent system crash"
  (`e65b4ca339`, `9417c5818a`) [src].
- rtw89: RTL8922DE (Wi-Fi 7), LEDs, coex, and a PCI `.shutdown` [src]. `RTW89_8922DE` is off on both.
- **Firmware:** the linux-firmware package needs `rtw89/rtw8922d*`, `mediatek/mt7928*` and the MT7920 BT RAM code
  [inferred: confirm the package version].

### 7.5 USB, Thunderbolt, Type-C
- xHCI bails out when the first capability read returns all-ones, where before it **oopsed on arm64** (`78203d5b54`),
  plus isochronous and link-error recovery fixes [src]. Sky1 degrades cleanly when an xHCI fails to leave D3cold [inferred].
- Thunderbolt/USB4 gets DP tunnel teardown and lifecycle fixes and a NULL deref fix (`0b457c6733`, `4310c6b8e7`) [src].
  The vendored `t2thunderbolt` DKMS stays flagged as unsafe; these fixes do not change that.

## 8. Storage and filesystems

- **btrfs (our root on every platform):**
  - Direct I/O goes through the iomap bounce buffer instead of falling back to buffered I/O; per the pull, about 50% to
    95% of theoretical (`e9b7b9d9e7`).
  - The 1-jiffy log-commit sleep is removed (`5093038fc2`).
  - Full fsync skips hole detection on files without holes (`4bdec1b14b`).
  - The **v1 space cache is off by default** (`545e560a5b`).
  - The **`usebackuproot` mount option is removed** (`ee2851074b`); use `rescue=usebackuproot`.

  [src; notes: https://kernelnewbies.org/Linux_7.3] Our fstab (`defaults,ssd,discard=async`) uses neither removed
  option, and no script suggests `usebackuproot` [src: grep]. No change needed.
- **iomap:** `struct iomap_ops` becomes a single `->iomap_next()`, and there is a simple direct-I/O fast path for small
  reads [src: `include/linux/iomap.h:242`]. APFS (8001) defines no `iomap_ops`, so it is unaffected.
- **APFS 8001/8002:** apply with no offset or fuzz on rc6, build in all four rc6 flavours, and already handle the 7.3
  `->create` without `excl` behind `KERNEL_VERSION(7,3,0)` [src: `b2f1e6301e`, patch 8001]. They are **not mount-tested
  on 7.3**; add a read-only macOS-volume mount to the T2 checklist.
- **squashfs/erofs/overlayfs:** squashfs gets cache-herd and bounds fixes (`f6f47a9ca8`, `e300eb5002`). erofs takes a
  source fd via `fsconfig()` (composefs) and gets large folios. The overlayfs merged mount can be idmapped [src/notes].
  **Sky1 cannot decompress zstd squashfs** (`SQUASHFS_ZSTD=n` since 7.2.8), while `build/build-squashfs-layers.sh`
  writes zstd layers. Whether any Sky1 boot path mounts those layers with our kernel was not traced [inferred]. Align with
  amd64 either way.
- A press claim of a "71% Zstd decompression speedup" does not match any commit: `git log v7.2..v7.3-rc6 -- lib/zstd`
  is empty [src, negative check].
- **NTFS (new driver):** Windows System Compression read support behind `NTFS_FS_WOF_COMPRESSION` [src; notes: merge
  `7f22f3a193`]. This helps Boot Camp and dual-boot users.
- **HFS/HFS+:** B-tree bitmap and CNID validation; a corrupt volume now mounts read-only [notes: merge `0de672c7e1`].
- **RWF_DONTCACHE on block devices** (`8b5ffb43ae`) [src]. An image writer that uses `pwritev2(RWF_DONTCACHE)` avoids
  flooding the page cache. Optional (M).
- **fuse:** io_uring buffer pools and zero-copy (`FUSE_IO_URING=y` on both already); the server has to opt in [notes].
- NVMe: the `nvme-apple` fixes are for Apple silicon. T2 ANS2 enumerates as standard NVMe [inferred].

## 9. Security, eBPF, Rust, modules

### 9.1 Security
- **Landlock ABI 10 to 11:** `LANDLOCK_RESTRICT_SELF_NO_NEW_PRIVS`, tracepoints, and denial logging split from audit
  (`SECURITY_LANDLOCK_LOG`) [src: `security/landlock/syscalls.c:175`, `include/uapi/linux/landlock.h:198-212`; notes:
  https://kernsec.org/pipermail/linux-security-module-archive/2026-August/059142.html]. Already enabled on both. Our own
  sandboxing code should probe ABI 11.
- **AppArmor:** userspace-compressed policy (`SECURITY_APPARMOR_COMPRESSED_POLICY`, default y, on in both), an audit
  mode, and a cred use-after-free fix [src: `security/apparmor/Kconfig:96`; notes: https://www.phoronix.com/news/Linux-7.3-AppArmor].
  The faster load needs a newer `apparmor_parser` than trixie has [inferred].
- **IMA:** `IMA_INIT_LATE_SYNC` stops late TPM probes from forcing TPM-bypass mode [notes: merge `a51ec5e8e5`]. We do not
  use IMA, so leave it off.
- **Module signing:** nothing new in 7.3. ML-DSA key types already existed in 7.2 (`certs/Kconfig:42-55@v7.2`) [src].
  Posture differs per arch (see the options table). Do **not** enable `MODULE_SIG_FORCE` without a DKMS MOK signing flow.

### 9.2 eBPF
- **binfmt_misc BPF handlers** (`BINFMT_MISC_BPF`, the `'B'` type, `bpf_binprm_*` kfuncs, transparent dispatch)
  [notes: https://www.phoronix.com/news/Linux-7.3-binfmt-misc; src: `fs/Kconfig.binfmt:171-174`]. This needs
  `BINFMT_MISC=y` (m on both today) and BTF. Watch for use by an emulation layer on Sky1 (box64/FEX/qemu-user).
- **Signed BPF program verification** reworked at `BPF_PROG_LOAD` [notes: merge `5a8cd539ac`]. Groundwork only.
- **pahole dependency reduced:** `resolve_btfids` discovers kfuncs itself, and the "KF_IMPLICIT_ARGS requires pahole
  1.26" note is gone from `changes.rst` [src]. That makes Sky1 BTF easier.
- **Sky1 has no BTF** (`DEBUG_INFO_NONE=y`, `PAHOLE_VERSION=0`), so CO-RE tools, sched_ext, HID-BPF struct_ops and
  `BINFMT_MISC_BPF` are all unavailable there [src: config]. This is the largest feature-parity gap between the two
  arches. **Effort:** M.

### 9.3 Rust
- Minimum rustc stays **1.85.0** on x86 and arm64. There is a new warning for bindgen < 0.72.1 with libclang >= 22
  [src: `scripts/min-tool-version.sh`; notes: merge `d24f5cdbef`]. `RUST` is off in both builds (no rustc in either
  build environment). Today, enabling Rust buys only the QR panic screen; later it would buy Tyr. Defer it, and use
  `"kmsg"` for the panic screen meanwhile.

### 9.4 kbuild and modules
- Modules link with `--force-group-allocation`, modpost message format is canonicalised, and the broken
  `modules.builtin` top-level targets are removed [notes: merge `3abe3d0223`]. Minimum GCC, binutils, LLVM and pahole
  are unchanged [src]. Any log scraper that greps modpost output may need new patterns [inferred].

## 10. Removals and renames that could break us

### 10.1 Kconfig symbols in v7.2 but not v7.3-rc6 that appear in our configs
37 symbols were removed or renamed tree-wide [src: Kconfig `config` lines diffed at both tags]. The ones in our configs:

| Symbol | amd64 7.2.9 | Sky1 7.2.8 | Fate |
|---|---|---|---|
| `PROC_SYSCTL` | y | y | folded into `SYSCTL` (`8d75c338f0`); `SYSCTL=y` in both rc6 configs |
| `HAVE_GENERIC_VDSO` | y | y | renamed `VDSO_DATASTORE` (`ecacc9c8d3`) |
| `ARCH_ENABLE_THP_MIGRATION` | y | y | renamed `ARCH_HAS_PMD_SOFTLEAVES` (`d547b10017`) |
| `ARM64_WORKAROUND_REPEAT_TLBI` | - | y | renamed `ARM64_WORKAROUND_REPEAT_TLBI_SYNC` |
| `CRYPTO_LIB_AESGCM` | y | - | replaced by `CRYPTO_LIB_AES_GCM` (`6d22ec2629`) |
| `HAVE_BOOTMEM_INFO_NODE`, `HAVE_KVM_ARCH_GMEM_PREPARE` | y | - | removed / replaced (internal selects) |
| `XEN_PVHVM`, `XEN_PVHVM_SMP`, `XEN_AUTO_XLATE` | y | y (AUTO_XLATE) | removed; Xen guests only |
| `EFS_FS`, `VXFS_FS` | m | n | filesystems removed |
| `IBM_ASM`, `IPWIRELESS`, `PCMCIA_XIRCOM` | m | - | drivers removed |
| `OPENVSWITCH_GENEVE/GRE/VXLAN` | m | - | OVS legacy tunnel vports removed |
| `CACHEFILES_ONDEMAND` | n | - | removed |

None of these loses a feature our hardware uses. The amd64-kernel-t2 `scripts/config-gate.sh`, run against the 7.2.9-2
reference, reports every row as drift, so regenerate the reference from the accepted 7.3 config (or add allowed-deltas)
when 7.3 becomes the line [inferred from the gate's semantics]. Any out-of-tree `#ifdef CONFIG_PROC_SYSCTL` now silently
compiles its sysctl code out; our DKMS trees have none [src: grep].

**Silent drops** (symbol still exists, but was on in 7.2 and is off in rc6):
- amd64: none [src].
- Sky1: module compression (`MODULE_COMPRESS` y to n; the config audit asserts no `.ko.xz`, so this looks deliberate),
  and the watchdog pretimeout default governor moved from NOOP to DUMP. Confirm both are intended [src].

### 10.2 ABI, sysfs and boot parameters
- `Documentation/ABI/removed` and `obsolete`: no additions in v7.2..rc6 [src].
- Removed or renamed parameters and sysfs:
  - `amd_dynamic_epp=` and amd-pstate `dynamic_epp` (removed)
  - `main.dpm_watchdog_*` renamed to `pm.*`
  - `noreplace-smp` (x86-32), `pata_legacy.*`, `smsc-ircc2.*`
  - the btrfs `usebackuproot` mount option
  - the LED `apple::kbd_backlight` becomes `:white:kbd_backlight`

  None of these appear in our cmdlines or scripts [src: grep].
- `/proc/2/root` and every kthread root are now an empty nullfs [notes: merge `fff0150b02`].
- memcg v1 `soft_limit_in_bytes` is inert (`a3417097fb`); we use cgroup v2 only.

### 10.3 Kernel APIs and out-of-tree modules
136 exported symbols were removed between v7.2 and v7.3-rc6. Many became macros or inline functions [src]. Audit of our
out-of-tree code (t2smc, t2gmux, t2smp, t2thunderbolt, t2bce/1001, APFS/8001, Mali kbase, panthor fork, armchina NPU, amvx VPU):

| Module | Location | API | 7.3 status | Severity |
|---|---|---|---|---|
| amvx (VPU) | `vpu/src/driver/if/mvx_mmu.c:401-447` | `for_each_sg_page()` on an imported dma-buf sgt | zero pages under `DMABUF_DEBUG=y` | **High** |
| amvx (VPU) | `vpu/src/driver/if/mvx_session.c:594,602,3802` | `filp_open` (debug dump) | fails if reached from a kthread; call sites are user context | Low |
| panthor fork | `assets/kernel/panthor` | `DRIVER_GEM_GPUVA` removed (`21fcb222f0`) | 7.3 variant already adapted; 7.2 variant cannot share the tree | Low (retire 7.2) |
| t2bce | patch 1001 | `init_srcu_struct` | export removed, macro remains; builds | None |
| npu (aipu) | `aipu_dma_buf.c:278-283` | `dma_buf_map_attachment` | fine under DMABUF_DEBUG; checks `!table` instead of `IS_ERR()` (old bug) | Low |
| APFS | patch 8001 | `->create` loses `excl`; `iomap_ops` reshaped | handled / not used | None |
| t2smc, t2gmux, t2smp, t2thunderbolt, Mali kbase | — | none found | build PASS on rc6 headers | None |

Build evidence: the Sky1 r282 staging built `mali_kbase`, `memory_group_manager`, `protected_memory_allocator`, `aipu`,
`panthor` and `amvx` against rc6 with matching vermagic, and the DKMS ABI gate passed (with `MODVERSIONS=y`). The amd64
rc6 static gate shows t2smc, t2gmux, t2smp and t2thunderbolt building. **Building is not the same as working.** The
dma-buf issue compiles cleanly.

Third-party DKMS that users install will hit: the removal of `struct acpi_driver`; path lookup from kthreads failing;
the cfg80211 `remain_on_channel`/`mgmt_tx` cookie signature change; `system_wq` deprecation warnings [src]. Put this
in the release notes.

## 11. Our T2 patch carry on 7.3-rc6

All 19 T2 patches apply on rc6 with no fuzz and no failed hunks [src: amd64-kernel-t2 `reports/t2-port-v7.3-rc6/gates/apply-rc6-plain.tsv`].

| Patch | Upstream in 7.3? | Note |
|---|---|---|
| 1001/1002 t2bce | no | builds; known `t2bce_ave` oops tracked separately |
| 2008 i915 4-lane quirk | no | consumer code changed (link caps); re-test on MBP15,1 |
| 2009 gmux iGPU at probe | no | gmux unchanged in 7.3; pairs with `eadb85cca1` |
| 4001/4003/4004/5001 HID | no | still needed |
| 6001/6002 amdgpu SMU | no | check against PPTable-derived PPT defaults |
| 7001 i915 fbdev | no | candidate for upstream against `bios_fb_ok()` |
| 8001/8002 APFS | n/a (out of tree) | 7.3 API handled; mount test pending |
| 9001 ACPI early CPU offline | no | still needed |
| 9002 BT adv-type | no | still needed |
| 9010 AER ANFE revert / 9011 quirk | no | see 1.1; prefer 9011 |
| 9503 brcmfmac D3 ACK | no | still needed |
| 9504 touchbar runtime PM | no | still needed |
| 9507 HDA direct-complete | no | still needed; coexists with `c0933934d5` |

## 12. Open questions

1. Does 9011 alone keep a second T2 model (MBP15,x or MBA) up on 7.3? Until it does, keep the 9010 fallback flavour.
2. Does `amdgpu.aspm=0` change the T2 7.3 power-cut picture? This tests the `4e0d6f2876` behaviour change.
3. Does any Sky1 boot path mount zstd squashfs with our kernel, or are layers always unpacked in userspace?
4. Is amvx dma-buf import actually used on Sky1 today (GStreamer/FFmpeg with dmabuf import from the display or GPU)?
   If it is, `DMABUF_DEBUG=n` is urgent for any Sky1 7.3 image.
5. Which Mesa release consumes Panthor 1.9 sparse binding? Not verified.
6. Is the Sky1 watchdog pretimeout default-governor change (NOOP to DUMP) intended?
7. kernelnewbies' "zswap per-cgroup proactive writeback" claim: no interface was found in rc6. Re-check at 7.3 final.

## Sources
- https://kernelnewbies.org/Linux_7.3
- https://www.phoronix.com/review/linux-73-features
- https://www.phoronix.com/news/Linux-7.3-DRM , https://www.phoronix.com/news/Linux-7.3-DRM-Color-Format ,
  https://www.phoronix.com/news/Linux-7.3-AMDGPU-GFX6-Modifiers
- https://www.phoronix.com/news/Linux-7.3-Power-Management , https://www.phoronix.com/news/Linux-7.3-AMD-Per-Core-Dynamic
- https://www.phoronix.com/news/Linux-7.3-HID , https://www.phoronix.com/news/Linux-7.3-Sound
- https://www.phoronix.com/news/Linux-7.3-AppArmor , https://www.phoronix.com/news/Linux-7.3-binfmt-misc
- https://kernsec.org/pipermail/linux-security-module-archive/2026-August/059142.html (Landlock 7.3 pull)
- Merge commits in `v7.2..v7.3-rc6` cited by sha throughout: pci `570f7e331f5f`, pm `a5778046a025`, acpi
  `0d508f1745b5`, drm-next `4e69c1856bfd` / `a99d741df737`, media `f4cdf7ca9a1f`, sound `e5c91aac491d`, net-next
  `91ec20351349`, hid `a93f3bf4e1d6`, btrfs `50c44fea13ec`, vfs `ff68e5f557f6`..`b9cba7ebfe53`, mm `ed3b875bea55` /
  `18fbf5151d2c`, efi `388b607d107c`, sched_ext `11260c335ec6`, bpf-next `5a8cd539ac19`, rust `d24f5cdbeff8`, landlock
  `7199989f3f31`, apparmor `8fefe68784ae`.
