# mali_kbase for 7.0.12-cix-sky1-next — EXPERIMENTAL, NOT YET FUNCTIONAL

Status as of 2026-07-27, tested on real CIX Sky1 hardware: cixmini (.66),
which reports DMI `Micro Computer (HK) Tech Limited MS-R1/P1WSB`, and O6N,
which reports `Radxa Computer (Shenzhen) Co., Ltd. / Radxa Orion O6N`.
(The single board string previously quoted here described cixmini only; it
read as if it covered both, which matters because boot cmdline gating keys
on exactly this DMI -- see ncz_efi_rt_workaround in assets/refind/.)

This is a DKMS-packaged port of the same mali_kbase / memory_group_manager /
protected_memory_allocator driver that ships as the validated default GPU
driver on the 7.2 (`KVER_NEXT`) kernel channel (`assets/kernel/mali/`), built
instead against the **7.0.12-cix-sky1-next** (`KVER_LEGACY`, our
secondary/emergency-fallback) kernel.

**7.0.12's shipping, validated default GPU driver remains in-tree panthor**
(see `docs/DRIVER_FIDELITY_7012.md`) — full GLES/EGL/OpenCL/Vulkan-compute
stack, live-validated. This package is an **opt-in A/B alternative for
follow-up perf-comparison work, not a replacement.** It is intentionally
**not** wired into `post-install/82-mali-gpu.sh` / `26-gpu-default-mali.sh`
and `dkms.conf` sets `AUTOINSTALL="no"` — nothing in a normal 26.7 install
touches this package.

## Investigation context

This build exists to answer one question for the 26.7 GPU-driver-lag
investigation: a keyboard-input-lag bug reproduces on 7.2+mali_kbase but
NOT on 7.0.12+panthor (both user-confirmed on real hardware). Is the lag
7.2-kernel-specific, or mali_kbase-driver-specific? Answering that requires
a *working* mali_kbase on 7.0.12 as the missing A/B cell. As of this
writing that cell is still blocked — see "What does not work yet" — so
the lag A/B question remains **open**, not answered, on this kernel.

## What works

- Builds clean against 7.0.12-cix-sky1-next kernel headers:
  `mali_kbase.ko` + `memory_group_manager.ko` + `protected_memory_allocator.ko`,
  vermagic `7.0.12-cix-sky1-next SMP preempt mod_unload aarch64`.
- `insmod` no longer crashes the board (two earlier NULL/garbage-pointer
  panics were root-caused + fixed — see
  `patches/0001-mali-kbase-port-and-fixes-for-7.0.12-cix-sky1-next.patch`).
- **NEW 2026-07-27: the original probe blocker is fixed.** mali_kbase's
  CIXH5000:00 "perf" SCMI power-domain attach used to permanently
  `-EPROBE_DEFER` (confirmed via `/sys/kernel/debug/devices_deferred`,
  non-transient). Root cause: `drivers/pmdomain/arm/scmi_perf_domain.c` is
  byte-identical between the 7.0.12 and 7.2 kernel bases, but 7.0.12's own
  patch series never picked up two probe-ordering hardening patches the
  7.2 series carries for that file (proven on 7.2 real hardware). Forward
  ported as **two** meta-cix `linux-cix-sky1-next` kernel patches (in
  `nclawzero-yocto/meta-cix`, branch `wip/ultra/2026-07-10-linlondp-26q2`,
  commits `c0a4697` + follow-up):
  - `2027-pmdomain-scmi-perf-defer-fwnode-provider-for-mali.patch` — widens
    the ACPI protocol-fwnode lookup + defers
    `genpd_add_fwnode_provider_onecell()` to `late_initcall`.
  - `2028-pmdomain-fix-attach-by-name-eexist-for-mali.patch` — **turned out
    to be required too**, not just a "maybe" contingency: with 2027 alone,
    dmesg showed the SCMI perf fwnode provider registering successfully
    (`scmi_perf: late fwnode provider registered (12 domains)`) but
    mali_kbase's own `dev_pm_domain_attach_by_name(kbdev->dev, "perf")`
    still failed identically (`CIXH5000:00` still stuck in
    `devices_deferred`). Root cause confirmed on real hardware: ACPI
    platform devices get a generic PM domain attached via
    `dev_pm_domain_attach()` before their own driver probes;
    `drivers/base/power/common.c`'s `dev_pm_domain_attach_by_name()` then
    unconditionally rejects any *additional* named attach with `-EEXIST`
    whenever `dev->pm_domain` is already set — short-circuiting before it
    ever reaches the genpd-by-name lookup 2027 fixed. 2028 narrows that
    rejection to non-ACPI devices (ACPI legitimately needs a second,
    additional domain alongside the generic one). **With both patches,
    mali_kbase gets past the perf-domain attach entirely** — confirmed via
    dmesg showing later-stage messages
    (`armchina CIXH4000:00: ... probe done`, `Protected memory allocator
    initialization ...`) that were never reached before.

## Crash #1 (2026-07-27) — FIXED, hardware-validated

With 2027+2028 applied, mali_kbase probes far enough to reach
`kbase_platform_sky1_late_init()`, whose hrtimer immediately queues
`sky1_power_model_work_handler()`. On real O6N hardware this crashed the
board (kernel oops escalating to a full reset — the machine ended up
requiring a physical power-cycle to recover). Root-caused from the serial
console crash trace + `addr2line` against a debug-symbol build of
`mali_kbase.ko`:

```
[    6.945344]   FSC = 0x04: level 0 translation fault
Workqueue: sky1_power_wq sky1_power_model_work_handler [mali_kbase]
kbase_get_real_power_locked+0xb0/0x378 [mali_kbase] (P)
Code: aa0003e1 d2847800 8b0002a0 94000c5e (f9400ac0)

$ addr2line -e mali_kbase.ko.debug -f -C 0x8ae28
kbase_get_real_power_locked
drivers/gpu/arm/midgard/ipa/mali_kbase_ipa.c:679   # model->ops->get_dynamic_coeff(...), model == NULL
```

`kbase_ipa_init()` (which populates `kbdev->ipa.configured_model` /
`fallback_model`) runs from `kbase_backend_devfreq_init()` during
`kbase_device_init()`, with no ordering guarantee relative to
`platform_late_init_func()`'s hrtimer. This race was **latent and
unreachable before** — probe never got past the perf-domain attach far
enough to run `late_init` at all. Fixing the probe blocker is what exposed
it.

**Fix**: `patches/0002-platform-sky1-guard-against-NULL-IPA-model.patch` —
guards `sky1_power_model_work_handler()` to skip the sample if neither IPA
model pointer is populated yet (hrtimer re-arms and retries next tick).
**Hardware-validated 2026-07-27**: booted with this patch + 2027/2028 on
real O6N, full serial capture through the boot — this specific crash did
not recur. Applied to `src/` in this package.

## Crash #2 (2026-07-27) — NEW, found immediately after fixing #1, NOT fixed

With crash #1 fixed, the very next boot attempt (same session, same
hardware) hit a **different** NULL-pointer-deref, in the generic devfreq
subsystem, unrelated to mali_kbase's own IPA code:

```
[    4.381991] mali CIXH5000:00: Protected memory allocator initialization failed error = -517
[    6.837403] Unable to handle kernel NULL pointer dereference at virtual address 000000000000002e
[    6.841052] Internal error: Oops: 0000000096000004 [#1]  SMP
[    7.031755] Workqueue: devfreq_wq devfreq_monitor
[    7.043410] pc : clk_round_rate+0x50/0x3d0
[    7.161112]  devfreq_update_target+0xc8/0xe8
[    7.165372]  devfreq_monitor+0x3c/0x1d0
[    7.169197]  process_one_work+0x168/0x508
[    7.198797] Kernel panic - not syncing: Oops: Fatal exception
```

Same class of bug as crash #1 (a periodic/deferred callback — here
devfreq's monitor workqueue — firing before something it depends on is
fully initialized, here apparently a `clk` pointer passed into
`clk_round_rate()` that's still NULL). Not yet root-caused or fixed. The
board auto-recovered via `panic=30` (no physical power-cycle needed this
time), so this crash is less severe operationally than #1, but it still
means **mali_kbase does not yet reach a stable, usable state on 7.0.12** —
the lag A/B investigation this package exists for is still blocked. Not
yet investigated: whether this is in mali_kbase's own devfreq
registration path or a generic kernel/clk-framework race exposed the same
way crash #1 was — needs the same kind of cross-reference against how
mali_kbase's devfreq init orders itself relative to clk availability.
**Do not boot-test this combo unsupervised** — while this particular
occurrence auto-recovered, that isn't guaranteed.

## To continue this work (manual, opt-in only)

```
sudo cp -r assets/kernel/mali-70012/src /usr/src/cix-gpu-kmd-70012-1.0.0
sudo cp assets/kernel/mali-70012/dkms.conf /usr/src/cix-gpu-kmd-70012-1.0.0/
sudo dkms add -m cix-gpu-kmd-70012 -v 1.0.0
sudo dkms build -m cix-gpu-kmd-70012 -v 1.0.0 -k $(uname -r)   # must be 7.0.12-cix-sky1-next
sudo dkms install -m cix-gpu-kmd-70012 -v 1.0.0 -k $(uname -r)
```

This kernel-side prerequisite (2027+2028) must also be present — it's a
kernel patch, not a DKMS driver change, so it lives in the meta-cix
`linux-cix-sky1-next` recipe, not in this directory. Without it, mali_kbase
reverts to permanent `-EPROBE_DEFER` and never reaches the code patch 0002
guards. Patch 0002 is now applied to `src/` in this package (hardware-
validated, see "Crash #1" above) and fixes that specific race — but
**Crash #2 (devfreq/clk_round_rate, not yet fixed) means this combo can
still panic the board.** Do not power-cycle/reboot O6N with this combo
without operator supervision — both crashes found so far have required
either a physical recovery or relied on `panic=30` auto-reboot, which is
not guaranteed to work for every possible fault.

## Provenance

`patches/0001-mali-kbase-port-and-fixes-for-7.0.12-cix-sky1-next.patch` is a
consolidated diff (base: ARM's `cix_p1_mg_dev` tree, commit `a752e91` "Cix
p1 mg 202603 patch release") documenting the driver-source changes needed
to get this DKMS source to build + insmod cleanly. `../mali/mali-kbase-scmi-ratelimit.patch`
(already shipping for 7.2) is the same fix ported unchanged into this
tree's `mali_kbase_devfreq.c`.

The 2027/2028 kernel-side probe fix and the 2026-07-27 crash investigation
are documented in full (build logs, dmesg captures, addr2line output) in
MNEMOS and in the meta-cix `linux-cix-sky1-next` commit history — this
README summarizes the current state, not the full narrative.
