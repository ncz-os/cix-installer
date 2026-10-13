# NCZ-OS kernel source and build recipes

This directory, together with the public repositories listed below, is the
complete corresponding source for the Linux kernels shipped in NCZ-OS images,
provided under the GNU General Public License, version 2. It is the in-repo
record; every part listed here can also be fetched anonymously from a public
URL (no account, no credentials).

## 26.10 "Cygnus" Preview 1 (current)

Images `ncz-os-arm64-20261012-f64cba5` and `ncz-os-amd64-20261012-07c0644`
each ship exactly **one** kernel. The default, installer and rescue boot
entries all use it.

### arm64: `7.3.0-rc7-sky1-ncz` (build r289)

Packages `linux-image-cixmini` / `linux-headers-cixmini`
`7.3.0-rc7-sky1-ncz+r289` (`uname -r` = `7.3.0-rc7-sky1-ncz`).

| Part | Where | Exact revision |
|---|---|---|
| Upstream base | `https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git` | tag `v7.3-rc7`, commit `24a19b953e2a3d0ea5a8c4951a0ab8f32720c907` (tag object `ec8bf8280261294a9b9b4520414b42704c7f9f6b`, which is what the recipe's `SRCREV_kernel` names) |
| Patch series, defconfig, recipe | **this directory**: `linux-cix-sky1-ncz/linux-cix-sky1-ncz_7.3-rc7.bb` and `linux-cix-sky1-ncz/linux-cix-sky1-ncz-7.3-rc7/` | copied from `https://gitlab.com/ncz-os/meta-cix`, tag `kernel-sky1-7.3.0-rc7-r289` = commit `6b6b55aa13a877ff8083592048f0a6043703c26a` |
| As-built `.config` | `linux-cix-sky1-ncz/linux-cix-sky1-ncz-7.3-rc7/config-7.3.0-rc7-sky1-ncz.as-built` | sha256 `67bb71093fb073cb3e9d64a5de42b2947df6ad9b7cc7c6f8b9c6105718b1aa97` (the `/boot/config-*` of the shipped binary) |
| Complete patched tree, as one git commit | `https://gitlab.com/ncz-os/linux-cix`, branch `release/sky1-7.3.0-rc7-r289`, tag `kernel-sky1-7.3.0-rc7-r289-src` | commit `b275222cfc5703fb5595398a216b495ca7d6ee7a`, tree `73e5887e01f7cf9e9a9cd43453f8f098ea2a3cef` |
| Port history (207 commits on the base) | `https://gitlab.com/ncz-os/linux-cix`, branch `kernel-73rc7-port-20261011` | commit `e53244fffc0bcea79e6d2ccd357cbb6d06a856d7` |
| Debian packaging | `build/build-kernel-debs.sh` in this repository | the Preview 1 commit |
| Out-of-tree accelerator modules (`mali_kbase`, `memory_group_manager`, `protected_memory_allocator`, `panthor`, `aipu`, `amvx`) | `assets/kernel/{mali,panthor,npu,vpu}/` in this repository; each `<kver>/SOURCE.sha256` binds the shipped `.ko` to its source | built by `build/build-accel-overlays.sh`, packaged by `build/build-dkms-debs.sh` |

The patch series is the Sky1 port patch (`sky1-ncz-v7.3-rc7-port.patch`)
followed by `0001`-`0011` and `0013`-`0021`, applied in the order of the
recipe's `SRC_URI` (21 patches). Applying them to the base commit gives git tree
`73e5887e01f7cf9e9a9cd43453f8f098ea2a3cef`, which is exactly the tree of the
`linux-cix` commit above; the port patch alone gives exactly the tree of
`kernel-73rc7-port-20261011`.

The patch files and the as-built config are byte-identical copies.
The recipe and the defconfig are copies whose **comment lines** were made
generic (they mentioned internal build hosts); no functional line differs.
`linux-cix-sky1-ncz-7.3-rc7/PROVENANCE.tsv` lists every file with its sha256
and, for the two edited files, the sha256 of the meta-cix original.

#### Rebuild without Yocto

```sh
git clone --branch release/sky1-7.3.0-rc7-r289 https://gitlab.com/ncz-os/linux-cix.git
cd linux-cix
cp /path/to/kernel-source/linux-cix-sky1-ncz/linux-cix-sky1-ncz-7.3-rc7/config-7.3.0-rc7-sky1-ncz.as-built .config
make ARCH=arm64 LOCALVERSION=-sky1-ncz olddefconfig
make ARCH=arm64 LOCALVERSION=-sky1-ncz Image modules dtbs -j"$(nproc)"
```

`LOCALVERSION=-sky1-ncz` reproduces the shipped release string (the recipe's
`KERNEL_LOCALVERSION`); the config itself leaves `CONFIG_LOCALVERSION` empty.
On a non-arm64 host add `CROSS_COMPILE=aarch64-linux-gnu-`.

Or start from mainline and apply the series yourself:

```sh
git clone --branch v7.3-rc7 --depth 1 https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
cd linux
K=/path/to/kernel-source/linux-cix-sky1-ncz
for p in $(grep -oE 'file://[^ ]+\.patch' "$K/linux-cix-sky1-ncz_7.3-rc7.bb" | sed 's,file://,,'); do
    patch -p1 < "$K/linux-cix-sky1-ncz-7.3-rc7/$p"
done
```

The shipped binary was built with GCC 15.3.0 and binutils 2.46.1 under Yocto
(`MACHINE=cixmini`, recipe `linux-cix-sky1-ncz`). The recipe's `SRC_URI`
fetches the kernel from a local mirror of the `linux-cix`
`kernel-73rc7-port-20261011` branch; to build with Yocto from public sources,
point that `git://` entry at `https://gitlab.com/ncz-os/linux-cix.git`
(`protocol=https`) and keep `SRCREV_kernel`.

### amd64: `7.3.0-rc7-t2-ncz` (package revision `7.3.0-rc7-2`)

Packages `linux-image-7.3.0-rc7-t2-ncz` / `linux-headers-7.3.0-rc7-t2-ncz`
`7.3.0-rc7-2`. The kernel serves Apple T2 Macs and generic PCs alike.

| Part | Where | Exact revision |
|---|---|---|
| Upstream base | `https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git` | tag `v7.3-rc7`, commit `24a19b953e2a3d0ea5a8c4951a0ab8f32720c907` |
| Patch series (24 patches, t2linux plus NCZ), resolved config, build and packaging script, verification script | `https://gitlab.com/ncz-os/linux-t2-ncz` | tag `v7.3.0-rc7-t2-ncz-2`, commit `35249a98c7ad2f07cf2d0055a3be3c0c40f5b506` |
| T2 DKMS modules (`t2smc`, `t2gmux`, `t2thunderbolt`, `t2smp`) | `assets/kernel/t2smc/`, `t2gmux/`, `t2thunderbolt/`, `t2smp/` in this repository | the Preview 1 commit |

The source tree from `linux-t2-ncz` (base plus `patches/series`) is git tree
`451b5dfee3eb77e15dac561766000bc3ec2e4f41`. Its `config/` file has the same
sha256 (`e88c4505d5c4a9fce3720eb0ba2892aede33f12080865cb45bfbee2acc09219a`) as
`/boot/config-7.3.0-rc7-t2-ncz` in the shipped package. To reproduce that tree
id, run the repository's `verify.sh`, which applies the series the way the build
did; other ways of applying the patches (for example a plain `git apply` loop)
can give a different tree id. The README gives the build commands.

The amd64 kernel is not vendored in this directory; `linux-t2-ncz` is its
corresponding-source repository.

## Older releases

GPLv2 section 3 obliges us to keep source available for binaries distributed
in earlier releases, so the trees below stay here. **None of them is shipped
in 26.10.**

| Path | Shipped in |
|---|---|
| `linux-cix-sky1-ncz_7.2.bb`, `linux-cix-sky1-ncz-7.2/` | 26.7 "Maximilian" (`7.2.0-sky1-ncz`) |
| `linux-cix-sky1-ncz-7.1.1/`, `linux-cix-sky1-ncz_7.1.1.bb` | pre-26.7 |
| `linux-cix-sky1-ncz_7.1.2.bb` | pre-26.7 |
| `linux-cix-sky1-ncz_6.18.26.bb` | pre-26.7 |

### 26.7: `7.2.0-sky1-ncz`

- **KERNELRELEASE (as shipped):** `7.2.0-sky1-ncz`. The upstream base is
  v7.2-rc7, but the shipped kernel carries the release localversion.
- **Base:** mainline Linux v7.2-rc7 from
  `git://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git` at
  commit `db2ddb87143519e20a95aa36c60b36107b736a58`. Earlier bases, kept for
  continuity: v7.2-rc4 `1590cf0329716306e948a8fc29f1d3ee87d3989f`, v7.2-rc5
  `f5098b6bae761e346ebcd9da7f95622c04733cff`, v7.2-rc6
  `075b74841bd0065a3bda3440873c747938e69b68`.
- **Delta:** 176 patches wired into the recipe's `SRC_URI`, out of 197 files in
  `linux-cix-sky1-ncz-7.2/patches-7.2/` (the other 21 are superseded or
  experimental and are not applied), plus `config-7.2-lean-msr1-o6n.defconfig`.
  Apply them in `SRC_URI` order, which is not plain filename order.
- **As-built configuration:** `linux-cix-sky1-ncz-7.2/config-7.2.0-sky1-ncz.as-built`
  is the expanded `.config` used for the shipped binary.

```sh
git clone git://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
cd linux
git checkout db2ddb87143519e20a95aa36c60b36107b736a58
for p in $(grep -oE 'patches-7\.2/[0-9]+-[^ \\]+\.patch' /path/to/kernel-source/linux-cix-sky1-ncz/linux-cix-sky1-ncz_7.2.bb); do
    git am -3 --keep-non-patch "/path/to/kernel-source/linux-cix-sky1-ncz/linux-cix-sky1-ncz-7.2/${p}"
done
cp /path/to/kernel-source/linux-cix-sky1-ncz/linux-cix-sky1-ncz-7.2/config-7.2.0-sky1-ncz.as-built .config
make ARCH=arm64 olddefconfig
make ARCH=arm64 Image modules -j"$(nproc)"
```

26.7 shipped the CIX `mali_kbase` GPU driver as a DKMS module (source in
`assets/kernel/mali/src`, upstream `cixtech/cix_opensource__gpu_kernel`) with
one local patch, `assets/kernel/mali/mali-kbase-scmi-ratelimit.patch`.
`CORRESPONDING-SOURCE.md` records the self-mirrored pristine base archives for
the 7.2 and 7.0.12 lines.

## Written offer

This offer is valid for three years from the date of distribution, to any third party, for no more than the cost of physically performing source distribution: we will provide the complete corresponding machine-readable source of the GPL/LGPL components of any NCZ-OS binary we distributed. To ask, open an issue at <https://gitlab.com/ncz-os/cix-installer/-/issues> or email jperlow@gmail.com. The kernel source is this directory and the public repositories named above.
