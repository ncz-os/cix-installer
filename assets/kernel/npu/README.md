# cix-npu-kmd — out-of-tree NPU (Zhouyi v3) DKMS source

Source: `cixtech/cix_opensource__npu_driver`, staged from the meta-cix recipe
`cix-npu-kmd_1.0.bb` (which applies patches 0001-0008 before this tree is taken).

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

## Status: builds and installs, but cannot load yet

Verified on O6N (.3) against `7.2.0-rc6-sky1-ncz`: `dkms add/build/install`
succeeds and produces `aipu.ko.xz` with the correct vermagic. Loading it fails:

    aipu: exports duplicate symbol armchina_aipu_alloc_dma_buf (owned by armchina_npu)

The **in-tree** `armchina_npu` driver (`CONFIG_ARMCHINA_NPU=m`) already owns that
exported symbol, so the two cannot coexist. The in-tree driver currently provides
`/dev/aipu` and is what the board actually uses.

## What blocks turning the in-tree driver off

`CONFIG_ARMCHINA_NPU` cannot simply be set to `n`, because the in-tree driver
carries two fixes with **no equivalent** in the out-of-tree patch set:

  * `0121-misc-armchina-npu-sky1-null-pd-core-guard.patch`
  * `0123-misc-armchina-npu-force-D0-before-probe.patch`

(The other in-tree NPU patches do have out-of-tree counterparts, and the two ACPI
`_STA` quirks — `0122` and `0124` — live in kernel core, not the driver, so they
survive the flip either way.)

Order of work to finish the migration:

  1. Port 0121 and 0123 into `meta-cix/.../cix-npu-kmd-1.0/` as patches 0009+.
  2. Rebuild, install via DKMS, set `CONFIG_ARMCHINA_NPU` to `n`, and boot-test
     on O6N (.3) — never on .66, which is the production MS-R1.
  3. Confirm `/dev/aipu` still appears and real `libnoe` inference still runs.
     Presence of the device node is not proof the NPU works.
  4. Flip `CONFIG_ARMCHINA_NPU` from `warn` to `error` in `INTREE_ACCEL_POLICY`
     in `build/kernel-manifest.py`, so it can never regress back in-tree.
