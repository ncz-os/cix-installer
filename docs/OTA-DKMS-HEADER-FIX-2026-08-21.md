# OTA DKMS-header fix (2026-08-21)

A real, twice-reproduced packaging defect: every OTA kernel install left the
four CIX out-of-tree accelerator modules with **stale vermagic** against the
newly-installed kernel, baked those stale modules into the new initramfs, and
broke GPU / VPU / NPU on every fresh boot until the operator manually fixed
it. This document records the root cause, the fix that was applied (r246,
r247, and the finalised r248), and how to verify it on a future kernel bump.

## What the defect looked like

After `apt install linux-image-cixmini` of a freshly built kernel .deb, the
board rebooted into the new kernel with the GPU on llvmpipe (software
rendering — confirmed by `vulkaninfo` reporting the llvmpipe ICD), the VPU
falling back to the older in-tree amvx, and the NPU either failing `noe_init`
or panicking. Every accelerator module in `updates/` was present on disk
and loadable in principle, but its vermagic did not match the running
kernel:

```
$ modinfo /usr/lib/modules/7.2.0-sky1-ncz/updates/mali_kbase.ko | grep vermagic
vermagic:       7.2.0-sky1-ncz SMP preempt mod_unload aarch64   # <- OLD KVER
$ modinfo /usr/lib/modules/7.2.0-sky1-ncz/updates/mali_kbase.ko | grep depends
depends:        …
$ uname -r
7.2.0-sky1-ncz+r246                                              # <- NEW KVER
```

(illustrative; the actual mismatch was between the .deb-shipped / DKMS-built
modules and the new kernel after every revision bump of `BUILD_REV`).

The GPU fallback was the visible symptom; the VPU and NPU were failing
identically, just less obviously.

Reproduced twice in succession:

- **r246** — first 7.2 final build staged as the OTA path. Manually fixed
  by the operator: stage the headers tarball, run `make modules_prepare`,
  dkms remove/install for the four packages, regenerate the initramfs,
  reboot.
- **r247** — same fix, applied for the first time inside the build
  pipeline (the post-install hooks for fresh installs were unchanged but
  the r247 build's existing path was missing the headers .deb). Same
  manual remediation, again.

The fact that the manual remediation was identical, twice, is the
diagnostic: the .deb packaging pipeline was systematically failing to
do one specific thing, and the operator was systematically doing it by
hand to compensate.

## Root cause

`linux-image-cixmini_<KVER>+<REV>_arm64.deb` was being built by
[`build/build-kernel-debs.sh`](../build/build-kernel-debs.sh) as
**Image + in-tree modules only** — it shipped:

```
/boot/vmlinuz-<KVER>
/boot/config-<KVER>
/usr/lib/modules/<KVER>/kernel/...        # in-tree modules
/usr/lib/modules/<KVER>/updates/*.ko     # 3 GPU overlay modules
/usr/lib/modules/<KVER>/modules.builtin  # kernel build metadata
```

It did **not** ship the DKMS build/ tree. The matching header tree
(`/lib/modules/<KVER>/build/`) was a build-side artifact that lived at
`assets/kernel/edge/headers-cixmini.tar.zst` (produced by
[`build/extract-kernel-headers.sh`](../build/extract-kernel-headers.sh))
and was transferred to the target only by the install-time post-install
hooks (`post-install/10-our-kernel.sh`). Those hooks run **once at first
install**; they do not run on an OTA kernel upgrade.

The standard Debian kernel-package postinst chain (triggered by the
`update-initramfs | dracut` dep) regenerated the initramfs as part of
the new kernel's install. That regeneration baked in whatever DKMS
modules were already on disk — which were the modules built against the
**previous** kernel's headers, because nothing in the OTA path had
rebuilt them. The new kernel then booted into an initrd containing
mismatched-vermagic modules for mali_kbase, memory_group_manager,
protected_memory_allocator, panthor, amvx, and aipu.

A secondary failure mode lurked in the same path: the header tree the
operator had to manually re-stage carried `scripts/basic/fixdep` and
`scripts/mod/modpost` as Yocto build-host binaries linked against the
uninative loader. Those were documented in `post-install/79-dkms-prep.sh`
(which, again, runs at install time, not on OTA upgrade) — and a manual
`make modules_prepare` on the target was the only way to get native
host tools on a board that had never run the install-time hooks.

## What the fix does

Two .debs are now produced per kernel and installed together:

| package                 | role                                                                |
| ----------------------- | ------------------------------------------------------------------- |
| `linux-image-cixmini`   | Image + in-tree modules + GPU overlay (unchanged)                   |
| `linux-headers-cixmini` | `/lib/modules/$KVER/build/` + the postinst that fixes the OTA gap  |

`linux-image-cixmini` declares `Depends: linux-headers-cixmini (= $ver)`,
so apt always installs the headers package first in the same transaction
and the image's postinst runs against an already-corrected tree. The
headers .deb's postinst performs the full **OTA-DKMS-HEADER-FIX-2026-08-21**
sequence:

1. **Stage the header tree.** The .deb's data.tar already extracted it
   under `/usr/lib/modules/$KVER/build/`, which is the canonical DKMS
   path. The postinst verifies the three required files
   (`Makefile`, `.config`, `Module.symvers`) are present and refuses to
   continue if any are missing. Re-running the .deb on a board that
   already has the tree is a no-op at this step.

2. **`make modules_prepare`.** Rebuilds the host tools the headers
   tarball omits — `scripts/basic/fixdep` and `scripts/mod/modpost` —
   as native binaries. The expected late failure on `kernel/bounds.s`
   (the tarball does not carry the full source tree that target
   depends on) is documented and harmless: both tools are built by the
   time kbuild reaches that target. The postinst also pins
   `localversion-ncz` and verifies `include/config/kernel.release`
   equals `$KVER` before proceeding; mismatched release strings are
   the second mode of the r246/r247 defect, and refusing to continue
   here is the only way to surface them at install time rather than at
   first boot.

3. **`dkms autoinstall -k $KVER`.** Rebuilds **every** registered DKMS
   package against the now-correct headers in one call. A package that
   fails to build is a real defect (the source no longer compiles
   against this kernel) and the postinst **fails the dpkg transaction
   loudly** with the last 30 lines of `/var/log/ncz-dkms-autoinstall.log`
   and the current `dkms status` output. A silent-stale GPU driver is
   strictly worse than a failed install a human will notice — that is
   the r246/r247 lesson, and it is enforced here.

4. **Regenerate the initramfs** (dracut primary, `update-initramfs`
   fallback). This is the **only** place initrd regen happens for an
   OTA kernel install: the image .deb's own postinst deliberately does
   not call any initramfs builder, because the standard
   `/etc/kernel/postinst.d/` trigger chain would race step 3 and bake
   in the still-stale modules. The headers package configures first
   (dependency order), runs steps 1–3, regenerates the initrd in step
   4, and only then does the image package's postinst run — at which
   point the initrd at `/boot/initrd.img-$KVER` already contains the
   correctly-vermagic'd modules.

The full sequence is in
[`build/build-kernel-debs.sh:build_headers_deb()`](../build/build-kernel-debs.sh);
the postinst is the heredoc starting with `# 1. Stage the header tree`.

## Why a separate headers .deb (and not a tarball in the image .deb)

Two equivalent fixes were on the table:

- A `linux-headers-cixmini` .deb installed as a `Depends:` of the image.
- The headers tarball bundled directly into the image .deb's payload,
  with the postinst sequence bolted onto the image's own postinst.

A separate .deb won, for three reasons:

1. **Clean dependency ordering.** With a `Depends: linux-headers-cixmini (= $ver)`,
   apt guarantees the headers package configures before the image does.
   Bundling everything in one .deb would force a more fragile ordering
   argument (e.g. "do X before the standard kernel-package initramfs
   trigger fires", which is the kind of dependency on hook ordering
   that has bitten this project before — see the bootloader-helper
   wrapper comment in `cixmini-boot`'s postinst for the closest prior
   incident).

2. **Idempotency of the remediation.** A board that has gone through
   the r246/r247 manual remediation already has a `/lib/modules/$KVER/build/`
   tree on disk. Reinstalling the image-only .deb would silently do
   nothing about DKMS, because the image-only .deb still did not
   contain the postinst that does the rebuild. With a separate
   headers .deb, `apt install --reinstall linux-headers-cixmini`
   re-runs the whole (1)–(4) sequence and is the documented way to
   recover a board that finds itself with stale modules.

3. **Reuse by future packages.** Any future CIX DKMS source
   (`cix-gpu-kmd` 1.1, `panthor-cix` 7.3, a hypothetical NPU upgrade)
   adds itself to `dkms status` automatically and is picked up by
   `dkms autoinstall` in step 3. No new .deb, no new Depends, no new
   postinst — `dkms autoinstall` walks `/var/lib/dkms/` and rebuilds
   every registered package, full stop.

## Verification on a future kernel bump

These are the commands the operator should run on a disposable board
(or in the KVM install gate, if the operator prefers to validate
without hardware) after a future `build-kernel-debs.sh` run.

### 1. The .deb contents

```sh
# Build the .debs from a current assets/kernel/edge/ tree.
$ bash build/build-kernel-debs.sh
…
  [edge] 7.2.0-sky1-ncz -> linux-image-cixmini (7.2.0-sky1-ncz+r248)
  [edge] staged 3 out-of-tree GPU module(s) into updates/
  [edge] 7.2.0-sky1-ncz -> linux-headers-cixmini (7.2.0-sky1-ncz+r248)

# Confirm the headers .deb actually carries the build/ tree.
$ dpkg-deb -c build/kernel-debs/linux-headers-cixmini_*.deb | head
drwxr-xr-x root/root         0  …  ./
drwxr-xr-x root/root         0  …  ./usr/
drwxr-xr-x root/root         0  …  ./usr/lib/
drwxr-xr-x root/root         0  …  ./usr/lib/modules/
drwxr-xr-x root/root         0  …  ./usr/lib/modules/7.2.0-sky1-ncz/
drwxr-xr-x root/root         0  …  ./usr/lib/modules/7.2.0-sky1-ncz/build/
-rw-r--r-- root/root    279230  …  ./usr/lib/modules/7.2.0-sky1-ncz/build/.config
…

# Confirm the postinst text was emitted with no shell-escape damage.
$ dpkg-deb -e build/kernel-debs/linux-headers-cixmini_*.deb /tmp/hdr
$ sh -n /tmp/hdr/postinst && echo "postinst syntax OK"
$ grep -c '__KVER__' /tmp/hdr/postinst       # must be 0
0
$ head -10 /tmp/hdr/postinst
#!/bin/sh
set -e
KVER="7.2.0-sky1-ncz"
[ -n "$KVER" ] || { echo "linux-headers-cixmini: empty KVER, aborting"; exit 1; }
B="/usr/lib/modules/$KVER/build"
…

# Confirm the headers .deb has the matching Depends + the right runtime deps.
$ dpkg-deb -f build/kernel-debs/linux-headers-cixmini_*.deb \
    Package Version Architecture Depends
Package: linux-headers-cixmini
Version: 7.2.0-sky1-ncz+r248
Architecture: arm64
Depends: cixmini-boot (>= 1.2+r248), kmod, make
Recommends: dkms, build-essential, flex, bison, bc, libelf-dev,
            dracut | initramfs-tools | linux-initramfs-tool

# Confirm the image .deb now depends on the headers .deb at the SAME version.
$ dpkg-deb -f build/kernel-debs/linux-image-cixmini_*.deb Depends
Depends: cixmini-boot (>= 1.2+r248), linux-headers-cixmini (= 7.2.0-sky1-ncz+r248),
         kmod, dracut | initramfs-tools | linux-initramfs-tool, systemd
```

### 2. The on-target install flow (disposable board)

```sh
# Confirm apt will pull both packages together.
$ apt-cache policy linux-image-cixmini linux-headers-cixmini
linux-image-cixmini:
  Installed: (none)
  Candidate: 7.2.0-sky1-ncz+r248
linux-headers-cixmini:
  Installed: (none)
  Candidate: 7.2.0-sky1-ncz+r248

# Install the kernel (pulls headers as a Depends).
$ sudo apt install linux-image-cixmini
…
Setting up linux-headers-cixmini (7.2.0-sky1-ncz+r248) …
linux-headers-cixmini[7.2.0-sky1-ncz]: release string OK (7.2.0-sky1-ncz)
linux-headers-cixmini[7.2.0-sky1-ncz]: host tools already native
linux-headers-cixmini[7.2.0-sky1-ncz]: running dkms autoinstall -k 7.2.0-sky1-ncz
linux-headers-cixmini[7.2.0-sky1-ncz]: dkms autoinstall OK
           cix-gpu-kmd/1.0, 7.2.0-sky1-ncz, aarch64: installed
           panthor-cix/7.2.0, 7.2.0-sky1-ncz, aarch64: installed
           cix-vpu-driver/1.0.2-ncz1, 7.2.0-sky1-ncz, aarch64: installed
           aipu/6.2.0, 7.2.0-sky1-ncz, aarch64: installed
linux-headers-cixmini[7.2.0-sky1-ncz]: regenerating initrd via dracut
linux-headers-cixmini[7.2.0-sky1-ncz]: initrd regenerated (dracut)
linux-headers-cixmini[7.2.0-sky1-ncz]: OTA-DKMS-HEADER-FIX sequence complete
Setting up linux-image-cixmini (7.2.0-sky1-ncz+r248) …

# VERIFY, BEFORE REBOOT, that every DKMS module is now stamped against the
# new kernel. THIS IS THE GATING CHECK. If the vermagic here is wrong the
# fix is broken and a reboot will land the same broken system r246/r247
# produced.
$ for m in /usr/lib/modules/7.2.0-sky1-ncz/updates/{mali_kbase,memory_group_manager,protected_memory_allocator}.ko \
         /var/lib/dkms/panthor-cix/7.2.0/*/updates/dkms/panthor.ko* \
         /var/lib/dkms/cix-vpu-driver/1.0.2-ncz1/*/updates/dkms/amvx.ko* \
         /var/lib/dkms/aipu/6.2.0/*/updates/dkms/aipu.ko*; do
    [ -e "$m" ] || continue
    v=$(modinfo -F vermagic "$m" | awk '{print $1}')
    if [ "$v" = "7.2.0-sky1-ncz" ]; then
        echo "OK   $m   $v"
    else
        echo "FAIL $m   $v   (expected 7.2.0-sky1-ncz)"
    fi
done

# VERIFY the initrd was actually rebuilt and contains the new modules.
$ lsinitramfs /boot/initrd.img-7.2.0-sky1-ncz | grep -E 'updates/(mali_kbase|memory_group_manager|protected_memory_allocator|panthor|amvx|aipu)\.ko'
usr/lib/modules/7.2.0-sky1-ncz/updates/mali_kbase.ko
usr/lib/modules/7.2.0-sky1-ncz/updates/memory_group_manager.ko
usr/lib/modules/7.2.0-sky1-ncz/updates/protected_memory_allocator.ko
usr/lib/modules/7.2.0-sky1-ncz/updates/panthor.ko
usr/lib/modules/7.2.0-sky1-ncz/updates/amvx.ko
usr/lib/modules/7.2.0-sky1-ncz/updates/aipu.ko

# dkms status should show the four CIX packages all installed for the new
# kernel -- NOT added, NOT built-but-not-installed.
$ dkms status
cix-gpu-kmd/1.0, 7.2.0-sky1-ncz, aarch64: installed
panthor-cix/7.2.0, 7.2.0-sky1-ncz, aarch64: installed
cix-vpu-driver/1.0.2-ncz1, 7.2.0-sky1-ncz, aarch64: installed
aipu/6.2.0, 7.2.0-sky1-ncz, aarch64: installed
```

If every line in the vermagic loop is `OK`, the fix is working. The board
can now be rebooted; the GPU will initialise against `mali_kbase` (not
llvmpipe), the VPU will be the DKMS `amvx` (not the older in-tree
fallback), and the NPU will be the real 6.2.0 driver.

### 3. Failure modes the postinst catches

The postinst is intentionally loud in the failure modes that produced
r246/r247:

- **`include/config/kernel.release` ≠ `$KVER`** → the postinst aborts
  with `Refusing to run dkms autoinstall -- investigate the headers
  tree`. Cause: a Yocto recipe that misapplies `KERNEL_LOCALVERSION`,
  or a tarball produced from a non-staged build. Fix: re-run
  `extract-kernel-headers.sh` against a clean build.

- **`dkms autoinstall` returns non-zero** → the postinst aborts with
  the last 30 lines of `/var/log/ncz-dkms-autoinstall.log` and the
  current `dkms status`. Cause: a DKMS source no longer compiles
  against this kernel. Fix: investigate `/var/lib/dkms/<pkg>/<ver>/build/make.log`
  for the named package; do **not** reboot into a half-built state.

- **Neither `dracut` nor `update-initramfs` present** → the postinst
  warns and does not regenerate the initrd, but the package install
  itself succeeds (the kernels/modules/ are on disk; the operator has
  the rest of a working system minus the initrd). Cause: a chroot or
  rescue image missing both builders. Fix: install at least one
  builder and re-run `apt install --reinstall linux-headers-cixmini`.

- **`set -e` is honored throughout**, so any uncaught failure aborts
  the postinst and surfaces as a dpkg error in the apt transaction.
  An installed board that finds itself in a half-configured state can
  recover with `apt install -f` or `dpkg --configure -a`, both of
  which re-run the postinst from the top.

## What the operator is no longer expected to do

The manual remediation that produced two working r246/r247 boards but
should never have to be repeated:

```sh
# (OLD, no longer required)
$ sudo -i
# cp /cdrom/cixmini/assets/kernel/edge/headers-cixmini.tar.zst /tmp/
# mkdir -p /usr/src
# tar --zstd -xf /tmp/headers-cixmini.tar.zst -C /usr
# cd /usr/lib/modules/$(uname -r)/build
# make ARCH=arm64 modules_prepare           # late failure on kernel/bounds.s is harmless
# for pkg in cix-gpu-kmd/1.0 panthor-cix/7.2.0 cix-vpu-driver/1.0.2-ncz1 aipu/6.2.0; do
#     dkms remove $pkg -k $(uname -r)
#     dkms install $pkg -k $(uname -r) --force
# done
# dracut -f
# reboot
```

None of those steps is required after r248, on a board that took the
.deb through `apt install` cleanly. If the postinst failed visibly,
fix whatever the postinst reported; if the postinst succeeded, the
operator's job is to reboot.

## Cross-references

- The fix lives in [`build/build-kernel-debs.sh:build_headers_deb()`](../build/build-kernel-debs.sh);
  the postinst heredoc is the file the fix ultimately reduces to.
- The headers tarball itself is produced by
  [`build/extract-kernel-headers.sh`](../build/extract-kernel-headers.sh);
  the on-target repair of the foreign-host-tools defect the tarball
  introduces is what the new postinst duplicates inline (so the OTA
  path is independent of `post-install/79-dkms-prep.sh`).
- The post-install DKMS registration that the new postinst now makes
  idempotent is [`post-install/86-cix-dkms-register.sh`](../post-install/86-cix-dkms-register.sh);
  the operator-facing version of the r246/r247 fix is
  `post-install/79-dkms-prep.sh` (also referenced inline from the
  postinst so the OTA path does not depend on a hook that has not
  run on a pre-existing install).
