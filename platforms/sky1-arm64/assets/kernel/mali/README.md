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

**cixmini is no longer a build host** (2026-09-14 — it and O6N are now
alternating kernel test/boot-validation hosts, reflashed constantly; nothing
durable, including a Yocto environment, survives on either between sessions).
The Yocto recipe path below (`meta-cix/recipes-kernel/cix-modules/
cix-gpu-kmd_1.0.bb`) is still the canonical, most-authoritative build — run it
on **TYDEUS** (`~/yocto-docker/yocto6-ncz-tydeus`), which now hosts the real
Yocto environment:

    cd ~/yocto-docker
    ./y6-run.sh "bitbake -c cleansstate cix-gpu-kmd && bitbake cix-gpu-kmd"

Then copy the three modules out of the recipe's image directory:

    ybuild/tmp/work/cixmini-nclawzero-linux/cix-gpu-kmd/1.0+cix/image/usr/lib/modules/<KVER>/extra/cix/

into a new `assets/kernel/mali/<KVER>/` here.

**Blessed alternate path** when the Yocto recipe route isn't available
(validated twice now — 7.2.5 on 2026-09-12, 7.2.6 on 2026-09-14): build
directly via DKMS against the target kernel's real, dkms-abi-gate-verified
headers (e.g. staged at the shared `kernel-staging/<rev>/headers-dir/` on
ARGONAS — see `~/.claude/rules/build-cluster-distribution.md`), using the
same `src/` + `dkms.conf` this directory already carries:

    make modules_prepare        # builds native fixdep/modpost against these headers
    dkms build -m cix-gpu-kmd -v 1.0 -k <KVER>

This is not a workaround — it's the same DKMS registration `82-mali-gpu.sh`
already uses on-target for automatic rebuilds on a future kernel upgrade
(see that file's "belt + suspenders" comment); doing it once, ahead of time,
on a build host just produces the prebuilt fast-path overlay so a fresh
install doesn't need a live compile at first boot. Confirm the toolchain used
differs from the OE cross-compiler (this is expected — see the 2026-09-12
commit message for why that's fine here, unlike a real headers/image
provenance mismatch).

**Always verify vermagic before committing** — this is the check that would have
caught the rc5/rc6 regression:

    modinfo -F vermagic <module>.ko    # must equal <KVER> exactly

The recipe derives the release string from
`${STAGING_KERNEL_BUILDDIR}/kernel-abiversion`; it previously hardcoded a
literal, which silently stamped every module with a stale release.
