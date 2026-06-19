# cix-installer

> **🌐 语言：** [English](README.md) · 简体中文
>
> **📚 从这里开始：** [AI/ML 软件栈参考](docs/AI-ML-STACK.zh-CN.md) ([English](docs/AI-ML-STACK.md)) · [我们是如何走到这一步的 —— 工程复盘](docs/HOW-DID-WE-GET-HERE.zh-CN.md) ([English](docs/HOW-DID-WE-GET-HERE.md)) · [下载 ISO](https://gitlab.com/ncz-os/cix-installer/-/releases/v26.6-r113)

**面向 NCZ Linux 发行版的定制化 debian-installer ISO 构建器。**

生成一个完全无人值守、可 UEFI 启动的安装器 ISO：对目标磁盘分区，先用
debootstrap 安装 Debian 12 基础系统并在磁盘上全量升级到 Ubuntu（resolute），
然后叠加适配硬件的内核 + 厂商用户态运行时 + 桌面环境 + Claude Code + NCZ 智能体
栈（`zeroclaw` 默认激活；`openclaw`、`hermes`、`portainer`、`nemoclaw` 可选），
并将系统品牌化为 NCZ（桌面版为 Reinhardt，服务器/常驻智能体设备为 Magnetar）。

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
- **智能体运行时**：可并存选择。`zeroclaw` 默认激活；运维者可用 `ncz agent install`
  选装 `openclaw`、`hermes` 和 `portainer`，或用 `ncz install nemoclaw` 选装
  NVIDIA NemoClaw。

`build/build-iso-di.sh` 中当前的构建路径是 Cix Sky1 的实现；其架构是可复用的脚手架。

## 硬件支持与测试状态

> **在刷写任何东西之前请先读这一节。** NCZ 在*设计上*是厂商中立的，但"设计上
> 支持"不等于"已在其上测试"。以下是硬件验证的真实状态。

| 板卡 | SoC | 状态 |
|---|---|---|
| **Minisforum MS-R1**（32 GB，以及 64 GB "超大杯"） | Cix Sky1 / CP8180 | ✅ **我们唯一测试过的硬件。** 全部验证 —— UEFI 启动、安装器、GPU（Mesa 26.1.3 panvk + rusticl）、NPU（Zhouyi 嵌入 + 视觉）、音频，以及 A/B 内核方案 —— 都是在这台机器上完成的。 |
| **Radxa Orion O6 / O6N** | Cix Sky1 | ❌ **未测试 —— 我们非常需要测试者。** 相同的 SoC，但*板卡不同*（设备树、PMIC、BIOS、外设都不同）。我们**没有**这台机器。**如果你有 O6：请安装、测试并提交 issue。如果 Radxa 的同仁看到这里 —— 我们需要一台板子。** |
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

1. 把 ISO 刷到 U 盘（≥4 GB）：
   ```bash
   sudo bmaptool copy --bmap nclawzero-installer-cixmini.iso.bmap \
       nclawzero-installer-cixmini.iso /dev/sdX
   ```
2. 插入目标机（cixmini），上电，按 F 键进入 UEFI 启动菜单，选择 U 盘
3. d-i 自动运行 preseed；约 20–30 分钟无人值守安装
4. 重启，拔掉 U 盘，目标机从内部存储启动 nclawzero

## 架构

```
┌────────────────────────────────────────────────────────────────┐
│                  nclawzero-installer-cixmini.iso               │
│                                                                │
│  ┌─────────────────────────┐    ┌───────────────────────────┐  │
│  │  Debian d-i 基础 ISO    │    │  定制资产层               │  │
│  │  (debian-12-netinst-    │    │  - preseed.cfg            │  │
│  │   arm64.iso)            │    │  - post-install/*.sh      │  │
│  │  - UEFI 引导器          │    │  - assets/cix-debs/*.deb  │  │
│  │  - kernel + initrd      │    │  - assets/kernel/*        │  │
│  │  - debootstrap          │    │  - assets/agent-stack/*   │  │
│  │  - partman              │    │  - assets/branding/*      │  │
│  │  - tasksel              │    │  (在 late_command         │  │
│  │  - apt                  │    │   期间解压到 /target)     │  │
│  └─────────────────────────┘    └───────────────────────────┘  │
└────────────────────────────────────────────────────────────────┘
```

ISO 自带以下内容的副本：
- 37 个 Cix 专有 `.deb`（约 1.9 GB）—— 闭源用户态
- `linux-cix-msr1` 内核二进制 + 模块 tarball（约 640 MB）
- zeroclaw 的 quadlet 定义，外加可选的 OpenClaw、Hermes 和 NemoClaw 模板
- Plymouth 主题（定制 nclawzero 启动画面）

因此，对于 Cix 各层而言安装是可离线的，并且只默认激活 zeroclaw；可选的智能体
运行时由运维者在安装后自行拉取。

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
| `assets/cix-debs/` | 对原厂 Cix Debian 做 `dpkg-repack`（gitignore） | 37 个闭源 `.deb` |
| `assets/kernel/Image-cixmini.bin` + `modules-cixmini.tgz` | Yocto 构建 `meta-cix:linux-cix-msr1`（gitignore） | 我们的内核产物 |
| `assets/agent-stack/*` | `meta-cix/recipes-nclawzero/agent-stack/files/` | systemd quadlet（已提交） |
| `assets/branding/*` | 本仓库 | os-release、motd、Plymouth 主题 |
| `preseed/preseed.cfg` | 本仓库 | d-i 无人值守 preseed |
| `post-install/*.sh` | 本仓库 | 安装末尾在 chroot 中按序运行的编号钩子 |

## 阶段（安装后钩子）

`/target/usr/local/lib/cix-installer/` 通过 `preseed/late_command` 按序运行：

1. `00-cix-proprietary.sh` —— `dpkg -i` 37 个 Cix `.deb`
2. `10-our-kernel.sh` —— 安装 `linux-cix-msr1` 内核二进制 + 模块
3. `20-desktop.sh` —— apt 安装 GNOME + chromium + gnome-remote-desktop
4. `30-agents.sh` —— 安装 podman + zeroclaw 默认 quadlet + 可选智能体模板
5. `40-claude-code.sh` —— `npm install -g @anthropic-ai/claude-code`
6. `50-brand.sh` —— `/etc/os-release`、motd、主机名
7. `60-plymouth.sh` —— Plymouth 启动画面 + nclawzero 主题

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
   `ncz_diag=1` 启用它。可在 GRUB 菜单处直接切换。

**可调项（内核命令行）：**
- `ncz_diag_pw=<pw>` —— root/diag 密码（默认 `diags`）。
- `ncz_diag_log=<host[:port]>` —— 远程 syslog 收集器（默认 `192.168.207.22:5514`）。
  指向你自己的机器。

**工作原理。** 一个静态 arm64 busybox（`assets/diag/busybox-arm64`，内编
`telnetd`/`httpd`/`syslogd`/`klogd`/`chpasswd`）随光盘发布；`preseed/early_command`
在后台启动 `preseed/diag-console.sh`。该脚本依据 `ncz_diag` 自我门控，安装完整
applet 以提供丰富 shell，设置 root 密码，用一个**同时转发到收集器**的 syslogd
替换 d-i 的 syslogd，并启动 telnetd + httpd —— 全部**幂等**（pidfile 守卫）且在
整个安装期间自我重生。基础 d-i initrd 没有这些（只有 `nc`/`wget`/`tftp`，且仅在
network-console 之后才有 `sshd`）。

**收集器侧。** 在收集主机（如 `192.168.207.22`）上运行 `ncz-logd.sh`：一个监听
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

## OTA 通道（内核 + 驱动更新）

已部署的设备通过一个**临时的、容器交付的 APT 仓库**升级其内核和专有 CIX 驱动
—— 而不是一个持久的在线仓库。

**如何发布。** `build/build-kernel-debs.sh` 把内核打包为真正的 `.deb`
（`cixmini-boot`、`linux-image-cixmini-lts`、`linux-image-cixmini-edge`）；
`build/build-ota-repo.sh` 把它们与 CIX 驱动 `.deb` 组合成一个 `apt-ftparchive`
仓库，**用 NCZ OTA 归档密钥对 `Release` 进行 GPG 签名**（clearsigned `InRelease`
+ 分离的 `Release.gpg`），并打包进单个 `squashfs`；`build/build-ota-image.sh` 把该
squashfs 包进一个 OCI 镜像（`FROM scratch`，以 squashfs 的 `sha256` 标注），推送到
`ghcr.io/ncz-os/cix-repo`。私有签名密钥及其 GNUPGHOME 仅存在于构建主机的
`build/keys/` 下（gitignore）；配套的**公钥环随
`assets/keys/ncz-ota-archive-keyring.gpg` 发布**，并在安装时配置到每台设备上
（`post-install/90-ota-channel.sh` → `/usr/share/keyrings/ncz-ota-archive-keyring.gpg`）。

**如何更新。** 在设备上，`ncz-update [--apply]`：

0. **在拉取或挂载任何东西之前，先用 cosign 验证 OCI 镜像签名**
   （`cosign verify --key /usr/share/keyrings/ncz-ota-cosign.pub`），然后把 `IMG`
   钉死到 cosign 验证过的确切摘要（无 tag TOCTOU）。cosign 在需要时按需获取
   （版本钉死、sha256 校验）；若已配置 cosign 公钥却无法执行验证，则该次运行宁可
   拒绝也不静默跳过检查。
1. 拉取该已验证摘要的 OCI 镜像（`podman` > `skopeo` > `docker`）并解出 squashfs，
2. 对照镜像标签校验其 `sha256`（一个廉价的损坏绊线），
3. **仅在 apt 事务期间以只读方式 loop 挂载到 `/run/ncz-ota/repo`**，写入一个用
   `[signed-by=/usr/share/keyrings/ncz-ota-archive-keyring.gpg]` 钉死的临时 apt
   源 —— **不是** `trusted=yes`，因此 `apt` 会针对 NCZ OTA 密钥对已签名的
   `InRelease` 做密码学验证，并拒绝任何未签名或外来签名的仓库，
4. 对 cix/内核包运行 `apt-get install --only-upgrade`，
5. 然后通过一个有保障的拆解（EXIT trap）**完全卸载一切**：卸载、分离 loop 设备、
   删除 squashfs、清理拉取的 OCI 镜像，并移除临时 apt 源及其缓存索引。

对于锁定/可复现的车队，在 `/etc/ncz-ota.conf` 中把 `IMG` 钉死到一个摘要
（`ghcr.io/ncz-os/cix-repo@sha256:…`）而非滚动的 `:26.6` tag；无论哪种方式，GPG
签名仍保证包层的真实性。

`ncz-update --status` 报告已配置的镜像和已安装的版本，不拉取任何东西。

**为什么仓库是临时的（而非持久的 `fstab` loop 挂载）。**

- **占用** —— 持久 loop 挂载会让 2.1 GB+ 的 squashfs 后备文件无限期留在磁盘上，
  并让其解压后的页面在页缓存中累积。该仓库只在 `apt` 读取 `.deb` 时才需要；在
  存储/内存有限的设备上，我们在之后立即回收它（删除文件 + 取消挂载使那些页缓存
  页面可回收）。
- **卫生 / 信任窗口** —— 永久挂载的 `file://` 源会扩大信任面，并使之后每一次
  `apt update` 都依赖该挂载的存在。每次按需拉取并拆解，可把该窗口降到最小。
- **确定性** —— OTA 仓库是一个临时的*构建输入*，而非运行系统的一部分。
  拉取 → 使用 → 丢弃，让已安装系统保持可复现，并避免陈旧索引。

> **信任模型（两个独立签名）。**
> 1. **传输层** —— OCI 镜像是 **cosign 签名**的（`build/release-ota.sh`，密钥在
>    `build/keys/cosign.key`，公钥作为 `assets/keys/ncz-ota-cosign.pub` 发布）。
>    `ncz-update` 在拉取/挂载*之前*运行 `cosign verify` 并钉死验证过的摘要，因此
>    被替换或未签名的镜像会被当场拒绝。
> 2. **包层** —— squashfs 内的 apt `Release` 是 **GPG 签名**的，并通过 `signed-by`
>    针对设备钉死的密钥环验证（无 `trusted=yes`），因此即使是传输合法但外来的
>    仓库也无法安装。
>
> 两个私钥都仅存在于构建主机（`build/keys/`，gitignore）且从不发布。镜像标签中的
> squashfs `sha256` 是第三道损坏/篡改绊线。剩余加固项：cosign + GPG 密钥
> 轮换/过期策略，以及（可选）Rekor 透明日志收录。见 `post-install/90-ota-channel.sh`、
> `build/build-ota-repo.sh` 和 `build/release-ota.sh`。

## 状态

**26.6（r113）** —— 首个完整发布，带来 Mesa 26.1.3 GPU 计算栈（panvk + rusticl）、
经验证的 NPU 嵌入，以及 A/B 内核方案（6.18 LTS 默认 + 7.0.x edge）。仅在
Minisforum MS-R1 上测试 —— 见上文**硬件支持与测试状态**。**Reinhardt**（桌面）和
**Magnetar**（服务器）两个变体都从这棵代码树构建。

## 姊妹项目

- [`gitlab.com/nclawzero/cix-gen`](https://gitlab.com/nclawzero/cix-gen) —— 基于脚本的镜像构建器；从一个可用的 aarch64 系统运行，绕过 d-i 流程。用例不同（原地重建 vs 全新安装）。
- [`gitlab.com/nclawzero/meta-cix`](https://gitlab.com/nclawzero/meta-cix) —— BSP 的 Yocto 层（内核 + Cix 用户态配方）。提供此处消费的 `linux-cix-msr1` 内核产物。
