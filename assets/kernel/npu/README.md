# cix-npu-kmd — out-of-tree NPU (Zhouyi v3) DKMS source

Source: `cixtech/cix_opensource__npu_driver`, staged from the meta-cix recipe
`cix-npu-kmd_1.0.bb` (which applies patches 0001-0009 before this tree is taken).

Unlike `cix_opensource__gpu_kernel` and `cix_opensource__vpu_driver`, the upstream
NPU repo ships **no** `dkms.conf`, so ours is hand-written and transcribes the
build variables from the recipe's `do_compile`:

    COMPASS_DRV_BTENVAR_KMD_VERSION=5.11.0
    BUILD_AIPU_VERSION_KMD=BUILD_ZHOUYI_V3
    BUILD_TARGET_PLATFORM_KMD=BUILD_PLATFORM_SKY1
    BUILD_NPU_DEVFREQ=n

Those are **not defaults**. Getting them wrong produces a module that builds
happily but targets the wrong NPU generation, so keep this file in sync with the
recipe whenever the recipe changes.

## Status: builds, loads and probes — pending the config flip

Verified on O6N (.3) against `7.2.0-rc6-sky1-ncz`, booted with
`module_blacklist=...,armchina_npu` so the in-tree driver never touched the
hardware:

    /dev/aipu created
    armchina CIXH4000:00: AIPU detected: zhouyi-v3
    armchina CIXH4000:00: ############# ZHOUYI V3 AIPU #############
    armchina CIXH4000:00: sky1_npu_probe: armchina_aipu_probe done

Getting there required syncing `sky1.c` with the in-tree copy. The vendored
snapshot probed only as far as:

    sky1_npu_probe: NPU core num is 3
    probe with driver armchina failed with error -13

never reaching `armchina_aipu_probe`'s "AIPU KMD probe start". The two trees
acquire the per-core devices differently — this one used
`&(to_acpi_device_node(child)->dev)` where in-tree uses
`bus_find_device_by_fwnode()` — so the `pd_core[]` entries were different objects
and runtime-PM resume on them returned `-EACCES`. The in-tree file also carries
the Sky1 NULL pd-core guards and BIOS-v1.0 ACPI D0 forcing this snapshot
predates. `src/driver/armchina-npu/sky1/sky1.c` here is now the in-tree copy, and
meta-cix carries the same change as
`cix-npu-kmd-1.0/0009-armchina-npu-sync-sky1-with-intree.patch`.

**Keep both in sync** with `linux-cix-sky1-ncz-7.2/patches-7.2/0121-*.patch` and
`0123-*.patch`. If the in-tree `sky1.c` moves and these do not follow, the
out-of-tree driver silently regresses to a non-probing state.

## Do NOT turn the in-tree driver off — it is the only one that works

Probing is not the bar. Measured on O6N (.3), 7.2.0-rc6-sky1-ncz, same model
(`/opt/ncz/models/bge-small-zh-v1.5_256.cix`) and same userspace:

| driver | probe | memory regions | ASIDs | real inference |
|---|---|---|---|---|
| in-tree `armchina_npu` | yes | 6 | 0-5 set | **62.8 inf/s, 15.9 ms avg** |
| out-of-tree `aipu` (DKMS) | yes | none | none | **fails** |

The out-of-tree failure is not subtle:

    armchina CIXH4000:00: driver mem management is disabled
    [UMD ERR] aipu.cpp:208: schedule job [fail]
    [PY UMD ERROR] noe_job_infer_sync: Job dispatch fail

The graph loads and the job is created; dispatch fails because the driver never
set up the memory regions or ASIDs. Syncing `sky1.c` got the out-of-tree driver
as far as probing, but the things that make the NPU *compute* live in the CORE
driver, not in `sky1.c` — per `post-install/80-npu.sh` these are the SMMU 32-bit
constraint (`bus_dma_limit=0xc0000000`, `dma_mask=32`, without which the IOMMU
hands out 35-bit IOVAs the NPU's 32-bit bus truncates), the
`asid_base[4]`→`asid_base[32]` widening for the QUERY_CAP UMD ABI, and the
v0-compat ioctl handlers bridging cix-noe-umd 2.0.x's k6.6 struct layouts.

**Setting `CONFIG_ARMCHINA_NPU=n` today converts a working NPU into a
non-functional one.** It was set to `n` during this work and reverted once the
inference comparison above was measured.

Before that flip can happen, the out-of-tree tree needs the core patches too,
not just `sky1.c`, and the gate is an inference benchmark — not the presence of
`/dev/aipu`. `INTREE_ACCEL_POLICY` in `build/kernel-manifest.py` therefore keeps
`CONFIG_ARMCHINA_NPU` at `warn`, and it should stay there until a
DKMS-driver-only boot reproduces the throughput above.

The two ACPI `_STA` quirks (`0122`, `0124`) live in kernel core, not the driver,
and are unaffected either way.

## Userspace

`post-install/88-noe-umd-venv.sh` builds the Python side. The wheels pin
`>=3.11,<3.13` while Debian forky ships 3.14, so the stock `cix-noe-umd` postinst
cannot succeed; that script creates a uv-managed CPython 3.12 venv at
`/opt/ncz/noe-venv`, installs the wheels plus numpy (which `NOE_Engine` imports
but does not declare), and exposes `ncz-npu-python`.
