# Prebuilt mali GPU module overlays

Each `<KVER>/` directory holds the three CIX Sky1 mali modules built against
exactly that kernel release:

    mali_kbase.ko  memory_group_manager.ko  protected_memory_allocator.ko

`post-install/82-mali-gpu.sh` installs the directory matching the kernel being
staged. These are **vermagic-locked**: a module built for one kernel release is
refused by any other, so a new `<KVER>/` must be built for every kernel bump.
Shipping only a stale directory is how the board ends up on software rendering
with no `/dev/mali0` — that is exactly what happened between rc5 and rc6.

## Provenance

Source: `cixtech/cix_opensource__gpu_kernel` (published as the `cix-gpu-driver`
deb on the CIX Debian image), built from source by the Yocto recipe
`meta-cix/recipes-kernel/cix-modules/cix-gpu-kmd_1.0.bb`.

## How to rebuild for a new kernel

On cixmini (.66), which has the native aarch64 Yocto environment:

    cd ~/yocto-docker
    ./y6-run.sh "bitbake -c cleansstate cix-gpu-kmd && bitbake cix-gpu-kmd"

Then copy the three modules out of the recipe's image directory:

    ybuild/tmp/work/cixmini-nclawzero-linux/cix-gpu-kmd/1.0+cix/image/usr/lib/modules/<KVER>/extra/cix/

into a new `assets/kernel/mali/<KVER>/` here.

**Always verify vermagic before committing** — this is the check that would have
caught the rc5/rc6 regression:

    modinfo -F vermagic <module>.ko    # must equal <KVER> exactly

The recipe derives the release string from
`${STAGING_KERNEL_BUILDDIR}/kernel-abiversion`; it previously hardcoded a
literal, which silently stamped every module with a stale release.
