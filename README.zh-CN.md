<p align="center">
  <img src="assets/branding/logo/ncz.png" alt="NCZ-OS" width="120">
</p>

<h1 align="center">NCZ-OS</h1>
<p align="center"><em>面向 CIX Sky1 的 Arm64 Linux —— GPU、VPU、NPU 真正可用</em></p>

# cix-installer

> **🌐 语言：** [English](README.md) · 简体中文
>
> **📚 从这里开始：** [设计理据 —— 为什么这样构建](docs/DESIGN-RATIONALE.md) · [AI/ML 技术栈参考](docs/AI-ML-STACK.zh-CN.md) · [源码发布](docs/SOURCE-RELEASES.zh-CN.md) · [下载 ISO](https://gitlab.com/ncz-os/cix-installer/-/releases/permalink/latest)

**为 NCZ Linux 发行版定制的 debian-installer ISO 构建器。**

它生成一张完全无人值守、可 UEFI 启动的安装 ISO：对目标磁盘分区，在磁盘上
debootstrap 一个 **Debian Testing（Forky）** 基础系统，随后叠加适配该硬件的内核、
厂商用户态运行时、桌面环境、Claude Code 以及（可选加入的）NCZ agent 栈，并将系统
品牌化为 NCZ。

> **NCZ-OS 26.7 "Maximilian"** 搭载 **Singularity** 桌面（labwc/wlroots，原生
> Mali GLES）—— X11/XFCE 已被完全移除 —— 运行在单一内核 `7.2.0-sky1-ncz` 上。
> 已在 Radxa Orion O6N 与 Minisforum MS-R1 上验证；Orange Pi 6 验证进行中。
>
> **最新版本：** [2026.08.18-v12](docs/releases/2026.08.18-v12.md) ·
> [下载](https://gitlab.com/ncz-os/cix-installer/-/releases/permalink/latest)

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

- **当前出货目标**：Cix Sky1 / CP8180 —— **Radxa Orion O6N** 与 **Minisforum
  MS-R1**，两者均已在真机上验证。这是构建路径被锤炼得最充分、也是可离线的专有用户态
  层接入之处。**Orange Pi 6** 验证进行中。仓库名反映的是历史，不代表项目范围。
- **Arm 路线图**：Radxa 的高通平台板（Snapdragon + Hexagon NPU）、Rockchip
  RK3588 / RK3576 系列、MediaTek Genio、Apple Silicon（仅套件，非操作系统），
  以及任何我们能拿到样机的量产 Arm SoC。
- **x86 路线图**：并行的构建路径，**Intel**（CPU + iGPU + NPU，经由 OpenVINO
  2026.x）与 **AMD**（Ryzen / XDNA NPU / ROCm）都是一等目标。构建脚本已接受
  `--platform=x86_64`；目前只差适配层的工作。

## 硬件支持与测试状态

> **在你烧录任何东西之前请先读这一节。** NCZ 在**设计上**是厂商中立的，但"设计上
> 支持"与"已经测试过"并不是一回事。以下是硬件验证的诚实状态。

| 主板 | SoC | 状态 |
|---|---|---|
| **Radxa Orion O6N**（48 GB） | Cix Sky1 | ✅ **已验证可用——我们的主力开发/调试目标。** Mali `mali_kbase` GPU 驱动移植与完整的 Singularity 桌面栈都是在这块板上构建并验证的。在所发布的镜像上确认：安装、启动、GPU（GLES 3.2）、NPU（每 256 token 约 95 ms）、VPU（H.264/HEVC 编码 + 8 种解码格式）、音频与 2.5 GbE 全部可用。 |
| **Minisforum MS-R1**（32 GB，及 64 GB "jumbo"） | Cix Sky1 / CP8180 | ✅ **已验证可用**，运行 `7.2.0-sky1-ncz`。UEFI 启动、安装程序、GPU（Mali `mali_kbase`）、NPU（Zhouyi 嵌入）、VPU、音频与网络均已在这块板上验证。 |
| **Radxa Orion O6** | Cix Sky1 | ⚠️ **我们未直接测试——用户反馈可用。** 硬件上比 O6N 更接近 MS-R1；已有用户在自己的 O6 上确认可以安装与启动，包括 Realtek 网卡（RTL8125/8126）凭随安装程序与已装系统一同发布的 `rtl_nic` 固件开箱即用。我们没有亲手接触过 O6。 |
| **MetaComputing AI PC** —— 面向 Framework Laptop 13 的 Arm 主板 | Cix Sky1 / **CP8180** | ⏳ **未测试，但与我们出货所用的是同一颗 SoC。** MetaComputing 的 CP8180 主板可装入 Framework Laptop 13 机身：12 核 Armv9（Cortex-A720 + A520，最高 2.6 GHz）、10 核 Mali GPU、约 45 TOPS NPU、16/32 GB 内存，起价 549 美元。与 MS-R1 和 O6N 同硅片，因此内核、GPU/VPU/NPU 驱动与用户态应当可以沿用；未知数是笔记本特有的部分——面板/eDP、电池与散热、合盖/休眠，以及 Framework 的 EC。**我们没有该硬件——欢迎测试者。** 注意其 28 W TDP 对应 55 Wh 电池。 |
| **Orange Pi 6**（Cix 版本） | Cix Sky1 | ⏳ **验证进行中——硬件在途。** 预计在 2026-08-18 起两周内。安装程序 v12 中新增的无线固件（`firmware-brcm80211`、`firmware-mediatek`、`firmware-atheros`、`firmware-iwlwifi`）正是为了覆盖这块板可能搭载的任意 WiFi/BT 模块。 |
| 其他 Arm（RK3588/RK3576、MediaTek Genio、Snapdragon）与 x86（Intel、AMD） | — | 🗺️ 仅路线图/适配层——尚未构建或测试。 |

## GPU 驱动与启动项

NCZ-OS **同时发布两个 GPU 驱动**，由你在启动时选择。两者都会安装；两者都不会自动加载。

| 启动项 | 驱动 | 提供 | 状态 |
|---|---|---|---|
| **NCZ-OS**（默认） | `mali_kbase` —— CIX 厂商 DDK | OpenGL ES 3.2、EGL 1.5，经 `libmali` 提供 OpenCL | 已在 O6N 与 MS-R1 真机验证。桌面就跑在它上面。 |
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

**先校验，再写入。** 每个版本都在 ISO 旁附带 `.md5`：

```bash
md5sum -c nclawzero-installer-cixmini-<版本>.iso.md5
```

该 ISO 是混合镜像，请写入**整块设备**（`/dev/sdX`），而不是某个分区（`/dev/sdX1`）：

```bash
sudo dd if=nclawzero-installer-cixmini-<版本>.iso of=/dev/sdX \
     bs=4M status=progress oflag=direct conv=fsync
sync
```

> **`dd` 会毫不询问地写入你所指定的任何设备。** 执行前请用 `lsblk` 再确认一次目标；
> 写错设备会销毁那块磁盘上的数据。

安装程序是无人值守的：它选择目标磁盘，安装基础系统、驱动与桌面，然后重启进入一个
可用的系统。

**开机前请接好有线网络。** 安装程序中没有 Wi-Fi；若检测不到链路，安装程序会明确停在
"Network autoconfiguration failed"，而不是无声地重试。

基础系统本身来自镜像，因此安装过程中**不存在**会因链路不稳或镜像源不可达而失败的
软件包解析环节。但这并不等于"全程不需要网络"：部分安装后步骤会使用 apt，少数可选
组件会从网络获取。网络不好时受影响的是这些部分，而不是安装本身。

启动菜单另外还提供一个救援 shell，以及一个串口全程跟踪的诊断项（O6/O6N，
`ttyAMA0`，115200）。

## 嵌入模型

模型**不在 ISO 上**——每个动辄数百 MB，而多数安装并不需要。安装完成后
`/opt/ncz/models` 是空的。

当你需要 NPU 推理时，从 apt 仓库安装其一：

```
sudo apt install ncz-model-nomic-embed   # 768 维，默认
```

在安装模型之前，NPU 推理会以 `noe_load_graph` 失败。**那是缺少模型，不是硬件或驱动
问题。** 可用的档位见 [docs/EMBEDDING-MODELS.md](docs/EMBEDDING-MODELS.md)。

## 内核

26.7 只发布**一个**内核：`7.2.0-sky1-ncz`。早期版本还带有一个 7.0.12 通道；它已被
**从镜像中移除**——它不是回退方案，也不是救援内核。

对应源码见 [`kernel-source/`](kernel-source/SOURCE.md)，其中包含实际用于构建所发布
二进制的展开 `.config`。

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
Sky1 使能不过是 176 个补丁，叠在三十年间数千人的工作之上；而一组厂商补丁系列**能够**
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
`poky`，CIX 使能则以 `meta-cix` 层的形式承载。那 176 个补丁的系列、它们的 `SRC_URI`
顺序、defconfig 以及可复现的部署产物，全都存在于这套模型之中。正是它让"一组 176 个
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

**此外**：**Radxa**（Orion O6 与 O6N，我们的主力开发与验证平台）、**Minisforum**
（MS-R1，本项目起步的那块板）、**Debian**（把 ARM 当作一等架构，这正是 26.7 建立在
Forky 上的原因），以及 **Mesa、wlroots 与 labwc**（Panthor 路径所依赖的开源图形与
合成器栈）。

**还有 Rachel。** 我的妻子。从这个爱好开始的第一天起，她就一直容忍着它——摊在餐桌上的
板卡、风扇的噪音、凌晨两点那句"再构建一次就好"。没有那份耐心，上面这一切都不会发生。

---

*本文档为英文 [README.md](README.md) 的中文版本。若两者出现分歧，以英文版为准。*
