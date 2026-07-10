# cix-installer

> **🌐 语言：** [English](README.md) · 简体中文
>
> **📚 从这里开始：** [AI/ML 软件栈参考](docs/AI-ML-STACK.zh-CN.md) ([English](docs/AI-ML-STACK.md)) · [我们是如何走到这一步的 —— 工程复盘](docs/HOW-DID-WE-GET-HERE.zh-CN.md) ([English](docs/HOW-DID-WE-GET-HERE.md)) · [下载 ISO](https://gitlab.com/ncz-os/cix-installer/-/releases/permalink/latest)

**面向 NCZ Linux 发行版的定制化 debian-installer ISO 构建器。**

生成一个完全无人值守、可 UEFI 启动的安装器 ISO：对目标磁盘分区，先用
debootstrap 安装 Debian 12 基础系统并在磁盘上全量升级到 Ubuntu（resolute），
然后叠加适配硬件的内核 + 厂商用户态运行时 + 桌面环境 + Claude Code + （可选启用的）
NCZ 智能体栈，并将系统品牌化为 NCZ（桌面版为 Reinhardt，服务器/常驻智能体设备为 Magnetar）。

> **r195 新增：** 内核通道整体前移 —— **7.0.12 成为稳定（stable）通道**，
> **7.2.0-rc1-ncz 成为新的前沿（edge）通道**（6.18 LTS 内核自本版起从 ISO 中退役）。
> 7.2 内核带来本周期的实质修复：VPU 启动挂死修复（pm_runtime 的 IRQ/复位顺序竞争，
> 与 CIX 官方 v1.0.1 驱动的修复一致）、修正后的 RTL8127 PCIe ASPM/ClockPM quirk、
> 移除树内 panthor 驱动（以树外 Mali DDK 栈为准）、以及 linlondp 26q2 的 -Werror
> 修复。内核现基于 **Yocto Project 6.0 "Wrynose"** 构建。基础镜像同时瘦身约 2 GB
> （不再把安装器从不安装的测试包烤进镜像）。新内核对 apt 通道的 OTA 发布将另行进行。
> 参见 [当前 ISO](#当前-iso--r195ncz-os-266-正式发布)。

### 已有 Canonical / Armbian / 厂商镜像，为什么还要 NCZ-OS？

这是个合理的问题 —— ARM 单板领域从不缺镜像。NCZ-OS 并不想做又一个通用移植，
它是一个 **面向智能体（agentic）的 ARM Linux 发行版**，差异本身就是目的：

- **在多款（往往颇为小众的）ARM 系统上提供同一套安装器** —— 相同的无人值守
  安装、分区、引导与恢复模型，而不是每个厂商一套各行其是的镜像。
- **专有部分开箱即用** —— 每个平台的 GPU、NPU、VPU、音频与固件都经过集成、
  在厂商滞后于主线时打上补丁，并在真实硬件上验证后才发布。
- **智能体、推理与智能体记忆是一等公民** —— ncz 智能体栈、端侧 NPU 推理与
  记忆基座随系统就位（选择性启用，不主动运行），而不是事后拼装。
- **可恢复性是纪律** —— 每次安装都带有可独立引导的救援分区，内置自动配置
  网络（DHCP + 静态回退）与多种接入通道；一台远程失联的 ARM 盒子是本项目
  拒绝接受的“常态故障”。

如果通用镜像已经很好地为你服务，请继续愉快地使用。NCZ-OS 面向的是另一种
场景：你希望手里的 ARM 机器像一支协调一致、随时可跑智能体的舰队，而不是
一架子各自为政的单板 —— 给一个至今缺乏标准化的领域注入一点秩序。

### 两个相互独立的层：可用的操作系统，以及*可选的* AI 层

NCZ 有意将操作系统与 AI 分离。安装 ISO 即可获得第一层；第二层在你主动请求之前，
绝不会被安装或启动。

**1. 操作系统 + 驱动 —— 开箱即装、即可工作。**
全新安装即是一套完整可用的 Linux 桌面，无需任何 AI：
- 硬件使能：合适的内核、**GPU 驱动**（Mesa panvk + rusticl）、**NPU 驱动**
  （`/dev/aipu`）、**音频**（HDMI + 模拟耳机/扬声器接口），以及 Wi-Fi/以太网固件 —— 驱动均可工作。
- XFCE 桌面 + 浏览器、媒体播放器、字体、压缩工具 —— 完全可用于日常的非 AI 工作。
- Claude Code CLI 作为*工具*存在；它本身不会自行运行任何东西。

**2. AI 智能体 + 记忆基座 —— 可选，通过 `ncz` 命令安装。**
这一层是**「具备智能体能力，但默认不开启」**：运行时、quadlet 以及设备端 NPU 嵌入栈
都已预置就绪，但**在你于终端运行 `ncz` 之前，这里没有任何东西被安装或运行。**
开机时不会自启动，也不会自行联网拉取。
- **AI 智能体** —— `ncz agent install <名称>`（`zeroclaw`、`openclaw`、`hermes`、
  `portainer`）或 `ncz install nemoclaw`（NVIDIA NemoClaw）。
- **MNEMOS 记忆基座**（设备端语义记忆系统）—— `ncz install mnemos`。

在你运行 `ncz` 之前，系统的行为与任何普通 Linux 桌面无异。
（早期 ISO 会默认激活 `zeroclaw`；当前 ISO 不再如此。）

## 设计上的厂商中立

NCZ **在设计与意图上都是厂商中立的。** 目标：在能获取样机进行验证的前提下，
支持市面上每一款 Arm 芯片系统和每一个主流 x86 平台。

- **当前概念验证目标**：Cix Sky1 / CP8180（Minisforum MS-R1 及后继机型）。这是
  构建路径被锤炼得最充分、且接入了可离线的专有用户态层的平台。仓库名反映的是
  历史，并不代表项目范围。
- **Arm 路线图**：Radxa Orion O6 / O6N（Sky1，不同板卡）、Radxa 高通平台板卡
  （Snapdragon + Hexagon NPU）、Rockchip RK3588 / RK3576 系列、MediaTek Genio、
  Apple Silicon（仅套件，非操作系统），以及任何我们能拿到样机的、量产的 Arm SoC。
- **x86 路线图**：并行的构建路径，**Intel**（CPU + 核显 + 通过 OpenVINO 2026.x
  的 NPU）和 **AMD**（Ryzen / XDNA NPU / ROCm）都是一等目标。构建脚本已支持
  `--platform=x86_64`；只剩适配层的工作待做。
- **嵌入推理**：由 `mnemos-embedkit`
  （https://github.com/mnemos-os/mnemos-embedkit）处理 —— 厂商无关的 Python 套件，
  在运行时自动检测最高级别的加速器（NPU > GPU > CPU）。同一个 `Engine.auto()`
  调用在每条芯片路径上都能工作。
- **智能体运行时**：可并存选择，且**完全可选启用 —— 默认不安装、不激活任何智能体。**
  运行 `ncz`（或 `ncz agent install <名称>`）来安装 `zeroclaw`、`openclaw`、`hermes`
  或 `portainer`，用 `ncz install nemoclaw` 安装 NVIDIA NemoClaw，用 `ncz install
  mnemos` 安装 MNEMOS 记忆系统。开机时不会自启动任何智能体，也不会自行联网拉取。

`build/build-iso-di.sh` 中当前的构建路径是 Cix Sky1 的实现；其架构是可复用的脚手架。

## 硬件支持与测试状态

> **在刷写任何东西之前请先读这一节。** NCZ 在*设计上*是厂商中立的，但"设计上
> 支持"不等于"已在其上测试"。以下是硬件验证的真实状态。

| 板卡 | SoC | 状态 |
|---|---|---|
| **Minisforum MS-R1**（32 GB，以及 64 GB "超大杯"） | Cix Sky1 / CP8180 | ✅ **我们唯一测试过的硬件。** 全部验证 —— UEFI 启动、安装器、GPU（Mesa 26.1.3 panvk + rusticl）、NPU（Zhouyi 嵌入 + 视觉）、音频，以及 A/B 内核方案 —— 都是在这台机器上完成的。 |
| **Radxa Orion O6** | Cix Sky1 | ✅ **已验证可用。** 与 MS-R1 *板卡不同*（有其自己的设备树、PMIC、BIOS 和外设），现已确认可安装并启动。Realtek 网卡（RTL8125/8126）开箱即用 —— `rtl_nic` 固件已在安装器和已安装系统中同时附带，解决了此前无网络的回归问题。 |
| **Radxa Orion O6N** | Cix Sky1 | ⚠️ **未测试，但预计可用。** 相同的 Sky1 SoC，且与 O6 属同一板卡系列（细小变体）；我们只是尚未在硬件上确认。**如果你有 O6N：请安装、测试并提交 issue。** |
| **Framework Cix 扩展板 / 主板** | Cix Sky1 | ❌ **未测试。** 在我们的视野内；手头没有硬件。 |
| **Orange Pi（Cix 变体）** | Cix Sky1 | ❌ **未测试。** 手头没有硬件。 |
| 其他 Arm（RK3588/RK3576、MediaTek Genio、Snapdragon）与 x86（Intel、AMD） | — | 🗺️ 路线图 / 仅适配层 —— 尚未构建或测试。 |

**"未测试"对你意味着什么：** 构建路径中有些部分是 MS-R1 专属的 —— 例如一个
绕过 MS-R1 *出厂 BIOS 缺陷*的 ACPI SSDT override（该缺陷遗漏了 NPU 核心上的
`_HID="CIXH4010"`，导致它们从不枚举）、固件 blob 路径，以及板卡/设备树相关的
怪癖。在任何其他板卡上，它可能无法启动，NPU/GPU/VPU 可能无法初始化，或者安装器
需要做板级适配工作。**测试者和捐赠的硬件是把 ❌ 变成 ✅ 的最快途径。**

## 快速开始（构建 ISO）

```bash
make
# → 输出: build/nclawzero-installer-cixmini-${VERSION}.iso
```

## 快速开始（在硬件上安装）

> **必须使用有线以太网连接。** 安装器通过网络 debootstrap 基础系统并完成升级，
> 而 d-i 中无法使用 Wi-Fi。**上电前**请先插好有线网线。若检测不到链路，安装器
> 现在会以清晰的"网络自动配置失败"提示停下（插好网线后选择重试），不再静默地
> 无限循环。Realtek 网卡 —— 包括 Orion O6 的 RTL8125/8126 —— 开箱即用：
> `rtl_nic` 固件已在安装器和已安装系统中同时附带。

1. 把 ISO 刷到 U 盘（≥8 GB）：
   ```bash
   sudo bmaptool copy --bmap nclawzero-installer-cixmini.iso.bmap \
       nclawzero-installer-cixmini.iso /dev/sdX
   ```
2. 先插好**有线以太网线**，再把 U 盘插入目标机（cixmini / Orion O6），上电，
   按 F 键进入 UEFI 启动菜单，选择 U 盘
3. **选择磁盘与根文件系统。** 安装器会先显示一个真正的磁盘选择界面（适用于多盘
   系统），随后是文件系统选择 —— **btrfs**（默认：支持快照与透明压缩）或
   **ext4**（简单、最稳健）。**暂不支持** ZFS 根文件系统。两项均可通过内核
   命令行预设，用于无人值守批量部署（`ncz_disk=<设备>`、`ncz_fs=<ext4|btrfs>`）。
4. d-i 自动运行 preseed；约 20–30 分钟无人值守安装
5. 重启，拔掉 U 盘，目标机从内部存储启动 nclawzero

## 架构

安装器围绕**分层 squashfs 镜像**重新设计，取代了安装时实时 debootstrap +
apt 安装的旧模式。动机是具体的工程考量，不是架构上的偏好：安装**速度**
（解包预构建、预配置好的 squashfs 远快于 debootstrap 加上数百个软件包的
postinst 脚本在设备端逐一运行）以及**离线可靠性**（squashfs 增量包要么解压
成功要么失败，安装过程中不再有依赖网络的包解析步骤——这在旧的"安装时 apt"
模式下曾是安装失败的常见根源）。

![Architecture diagram](docs/architecture.svg)

**两个变体增量包都随每张 ISO 一同发布。** rEFInd 菜单在启动时选择 Reinhardt
（桌面版）或 Magnetar（服务器版），`preseed/extract-rootfs.sh` 将匹配的增量包
叠加到 base 之上。一张光盘，两种变体。

ISO 还自带：
- CIX 专有用户态 `.deb`，离线预置在 `assets/cix-debs/`（排除内部测试/验证用
  构建后约 30 个包，这些从未实际被安装）—— 由
  `post-install/25-cix-proprietary.sh` 用 dpkg 安装。同一批软件包**也**被
  镜像进 Cloudflare R2 上的 `ncz-os/ncz` apt 仓库（31 个包，约 81MB），以便安装后
  无需重装即可重新拉取 —— 见 [OTA 更新通道](#通过-apt-升级内核与驱动--无需重装)。
- 两个内核（默认 `6.18.26-cix-sky1-lts` + edge 版 `7.0.12-cix-sky1-next`）
  及固件，设备可在两个内核间切换而无需重新下载任何东西。
- zeroclaw 的 quadlet 定义，外加可选的 OpenClaw、Hermes 和 NemoClaw 模板（仅预置，默认均不激活）
- Plymouth 主题（定制 nclawzero 启动画面）

因此，对于 Cix 各层而言安装是可离线的：智能体 quadlet 与 OCI 镜像都只是**预置**而不会被激活；
每个智能体（包括 zeroclaw）以及 MNEMOS 记忆系统，都由运维者在安装后通过 `ncz` 按需安装。

## 设备端 AI：NPU 嵌入与推理

ISO 自带一套可用的 **NPU 嵌入栈**，让刚装好的设备能以 NPU 级延迟、离线、零配置
地进行语义记忆。这是 MNEMOS（记忆层）的核心 AI 工作负载，并且被设计为**自动**的
—— 运维者从不需要挑选模型或加速器。

### 安装中烘焙了什么

| 组件 | 落地于 | 来自 |
|---|---|---|
| NPU 内核驱动（`armchina_npu.ko`，`/dev/aipu`） | 内核 + `modules-load.d` | `assets/npu`、`80-npu.sh` |
| NPU 用户态（`libnoe.so.0.6.0` + `libnoe`/`NOE_Engine` wheel） | `/usr/share/cix/lib`、`/usr/share/cix/pypi` | `cix-noe-umd 2.0.2`、`25-cix-proprietary.sh` |
| Python 3.11 venv（libnoe wheel 仅 cp311/cp312） | `/opt/ncz/embed-venv` | `46-python311.sh`、`47-embedkit.sh` |
| **嵌入模型** `bge-small-zh-v1.5_256.cix`（INT8，512 维） | `/opt/ncz/models/` | `assets/models`、`47-embedkit.sh` |
| 离线分词器 | `/opt/ncz/models/bge-small-zh-v1.5/` | `assets/models` |
| GGUF CPU/GPU 回退 | `/opt/ncz/models/` | `assets/models` |
| 运维者文档（本节的深入文档） | `/usr/share/doc/ncz/` | `assets/docs`、`80-npu.sh` |

`.cix` 是从 Cix `ai_model_hub`（ModelScope，26_Q1）拉取的预编译 Compass-NN
产物，并**提交进本仓库**，以便重装时永不丢失（即 cixtech/cix-linux-main#21 的
故障模式）。

### 嵌入是自动的

MNEMOS 在写入时通过 `embedkit.Engine.auto()` 为每条记忆生成嵌入，它会：

1. 探测硬件，看到 `libnoe` + `/dev/aipu`，选择 `npu-cix` 适配器；
2. 从 `/opt/ncz/models/` 加载 `.cix` 并离线分词；
3. 返回用于向量检索的 512 维向量。

无需手动嵌入步骤，无需逐模型接线。同一个 `Engine.auto()` 调用在非 NPU 芯片上会
回退到 CPU/GPU —— 该套件是厂商无关的。已在 Sky1（`7.0.12-cix-sky1-next`）上验证：
语义检索正确，约 51 emb/s。

### 推理层级（什么跑在哪里）

| 工作负载 | 使用 | 避免 |
|---|---|---|
| 文本嵌入（编码器，≤256 tok） | **NPU**（`.cix`） | GPU 计算 |
| 长文档嵌入 / LLM 解码 / 动态形状 | **CPU** | NPU、GPU 计算 |
| 视觉 / CNN（mobilenet、resnet、yolo） | **NPU** | GPU 计算 |
| 显示 / 桌面 GL/Vulkan | **GPU**（panthor） | — |

NPU = 固定形状的编码器，CPU = 一切动态的，GPU = 像素而非 ML。Mali-G720 没有
协作矩阵，因此 GPU 上的 ML 计算比 CPU 慢 6–47 倍 —— 它只为显示而接线。完整的
逐驱动矩阵及数字见：[`docs/INFERENCE_LIMITS.md`](docs/INFERENCE_LIMITS.md)。

### 拉取更多模型

`.cix` 模型从 Cix hub 预编译而来（Compass 编译器未公开）。拉取单个文件：

```bash
BASE="https://www.modelscope.cn/models/cix/ai_model_hub/resolve/26_Q1"
curl -fL "$BASE/models/.../bge-small-zh_256.cix" -o model.cix
```

把它放进 `assets/models/`，在 `assets/models/MODELS-README.md` 加一行，重新构建。
完整指南（单文件 + LFS 克隆 + 自定义 ONNX→`.cix`）：
[`docs/MODELSCOPE-MODELS.md`](docs/MODELSCOPE-MODELS.md)。

### 深入文档（也会随设备发布到 `/usr/share/doc/ncz/`）

- [`docs/MNEMOS-NPU-EMBEDDINGS.md`](docs/MNEMOS-NPU-EMBEDDINGS.md) —— 自动嵌入链、I/O 契约、验证命令
- [`docs/INFERENCE_LIMITS.md`](docs/INFERENCE_LIMITS.md) —— 完整的逐硬件/驱动能力 + 限制矩阵
- [`docs/MODELSCOPE-MODELS.md`](docs/MODELSCOPE-MODELS.md) —— 拉取/编译 `.cix` 模型

## AI/ML 软件栈与项目历史

关于设备上随附了哪些 AI/ML、每个二进制和库的用途、如何把工作负载在四个计算引擎
（CPU / NPU / GPU / VPU）间路由、实测性能，以及如何拉取新模型的完整指南：

- [`docs/AI-ML-STACK.zh-CN.md`](docs/AI-ML-STACK.zh-CN.md) —— AI/ML 软件栈参考
  · [English](docs/AI-ML-STACK.md)
- [`docs/HOW-DID-WE-GET-HERE.zh-CN.md`](docs/HOW-DID-WE-GET-HERE.zh-CN.md) —— 进度复盘：
  打造这款芯片首个完整 Linux 发行版背后的工程努力 · [English](docs/HOW-DID-WE-GET-HERE.md)

## 输入

| 路径 | 来源 | 说明 |
|---|---|---|
| `assets/cix-debs/` | 离线预置的 CIX 专有 `.deb`（gitignore） | 同时也镜像进 Cloudflare R2 上的 `ncz-os/ncz`（31 个包，见 OTA 章节） |
| `assets/kernel/{stable,edge}/` | Yocto 构建 `meta-cix:linux-cix-sky1-{lts,next}`（gitignore） | 每个内核对应的 `Image-cixmini.bin` + `modules-cixmini.tgz` + `KVER`；另有 `modules-overlay/$KVER/` 子目录存放经验证的修复用 `.ko`（见 `post-install/80-npu.sh`、`81-vpu.sh`） |
| `assets/agent-stack/*` | 本仓库 | zeroclaw/openclaw/hermes/portainer/mnemos/nemoclaw 的 systemd quadlet |
| `assets/branding/*` | 本仓库 | os-release、motd、Plymouth 主题、壁纸 |
| `preseed/preseed.cfg`、`preseed/late.sh` | 本仓库 | d-i 无人值守 preseed + late_command（chroot 之前，仅安装时执行） |
| `post-install/*.sh` | 本仓库 | 40 多个编号钩子；在 chroot 内运行 |

## 阶段（安装后钩子）

`post-install/run-all.sh` 在 chroot 内按三个阶段运行编号的 `post-install/*.sh`
钩子：必需的内核/网络钩子（在预烘焙镜像上跳过，因为内核已在 squashfs 中）、
由 `MACHINE_HOOKS_RE` 门控的机器专属钩子（apt 源、CIX 专有用户态、GPU 固定、
智能体栈、Python/embedkit、Claude Code、Vivaldi、NPU/VPU 覆盖、救援分区），
以及从 `EXIT` trap 运行的引导器/诊断钩子。这份清单很容易过时（已经过时两次
了）——`run-all.sh` 和各个 `post-install/NN-*.sh` 文件才是准确记录实际运行了
什么、按什么顺序运行的权威来源，而不是这里手写的摘要。

## 远程诊断（安装器运行期间）

一个**可移除、可开关**的诊断模块，让远程运维者在 *d-i 安装器运行期间*拥有完整
访问权限，这样安装永远不会把我们关在门外，即使无人值守也能捕获故障。

> **🔑 默认登录（仅限安装器）：** 用户名 **`installer`**（或 **`root`**），
> 密码 **`diags`**。可在启动时用内核命令行的 `ncz_diag_pw=<pw>` 覆盖密码。
> （仅限局域网 / 测试 —— 见下方安全说明。）

| 通道 | 端口 | 访问方式 |
|---|---|---|
| **SSH（密码）** | 22 | `ssh root@<host>` —— 密码 `diags`。`network-console` + `sshd-watcher.sh` 强制 `PasswordAuthentication yes`/`PermitRootLogin yes`；模块会设置 root 密码，让密码认证真正可用（无需密钥）。`installer@<host>`（密码 `diags`）也能进入 network-console 菜单。 |
| **Telnet** | 23 | 来自随附静态 arm64 busybox 的丰富 shell（完整 applet：`vi`/`awk`/`sed`/`tar`/`less`/…） |
| **HTTP（文件拉取）** | 8080 | `wget http://<host>:8080/var/log/syslog`，或浏览 `http://<host>:8080/` 获取任意安装器文件（仅 GET） |
| **远程 syslog** | 5514/udp | 每一行安装器日志（外加 `DEBCONF_DEBUG=5` 的详细 d-i 输出）都发送到收集主机，这样无需登录也能拿到故障 |

**开关 / 移除（两个独立开关）。**
1. **构建开关** —— `DIAG_ENABLE=0 build/build-iso-di.sh …` 生成一个**出厂干净**的
   镜像：模块不会被暂存，`ncz_diag`/`DEBCONF_DEBUG` 也不会加入内核命令行。
   （bring-up 期间默认 `DIAG_ENABLE=1`。）
2. **启动变量** —— 即使已暂存，`ncz_diag=0|off` 也会在内核命令行禁用该模块；
   `ncz_diag=1` 启用它。可在 rEFInd 菜单处直接切换。

**可调项（内核命令行）：**
- `ncz_diag_pw=<pw>` —— root/diag 密码（默认 `diags`）。
- `ncz_diag_log=<host[:port]>` —— 远程 syslog 收集器（默认指向构建方的内部开发收集器，端口 `5514`）。
  指向你自己的机器。

**工作原理。** 一个静态 arm64 busybox（`assets/diag/busybox-arm64`，内编
`telnetd`/`httpd`/`syslogd`/`klogd`/`chpasswd`）随光盘发布；`preseed/early_command`
在后台启动 `preseed/diag-console.sh`。该脚本依据 `ncz_diag` 自我门控，安装完整
applet 以提供丰富 shell，设置 root 密码，用一个**同时转发到收集器**的 syslogd
替换 d-i 的 syslogd，并启动 telnetd + httpd —— 全部**幂等**（pidfile 守卫）且在
整个安装期间自我重生。基础 d-i initrd 没有这些（只有 `nc`/`wget`/`tftp`，且仅在
network-console 之后才有 `sshd`）。

**收集器侧。** 在你自己的收集主机上运行 `ncz-logd.sh`：一个监听
`:5514` 的 `socat` UDP 监听器，追加写入 `~/cixmini-install-logs/install-<date>.log`。
安装期间 `tail -f` 它即可。

**文件传输。** *拉取：* `wget http://<host>:8080/<path>`。*推送：* 通过 SSH，
`cat local | ssh root@<host> 'cat >/tmp/x'`（httpd 仅 GET）。

在**已安装的系统**上，完整 SSH（scp/sftp）、:23 上的 telnet
（`post-install/36-telemetry.sh`）和遥测接管；仅限安装器的控制台随 d-i ramdisk
一同消失。

> **安全：** 默认密码 `diags`、近乎无认证的 telnet root shell、以及全局可读的
> httpd 都是**仅限局域网 / 仅供测试**。发布时用 `DIAG_ENABLE=0`（或 `ncz_diag=0`）
> 一键剥离整个模块。

### 已安装系统的访问姿态（默认）

- **运行中的设备上没有诊断账户。** `post-install/09-diag-account.sh` 会播种
  `magnetar` 救援账户，让安装/首次启动永远不会把你锁在外面，但它是**仅限安装器**
  的：一个首次启动的 oneshot（`nclawzero-diag-selfdestruct.service`）会删除该账户
  及其每一个产物（sudoers 片段、AccountsService 条目、SSH 密钥、标记），然后删除
  自身。首次干净启动后，交付的系统**不携带任何**诊断凭据。（若首次启动在它运行前
  失败，该账户仍在以供救援。）
- **已安装系统默认启用密码 SSH 认证**，以方便运维（`PasswordAuthentication yes`）。
  日常登录使用你在安装时设置的运维账户。要把车队镜像加固为仅密钥，在
  `post-install/35-ssh.sh` 中设置 `PasswordAuthentication no` /
  `PermitRootLogin prohibit-password` 并重新烘焙。
- **主机名**默认为 `ncz-<mac8>`（首个有线 MAC 的后 8 位十六进制），这样局域网上
  每台机器都有唯一名称；安装时设置的运维者主机名（若有）始终优先。见
  `post-install/37-ntp-hostname.sh`。

## 救援分区

每次安装都会附带一个独立的 4 GiB ext4 **NCZRESCUE** 分区，由
`post-install/72-rescue-partition.sh` 在安装时用预构建的救援根文件系统
（`build/build-rescue-rootfs.sh`）填充。它有自己的 rEFInd 菜单项
（"RESCUE PARTITION"），与主根文件系统相互独立 —— 即使主系统（btrfs 或
ext4）无法启动，救援分区仍能启动。

**登录：** root，密码 **`rescue`**（仅限局域网使用）。主机名 `ncz-rescue`。

**访问方式：** SSH（22 端口，密码认证）、dropbear（2222 端口）、telnet
（23 端口）、串口控制台（`ttyAMA2@115200`）。DHCP 失败时回退到静态 IP
`192.168.207.66/24`（网关 `192.168.207.1`）。

**工具集：** 一套真正完整的恢复工具集（不只是最小 shell）——
文件系统（btrfs-progs、e2fsprogs、xfsprogs 等）、磁盘/分区
（fdisk、parted、gdisk、nvme-cli、lvm2、cryptsetup）、镜像/数据恢复
（`ddrescue`、`testdisk`+`photorec`）、网络（完整 iproute2/net-tools、
tcpdump、socat、rclone）、硬件诊断（pciutils、usbutils、efibootmgr、
`refind` 本身）、内核/initrd 修复（kmod、initramfs-tools、
device-tree-compiler，以及两个专用助手 `ncz-rescue-fixlib` 和
`ncz-rescue-chroot <device>`）、shell/脚本（vim、tmux、python3）。
`/AGENTS.md` 记录了系统信息与逐步恢复流程。

## 通过 APT 升级内核与驱动 —— 无需重装

`post-install/24-apt-sources.sh` 接入 Cloudflare R2 上的 apt 源并刷新软件包索引，
且刻意放在很早的位置（在任何安装软件包的钩子之前），这样它们各自的依赖解析步骤都能
拿到真实、最新的索引数据。这修复了一个 2026-07-05 的回归问题：
`vivaldi-stable` 在每次全新安装时都会卡在 dpkg 的 `iU`（半配置）状态，因为其
`fonts-liberation` 依赖无法解析。根因**不是**缺少 apt 源 —— Ubuntu 官方源
（main+universe+restricted+multiverse，一直默认启用）本来就在那里 —— 而是
在那个依赖解析步骤需要之前，从未运行过 `apt-get update`，再加上该步骤当时用了
`--no-download`（已在 `52-vivaldi.sh` 中单独修复）。

**软件包各自的来源。**
- **Ubuntu 官方源**（main + universe + restricted + multiverse，以及
  `-updates`/`-security`/`-backports`）→ `ports.ubuntu.com/ubuntu-ports`
  （arm64）。每个镜像默认启用于 `/etc/apt/sources.list` —— 这从来都不是
  "仅限光盘"，尽管仓库里有些注释这样描述过一种"仅离线"的信条；那种信条
  针对的是特定的单一厂商源（见下文 Vivaldi），而不是 Ubuntu 官方源本身。
- **内核** —— 编译好的 `linux-image-cixmini-{lts,edge}` + `cixmini-boot`
  （`build/build-kernel-debs.sh`）→ 一个公开的 **Cloudflare R2** 存储桶上经
  签名的 Debian 仓库 `ncz-os/ncz`，由 `post-install/24-apt-sources.sh` 接入：
  `deb [signed-by=…] https://pub-d7b784e01679403d9c70fcd23fff5b96.r2.dev any main`。
  仓库此前托管在 Buildkite Packages 上，但其私有注册表存在鉴权 bug、改为公开后
  又撞上套餐层级的资源限额，曾在真机上导致 `apt-get update` 返回 `403
  Forbidden` 的硬性安装失败 —— 已于 2026-07-05 整体迁移至 R2：无需客户端鉴权，
  也没有套餐配额，且 R2 没有出口流量费用，经由 Cloudflare 边缘节点提供服务。
- **CIX 用户态驱动/运行时** → **同一个** R2 上的 `ncz-os/ncz` 仓库（于
  2026-07-05 从 `archive.cixtech.com` —— 上游 CIX 的中国大陆托管 Debian 仓库，
  经常直接拒绝连接 —— 镜像而来）。共 31 个包，约 81MB；5 个从未实际安装的内部
  测试/验证用包（`cix-unit-test`、`cix-npu-onnxruntime`、`cix-ltp`、
  `cix-gpu-test`、`cix-vpu-test`，合计 1.6GB）已被排除。这里**不存在** Codeberg
  apt 源 —— 本文档早期版本描述过一个（`post-install/91-codeberg-apt.sh`），但该
  脚本在本仓库中从未真正实现过。
- **内核源码 + Yocto 配方** → GitLab [`ncz-os/meta-cix`](https://gitlab.com/ncz-os/meta-cix)。

R2 上的这个源经 GPG 签名（`signed-by`，绝非 `trusted=yes`）；安装介质的
`file:///cdrom` 源在安装后被移除，此前的 GHCR/squashfs OTA 机制
（`90-ota-channel.sh`）已废弃。

**如何更新。** 在设备上，`apt update && apt upgrade`（或
`ncz-update [--apply]`）会从签名仓库拉取新内核 + CIX 软件包并安装 ——
切换到新内核不再需要重装系统。

## 当前 ISO — r195（NCZ-OS 26.6 正式发布）

内核 + CIX 专有软件包现已从一个公开的 **Cloudflare R2** apt 仓库分发，
不再经由 Buildkite Packages —— 修复了一个曾在真机上导致硬性安装失败
（`403 Forbidden`）的真实缺陷。NoMachine 已被移除（xrdp 是唯一的图形化
远程访问方式）；同时屏蔽了几个每次启动都失败、无用的服务以精简启动日志。
本版本同时携带 r192/r193 的成果：**Reinhardt（桌面版）与 Magnetar（服务器版）
都能从同一张光盘安装**，且 **APT 内核 + CIX 用户态升级**现已真正由 dpkg
跟踪 —— 切换新内核或驱动构建无需重装。两个变体均已在 KVM 下完成端到端启动
验证（rEFInd → 内核 → d-i → preseed 启动，在具备硬件加速的通用 aarch64
虚拟主板上确认；完整的 NPU/GPU/VPU/音频驱动验证仍仅限于 MS-R1 真机，见上文
**硬件支持与测试状态**）。

**内核：** 6.18.26-cix-sky1-lts（默认，生产）+ 7.0.12-cix-sky1-next（edge）。（7.1.2 为实验性/不可用；7.2 迁移进行中。）

两者的来源不同：**6.18.26 LTS** 是主线 Linux 加上
[Sky1-Linux](https://github.com/Sky1-Linux/linux-sky1) 社区补丁 ——
一个我们消费、打包的上游友好型社区 fork，并非我们自己的内核工作。
**7.0.12 NEXT** 则是*我们自己*移植的：我们拿原始的 v7.0.12 稳定版 tag，
自行完成了 MS-R1 专属的验证与修复（SCMI、GPU、VPU、NPU、显示，以及从
LTS 代码树移植过来的音频栈）。

**安装：** 无人值守 d-i（自动分区：ESP + NCZRESCUE 救援分区），rEFInd 引导。可交互选择磁盘与根文件系统 —— **btrfs**（默认）或 **ext4**；暂不支持 ZFS 根。安装器运行于经验证的 6.18 LTS 内核。

**恢复：** NCZRESCUE 分区含完整修复工具集 + 自动联网，独立于主根文件系统可达；USB 启动时安装器远程诊断（network-console + telnet/http）可用。

**MS-R1（cixmini）驱动支持 —— 6.18 / 7.0.12：** NVMe/PCIe、USB、以太网/Wi-Fi、音频、NPU（Zhouyi V3 `/dev/aipu`）、GPU（Mali-G720 panthor `renderD128`，Mesa 26.1.3 panvk+rusticl；合成关闭）、VPU 均正常。

**复现：** 内核源自 kernel.org stable git + meta-cix 补丁系列（Yocto，见 [docs/KERNEL-BUILD-YOCTO.md](docs/KERNEL-BUILD-YOCTO.md)）；ISO 经 build/build-iso-di.sh 构建（见 [docs/NEXT_ISO.md](docs/NEXT_ISO.md)）。无需单独的内核源码仓库 —— meta-cix 已将每一个 Sky1 专属补丁作为受版本控制的文件保存。

## 状态

**26.6（r194）** —— 当前发布。开源 Mesa 26.1.3 栈是 **OpenGL/GLX、Vulkan
和 OpenCL** 的完整默认 GPU 提供方；CIX 专有栈仍保留在磁盘上（`.disabled`），
供将来的可选切换器使用。仅在 Minisforum MS-R1 上测试 —— 见上文**硬件支持与测试
状态**。**Reinhardt**（桌面）与 **Magnetar**（服务器）现在都能从*同一张*
ISO 启动并安装 —— rEFInd 选择变体，两个 squashfs 增量包都随每张光盘发布（见
[架构](#架构)）。

自 r147 基线以来的变更：

- **r193 —— apt 内核升级承诺终于名副其实。** r147/r192 就宣称"`apt upgrade`
  可拉取新内核，无需重装"，但那只是设计意图，实际运行并非如此：内核此前是
  靠原始文件拷贝（`install -D` + `tar xzf`）直接写入 `/boot` 和
  `/usr/lib/modules`，完全绕过了 dpkg —— 即便一台机器正在运行该内核，
  `apt-cache policy` 仍显示"未安装"，`apt upgrade` 自然认为无需升级。现在
  内核改由 `apt-get install linux-image-cixmini-{lts,edge}` 从签名仓库安装，
  dpkg 能真正跟踪它；配套修复了 rEFInd 菜单刷新脚本（安装后仍可调用）以及
  `cixmini-boot` 的钩子（此前误写入已废弃的 systemd-boot 条目）。
- **r195 —— 内核通道前移：7.0.12=稳定，7.2=前沿（VPU 挂死修复、ASPM quirk 修正、panthor 移除、Yocto 6.0 构建）；6.18 退役；基础镜像瘦身约 2 GB。**
- **r194 —— apt 仓库迁移至 Cloudflare R2；移除 NoMachine；启动更安静。**
  一位社区用户在真机上遇到安装硬性失败：拉取内核仓库时 `apt-get update`
  返回 `403 Forbidden`。根因是原 Buildkite 私有仓库的鉴权配置有误，读取令牌
  从未真正生效；改为公开后又撞上了套餐层级的资源限额。修复方式是把内核构建
  与 CIX 专有用户态整体迁移到一个公开的 Cloudflare R2 存储桶 —— 无需客户端
  鉴权，也没有套餐限额，已在真机全新安装上端到端验证。本次还给安装器新增了
  IPv6 DNS 回退（此前仅 IPv4），彻底移除了 NoMachine（其首次启动网络安装并不
  可靠，已确认在真机安装上失败），改由 xrdp 作为唯一的图形化远程访问方式；
  并屏蔽了三个每次启动都失败或配置有误、对本平台毫无用处的服务
  （`cix-audio-switch`、`iscsid`、`apport`）。
- **r192 —— 分层 squashfs 缺陷排查 + 双变体修复 + apt 源加固。** 一整天
  针对全新安装的端到端验证发现并修复了若干真实缺陷，均非表面问题：
  - **ISO 曾虚胖约 3GB。** squashfs 层被重复打包了两次 —— 一次是正确的路径，
    另一次是通过一个通用资产复制步骤（没有为 `assets/squashfs/` 设置排除
    规则）。已修复；ISO 从 7.98GB 降到 5.0GB。
  - **服务器变体从未真正登上过 ISO。** `manifests/server.pkgs` 此前不存在，
    因此 `server.squashfs` 从未被构建过；rEFInd 菜单曾提供一个 Magnetar 启动
    选项，选择后会静默降级为仅有 base 的安装。现已构建、打包，并在 KVM 下
    完成启动测试。
  - **`vivaldi-stable` 在每次全新安装时都卡在半配置状态。** 根因：一处
    manifest 内联注释破坏了整个 apt 事务，连带静默丢弃了 `librsvg2-bin` 及
    若干 Vulkan/SPIR-V 软件包 —— 并非缺少 apt 源（Ubuntu 官方源其实一直都在）。
    已在解析器层面修复，防止此类缺陷再次发生；同时修复了一个可能无限期挂起
    squashfs 构建、且没有 tty 可以应答的 `needrestart` 内核升级提示。
  - **离线镜像重建现在是增量式的**，不再是每次都完整清空并重新下载约
    1500 个软件包的闭包。
  - **内核配置缺口**：Sky1 的 NPU 报告的是 Zhouyi ISA 版本 5（V3），但此前
    只启用了 `CONFIG_ARMCHINA_NPU_ARCH_V3_1`（版本 6）—— 部分安装上 NPU
    因此是暗的。现在两者都已启用。
  - 其他若干小修复：一个（Zoder）桌面图标此前会打开一个空白终端而不是指向
    项目主页；若干安装时钩子（SSH、telnet 控制台、NTP/主机名、故障保护恢复
    控制台、xrdp、nspawn 恢复容器、Magnetar 无头模式切换）虽已存在
    于仓库中，却从未真正接入预烘焙镜像的钩子白名单，因此静默地从未运行过。
- **r147 —— 首个支持 apt 内核升级的正式版。** `apt upgrade` /
  `ncz-update` 从 Buildkite Packages 拉取新内核 —— 切换内核无需重装。
  已在 QEMU 中端到端验证。
- **r126 —— 开源 Mesa 成为完整默认；修复桌面与 Vulkan。**
  `26-gpu-default-open.sh` 现在会把*所有* CIX GPU 组件从加载器路径中降级。此前
  CIX 的 `cix-libglvnd` `libGLX.so.0` 会执行一次"CIX 驱动检查"，失败后（没有
  `mali_kbase`；GPU 由 panthor 接管）直接调用 `abort()` —— 拖垮 Xorg 并使
  lightdm 崩溃重启（启动后看起来像没有图形界面的"服务器"）。CIX 的 Vulkan ICD
  （`mali.json`）和 WSI 隐式层会以同样方式让每个应用的 `vkCreateInstance` 中止。
  把 cixgpu-compat（GL/GLX）、`mali.json` 和 WSI 层降级 —— 连同已有的
  cixgpu-pro（OpenCL）降级 —— 使 Mesa 在各处成为默认：桌面直接启动到 XFCE
  登录界面，`panvk` Vulkan 与 `rusticl` OpenCL 无需任何环境变量覆盖即可工作。
- **r125 —— rusticl OpenCL 开箱即用。** 将缺失的 `libclang-cpp` +
  `libLLVMSPIRVLib` 运行库（`$ORIGIN` RPATH）和 `libclc` SPIR-V 打包进 Mesa
  bundle，并降级了遮蔽 `ocl-icd` 的 CIX `libOpenCL.so.1`。`clinfo` →
  `Mali-G720 MC10 (Panfrost)`，OpenCL 3.0。
- **r124 —— 智能体改为可选安装；NPU 门控加固。** 所有智能体（包括 `zeroclaw`）
  现在通过 `ncz agent install` 按需安装（桌面图标 + 首次登录提示），不再自动激活，
  消除了首次启动的崩溃重启。收紧了 NPU SSDT 注入门控，使其不再在未识别的主板上误触发。
- **r113 —— 首个完整发布**，带来 Mesa 26.1.3 GPU 计算栈（panvk + rusticl）、
  经验证的 NPU 嵌入，以及 A/B 内核方案（6.18 LTS 默认 + 7.0.x edge）。

## 姊妹项目

- [`gitlab.com/ncz-os/cix-gen`](https://gitlab.com/ncz-os/cix-gen) —— 基于脚本的镜像构建器；从一个可用的 aarch64 系统运行，绕过 d-i 流程。用例不同（原地重建 vs 全新安装）。
- [`gitlab.com/ncz-os/meta-cix`](https://gitlab.com/ncz-os/meta-cix) —— 提供内核配方（LTS 版 `linux-cix-sky1_6.18.26.bb`、edge 版 `linux-cix-sky1-next_7.0.12.bb`）以及本安装器所消费的 Cix 用户态配方的 Yocto BSP 层。内核源码本身直接取自公开的 `kernel.org` 稳定版代码树的某个固定提交；每一个 Sky1 专属补丁都是本层中受版本控制的文件 —— 复现构建无需另外的内核源码仓库。见 [`docs/KERNEL-BUILD-YOCTO.md`](docs/KERNEL-BUILD-YOCTO.md)。
