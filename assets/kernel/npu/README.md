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

## Remaining: turn the in-tree driver off

While `CONFIG_ARMCHINA_NPU=m` the two drivers cannot coexist —

    aipu: exports duplicate symbol armchina_aipu_alloc_dma_buf (owned by armchina_npu)

— so the in-tree module wins and the DKMS one cannot load. What is left:

  1. Set `CONFIG_ARMCHINA_NPU` to `n` in the 7.2 defconfigs. Deliberately not
     done yet: it needs a kernel rebuild and boot test, and at the time of
     writing those defconfigs carried unrelated uncommitted work.
  2. Rebuild the kernel, boot-test on O6N (.3) — never on .66, the production
     MS-R1.
  3. Confirm real `libnoe` inference, not just the device node. A probing driver
     and a working NPU are not the same claim; the userspace UMD is not
     installed here, so only probe has been demonstrated.
  4. Flip `CONFIG_ARMCHINA_NPU` from `warn` to `error` in `INTREE_ACCEL_POLICY`
     in `build/kernel-manifest.py`, so it cannot regress back in-tree.

The two ACPI `_STA` quirks (`0122`, `0124`) live in kernel core, not the driver,
and survive the flip either way.
