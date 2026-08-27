<p align="center">
  <img src="../assets/branding/logo/ncz.png" alt="NCZ-OS" width="96">
</p>

# 源码发布 —— 我们构建了什么，源码在哪里

> **🌐 语言：** [English](SOURCE-RELEASES.md) · 简体中文

NCZ-OS 分发 GPL/LGPL 软件，并从修改过的源码构建若干组件。本页是**所发布镜像中一切
由我们自行编译的内容**的权威索引，并给出各自的源码位置。

如果我们发布的某个组件是从源码构建的却未列于此，那是本文档的缺陷——请提交 issue。

**分发点是 GitLab**（`gitlab.com/ncz-os/cix-installer`）。GitHub 仓库是文档镜像，
其下载链接指回此处。

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
的 `SRC_URI`**）、`config-7.2-lean-msr1-o6n.defconfig`，以及锁定的上游基线版本及其
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
