<p align="center">
  <img src="../assets/branding/logo/ncz.png" alt="NCZ-OS" width="96">
</p>

# 源码发布 —— 我们构建了什么，源码在哪里

> **🌐 语言：** [English](SOURCE-RELEASES.md) · 简体中文

> **说明：** 本页 26.10 "Cygnus" 的内核源码部分已与[英文版](SOURCE-RELEASES.md)
> 同步；其余各节仍描述 26.7（2026.08.18-v12），以英文版为准。

## 26.10 "Cygnus"：内核对应源码

镜像 `ncz-os-arm64-20261013-d395bb2d` 与 `ncz-os-amd64-20261013-d395bb2d` 由提交 `d395bb2d` 构建。
每个镜像只带一个内核（默认、安装程序与救援启动项共用）。以下各部分均已于
2026-10-13 在无账号、无令牌的情况下用 `git ls-remote` 或 `curl` 匿名获取验证。

**arm64：`7.3.0-rc7-sky1-ncz`（构建 r289，软件包 `linux-image-cixmini` `7.3.0-rc7-sky1-ncz+r289`）**

| 组成部分 | 位置 | 版本 | 许可证 |
|---|---|---|---|
| 上游基线 | `https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git` | 标签 `v7.3-rc7`：提交 `24a19b953e2a3d0ea5a8c4951a0ab8f32720c907`（标签对象 `ec8bf828…`，即配方 `SRCREV_kernel` 的值） | GPL-2.0 |
| 配方、Sky1 移植补丁、补丁 0001-0011 与 0013-0021、defconfig | [`ncz-os/meta-cix`](https://gitlab.com/ncz-os/meta-cix) `recipes-kernel/linux-cix-sky1-ncz/linux-cix-sky1-ncz_7.3-rc7.bb` | 标签 `kernel-sky1-7.3.0-rc7-r289`（分支 `fix/sky1-r289-20261012`），提交 `7e8c821f8c7b79309af815ae0ee243bc36befa5b` | GPL-2.0（补丁），Apache-2.0（配方） |
| 上述内容的仓库内副本，以及实际构建所用的 `.config`（sha256 `67bb7109…`） | 本仓库 [`kernel-source/`](../kernel-source/SOURCE.md) | 当前提交 | GPL-2.0 |
| 打完全部补丁的完整源码树（单个提交） | [`ncz-os/linux-cix`](https://gitlab.com/ncz-os/linux-cix) | 标签 `kernel-sky1-7.3.0-rc7-r289-src`，提交 `b275222cfc5703fb5595398a216b495ca7d6ee7a`（分支 `release/sky1-7.3.0-rc7-r289`） | GPL-2.0 |
| Debian 打包 | 本仓库 `build/build-kernel-debs.sh` | 提交 `d395bb2d` | 见仓库 |
| 树外模块 `mali_kbase` 等、`panthor`、`amvx`（VPU）、`aipu`（NPU） | 本仓库 `assets/kernel/{mali,panthor,vpu,npu}/`；`assets/kernel/*/7.3.0-rc7-sky1-ncz/SOURCE.sha256` 将发布的 `.ko` 与源码绑定 | 提交 `d395bb2d` | GPL-2.0（`panthor` 为 GPL-2.0 OR MIT） |

**amd64：`7.3.0-rc7-t2-ncz`（软件包版本 `7.3.0-rc7-2`）**

| 组成部分 | 位置 | 版本 | 许可证 |
|---|---|---|---|
| 上游基线 | `https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git` | 标签 `v7.3-rc7`：提交 `24a19b953e2a3d0ea5a8c4951a0ab8f32720c907` | GPL-2.0 |
| 补丁系列（24 个：t2linux 补丁与我们的 T2 修复）、最终 config、构建与打包脚本、`verify.sh` | [`ncz-os/linux-t2-ncz`](https://gitlab.com/ncz-os/linux-t2-ncz) | 标签 `v7.3.0-rc7-t2-ncz-2`，提交 `35249a98c7ad2f07cf2d0055a3be3c0c40f5b506` | GPL-2.0 |
| T2 DKMS 模块 `t2smc`、`t2gmux`、`t2thunderbolt`、`t2smp` | 本仓库 `assets/kernel/t2*/` | 提交 `d395bb2d` | GPL-2.0 |

`linux-t2-ncz` 中的 config 与所发布软件包里的 `/boot/config-7.3.0-rc7-t2-ncz` 逐字节相同
（sha256 `e88c4505…`）。amd64 内核软件包同时在公开的 NCZ apt 仓库中，sha256 与构建记录一致。

**安装程序 initrd 与其他 GPL 二进制：** `debootstrap-udeb` 由 `build/iso/patch-debootstrap-stub.py`
修改；`+ncz1` 的 udeb 是未改动的 Debian sid 源码（`snapshot.debian.org`，`20261005T120000Z`），
由 `build/rebuild-sid-udeb.sh` 重新构建；`assets/diag/busybox-*` 是未改动的 Ubuntu
`busybox-static` 二进制（amd64 `1:1.36.1-6ubuntu3.1`、arm64 `1:1.37.0-7ubuntu1`），源码见 Launchpad。

**重建镜像：** 上述 GPL 源码是完整的，但逐字节重建镜像目前**无法**仅凭公开来源完成。
`manifests/build-inputs.tsv` 中的 44 个预置输入里，只有 6 个（两种架构的 CPython 3.11 与 `uv`、
`ncz-screensavers` 0.8.13）能从公开地址取得完全相同的字节，见
`manifests/build-inputs-public.tsv` 与 `build/stage-build-inputs.sh --public`。其余输入的分类见英文版
"Rebuilding an image: what you can fetch" 一节。

NCZ-OS 分发 GPL/LGPL 软件，并从修改过的源码构建若干组件。本页是**所发布镜像中一切
由我们自行编译的内容**的权威索引，并给出各自的源码位置。

如果我们发布的某个组件是从源码构建的却未列于此，那是本文档的缺陷——请提交 issue。

**源码以 GitLab 为准**（`gitlab.com/ncz-os/cix-installer`）。发布镜像作为 GitHub 镜像仓库的
release 附件托管（`github.com/ncz-os/cix-installer/releases`），文档中的下载链接指向那里。

---

## 范围：哪些是我们的，哪些是厂商的

| 类别 | 源码义务 |
|---|---|
| **我们**从源码构建的组件（见下表） | **属于我们。** 源码在此发布。 |
| CIX 专有厂商 `.deb`（28 个包：`cix-gpu-umd`、`cix-ai-engine`、`cix-firmware` 等） | **不属于我们。** 依厂商条款再分发的厂商专有二进制。我们既不持有也不再发布其源码。 |
| Debian forky 原版软件包 | 属于 Debian。依 Debian 自身条款从 `deb.debian.org` 获取。 |

---

## 2026.08.18-v12 中由源码构建的组件

| 组件 | 发布版本 | 许可证 | 源码 |
|---|---|---|---|
| **Linux 内核** | `7.2.0-sky1-ncz` | GPL-2.0 | **本仓库中的 [`kernel-source/`](../kernel-source/SOURCE.md)** —— 完整的对应源码交付：286 个补丁文件（其中 176 个接入 `SRC_URI`）、defconfig，以及锁定的上游 SRCREV。见下文"内核源码"。 |
| **cix-installer**（d-i 安装程序、preseed、安装后钩子、构建脚本） | `2026.08.18-v12` | 见仓库 | **本仓库。** 标签 `v2026.08.18-v12`。安装程序本身即是其源码发布。 |
| **ncz-ffmpeg** | `6.6+20260608-2` | LGPL-2.1+/GPL-2+ | 带 Sky1 V4L2 multiplane 支持的修改版 FFmpeg。补丁随仓库提供，位于 `docs/upstream-patches/ffmpeg-v4l2-multiplane.patch`。 |
| **chromium-ncz-sky1** | `151.0.7922.75-ncz20260808` | BSD-3-Clause 及其他 | 带 Sky1 构建与运行时修复的 Chromium。 |
| **ncz-singularity-desktop** | `9.0.1-ncz3` | 见上游 | Singularity 桌面（labwc/wlroots），上游为 `singularityos-lab`，含我们的打包与修复。 |
| **cixmini-boot** | `0.29-3+b1` | GPL-2.0 | Sky1 主板的引导/固件胶合层。 |
| **libdrm**（已打补丁） | 见 `docs/upstream-patches/` | MIT | `libdrm-xf86drm-acpi-platform-identity.patch`。 |

### 内核源码

内核是 GPL 义务最实质的组件，因为我们在每一张 ISO 上都分发一个修改过的二进制内核。

**源码就在本仓库的 [`kernel-source/`](../kernel-source/SOURCE.md) 目录下。** 该目录
是所发布内核的对应源码：300 个文件（9.3 MB）、286 个补丁文件（其中 **176 个接入配方
的 `SRC_URI`**）、7.2 精简 defconfig（`config-7.2-lean-*.defconfig`），以及锁定的上游基线版本及其
kernel.org 提交哈希。它不依赖 GitLab 软件包注册表。

补丁按 **`SRC_URI` 顺序**应用——**而非文件名顺序**。`build/port-series.sh` 会校验
配方中接入的每一个补丁确实可以应用（7.2 系列为 176/176）。

软件包注册表中的通用包 `linux-source-cix-sky1-ncz`（`7.0.12`、`7.2-rc5`）与
`linux-pristine-base-*` 压缩包是**补充性**的——它们让你无需克隆 kernel.org 即可取得
纯净上游树，并覆盖早期版本所分发的二进制。

> **2026.08.18-v12 的待办事项 —— 版本字符串不一致。**
> `kernel-source/SOURCE.md` 记录的是 `KERNELRELEASE = 7.2.0-rc7-sky1-ncz`，而所发布
> 的 ISO 报告为 `7.2.0-sky1-ncz`（`KVER_NEXT`）。源码树本身是正确的；记录下来的发布
> 字符串是过时的。需要将两者对齐，使接收者不必靠推断就能把手上的二进制与下载到的
> 源码对应起来。

---

## 内核通道 —— 当前实际情况

NCZ-OS 26.7 只发布**一个**内核：`7.2.0-sky1-ncz`。

较早的 `7.0.12-cix-sky1-next` 通道**已从 ISO 中移除**。它不是回退方案、不是救援内核，
也无法从引导菜单中选择。已在 v12 镜像上核实：`assets/kernel/` 中只有 `edge`，不存在
`KVER_LEGACY`，且 ISO 上没有任何文件引用 7.0.12。

其源码与纯净基线之所以仍在发布，仅仅因为早期版本分发过由它们构建的二进制，而
GPLv2 §3(b) 要求我们对已获得这些二进制的人持续提供源码。

---

## 索取源码

以上全部内容均可从本项目的软件包注册表与 git 历史中下载。如果你拿到了某个 NCZ-OS
二进制，却在此找不到其对应源码，请在 GitLab 上提交 issue，我们会将其发布。

**书面要约。** 本要约自分发之日起三年内有效，适用于任何第三方，收费不超过实际执行源码分发的成本：我们将提供我们分发的任何 NCZ-OS 二进制中 GPL/LGPL 组件的完整、机器可读的对应源码。如需索取，请在 <https://gitlab.com/ncz-os/cix-installer/-/issues> 提交 issue，或发邮件至 jperlow@gmail.com。
