<p align="center">
  <img src="assets/branding/logo/ncz.png" alt="NCZ-OS" width="120">
</p>

<h1 align="center">NCZ-OS</h1>
<p align="center"><em>面向 Arm64（CIX Sky1）与 AMD64（Intel/AMD PC 与 Apple T2 Mac）的 Debian —— 带有可用的 GPU、VPU 与 NPU 驱动</em></p>

> ### NCZ-OS 26.10 "Cygnus" —— Preview 1（2026-10-12）
>
> **[前往发布页下载](https://github.com/ncz-os/cix-installer/releases/tag/v26.10-preview1)**
> · [发布说明（英文）](docs/releases/26.10-cygnus-preview1.md)
> · [已测试硬件](#硬件支持与测试状态)
> · [文档索引（英文）](docs/INDEX.md)
>
> | 镜像 | 适用于 | 内核 |
> |---|---|---|
> | `ncz-os-arm64-20261012-f64cba5.img` | CIX Sky1 主板（Radxa Orion O6N、Minisforum MS-R1） | `7.3.0-rc7-sky1-ncz` |
> | `ncz-os-amd64-20261012-07c0644.img` | Intel/AMD PC 与 Apple T2 Mac | `7.3.0-rc7-t2-ncz` |
>
> 每个镜像都是原始 GPT 磁盘镜像（`.img`），在发布页上被拆分为多个分片（GitHub 单个文件
> 上限 2 GiB）。把所有分片、`SHA256SUMS`、`PARTS.sha256` 与
> [`ncz-join-image.sh`](tools/ncz-join-image.sh) 放在同一个文件夹里，运行
> `sh ncz-join-image.sh arm64`（或 `amd64`）：脚本会校验每个分片、拼接并解压，再校验
> 得到的 `.img`；它绝不会写入任何磁盘。然后把 `.img` 写入**至少 16 GB** 的驱动器
> （会清空该驱动器），见下文"快速开始（在硬件上安装）"。
>
> **这是预览版**，基于候选版（release candidate）内核构建。请先备份重要数据；安装时请
> 拔掉 USB 串口/调试线（安装程序可能把 USB 串口适配器误认为盲文显示器）。

> **说明：** 本中文版只同步了 26.10 Preview 1 的关键内容（上方横幅、硬件测试状态、
> 安装步骤、内核）。其余章节保留了 26.7 时期的译文，可能已过时；**一切以英文
> [README](README.md) 为准。**

# cix-installer

> **🌐 语言：** [English](README.md) · 简体中文
>
> **📚 从这里开始：** [文档索引](docs/INDEX.md) · [26.10 Preview 1 发布说明](docs/releases/26.10-cygnus-preview1.md) · [设计理据 —— 为什么这样构建](docs/DESIGN-RATIONALE.md) · [AI/ML 技术栈参考](docs/AI-ML-STACK.zh-CN.md) · [源码发布](docs/SOURCE-RELEASES.zh-CN.md) · [下载镜像](https://github.com/ncz-os/cix-installer/releases/tag/v26.10-preview1)

**NCZ-OS Linux 发行版的安装程序与镜像构建。**

`make image` 生成可启动的**原始 GPT 安装镜像**（`ncz-os-<架构>-<日期>-<sha>.img`），
覆盖**两个一等目标架构**，共享同一条构建流水线与同一套用户态：

- **Arm64 — CIX Sky1**（Radxa Orion O6N、Minisforum MS-R1）。原生 Mali-G720 GLES
  （Panthor 作为实验性启动项）、Zhouyi V3 NPU、Linlon VPU —— 全部基于 CIX 的 DKMS
  加速器模块，运行在 NCZ Sky1 内核之上。
- **AMD64 — Intel/AMD PC 与 Apple T2 Mac。** Intel/AMD/NVIDIA 标准驱动在安装时从各家
  厂商真实、已签名的 apt 源接入；T2 Mac 上使用 NCZ T2 内核，Apple 固件与音频配置来自
  AdityaGarg8 的 `t2-ubuntu-repo`。

安装程序运行的是上游 **Debian Installer（d-i）**（取自 Debian Testing netinst，按架构以
内容哈希锁定，见 `manifests/base.pin`），并解压出预先构建好的 **Debian Testing（Forky）**
系统，再叠加与硬件匹配的内核、厂商用户态、Singularity 桌面与（可选加入的）NCZ agent 栈。

> **当前版本：NCZ-OS 26.10 "Cygnus" Preview 1** —— Cygnus 主题的 Singularity 桌面
> （labwc/wlroots），每个镜像只带一个内核：
>
> | | Sky1（Arm64） | Intel/AMD PC 与 T2 Mac（AMD64） |
> |---|---|---|
> | **内核** | `7.3.0-rc7-sky1-ncz`（构建 r289） | `7.3.0-rc7-t2-ncz`（软件包 `7.3.0-rc7-2`） |
>
> 默认、安装程序与救援启动项都使用这同一个内核；救援项会屏蔽 GPU/加速器驱动。7.2 系列
> 与旧的"前沿版"通道已退役。7.3.0-rc7 是**候选版**内核，之后会换成 7.3.0 正式版。

> ### 远程访问默认项
>
> NCZ-OS 面向的是**家庭用户、爱好者与实验台**，其默认设置也据此而定：**telnet
> （23 端口）**、2323 端口上的应急 root 控制台、允许口令认证与 root 登录的 SSH，
> 以及一个会在你的局域网上**占用独立 IP** 的恢复容器。它们的存在，是为了让一块刚被
> 你弄坏的板子仍然能被连上——这些机器很多是无头的，且没有可用的串口控制台。
>
> 在路由器后的家庭局域网上，我们不认为这构成实质暴露。**但在企业环境、共享网络，
> 或任何拥有可路由地址的场合，请关闭它们**——一条命令即可，见下文。
>
> **→ [docs/REMOTE-ACCESS.md](docs/REMOTE-ACCESS.md)** —— 究竟启用了什么、为什么，
> 以及如何逐项关闭。

### 这个项目为什么存在，又为什么这样构建

简短版本：NCZ-OS 面向的是那些 **GPU、VPU、NPU 才是重点**的 ARM 系统——它不是"板级
支持包外加一个桌面"，也不是"把轻量桌面移植到新硅片上"。

这里每一个不那么显而易见的决定（GPU 栈、编解码路径、放弃 X/XFCE 改用 Singularity、
基础发行版、initramfs、发布节奏），都是对着真实 Sky1 硬件上的实测做出的。这些决定
及其证据都完整写在：

**→ [docs/DESIGN-RATIONALE.md](docs/DESIGN-RATIONALE.md)**

该文档中的论断都标注为 MEASURED（实测）、DECIDED（判断）或 OPEN（未决），因此你可以
基于证据而非口味来重新讨论它们。

## 设计上厂商中立

NCZ **在设计与意图上都是厂商中立的**。目标是：在能取得样机进行验证的前提下，支持
市面上出货的每一种 Arm 硅片系统，以及每一个主流 x86 平台。

**当前出货目标（两个都是一等目标——共享构建流水线、共享桌面、共享 agent 栈）**：

- **Arm64 — CIX Sky1 / CP8180** —— **Radxa Orion O6N** 与 **Minisforum MS-R1**，
  两者均已在真机上测试。这是 CIX 专有用户态（`libmali`、NOE、VPU 固件）以及四个
  DKMS 加速器模块（`mali_kbase`、`panthor`、`amvx`、`aipu`）接入之处。其他 Sky1 主板
  （Orange Pi 6 等）尚未测试。仓库名反映的是历史，不代表项目范围。
- **AMD64 — Apple T2 Mac** —— 2018–2020 出货、搭载 T2 协处理器的 MacBookPro
  （15,1 / 15,3 / 16,1 / 16,2 / 16,3 / 16,4）与 MacBookAir（8,1 / 8,2 / 9,1）等机型；其中只有 MacBookPro16,1 经过测试。
  硬件识别通过 PCI `106b:1801` —— Apple T2 桥接设备 ID，正是 `t2linux` 的
  `linux-t2-patches` 所依凭的同一标识（已直接核对
  `9001-ACPI-x86-Apple-T2-systems-need-early-CPU-offlining.patch` 源文件）。在 T2 Mac 上，
  NCZ-OS 把 `apple-bce`、`applesmc`、HID 与 APFS 接入内核树（我们自己的 `7.3.0-rc7-t2-ncz` 内核），
  并在首次启动时从 AdityaGarg8 的真实、已签名 `t2-ubuntu-repo` 拉取 Apple 固件与音频配置。
- **AMD64 — 通用 x86-64 PC** —— 同一份构建、同一套用户态，无 CIX 栈。同一个镜像
  能在普通 Intel/AMD 台式机或服务器上启动；与具体硬件绑定的加速器仓库（NVIDIA CUDA、
  AMD ROCm、Intel OpenVINO）由 `post-install/54-gpu-accel.sh` 中的 `lspci -nn`
  PCI 类自动检测并接入。没有独立显卡的机器会静默跳过，这是正常行为。

## 硬件支持与测试状态

> **在你烧录任何东西之前请先读这一节。** NCZ 在**设计上**是厂商中立的，但"设计上
> 支持"与"已经测试过"并不是一回事。以下是 **26.10 Preview 1**（内核 `7.3.0-rc7`，
> 候选版）的诚实测试状态。表中未列出的硬件，我们都没有在本版本上启动过。

Preview 1 带有 **amd64 上的 AMD、NVIDIA 与 Intel GPU 驱动**、**CIX Sky1 上的 Arm Mali
驱动（默认使用厂商 Mali 栈，也提供开源 Panthor 驱动）**，以及 **CIX Sky1 的 NPU 与 VPU**
驱动。我们实际运行过的机器：

| 机器 | CPU | GPU（驱动） | Preview 1 上的状态 |
|---|---|---|---|
| Radxa Orion O6N | CIX P1（Sky1） | Arm Mali（厂商 Mali；可选 Panthor）+ NPU + VPU | 已安装，桌面、视频（VPU 硬件解码）与音频播放正常 |
| Minisforum MS-R1 | CIX P1（Sky1） | Arm Mali（厂商 Mali；可选 Panthor）+ NPU + VPU | 已安装，桌面、视频（VPU 硬件解码）与音频播放正常 |
| MacBookPro16,1（两台） | Core i9-9980HK、Core i7-9750H | AMD Radeon Pro 5300M/5500M 级（Navi 14，`amdgpu`）+ Intel UHD 630（`i915`） | 已安装，可启动到桌面 |
| ASUS ROG GU502LV 笔记本 | Core i7-10750H | NVIDIA GeForce RTX 2060 Mobile（专有 `nvidia`）+ Intel UHD 630（`i915`） | 已安装，可启动到桌面 |
| HP OmniDesk 台式机 | Core Ultra 7 265 | Intel 集成显卡（Xe-LPG，`i915`） | 已安装，可启动到桌面 |
| Dell Inspiron 5521（2013） | Core i7-3537U | Intel HD Graphics 4000（`i915`） | 已安装，可运行桌面 |
| Mac mini 2011（Macmini5,1） | Core i5-2415M | Intel HD Graphics 3000（`i915`） | 已安装，桌面正常（硬件加速图形） |

其他 GPU 与主板均未测试。视频、音频播放以及 VPU 硬件视频解码已在 Sky1 主板上验证；
其他 GPU 上的硬件视频解码取决于驱动。详细说明（Sky1 主板列表、T2 Mac 与通用 PC 的
分类、GPU 计算的硬件下限）见英文 [README](README.md#hardware-support--testing-status)。

**Preview 1 已知问题：**

- 安装时请拔掉 USB 串口/调试线（安装程序可能把它误认为盲文显示器）。
- Apple T2 MacBook 在首次登录后会发热：首次登录导览会带来约一分钟的 CPU 高负载，且独立
  AMD GPU 始终通电（空闲约 60 °C）。修复计划在下一个镜像中提供。
- 锁屏：在两台 T2 MacBook 上未能确认锁屏背后的屏保动画（其他机器上已确认，正在调查）；
  锁屏不会关闭显示（"N 秒后黑屏"尚未实现）。
- T2 MacBook 每次从休眠恢复都会记录一条内核警告，Thunderbolt/USB4 端口会短暂断开（恢复本身
  正常）；登录界面与桌面会话的分辨率不同，因此在这些机器上登录界面与锁屏的一致性尚未验证。
- 在 Radxa Orion O6N 上，GTK 文件选择门户服务可能无法启动，部分应用可能打不开文件选择对话框。
- 锁屏上的屏保在默认时间点可能无法启动：两条空闲锁屏路径会争用锁屏的屏保连接，导致锁屏
  背后没有屏保（在一台台式机上出现）。锁屏本身总会生效。修复计划在下一个镜像中提供。

## GPU 驱动与启动项

NCZ-OS **同时发布两个 GPU 驱动**，由你在启动时选择。两者都会安装；两者都不会自动加载。

| 启动项 | 驱动 | 提供 | 状态 |
|---|---|---|---|
| **NCZ-OS**（默认） | `mali_kbase` —— CIX 厂商 DDK | OpenGL ES 3.2、EGL 1.5，经 `libmali` 提供 OpenCL | 已在 Radxa Orion O6N 与 MS-R1 真机验证。桌面就跑在它上面。 |
| **NCZ-OS (Panthor)** | `panthor` —— 主线开源驱动 | 经 Mesa PanVK / rusticl 提供 Vulkan 与 OpenCL | 在 Sky1 上仍属实验性。 |

两个驱动会认领同一个设备，因此 `/etc/modprobe.d/ncz-gpu-drivers.conf` 将**两者都**
列入黑名单。由启动项决定绑定哪一个，`ncz-gpu-select` 可在已安装的系统上切换而无需重装。

**各自的代价。** `mali_kbase` 提供加速桌面，但**不暴露任何 Vulkan 入口**——`libmali`
本身就没有。`panthor` 是通往 Vulkan 的路，也是生态的走向，但在 Sky1 上它仍在处理枚举
问题：该板经由 ACPI 而非设备树启动，而主线 panthor 没有 `.acpi_match_table`。

两者都不会被放弃。只发布厂商二进制，会让发行版失去开源继任者；只发布 panthor，则意味着
桌面今天无法加速。

### 每一个加速器驱动都是 DKMS 模块

这是一条刻意的规则，而非打包上的偶然：

| 加速器 | DKMS 包 | 模块 |
|---|---|---|
| GPU（默认） | `cix-gpu-kmd` | `mali_kbase` |
| GPU（备选） | `panthor-cix` | `panthor` |
| VPU | `cix-vpu-driver` | `amvx` |
| NPU | `cix-npu-driver-dkms` | `aipu` |

**为什么用 DKMS 而不是内核内置。** 内核升级时 DKMS 模块会针对新内核重新构建；而以预编译
二进制形式随内核发布的模块被锁定在某一个 `vermagic` 上，内核一动它就会**悄无声息地**
不再加载——你会得到一个能启动、但加速器已死且毫无线索的系统。

它同时也让冲突可预测。当内核内置驱动与树外驱动同时匹配同一硬件时，DKMS 安装到
`updates/dkms/`，而 `depmod` 优先选择该目录，因此胜出的是我们期望的那个驱动，而不是内核
恰好编译进去的那个。内核内置的 `armchina_npu` 被彻底关闭（`CONFIG_ARMCHINA_NPU=n`）
也是同样的道理：厂商 26Q2 SDK 驱动比内核内置的更新，绝不能被后者遮蔽。

以上每一个驱动的对应源码都已发布 —— 见 [docs/SOURCE-RELEASES.zh-CN.md](docs/SOURCE-RELEASES.zh-CN.md)。

## 快速开始（在硬件上安装）

> **开机前请接好有线网络。** 安装程序中没有 Wi-Fi；若检测不到链路，安装程序会明确停在
> "Network autoconfiguration failed"（接好网线后选 Retry），而不是无声地重试。

> **安装前请拔掉 USB 串口/调试线。** 安装程序可能把 USB 串口适配器误认为盲文显示器：
> 会弹出"braille device?"提示，并把安装界面挤到屏幕左侧。选择 *No*，或拔掉线再安装。

1. **获取镜像。** 从[发布页](https://github.com/ncz-os/cix-installer/releases/tag/v26.10-preview1)
   下载对应架构的分片，然后拼接、解压并校验（需要 `zstd`）：

   ```bash
   sh ncz-join-image.sh arm64        # 或 amd64
   ```

   手动方式：`sha256sum -c PARTS.sha256`，然后
   `cat ncz-os-<架构>-<日期>-<sha>.img.zst.part-* | zstd -d -o ncz-os-<架构>-<日期>-<sha>.img`，
   再用 `sha256sum` 与 `SHA256SUMS` 对照。

2. **写入至少 16 GB 的驱动器**（镜像 7.6 GB；写入会清空该驱动器）。任何系统上都可以用
   Balena Etcher。在 Linux 上，请把原始 GPT 镜像写入**整块设备**（`/dev/sdX`），而不是某个
   分区（`/dev/sdX1`）：

   ```bash
   sudo dd if=ncz-os-<架构>-<日期>-<sha>.img of=/dev/sdX \
        bs=4M status=progress oflag=direct conv=fsync
   sync
   ```

   在 macOS 上先执行 `diskutil unmountDisk /dev/diskN`，再以 `/dev/rdiskN`（注意 `r`）
   为目标，并去掉 `oflag=direct`。

   > **`dd` 会毫不询问地写入你所指定的任何设备。** 执行前请用 `lsblk`（Linux）或
   > `diskutil list`（macOS）再确认一次目标；写错设备会销毁那块磁盘上的数据。

3. **启动。** 把驱动器插到目标机器上（arm64 镜像用于 Sky1 主板，amd64 镜像用于
   Intel/AMD PC 或 T2 Mac），开机后从 UEFI 启动菜单选择该驱动器；Mac 上开机时按住
   Option（⌥）。安装程序在两种架构上都会启动 NCZ 内核（T2 Mac 上为 T2 内核）；若 Mac
   内置键盘在安装过程中没有响应，请准备一个 USB 键盘。

4. **回答安装程序的问题：**国家/地区（同时决定语言、时区与键盘）、用户名与密码（root
   登录关闭）、要安装的可选组件（桌面、恢复容器、救援分区，默认全选），以及目标磁盘与
   根文件系统：**btrfs**（默认）或 **ext4**。主机名会自动生成，可以修改。

5. 安装程序在确认页之后清空磁盘、完成安装并重启。拔掉驱动器后，系统经 rEFInd 启动到
   Singularity 登录界面；首次登录会显示一段桌面导览。

## 嵌入模型

模型**不在镜像中**——每个动辄数百 MB，而多数安装并不需要。安装完成后
`/opt/ncz/models` 是空的。

当你需要 NPU 推理时，从 apt 仓库安装其一：

```
sudo apt install ncz-model-nomic-embed   # 768 维，默认
```

在安装模型之前，NPU 推理会以 `noe_load_graph` 失败。**那是缺少模型，不是硬件或驱动
问题。** 模型说明见 [docs/MODELSCOPE-MODELS.md](docs/MODELSCOPE-MODELS.md)（英文）。

## 内核

26.10 Preview 1 每个镜像只带**一个**内核：Sky1 为 `7.3.0-rc7-sky1-ncz`（构建 r289，
软件包 `linux-image-cixmini`，锁定于 `assets/kernel/sky1-manifest.json`），AMD64 为
`7.3.0-rc7-t2-ncz`（软件包版本 `7.3.0-rc7-2`，锁定于 `assets/kernel/amd64-stable/`）。
默认、安装程序与救援启动项都使用它；7.2 系列与"前沿版"通道已退役。

对应源码见 [docs/SOURCE-RELEASES.zh-CN.md](docs/SOURCE-RELEASES.zh-CN.md)（以英文版为准）。
仓库内的 [`kernel-source/`](kernel-source/SOURCE.md) 目前仍对应 26.7 的 7.2 内核。

## 构建镜像

构建步骤见英文 [README](README.md#quick-start-build-the-installer-image)。简要地说：
唯一入口是 `build/build-image.sh --arch amd64|arm64 --full --no-publish`；只组装镜像时用
`make image ARCH=<arm64|amd64>`，结果为 `build/ncz-os-<架构>-<日期>-<sha>.img`。

## 上游贡献

以下工作起源于本项目，已进入上游或正准备进入上游。它们都不是 NCZ 专有的：
缺陷位于共享代码之中，因此修复应当回到各自的项目，而不是堆在发行版的补丁堆里。

### 浏览器与编解码：硬件视频解码

要让浏览器在这块硅片上真正用上硬件视频解码，需要给 CIX VA-API 驱动打六个补丁，另外还要
给 FFmpeg、Firefox 和 Chromium 打补丁。四个底层缺陷**全部是静默失败**——没有任何组件
记录过错误——这也是这项工作连同证据一起被写下来、而不是只留下修复的原因：

- **[docs/HW-VIDEO-DECODE-STATUS.md](docs/HW-VIDEO-DECODE-STATUS.md)** —— 哪些能用，
  验证方式是**看渲染出来的画面**而不是看某个代理信号。Chromium 中 H.264 1080p 与
  VP9 720p 走硬件解码（H.264 下渲染进程 CPU 由约 27% 降至约 3.5%）；AV1 受阻于上游。
- **[docs/upstream-patches/cix-vaapi/](docs/upstream-patches/cix-vaapi/)** —— 六个
  VA-API 补丁。没有它们，浏览器硬件解码在本平台上**完全不工作**。
- **[ffmpeg/](docs/upstream-patches/ffmpeg/)**、
  **[firefox/](docs/upstream-patches/firefox/)**、
  **[chromium/](docs/upstream-patches/chromium/)** —— V4L2 M2M 解码器支持、AV1 接线
  与时间戳处理。
- **[cix-vaapi-repro/](docs/upstream-patches/cix-vaapi-repro/)** —— 独立的 C 复现程序，
  让驱动作者不必构建浏览器就能确认每一个缺陷。


### Singularity 桌面

- **传感器面板插件** —— 面向 Sky1 的硬件传感器发现与分类。该平台呈现的是五个
  无标签的 ACPI 热区（`TZB0`、`TZB1`、`TZM0`、`TZM1`、`TZGT`），而不是其他平台
  上那块带标签的 SCMI 芯片。包含温度邻近匹配与限值来源标注，使每个读数都能被
  归到正确的设备。
- **网络接口组件** —— 枚举**每一个**以太网口（无论是否已连接），并给出检测到的
  芯片组与链路能力（如 2.5 GbE），而不是只列出活动连接。
- **Layer-shell 与会话修复** —— 在真实 Sky1 硬件上验证过的表面重建行为，以及
  一处 GSettings schema 修复：缺失的键会让进程 `SIGABRT`，而不是抛出异常。
- **平台识别** —— 通过 ACPI 硬件 ID（`CIXH*`）识别 CIX Sky1，而不是依赖 DMI
  厂商字符串——后者报告的是板卡厂商，而非 SoC。

## 致谢

NCZ-OS 几乎完全建立在他人的工作之上。下面大致按这些工作自内核向上堆叠的顺序排列。

**Linus Torvalds 与内核社区。** 先说最显而易见的一笔：没有内核，这一切都不存在。这里的
Sky1 使能（26.10 中为一个合并的移植补丁加 20 个编号补丁；26.7 中为 176 个补丁的系列）叠在三十年间数千人的工作之上；而一组厂商补丁系列**能够**
被这样承载、变基与公开发布，本身就是那个项目治理方式的产物。

还有一笔不那么显而易见、但值得直说的：本发行版是由一个人借助 AI 结对工具构建的。在业界
不少表态流于姿态的时候，Torvalds 对 AI 辅助开发的立场一直是务实的。他的总结——
*"AI is just a tool, like any other tool we use. And AI is clearly a useful tool"*
（AI 只是一件工具，和我们用的其他工具一样；而它显然是件有用的工具）——以及他对"Linux 是
一个反 AI 项目"这种框定的否定
（[lore.kernel.org](https://lore.kernel.org/linux-media/CAHk-=wi4zC+Ze8e+p3tMv8TtG_80KzsZ1syL9anBtmEh5Z40vg@mail.gmail.com/)），
确立了一条重要的准则：**评判补丁本身，而不是评判产出它的工具。**

他还提出了更锋利的一点：靠文档要求解决不了真正的问题——*"the AI slop people aren't going
to document their patches as such"*（真正在灌水的人，根本不会把补丁标注成那样）。这是对的，
也正因如此，本仓库的纪律落在**实测**而非**声明**上：这里每一条能力论断，背后都有真实硬件上的
一个负载；凡是没有实测过的，文档就明说没有。无论是什么产出了这些工作，它都应当按这个标准被
检验。

**Yocto 项目与 Linux 基金会。** Sky1 内核使用
**[Yocto 项目](https://www.yoctoproject.org/)** 构建——BitBake、OpenEmbedded 与
`poky`，CIX 使能则以 `meta-cix` 层的形式承载。那组补丁系列、它们的 `SRC_URI`
顺序、defconfig 以及可复现的部署产物，全都存在于这套模型之中。正是它让 26.7 时"一组 176 个
补丁的厂商系列跨四个上游基线反复变基"成为一个人而非一个团队能做的事，也正是它让我们
发布的对应源码**真的对应得上**。
**[Linux 基金会](https://www.linuxfoundation.org/)** 托管并维系着 Yocto，以及本发行版
所依赖的大部分周边生态。这类基础设施之所以容易被视为理所当然，恰恰是因为它一直在正常
运转；这种规模的项目不可能独自扛起它。

**CIX Technology。** CIX 的 SDK、Sky1 内核补丁系列与厂商用户态（`libmali`、NPU/VPU 栈）
是这块硬件能被编程的前提。他们把 Sky1 支持推向 Linux 主线的工作，意义超出本项目：这是
"一块永远需要厂商树的板子"与"一块最终能直接启动发行版内核的板子"之间的区别。有一点值得
直说：一家中国芯片厂商把使能工作推向上游、公开 SDK 并与社区互动，在这个行业里并非默认
选项，而在我们基于它构建的这段时间里，他们对开源的投入是肉眼可见地在改善。

**刘剑锋（[Jianfeng Liu](https://github.com/amazingfate)，`amazingfate`）。** Armbian
维护者，其跨 ARM 平台、以及具体针对 Sky1 的补丁与打包工作，为本项目省下了大量重复摸索。
如果你近几年在 ARM SBC 上跑过 Armbian，你就用过他的成果。

**Singularity —— Mirko Brombin 与 singularityos-lab 项目。** 桌面是
[Singularity](https://github.com/singularityos-lab)，由 **Mirko Brombin** 创建。
用它替换 XFCE/X11 是让这块硅片上出现真正加速桌面的关键一步，因为 Singularity 基于
labwc/wlroots，能原生抵达 Mali GLES，而不必绕道 Xwayland。

Mirko 也接纳了反向流动的改动。那些属于我们的工作，因此列在
[上游贡献](#上游贡献)一节，而不是放在这里。

**此外**：**Radxa**（Radxa Orion O6N，我们的主力开发与验证平台）、**Minisforum**
（MS-R1，本项目起步的那块板）、**Debian**（把 ARM 当作一等架构，这正是 26.7 建立在
Forky 上的原因），以及 **Mesa、wlroots 与 labwc**（Panthor 路径所依赖的开源图形与
合成器栈）。

**t2linux 社区** —— 维护着让 T2 Mac 能在主线 Linux 上启动成为可能的 `linux-t2-patches`
系列。AdityaGarg8 的 `t2-ubuntu-repo`（通过 `apple-firmware-script` 提供的真实 WiFi/BT
固件、``apple-t2-audio-config`）让 AMD64 / T2 路径的 NCZ-OS 安装能跑出可用的桌面、而不是
只停在控制台。我们今天能有两台真 T2 MacBook 启动验证，都要归功于这些工作、而不是我们自己的。

**Apple 自己的 Asahi Linux 校友** —— `get-apple-firmware` 那台 macOS CDN 固件拉取器是
Asahi 衍生的工具，T2 固件钩子在调用它；没有它 T2 路径根本没有 WiFi/BT 固件可用。

**还有 Rachel。** 我的妻子。从这个爱好开始的第一天起，她就一直容忍着它——摊在餐桌上的
板卡、风扇的噪音、凌晨两点那句"再构建一次就好"。没有那份耐心，上面这一切都不会发生。

---

*本文档为英文 [README.md](README.md) 的中文版本。若两者出现分歧，以英文版为准。*

*同步状态（2026-10-13）：顶部 Preview 1 横幅、引言、"硬件支持与测试状态"、"快速开始
（在硬件上安装）"、"内核"与"构建镜像"已按 26.10 Preview 1 更新。其余章节仍是 26.7 时期的
译文，英文版中的"What's in 26.10"、"Architecture"、"OTA channel"、"The `ncz` utility"、
"Live recovery"、"Releases"等小节尚未翻译——请直接查阅 [README.md](README.md)。英文版始终是
规范版本。*
