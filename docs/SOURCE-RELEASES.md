<p align="center">
  <img src="../assets/branding/logo/ncz.png" alt="NCZ-OS" width="96">
</p>

# Source releases — what we build, and where its source is

> **🌐 Language:** English · [简体中文](SOURCE-RELEASES.zh-CN.md)

NCZ-OS redistributes GPL/LGPL software and builds several components from
modified source. This page is the authoritative index of **everything in the
shipped image that we compiled ourselves**, with the source location for each.

If something we ship is built from source and is not listed here, that is a
bug in this document — please open an issue.

**GitLab is canonical for source** (`gitlab.com/ncz-os/cix-installer`).
Release images are hosted as release assets on the GitHub mirror
(`github.com/ncz-os/cix-installer/releases`), and the documentation points
there for downloads.

---

## Scope: what is ours vs what is the vendor's

| Category | Source obligation |
|---|---|
| Components **we** build from source (below) | **Ours.** Source published here. |
| CIX proprietary vendor `.deb`s (current reviewed ledger: 25 vendor originals in `manifests/vendor-debs.tsv` plus 1 NCZ-repacked NPU DKMS in `manifests/ncz-packages.tsv`; older releases shipped a larger set) | **Not ours.** Vendor-proprietary binaries redistributed under vendor terms. We do not hold or republish their source. The NCZ-repacked NPU DKMS carries our packaging recipe. |
| Stock Debian forky packages | Debian's. Available from `deb.debian.org` per Debian's own terms. |

---

## Components built from source in 26.10 "Cygnus" Preview 1

Images `ncz-os-arm64-20261012-f64cba5` and `ncz-os-amd64-20261012-07c0644`.
Versions are taken from the reviewed NCZ build ledger,
[`manifests/ncz-packages.tsv`](../manifests/ncz-packages.tsv), at tag
`v26.10-preview1`.

| Component | Shipped version | License | Source |
|---|---|---|---|
| **Linux kernel, Sky1 (arm64)** | `7.3.0-rc7-sky1-ncz` (package `linux-image-cixmini` `7.3.0-rc7-sky1-ncz+r289`) | GPL-2.0 | Yocto recipe `linux-cix-sky1-ncz_7.3-rc7.bb` (build r289) in [`ncz-os/meta-cix`](https://gitlab.com/ncz-os/meta-cix): mainline v7.3-rc7 plus the Sky1 port patch and 20 numbered patches. The in-repo [`kernel-source/`](../kernel-source/SOURCE.md) drop still describes the 7.2 kernel of 26.7; see the note below. |
| **Linux kernel, amd64 (T2 Macs and PCs)** | `7.3.0-rc7-t2-ncz` (package `7.3.0-rc7-2`) | GPL-2.0 | [`ncz-os/amd64-kernel-t2`](https://gitlab.com/ncz-os/amd64-kernel-t2), branch `feat/t2-7.3-rc7-r2-20261012`: mainline v7.3-rc7 plus the t2linux patch series and our T2 fixes. |
| **cix-installer** (installer, preseed, post-install hooks, build scripts) | `v26.10-preview1` | see repo | **This repository**, tag `v26.10-preview1`. |
| **cixmini-boot** | `1.2+r289` | GPL-2.0 | Boot/firmware glue for Sky1 boards, built by `build/build-kernel-debs.sh`. |
| **ncz-ffmpeg** (arm64) | `9.0.1-ncz3` | LGPL-2.1+/GPL-2+ | FFmpeg with Sky1 V4L2 M2M support; patches under [`docs/upstream-patches/ffmpeg/`](upstream-patches/ffmpeg/). |
| **chromium-ncz-sky1** (arm64) | `154.0.8037.0-ncz20261011` | BSD-3-Clause + others | Chromium with Sky1 V4L2 decode fixes; patches under [`docs/upstream-patches/chromium/`](upstream-patches/chromium/). |
| **ncz-singularity-desktop** | built per image from pinned upstream commits | see upstream | Singularity desktop (labwc/wlroots) from `singularityos-lab`, with our packaging and the patches under [`assets/singularity/patches/`](../assets/singularity/patches/). |
| **ncz-screensavers**, **ncz-screensavers-plugin** | `0.8.12`, `0.3.20` | see upstream | NCZ screensaver engine and its Singularity settings page. |
| **libdrm** (patched) | `2.4.134-3+ncz2` | MIT | Debian libdrm plus `libdrm-xf86drm-acpi-platform-identity.patch` (in `docs/upstream-patches/`). |
| **DKMS accelerator packages** | `cix-gpu-kmd-dkms 1.0+ncz2`, `panthor-cix-dkms 7.2.0+ncz2`, `cix-vpu-driver-dkms 1.0.2-ncz1+ncz2`, `cix-npu-driver-dkms 6.2.0-cixdeb13-260714+ncz3` | GPL-2.0 | DKMS packages ship their module source in the package itself (`/usr/src`). |
| **Patched d-i udebs** | `debootstrap-udeb 1.0.145`, `apt-setup`/`partman-*`/`mdcfg`/`nobootloader` `+ncz1` | GPL | Debian sources plus the patches recorded for each row in `manifests/ncz-packages.tsv`. |

> **Open item for Preview 1 — kernel source drop.** The in-repo
> `kernel-source/` directory has not yet been refreshed from the 7.2 tree to
> the 7.3-rc7 trees above, and the r289 Sky1 recipe is still being published to
> `meta-cix` (its public branches stop at r284 as of 2026-10-13). Until then, the amd64 kernel source is in
> `amd64-kernel-t2` (branch above) and the Sky1 source is available on request. If
> you cannot find the exact source for a binary you received, open an issue and we
> will publish it.

## Components built from source in 2026.08.18-v12 (26.7, historical)


| Component | Shipped version | License | Source |
|---|---|---|---|
| **Linux kernel** | `7.2.0-sky1-ncz` | GPL-2.0 | **[`kernel-source/`](../kernel-source/SOURCE.md) in this repository** — a complete corresponding-source drop: 286 patch files (176 wired into `SRC_URI`), the defconfig, and the pinned upstream SRCREVs. **See "Kernel source" below.** |
| **cix-installer** (the d-i installer, preseed, post-install hooks, build scripts) | `2026.08.18-v12` | see repo | **This repository.** Tag `v2026.08.18-v12`. The installer *is* its own source release. |
| **ncz-ffmpeg** | `6.6+20260608-2` | LGPL-2.1+/GPL-2+ | Modified FFmpeg with Sky1 V4L2 multiplane support. Patch shipped in-tree at `docs/upstream-patches/ffmpeg-v4l2-multiplane.patch`. |
| **chromium-ncz-sky1** | `151.0.7922.75-ncz20260808` | BSD-3-Clause + others | Chromium with Sky1 build/runtime fixes. |
| **ncz-singularity-desktop** | `9.0.1-ncz3` | see upstream | Singularity desktop (labwc/wlroots), upstream `singularityos-lab`, with our packaging + fixes. |
| **cixmini-boot** | `0.29-3+b1` | GPL-2.0 | Boot/firmware glue for Sky1 boards. |
| **libdrm** (patched) | in `docs/upstream-patches/` | MIT | `libdrm-xf86drm-acpi-platform-identity.patch`. |

### Kernel source

The kernel is the component with the most substantive GPL obligation, because
we ship a modified binary kernel in every image.

* Upstream pristine bases are published as generic packages
  (`linux-pristine-base-cix-sky1-ncz`), so the exact unmodified starting tree
  can be obtained and diffed.
* Our patch series is applied in `SRC_URI` order — **not** filename order —
  by `build/port-series.sh`, which validates that every patch wired in the
  recipe actually applies (176/176 for the 7.2 series).
* A prior source drop could **not** rebuild the shipped kernel: 171 of 176
  patches were wired and 5 files were absent. That is fixed; the validator
  exists specifically so it cannot regress silently.

### Where the kernel source actually is

**In this repository, under [`kernel-source/`](../kernel-source/SOURCE.md).**
That directory is the corresponding source for the shipping kernel: 300 files
(9.3 MB), 286 patch files of which **176 are wired into the recipe's
`SRC_URI`**, the 7.2 lean defconfig (`config-7.2-lean-*.defconfig`), and the pinned upstream
base revisions with their kernel.org shas. It does not depend on the GitLab
package registry.

The generic packages `linux-source-cix-sky1-ncz` (`7.0.12`, `7.2-rc5`) and the
`linux-pristine-base-*` tarballs in the package registry are **supplementary**
— they let you fetch a pristine upstream tree without cloning kernel.org, and
they cover binaries distributed by earlier releases.

> **Open item for 2026.08.18-v12 — version-string mismatch.**
> `kernel-source/SOURCE.md` documents `KERNELRELEASE = 7.2.0-rc7-sky1-ncz`,
> but the shipped ISO reports `7.2.0-sky1-ncz` (`KVER_NEXT`). The source tree
> is the right one; the recorded release string is stale. Reconcile the two so
> a recipient can match the binary they have to the source they downloaded
> without having to infer it.

---

## Kernel channels — current reality

NCZ-OS 26.10 Preview 1 ships **one** kernel per image (`7.3.0-rc7-sky1-ncz` on
arm64, `7.3.0-rc7-t2-ncz` on amd64); the default, installer and rescue boot
entries all use it. There is no edge channel. The paragraphs below describe
26.7, which shipped `7.2.0-sky1-ncz`.

The older `7.0.12-cix-sky1-next` channel has been **removed from the ISO**. It
is not a fallback, not a rescue kernel, and not selectable from the boot menu.
Verified on the v12 image: `assets/kernel/` contains only `edge`, there is no
`KVER_LEGACY`, and no file on the ISO references 7.0.12.

Its source and pristine base remain published only because binaries built from
them were distributed in earlier releases, and GPLv2 §3(b) obliges us to keep
that source available to anyone who received those binaries.

---

## Requesting source

Everything above is downloadable from this project's package registry and git
history. If you received an NCZ-OS binary and cannot find its corresponding
source here, open an issue on GitLab and we will publish it.
