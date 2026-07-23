# NCZ-OS 26.7 "Maximilian" — Kernel Source & Build Recipe

This directory provides the complete, corresponding source and build recipe for
the Linux kernel shipped in NCZ-OS 26.7, in fulfilment of the GNU General Public
License (v2). Everything needed to reproduce the exact shipping kernel is here or
publicly available at the pinned upstream revisions below.

## Shipping kernel

- **KERNELRELEASE:** `7.2.0-rc4-sky1-ncz`
- **Base:** mainline Linux **v7.2-rc4**, from
  `git://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git`
  at **SRCREV `1590cf0329716306e948a8fc29f1d3ee87d3989f`** (the v7.2-rc4 tag).
- **Delta:** the CIX Sky1 (CD8180) enablement — 175 patches under
  `linux-cix-sky1-ncz/linux-cix-sky1-ncz-7.2/patches-7.2/` + the config
  `config-7.2-lean-msr1-o6n.defconfig`. Applied on top of the mainline base in
  numeric order.

## Contents

```
linux-cix-sky1-ncz/
  linux-cix-sky1-ncz_7.2.bb            # Yocto/OpenEmbedded recipe (the shipping kernel)
  linux-cix-sky1-ncz_6.18.26.bb        # LTS recipe (7.0.12-cix-sky1-next base)
  linux-cix-sky1-ncz_7.1.1.bb / _7.1.2.bb
  linux-cix-sky1-ncz-7.2/
    config-7.2-lean-msr1-o6n.defconfig # kernel config for the 7.2 ship
    patches-7.2/00xx-*.patch           # 175 CIX Sky1 enablement patches
```

## Reproduce (without Yocto)

```sh
git clone git://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
cd linux
git checkout 1590cf0329716306e948a8fc29f1d3ee87d3989f
for p in /path/to/kernel-source/linux-cix-sky1-ncz/linux-cix-sky1-ncz-7.2/patches-7.2/*.patch; do
    git apply "$p" || patch -p1 < "$p"
done
cp /path/to/kernel-source/.../config-7.2-lean-msr1-o6n.defconfig .config
make ARCH=arm64 olddefconfig
make ARCH=arm64 Image modules -j"$(nproc)"
```

## Reproduce (with Yocto)

The `.bb` recipe is the authoritative build spec. It is also maintained in the
`ncz-os/meta-cix` layer (GitLab). Build with the `ncz-yocto-y6` layer set,
`MACHINE=cixmini`, target `linux-cix-sky1-ncz`.

## Out-of-tree GPU driver (mali_kbase)

26.7 ships the CIX **mali kbase** GPU driver as a DKMS/overlay module (not
in-tree — panthor is the in-tree open driver, blacklisted on the Mali boot
entry). Upstream source: **`cixtech/cix_opensource__gpu_kernel`** (GitHub, the
CIX vendor org); **`Sky1-Linux/cix-gpu-kmd`** is the community DKMS repackage.
NCZ-OS applies one local patch on top:

- `../assets/kernel/mali/mali-kbase-scmi-ratelimit.patch` — rate-limits GPU
  SCMI DVFS requests to prevent a shared-SCP-mailbox wedge (ports the panthor
  rate-limit approach to mali kbase).

## Notable NCZ patches (submitted / pending upstream)

Upstream = the CIX vendor org **`github.com/cixtech`**:
`cix-linux-main` (kernel: amvx/VPU, panthor Sky1 patches) and
`cix_opensource__gpu_kernel` (mali kbase).

- `patches-7.2/0173-amvx-vb2-queue-lock-7.2.patch` — CIX Linlon/amvx VPU: set a
  per-port `vb2_queue.lock` before `vb2_queue_init()`. v6.x+
  `vb2_core_queue_init()` enforces a non-NULL `q->lock`, without which REQBUFS
  fails and the VPU codec is non-functional. → upstream: `cixtech/cix-linux-main`.
- `patches-7.2/0086-...gpu_core...patch` — panthor Sky1 GPU clock con_id fix
  (`gpu_core` → `gpu_clk_core`). Correct but held from panthor mode pending the
  GPU power-domain fix (a follow-up). → upstream: `cixtech/cix-linux-main`.
- The mali SCMI rate-limit patch (above). → upstream:
  `cixtech/cix_opensource__gpu_kernel`.

## Written offer

For three years from distribution, NCZ-OS will provide the complete
corresponding machine-readable source for the GPL/LGPL components of the shipped
kernel, at no charge beyond the cost of physical distribution. The source is
this directory plus the mainline base at the pinned SRCREV above. Contact:
`Jason Perlow <jperlow@gmail.com>`.
