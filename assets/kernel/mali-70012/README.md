# mali_kbase for 7.0.12-cix-sky1-next — EXPERIMENTAL, NOT YET FUNCTIONAL

Status as of 2026-07-26, tested on cixmini (.66, real CIX Sky1 hardware,
board `Micro Computer (HK) Tech Limited MS-R1/P1WSB`).

This is a DKMS-packaged port of the same mali_kbase / memory_group_manager /
protected_memory_allocator driver that ships as the validated default GPU
driver on the 7.2 (`KVER_NEXT`) kernel channel (`assets/kernel/mali/`), built
instead against the **7.0.12-cix-sky1-next** (`KVER_LTS`, our
secondary/emergency-fallback) kernel.

**7.0.12's shipping, validated default GPU driver remains in-tree panthor**
(see `docs/DRIVER_FIDELITY_7012.md`) — full GLES/EGL/OpenCL/Vulkan-compute
stack, live-validated. This package is an **opt-in A/B alternative for
follow-up perf-comparison work, not a replacement.** It is intentionally
**not** wired into `post-install/82-mali-gpu.sh` / `26-gpu-default-mali.sh`
and `dkms.conf` sets `AUTOINSTALL="no"` — nothing in a normal 26.7 install
touches this package. Caveat: `mali_kbase.ko` carries an ACPI modalias for
`CIXH5000`, so if you manually `dkms install` it on a box (see below), it
becomes modalias-autoload-eligible on later boots like any other installed
module — "not auto-installed" only holds until someone runs the manual
install steps below. That's fine functionally (the probe just defers, it
does not crash), but don't be surprised if it loads itself after a reboot
once installed.

## What works

- Builds clean against 7.0.12-cix-sky1-next kernel headers:
  `mali_kbase.ko` + `memory_group_manager.ko` + `protected_memory_allocator.ko`,
  vermagic `7.0.12-cix-sky1-next SMP preempt mod_unload aarch64`.
- `insmod` no longer crashes the board. Two real, reproducible NULL/garbage
  -pointer kernel panics were found via live insmod testing on cixmini and
  root-caused from pstore/ramoops-captured crash dumps (see
  `patches/0001-...patch` for the full writeup + panic traces). Both are
  fixed.

## What does not work yet

- **Probe never completes.** `sky1_gpu_attach_pd()`'s "perf" SCMI
  power-domain attach permanently defers (`-EPROBE_DEFER`) — confirmed via
  `/sys/kernel/debug/devices_deferred` showing `CIXH5000:00` stuck there,
  not a transient boot-ordering race. **No `/dev/mali0` appears.** GPU
  functionality (GLES/Vulkan/OpenCL, glmark2, etc.) was **not** validated
  and cannot be until this is fixed.
- Likely cause (unconfirmed): this kernel's
  `drivers/pmdomain/arm/scmi_perf_domain.c` is an older revision than the
  7.2 kernel's (see the patch writeup) and may simply never register a
  power domain matching the name/lookup mali_kbase's `sky1_gpu_attach_pd()`
  expects on this kernel/ACPI combination — needs further investigation
  (comparing this kernel's SCMI perf-domain driver + ACPI SSDT against the
  7.2 kernel's, where the identical mali_kbase platform code succeeds).

## To continue this work (manual, opt-in only — do not automate without fixing the probe-completion issue first)

```
sudo cp -r assets/kernel/mali-70012/src /usr/src/cix-gpu-kmd-70012-1.0.0
sudo cp assets/kernel/mali-70012/dkms.conf /usr/src/cix-gpu-kmd-70012-1.0.0/
sudo dkms add -m cix-gpu-kmd-70012 -v 1.0.0
sudo dkms build -m cix-gpu-kmd-70012 -v 1.0.0 -k $(uname -r)   # must be 7.0.12-cix-sky1-next
sudo dkms install -m cix-gpu-kmd-70012 -v 1.0.0 -k $(uname -r)
# then, to test WITHOUT flipping the default driver:
sudo rmmod panthor
sudo modprobe mali_kbase
dmesg | tail -30   # expect it to defer/fail cleanly, not hang
sudo rmmod mali_kbase; sudo rmmod protected_memory_allocator; sudo rmmod memory_group_manager
sudo modprobe panthor   # restore the shipping default
```

## Provenance

`patches/0001-mali-kbase-port-and-fixes-for-7.0.12-cix-sky1-next.patch` is a
consolidated diff (base: ARM's `cix_p1_mg_dev` tree, commit `a752e91` "Cix
p1 mg 202603 patch release") documenting every change already baked into
`src/`, in the order it was made, including the two panic root-causes and
fixes. `../mali/mali-kbase-scmi-ratelimit.patch` (already shipping for 7.2)
is the same fix ported unchanged into this tree's `mali_kbase_devfreq.c`.
