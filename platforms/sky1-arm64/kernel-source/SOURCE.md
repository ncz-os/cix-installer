# NCZ-OS 26.7 "Maximilian" — Kernel Source & Build Recipe

This directory provides the complete, corresponding source and build recipe for
the Linux kernel shipped in NCZ-OS 26.7, in fulfilment of the GNU General Public
License (v2). Everything needed to reproduce the exact shipping kernel is here or
publicly available at the pinned upstream revisions below.


## Historical kernel trees in this directory

Alongside the shipping 7.2 tree, this directory retains recipes and a patch
tree for kernels that **earlier releases** shipped:

| Path | Shipped in |
|---|---|
| `linux-cix-sky1-ncz-7.1.1/`, `linux-cix-sky1-ncz_7.1.1.bb` | superseded pre-26.7 line |
| `linux-cix-sky1-ncz_7.1.2.bb` | superseded pre-26.7 line |
| `linux-cix-sky1-ncz_6.18.26.bb` | superseded pre-26.7 line |

**None of these is shipped in 26.7.** They are kept because GPLv2 §3(b)
obliges us to keep corresponding source available to anyone who received a
binary built from them. Do not treat their presence as evidence of a supported
kernel channel — 26.7 ships exactly one kernel, `7.2.0-sky1-ncz`.

## Shipping kernel

> **As-built configuration.** `linux-cix-sky1-ncz-7.2/config-7.2.0-sky1-ncz.as-built`
> is the **expanded `.config` actually used to build the shipped binary**, not a
> defconfig. It is included because a defconfig plus a kernel version does not
> uniquely determine a `.config` — kconfig defaults change between revisions —
> so shipping only the defconfig would leave a gap in the corresponding source.
> `config-7.2-lean-msr1-o6n.defconfig` remains the human-maintained input.


- **KERNELRELEASE (as shipped):** `7.2.0-sky1-ncz`
  The upstream base is v7.2-rc7, but the shipped kernel carries the release
  localversion, not an rc one. `uname -r` on an installed system reports
  `7.2.0-sky1-ncz`; that is the string to match against this source drop.
- **Base:** mainline Linux **v7.2-rc7**, from
  `git://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git`
  at **SRCREV `db2ddb87143519e20a95aa36c60b36107b736a58`** (the v7.2-rc7 tag
  commit -- the commit, not the annotated tag object).

  Base history, retained for GPL corresponding-source continuity:
  v7.2-rc4 `1590cf0329716306e948a8fc29f1d3ee87d3989f` ->
  v7.2-rc5 `f5098b6bae761e346ebcd9da7f95622c04733cff` (2026-07-26) ->
  v7.2-rc6 `075b74841bd0065a3bda3440873c747938e69b68` (2026-08-02) ->
  v7.2-rc7 `db2ddb87143519e20a95aa36c60b36107b736a58` (2026-08-16).
  All four shas verified against git.kernel.org on 2026-08-16.
- **Delta:** the CIX Sky1 (CD8180) enablement — **176 patches** actually wired
  into the recipe's `SRC_URI`, out of 197 files present (the `patches-7.2/`
  directory also holds 21 superseded/experimental patches the recipe does not
  reference) under
  `linux-cix-sky1-ncz/linux-cix-sky1-ncz-7.2/patches-7.2/` + the config
  `config-7.2-lean-msr1-o6n.defconfig`. Applied on top of the mainline base in
  the exact order listed in the recipe's `SRC_URI` (not plain numeric/alpha
  filename order -- a handful of later fixups are interleaved earlier in the
  series). 169 of the 170 applied byte-identical onto the rc5 base (the rc4->rc5
  diff touches zero files this series modifies); one patch (0184) had a
  pre-existing malformed hunk unrelated to the rebase and was corrected.

> **Provenance.** This directory is a copy of the tree that actually builds the
> shipping kernel: `meta-cix/recipes-kernel/linux-cix-sky1-ncz/` in the
> `ncz-os/meta-cix` layer, as checked out on the build host. It was re-synced on
> 2026-08-16 after an audit found it had drifted: the published recipe wired 171
> patches while the build recipe wired 176, five patch FILES were absent
> entirely (0190, 0191, 0192, 0193, 0200), and the published defconfig still had
> `CONFIG_ARMCHINA_NPU=m` — which the build tree deliberately removed, because
> an in-tree copy claims the driver symbols first and stops the vendor DKMS
> module (`cix-npu-kmd`) from loading at all. Following the stale copy would
> therefore have produced a kernel with a non-functional NPU, which is precisely
> what a corresponding-source tree must not do. Re-verify this directory against
> the build tree whenever the kernel is rebased.

## Contents

```
linux-cix-sky1-ncz/
  linux-cix-sky1-ncz_7.2.bb            # Yocto/OpenEmbedded recipe (the shipping kernel)
  linux-cix-sky1-ncz_6.18.26.bb        # LTS recipe (7.0.12-cix-sky1-next base)
  linux-cix-sky1-ncz_7.1.1.bb / _7.1.2.bb
  linux-cix-sky1-ncz-7.2/
    config-7.2-lean-msr1-o6n.defconfig # kernel config for the 7.2 ship
    patches-7.2/00xx-*.patch           # CIX Sky1 enablement patches (176 of 197 wired into SRC_URI; see recipe)
```

## Reproduce (without Yocto)

```sh
git clone git://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
cd linux
git checkout db2ddb87143519e20a95aa36c60b36107b736a58
# Apply in the exact order listed in linux-cix-sky1-ncz_7.2.bb's SRC_URI --
# NOT plain `for p in patches-7.2/*.patch`, the directory holds a few
# superseded/experimental patches the recipe does not use, and the shipping
# order is not pure filename order.
for p in $(grep -oE 'patches-7\.2/[0-9]+-[^ \\]+\.patch' /path/to/kernel-source/linux-cix-sky1-ncz/linux-cix-sky1-ncz_7.2.bb); do
    git am -3 --keep-non-patch "/path/to/kernel-source/linux-cix-sky1-ncz/linux-cix-sky1-ncz-7.2/${p}"
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
