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

**Distribution point is GitLab** (`gitlab.com/ncz-os/cix-installer`). The
GitHub repository is a documentation mirror; its download links point back
here.

---

## Scope: what is ours vs what is the vendor's

| Category | Source obligation |
|---|---|
| Components **we** build from source (below) | **Ours.** Source published here. |
| CIX proprietary vendor `.deb`s (28 packages: `cix-gpu-umd`, `cix-ai-engine`, `cix-firmware`, …) | **Not ours.** Vendor-proprietary binaries redistributed under vendor terms. We do not hold or republish their source. |
| Stock Debian forky packages | Debian's. Available from `deb.debian.org` per Debian's own terms. |

---

## Components built from source in 2026.08.18-v12

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
we ship a modified binary kernel on every ISO.

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
`SRC_URI`**, the `config-7.2-lean-msr1-o6n.defconfig`, and the pinned upstream
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

NCZ-OS 26.7 ships **one** kernel: `7.2.0-sky1-ncz`.

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
