# NCZ 26.5 "Reinhardt" — Release Notes / 发布说明

**Release / 版本号:** r74-Reinhardt-thin
**Date / 日期:** 2026-05-06
**ISO sha256:** `e3143b76e0308e65ff61a2367db347e0550f3bba703555999a02af5c03db29cd`
**Architecture / 架构:** ARM64 (aarch64)
**Hardware target / 目标硬件:** Minisforum MS-R1 / Radxa Orion O6 / Framework 13 CP8180 mainboard / any Cix Sky1-based system / 任何基于 Cix Sky1 / CP8180 的设备
**Base distribution / 基础发行版:** Ubuntu 25.10 "Questing Quokka" (questing)
**Tagline / 口号:** *Workloads. Not wallpapers.* / *实干，非装点。*

> Dr. Reinhardt has gone into the Black Hole.
> 莱因哈特博士已经进入黑洞。

> NCZ is a trilingual project — release notes and on-device docs ship in **US English** and **Simplified Chinese (简体中文)**. NCZ is a personal-OSS project that lives at the boundary of US and Chinese open-source ecosystems: built on Yocto + Ubuntu (US/EU), targeting Cix Sky1 silicon (China), integrating ArmChina Zhouyi NPU tooling and FyrbyAdditive's community Linux port. We believe an open Linux on this silicon strengthens both ecosystems.
>
> NCZ 是一个个人开源项目，位于中美开源生态的交汇处：以 Yocto + Ubuntu（美国/欧洲）为基础，面向 Cix Sky1 芯片（中国），整合 ArmChina 周易 NPU 工具链和 FyrbyAdditive 社区 Linux 移植版。我们相信，在这块芯片上拥有一个开放的 Linux 发行版，将同时增强两个生态系统。

---

## Before you install — read this

**Use a fast, name-brand USB 3.x stick.**

The installer is sequential-IOPS-bound on the install media — most of the install time is reading thousands of small files off the USB (debootstrap base, ~37 Cix proprietary debs, kernel tarballs, agent OCI layers). Even on a fast stick the full install takes **~15-25 minutes**; on a slow stick it can take an hour.

Recommended USB sticks:
- **SanDisk Extreme / Extreme Pro** (USB 3.0 / 3.2)
- **Samsung Bar Plus** (USB 3.x)
- **Kingston DataTraveler Max / Kyson** (USB 3.x)

Avoid:
- **Cheap generic / no-brand sticks** — controllers often lie about write completion (writes go to internal RAM cache and never reach NAND), leaving you with a "flashed" stick that boots stale content. Several of ours did this during development.
- **USB 2.0 sticks** — capped at ~30 MB/s, doubles install time.

**Use the front USB-A port labeled "SS" on the MS-R1.** The MS-R1 has two front USB-A ports; only the one with the **"SS" mark** is SuperSpeed (USB 3.x — visually identifiable by the blue plastic interior). The other front port and rear ports are USB 2.0 only and will roughly double install time.

**Verify the flash from cold-cache reads before booting.** Run after dd:
- macOS: `sudo dd if=/dev/rdisk8 bs=1m count=3727 | shasum -a 256` and compare to the ISO SHA
- Linux: `sudo bash -c 'echo 3 > /proc/sys/vm/drop_caches; sleep 2; dd if=/dev/sdX bs=4M count=932 iflag=direct | sha256sum'`

Cheap-stick controllers will silently report success without persisting writes — verifying SHA from a fresh cache-dropped read is the only way to know the stick is actually populated.

If d-i prompts for hostname (defaults to "debian") instead of pre-filling "mini", the preseed didn't load — your USB has a stale or incomplete flash. Re-flash with a verify cycle.

---

## What is NCZ?

NCZ is a Linux distribution for **Cix Sky1 / CP8180** ARM64 hardware. It packages:

- A custom **Yocto-built kernel** (linux-cix-sky1) with full Sky1 SoC driver support (NPU, GPU, VPU, DSP, audio).
- **Ubuntu 25.10 questing** userspace (apt, systemd, GNOME ecosystem) — chosen for current package availability and broad ARM64 support.
- A pre-loaded **agent stack** (zeroclaw, openclaw, hermes) running as Podman containers under systemd quadlets.
- **NPU enablement** (Cix Zhouyi v3, 12 compute units) integrating FyrbyAdditive's MS-R1 patches — the kernel module probes clean, `/dev/aipu` is created, and `cix-noe-umd 2.0.2` userspace inference works end-to-end.
- An XFCE desktop with NCZ branding (cosmic-destruction aesthetic, amber accretion-disk palette).

This is a **first-of-kind** distribution for Sky1 hardware. No prior commercial Ubuntu image existed for this SoC. The path was: Yocto-built BSP for the kernel, debootstrap-style installer for the userspace, FyrbyAdditive's BIOS-bug-workaround SSDT override + v0-compat ioctl shim for the NPU, and a custom Debian-installer fork to glue them together.

---

## What's installed

### Kernels (dual)

Two kernels ship side-by-side. The bootloader defaults to LTS; NEXT is selectable from the systemd-boot menu.

| Slot | Version | Notes |
|---|---|---|
| **LTS (default)** | `6.18.26-cix-sky1-lts` | Production stable on MS-R1. Recommended for daily use. |
| **NEXT (BETA)** | `7.0.3-cix-sky1-next` | A/B testing track. Has documented SCMI transition warnings on current MS-R1 BIOS — boots and runs, but not yet recommended as default. |

Both kernels are Yocto-built from `gitlab.com/nclawzero/meta-base` with Sky1-specific patches and full driver support compiled in. Modules at `/usr/lib/modules/<KVER>/`.

**Bootloader:** systemd-boot. Loader entries at `/boot/efi/loader/entries/`:
- `cixmini-lts.conf` (default, sort-key `1-lts`)
- `cixmini-next.conf` ([BETA] sort-key `2-next`)
- `cixmini-rescue.conf` (rescue.target on LTS, sort-key `3-rescue`)

Each entry references both `vmlinuz-<KVER>` and `initrd.img-<KVER>` from the ESP. The initrd carries the FyrbyAdditive ACPI SSDT override (222-byte AML, prepended as CPIO) that fixes the missing `_HID` declaration on the three NPU cores.

### Sky1 SoC drivers (in-tree, kernel-built)

| Subsystem | Driver | Hardware |
|---|---|---|
| **GPU** | `panthor` | Mali-G720 (firmware: `mali_csffw.bin`) |
| **NPU** | `armchina_npu` (DKMS-style, in `/usr/lib/modules/<KVER>/extra/`) | Cix Zhouyi v3 (12 compute units) |
| **VPU** | `linlon` (in-tree, `CONFIG_VIDEO_LINLON`) | 13× codec firmwares (h264/h265/etc.) |
| **DSP** | `cix_dsp_rproc` | HiFi5 audio DSP (`dsp_fw.bin`) |
| **Display** | `linlondp` + `trilin_dpsub` (Linlon-D60 r0p0) | Built-in HDMI/DP outputs |
| **Audio** | `sky1-asoc-card`, `cix-ipbloq-hda`, `cix_sky1` HDMI/DP | Multi-card audio |
| **WiFi** | `rtw89` (Realtek WiFi, if equipped) | RTW8852b family |
| **Ethernet** | `r8169` | Realtek (rtl9151a / rtl8125k firmware) |
| **PCIe / NVMe** | upstream | Standard ARM64 PCIe + NVMe |
| **USB** | `xhci-hcd` upstream | All USB ports |

Sky1-firmware blobs at `/lib/firmware/` (panthor, dsp, vpu, rtw, etc.). Source: `github.com/Sky1-Linux/sky1-firmware`.

### Userspace stack

| Layer | What |
|---|---|
| **Init/services** | systemd 256+ |
| **Display manager** | LightDM (GTK greeter) — XFCE session, manual-login mode |
| **Desktop** | XFCE 4.20 (Xorg, not Wayland — Mali panthor + Wayland on questing's GDM produced black screens; LightDM + Xorg is the reliable path) |
| **Compositor** | xfwm4 (compositor disabled in xrdp sessions to avoid GL accel glitches) |
| **Browsers** | Chromium (flatpak), Vivaldi (.deb), Firefox (snap removed; .deb installed) |
| **Container runtime** | Podman 5.4 + crun + conmon + netavark + aardvark-dns + catatonit |
| **Remote access** | NoMachine 9.4 (preferred), xrdp (fallback), OpenSSH |
| **Time sync** | systemd-timesyncd (chrony available via apt; MS-R1 has unreliable RTC) |
| **Dev** | Claude Code CLI (`claude`), Python 3.13.7, Node.js 22, Git |
| **Cix proprietary userspace** | 37 prebuilt `.deb` packages from Cix factory image (audio DSP, GPU/Mali, NPU/NoE, VPU, ISP, Mesa, libdrm, libglvnd, llama.cpp, MNN, ONNX runtime, whisper.cpp, gstreamer plugins, etc.) staged at `assets/cix-debs/` and installed by `25-cix-proprietary.sh` |
| **Cix open-source userspace** | `cix-noe-umd` (NPU runtime), libcix-* libs from archive.cixtech.com PPA |
| **Mesa stack** | `mesa-sky1` build (panvk + zink for Vulkan + GL on Mali-G720) |
| **GUI flavors (opt-in)** | XFCE (default), GNUstep/Window Maker, KDE Plasma — selectable at first login |

### Containers (agent stack — opt-in via `ncz agent install`)

**r74 changed the agent install flow.** r73 and earlier auto-pulled all four containers at first boot, which produced two failure modes: (1) the cold-RTC clock skew on first boot caused TLS-cert validation to fail on the Portainer image pull, leaving Portainer dead until manual recovery, and (2) the 2.55 GB Hermes image pull blocked first-boot UX for 5–10 minutes with no progress indication.

**r74 inverts the flow.** Nothing pulls automatically. The base image ships:

- Podman 5.4 + crun + conmon + netavark + aardvark-dns + catatonit + whiptail
- Quadlet *templates* staged at `/usr/share/ncz/quadlets/` (not placed in `/etc/containers/systemd/`)
- `/etc/nclawzero/agent-env` populated from `agent-env.sample` (operator fills in API keys)
- `/usr/local/bin/ncz` CLI with `agent install` subcommand

To install agents (one-time, post-login):

```
sudo ncz agent install
```

A whiptail checkbox menu appears:

```
  [x] zeroclaw    NCZ daemon — gateway + agents (~109 MB)
  [ ] openclaw    OpenClaw — NemoClaw upstream OSS (~756 MB)
  [ ] hermes      Hermes Agent — NousResearch (~2.55 GB, slowest)
  [x] portainer   Container management web UI (~50 MB)
```

For each agent selected: `podman pull` → quadlet placed at `/etc/containers/systemd/<name>.container` → `systemctl daemon-reload` → service started → desktop launcher with themed icon written. Re-runnable; you can install more agents later.

| Service | Image | Port | Description |
|---|---|---|---|
| **zeroclaw** | `ghcr.io/zeroclaw-labs/zeroclaw:latest` | `42617` | NCZ daemon (gateway + agents). Switched from the pinned-digest `nclawzero-demo` build to upstream — the upstream image bakes the web dashboard. |
| **openclaw** | `ghcr.io/openclaw/openclaw@sha256:06b4f3df…` | `18789` | OpenClaw — upstream NemoClaw OSS. Reads config from `/var/lib/nclawzero/openclaw-home` (1000:1000-owned, baked into the installer). |
| **hermes** | `docker.io/nousresearch/hermes-agent@sha256:aa60e748…` | `8642` | NousResearch Hermes Agent. Dedicated podman network `hermes-isolated-v2` (cross-bridge isolation from siblings) + `--insecure` for non-TLS dashboard. |
| **portainer** | `docker.io/portainer/portainer-ce:lts` | `9000` (HTTP), `9443` (HTTPS) | Container management web UI. Run directly via `podman run` (not a quadlet) with `--label nclawzero=true` for ownership tracking. |

**Network topology** (created lazily by `ncz agent install hermes`):
- `podman` (default bridge) — zeroclaw + openclaw + portainer
- `hermes-isolated-v2` — hermes only (cross-bridge isolated, `Options=isolate=strict`)

**Persistent state** (created on first install, preserved across reinstalls):
- `zeroclaw-data` volume → `/zeroclaw-data` in container
- `openclaw-data` volume + `/var/lib/nclawzero/openclaw-home/` host bind (1000:1000)
- `hermes-data` volume → `/opt/data` in container
- `portainer_data` volume → `/data` in container

### Podman management — choose your tool

NCZ ships only **podman CLI** + the **`ncz agent`** subcommand by default. You pick the management UI:

| Tool | Install | When to use |
|---|---|---|
| **Podman CLI** | (always present) | The native interface. `podman ps -a`, `podman logs`, `podman exec` — full control. |
| **`ncz agent`** | (always present) | NCZ's curated wrapper. Best for the four supported agents. |
| **Portainer CE** | `sudo ncz agent install portainer` | Web dashboard at `http://127.0.0.1:9000/`. Container/volume/network management with logs and shell. The default for most users. |
| **Cockpit + cockpit-podman** | `sudo apt install cockpit cockpit-podman` then visit `https://<host>:9090/` | More integrated systemd-aware management. Heavier-weight. |
| **Lazydocker** | `sudo apt install lazydocker` then run `lazydocker` | Terminal UI, very fast. Reads the docker socket; works with podman via `DOCKER_HOST` env. |
| **Yacht** | Manual install (no apt package; podman pull `selfhostedpro/yacht`) | Lightweight web dashboard alternative to Portainer. |

The expectation is that operators install whichever fits their workflow. We recommend **Portainer** for first-time NCZ users (one-click via `ncz agent install portainer`) and **podman CLI + `ncz agent`** for fleet-managed deployments.

---

## What the user needs to know to get started

### First boot

1. **Boot from the installer USB** (UEFI, secure-boot disabled if needed). Pick `cixmini-lts` from the systemd-boot menu (default).
2. **Debian-installer phase** runs. Preseed handles partitioning, locale, mirror selection. **You will be prompted** for:
   - Hostname (default `cixmini` — accept or change)
   - Username (you pick — defaults to `mini` but use whatever you want)
   - Password
3. **Late-stage hooks run** (~2-5 minutes). The installer log is on `tty3` (Alt+F3) — you can watch hooks tick by:
   ```
   [10] our kernels (LTS + NEXT)
   [12] sky1-firmware
   [20] desktop (XFCE + LightDM)
   [22] display-fix detector
   [25] cix PPA + cix proprietary userspace
   [30] agent stack (zeroclaw + openclaw + hermes + Portainer)
   [31] remote-access (NoMachine + xrdp)
   [32] quadlet shim (no-op for podman 5.4+)
   [33] hostname + chrony
   [35] openssh-server + fleet keys
   [40] Claude Code CLI
   [50] NCZ brand identity (motd, cosmic quotes, greeter)
   [56] icon theme
   [60] plymouth
   [70] systemd-boot (loader entries + initrd staging)
   [80] NPU stack (FyrbyAdditive patches + SSDT override)
   [99] diagnostics
   ```
4. **Reboot.** USB removal prompted explicitly before the system shuts down.
5. **Greeter appears** with the NCZ rocket-into-black-hole branding. Log in with the username/password you set.
6. **XFCE desktop loads** with the NCZ wallpaper rotation (10 wallpapers, cycle every 10 minutes).

### What's on the desktop / 桌面快捷方式

**Pre-installed on first boot / 首次启动即有：**

| Launcher / 启动器 | What it does / 作用 |
|---|---|
| **Claude Code** | Opens xfce4-terminal with `claude` (Anthropic Claude Code CLI) |
| **Install NCZ Agents** | Opens xfce4-terminal running `sudo ncz agent install` (whiptail menu) — **the way you bring up zeroclaw / openclaw / hermes / portainer** |
| **NCZ CLI** | Opens xfce4-terminal with `ncz help` |
| **NCZ-Help.md** | Markdown quick-reference doc — open with mousepad/gedit |
| **MNEMOS** | Opens `https://github.com/mnemos-os/mnemos` (project page) |
| **Rheinhardt — Through and Beyond!** | YouTube link to *The Black Hole* (1979) Dr. Hans Reinhardt monologue |

**Appear after `sudo ncz agent install` / 运行 `sudo ncz agent install` 后出现：**

| Launcher | What it does | Themed icon |
|---|---|---|
| **ZeroClaw** | Opens `http://127.0.0.1:42617/` in Vivaldi | `ncz-zeroclaw` (clamps + accretion disk) |
| **OpenClaw** | Opens `http://127.0.0.1:18789/` in Vivaldi | `ncz-openclaw` |
| **Hermes** | Opens `http://127.0.0.1:8642/` in Vivaldi | `ncz-hermes` (winged caduceus) |
| **Portainer** | Opens `http://127.0.0.1:9000/` in Vivaldi | `portainer` |

### Configure agent API keys (REQUIRED for agents to do real work)

Agents start without keys but can't make outbound LLM calls. Edit:

```
sudo nano /etc/nclawzero/agent-env
```

Set any of:
```
TOGETHER_API_KEY=...
GROQ_API_KEY=...
GOOGLE_API_KEY=...
GEMINI_API_KEY=...
ANTHROPIC_API_KEY=...
OPENAI_API_KEY=...
PERPLEXITY_API_KEY=...
MISTRAL_API_KEY=...
```

Then restart the agents:

```
sudo systemctl restart zeroclaw openclaw hermes
```

> **Note:** Per the nclawzero project policy, Anthropic is **not** the recommended LLM provider for the claw-family agent runtime (against their ToS for agent frameworks). Together AI / Groq / OpenAI / local llama.cpp are the recommended choices for inference. Claude Code CLI (`claude`) is the **operator-side** dev tool — different scope.

### Installing agents — the `ncz` CLI / 安装智能体 — `ncz` 命令行工具

**English:** Located at `/usr/local/bin/ncz`. Manages the optional agent stack and wraps `systemctl` + `podman` + `journalctl`.

**中文：** `ncz` 工具位于 `/usr/local/bin/ncz`，用于管理可选的智能体（agent）容器组件，并封装了 `systemctl` + `podman` + `journalctl` 操作。

#### Install agents / 安装智能体

```
sudo ncz agent install              # interactive whiptail menu / 交互式复选框菜单
sudo ncz agent install zeroclaw     # one agent / 单个智能体
sudo ncz agent install --all        # all four (~3.5 GB pull) / 全部四个（约 3.5 GB 下载）
```

The interactive menu: pick which agents to pull/start (zeroclaw, openclaw, hermes, portainer). Re-runnable; you can install more later. After install, a desktop launcher with a themed icon appears for each selected agent.

交互式菜单中可勾选要拉取并启动的智能体（zeroclaw、openclaw、hermes、portainer）。可重复运行，随后可继续追加。安装完成后，桌面上会出现带有主题图标的快捷方式。

#### Daily operation / 日常操作

```
ncz agent list                      # show install state + URLs / 显示安装状态与 URL
ncz agent status <name>             # systemctl status
sudo ncz agent start|stop|restart <name>
sudo ncz agent logs <name>          # follow journal / 跟踪 journal 日志
ncz agent shell <name>              # shell into container / 进入容器 shell
ncz agent web                       # print dashboard URLs / 打印仪表板 URL
ncz agent uninstall <name>          # remove agent / 移除智能体
sudo ncz agent uninstall --all      # remove everything / 移除全部
ncz version
ncz help
```

Available agent names / 可用智能体名称: `zeroclaw`, `openclaw`, `hermes`, `portainer`

### Remote access

- **SSH** is enabled by default on port 22. The fleet authorized_keys is pre-staged for both root and the operator account. From any fleet host (or your laptop), `ssh <user>@<cixmini-ip>` works on day zero.
- **NoMachine** server is running on port 4000 — preferred for graphical remote access. Mac/Windows/Linux clients at https://www.nomachine.com/.
- **xrdp** is on port 3389 as a fallback. The XFCE-over-RDP session is wrapped with `dbus-launch` and runs without the xfwm4 compositor (which causes window-decoration glitches over RDP-side Xorg).

### NPU inference / NPU 推理

The patched `armchina_npu` kernel module loads on boot. `/dev/aipu` is created. ACPI enumerates the NPU controller (`CIXH4000:00`) and three cores (`CIXH4010:00..02`) thanks to the SSDT override carried in the initrd. The userspace API surface (`/usr/share/cix/include/npu/cix_noe_standard_api.h`) is **Apache 2.0 licensed** — open for third-party tooling.

`armchina_npu` 内核模块在启动时加载，自动创建 `/dev/aipu` 设备节点。借助 initrd 中的 SSDT 覆盖，ACPI 可正确枚举 NPU 控制器（`CIXH4000:00`）以及三个核心（`CIXH4010:00..02`）。用户空间 API（`/usr/share/cix/include/npu/cix_noe_standard_api.h`）采用 **Apache 2.0 许可证**，对第三方工具链开放。

#### What's shipped on disk / 系统已安装的 NPU 工具

```
/usr/share/cix/include/npu/cix_noe_standard_api.h    Apache 2.0 C API header
/usr/share/cix/lib/libnoe.so.3.1.0                   Native runtime (closed-source binary)
/usr/share/cix/lib/libnoe.a                          Static lib
/usr/share/cix/pypi/libnoe-3.1.0-py3-none-manylinux2014_aarch64.whl
                                                     Python wheel — bridges to libnoe via ctypes
                                                     Works with Python 3.10 / 3.11 / 3.12 / 3.13
                                                     pip install /usr/share/cix/pypi/libnoe-3.1.0*.whl
/usr/lib/aarch64-linux-gnu/pkgconfig/cix-noe-umd.pc  pkg-config metadata
```

#### Pull pre-compiled `.cix` models / 拉取预编译 `.cix` 模型

```bash
sudo apt install -y python3-numpy python3-pillow git git-lfs
git lfs install

# Cix AI Model Hub — official repo on ModelScope (China-based)
git clone --depth 1 https://www.modelscope.cn/cix/ai_model_hub_25_Q3.git
# GitHub mirror also available:
# git clone --depth 1 https://github.com/cixtech/ai_model_hub.git

cd ai_model_hub_25_Q3

# Just one model (faster):
git lfs pull --include="models/ComputeVision/Image_Classification/onnx_mobilenet_v2/*"

# Or pull everything (~ tens of GB of .cix artifacts):
git lfs pull
```

**Available pre-compiled `.cix` models in the Cix AI Model Hub** (verified ship-as-`.cix` artifacts):

| Category | Model | Use case |
|---|---|---|
| Image Classification | MobileNet V2, ResNet50/v1-101, Inception V3, VGG-16, EfficientNet | Vision tags, content moderation |
| Object Detection | YOLOv8-l / YOLOv8l-worldv2, YOLOv3, YOLOX-l, RetinaNet, SSD300, CenterNet | Surveillance, robotics, traffic |
| Face | CenterFace, SCRFD + ArcFace | Face detection + recognition |
| Pose / Hand | HRNet-pose, handpose | HCI, AR/VR |
| OCR | PP-OCRv4 (det / rec / cls), CRNN | Document AI |
| Lane | Ultra-Fast-Lane-Detection | ADAS / driving aids |
| Depth | MiDaS v2, depth-anything-v2 | 3D understanding |
| Segmentation / Super-Resolution | (multiple — see `models/ComputeVision/`) | Image enhancement |
| Audio | **Whisper tiny / small / medium-multilingual** | Speech-to-text |
| Image-to-Text | Chinese CLIP, SigLIP-so400m | VLM, image search |
| **Text Embeddings** | **BGE-small-zh-v1.5 (256-token context)** | **Semantic search, RAG, MNEMOS** |
| Text-to-Image | SDXL-Turbo (text_encoder, unet, vae_decoder) | Local image generation |
| LLM (recipes) | Llama-2/3/3.1/3.2, Qwen1.5/2/2.5, DeepSeek-R1-Distill, Phi-3/3.5, gemma-2-2b-it, MiniCPM3, ChatGLM3 | **CPU / Mali-Vulkan recipes only** — see "LLMs on the NPU" below |
| MultiModal (recipes) | Llava-v1.5/v1.6, Qwen2-VL, Qwen2.5-VL, MiniCPM-V/o-2.6 | **CPU / Mali-Vulkan recipes only** |

Each model directory ships:
- `inference_npu.py` — runs on the NPU via `utils.NOE_Engine.EngineInfer`
- `inference_onnx.py` — CPU fallback via standard ONNX runtime
- `cfg/<model>_build.cfg` — the Compass NN compiler recipe (ONNX → `.cix`)

#### LLMs on the NPU / NPU 上的大语言模型

**Currently structurally unsolved**, including by Cix. The Compass NN compiler is static-graph only — transformer models with KV-cache and variable sequence length don't compile cleanly to `.cix`. The Cix AI Model Hub's `Generative_AI/LLM/*.md` files document **CPU/llama.cpp Q4_0 quantization recipes**, not NPU compile recipes.

**Recommended path for LLMs on NCZ:** llama.cpp + **Vulkan backend on Mali-G720** (via Mesa panvk + zink). Expected ~5–15 tok/s on 7B-class models (Q4_0). Faster than CPU, 0% NPU utilization (NPU stays free for vision/audio/embeddings).

NPU 上的大语言模型目前在结构上仍未解决——包括 Cix 自己也尚未实现。Compass NN 编译器仅支持静态图，带有 KV-cache 和动态序列长度的 transformer 模型无法干净地编译为 `.cix`。Cix AI Model Hub 中的 `Generative_AI/LLM/*.md` 文档说明的是 **CPU / llama.cpp Q4_0 量化方案**，而非 NPU 编译方案。

**NCZ 上运行 LLM 的推荐路径：** llama.cpp + **Mali-G720 Vulkan 后端**（经由 Mesa panvk + zink）。7B 量级模型（Q4_0）预计速度为 5–15 tok/s。比 CPU 更快，且不占用 NPU。

#### MNEMOS on NCZ — coming in r75 / 即将到来 (r75)

The `bge-small-zh-v1.5` 256-token embedding model **does compile cleanly** to NPU (`bge-small-zh_256.cix`, INT16 quantized, target X2_1204MP3). r75 will add `ncz install mnemos` — a one-command setup that runs MNEMOS in a podman container with NPU embeddings via the libnoe Python wheel. Mali-Vulkan llama.cpp embedding fallback for non-Cix hardware.

`bge-small-zh-v1.5`（256 token 上下文嵌入模型）**可以干净地编译到 NPU**（`bge-small-zh_256.cix`，INT16 量化，目标 X2_1204MP3）。r75 版本将提供 `ncz install mnemos` 一键部署：在 podman 容器中运行 MNEMOS，通过 libnoe Python wheel 调用 NPU 进行嵌入推理；非 Cix 硬件可回落到 Mali-Vulkan llama.cpp 嵌入。

This is the **lighthouse demo**: AI memory at the edge, vector search at NPU latency, no cloud, no GPU saturation. Tracking issue: [r75 ncz install mnemos](https://gitlab.com/nclawzero/distro/-/issues).

See `/usr/share/doc/ncz/NPU-STATUS.md` for FyrbyAdditive credits and source repos.

#### Acknowledgments / 致谢

The NPU stack on NCZ stands on the shoulders of:
- **ArmChina** (周易 Zhouyi v3 IP, Compass NN SDK, libnoe runtime, [Model_zoo](https://github.com/Arm-China/Model_zoo))
- **Cix Tech** ([cixtech/ai_model_hub](https://github.com/cixtech/ai_model_hub) — pre-compiled `.cix` artifacts, NPU SDK)
- **FyrbyAdditive** (Linux port of the AOSP NPU driver + MS-R1 SSDT/IRQ workarounds)
- **Sky1-Linux community** ([Sky1-Linux](https://github.com/Sky1-Linux) — sky1-firmware, mesa-sky1, panthor enablement)

NCZ 的 NPU 栈建立在以下工作之上：**ArmChina**（周易 v3 IP、Compass NN SDK、libnoe 运行时）、**Cix Tech**（ai_model_hub 预编译 `.cix` 模型、NPU SDK）、**FyrbyAdditive**（AOSP NPU 驱动的 Linux 移植 + MS-R1 SSDT/IRQ 修复）、**Sky1-Linux 社区**（sky1-firmware、mesa-sky1、panthor 适配）。

---

## What's supported by the kernels (driver matrix)

### Sky1 / CP8180 SoC (in-tree drivers — both LTS and NEXT)

| Subsystem | Status | Notes |
|---|---|---|
| **GPU — Mali-G720 (panthor)** | ✅ Working | Vulkan via panvk, OpenGL via zink. `mali_csffw.bin` firmware required (shipped). |
| **NPU — Zhouyi v3 (armchina_npu)** | ✅ Working with FyrbyAdditive patches | Requires SSDT override (shipped via initrd CPIO prepend). 12 compute units. v0-compat ioctls bridge `cix-noe-umd 2.0.2` ABI. ~640 inf/s mobilenet. |
| **VPU — Linlon codec (linlon)** | ✅ Working | h264/h265 hardware decode via `CONFIG_VIDEO_LINLON`. 13 codec firmwares shipped. |
| **DSP — HiFi5 (cix_dsp_rproc)** | ✅ Working | Audio DSP for low-power audio. `dsp_fw.bin` shipped. |
| **Display Pipeline — Linlon-D60 (linlondp + trilin_dpsub)** | ✅ Working | HDMI + DP outputs. DRM auto-init may have a probe race on cold boot — `22-display-fix.sh` handles dynamic primary-display detection with a 30s retry loop. |
| **Audio — sky1-asoc-card** | ✅ Working | HDMI/DP audio + line-out + headphone. I2S codecs CIXH6011:04/06 are MS-R1-specific (not present, skipped cleanly). |
| **HDA controller — cix-ipbloq-hda** | ✅ Working | Onboard analog audio. |
| **PCIe** | ✅ Working | NVMe + extension cards. |
| **NVMe** | ✅ Working | Standard ARM64 NVMe driver. |
| **USB 3 / USB-C** | ✅ Working | xhci-hcd. **MS-R1 specific:** `typec_rts5453` and `rts5453` modules are blacklisted via kernel cmdline (`module_blacklist=typec_rts5453,rts5453`) due to IRQ 151 wedge — does not affect USB functionality. |
| **Ethernet — r8169** | ✅ Working | Realtek 2.5GbE. Firmware `rtl9151a-1.fw` and `rtl8125k-1.fw` shipped. |
| **WiFi — rtw89 (RTW8852b)** | ✅ Working (when equipped) | Realtek WiFi 6. Firmware blobs at `/lib/firmware/rtw89/`. |
| **Bluetooth** | ✅ Working | Standard Realtek BT stack. |
| **SCMI / SoC management** | ✅ Working on LTS, has transition warnings on NEXT | Power management / cpufreq. NEXT 7.0.3 logs `SCMI transition` warnings on current MS-R1 BIOS — boots OK but recommended to use LTS for production. |
| **IOMMU / SMMU** | ✅ Working with FyrbyAdditive 32-bit constraint patch | NPU is 32-bit; mainline arm64 SMMU defaults to 35-bit IOVAs which truncate. Patch forces `bus_dma_limit=0xc0000000`, `dma_mask=32`. |

### Generic ARM64 features (upstream)

- ARMv9-A baseline (Cortex-A720 / Cortex-A720R cores)
- ACPI 6.4+ enumeration
- KVM virtualization (host)
- BPF (CO-RE, CONFIG_DEBUG_INFO_BTF)
- io_uring
- Containers: cgroups v2, namespaces, seccomp, OverlayFS
- ZSTD compression (kernel images, initramfs)
- LUKS / dm-crypt for full-disk encryption (not enabled by default in installer; opt-in via custom partitioning)
- ZFS (kernel module via package, not enabled by default)
- Btrfs, ext4, F2FS, XFS — all supported

### What's NOT supported (yet)

- **LLMs on the NPU** (structural — Compass compiler is static-graph only, KV-cache requires dynamic shapes)
- **`cix-noe-umd 4.0.0`** (uses different `device_type_t` enum than 2.0.x — `2.0.2` is confirmed working, `4.0.0` returns "Unsupported device type")
- **Wayland on Mali panthor** (questing's GDM with Wayland produces black screens; we ship LightDM + Xorg as the reliable path. Wayland may work in compositor-specific configs but is not validated.)
- **MS-R1 firmware update for the NPU `_HID` bug** (this is a Minisforum BIOS bug — they shipped a DSDT that omits `_HID="CIXH4010"` on the three NPU cores. We work around it via SSDT override in the initrd. A firmware update from Minisforum would obsolete the workaround, but isn't currently published.)

---

## What's coming in r75 / r75 即将推出

**The NPU work begins in earnest.** r74 ships the foundation: open API header (Apache 2.0), libnoe Python wheel, NPU driver, vision/audio inference verified. r75 unlocks the agent-side use cases:

| Item | Status |
|---|---|
| **`ncz install mnemos`** | One-command MNEMOS deployment with NPU embeddings via `bge-small-zh_256.cix`. Mali-Vulkan llama.cpp embedding fallback for non-NPU hosts. *Lighthouse demo for the NCZ project.* |
| **`ncz models pull <name>`** | Curated subset puller from `cixtech/ai_model_hub_25_Q3` to `/opt/ncz/models/`. Pulls only the categories you want (vision / audio / embedding / text-to-image). |
| **LLM recipes baked** | `gemma-2-2b-it`, `Qwen2.5-1.5B-Instruct` / `0.5B-Instruct` / `3B-Instruct`, `DeepSeek-R1-Distill-Qwen-1.5B`, `Phi-3.5-mini-instruct`. CPU + Mali-Vulkan llama.cpp recipes (NPU-LLM remains structurally unsolved). One-command pull + GGUF conversion + Q4_0 quantization. |
| **LPI2 idle-power validation** | NPU idle states on Sky1 are firmware-conditional. `ncz cpuidle` will read `/sys/devices/system/cpu/cpu*/cpuidle/state*/` and report whether LPI2 is exposed by the operator's UEFI. |
| **Community .cix sourcing** | Once we have N installations, farm out ONNX → `.cix` recompilation work. ArmChina Compass NN access + community-built `.cix` artifacts shared back. Goal: a community catalog that grows independently of any single vendor relationship. |
| **NCZ-Help.md fully bilingual** | Full English / 简体中文 translation of every section. |
| **netinstall ISO** | ~500 MB ISO that pulls everything else from the network at install time. For users who don't want the 3.9 GB thin ISO. |
| **x86_64 NCZ scaffold** | A parallel x86_64 build for non-Cix hardware. Same agent stack, no NPU. *Not* a primary target but useful for cross-platform demo. |

We expect r75 in ~7 days, gated on the MNEMOS-NPU integration working end-to-end.

我们计划在大约 7 天内发布 r75，关键节点是 MNEMOS-NPU 集成端到端跑通。

---

## What changed between revisions

| Rev | Date | Highlights |
|---|---|---|
| r57 | 2026-05-05 ~15:00 | First FyrbyAdditive integration; NPU stack present but post-install paths broken (`/target/` prefix used inside chroot) |
| r58 | 2026-05-05 ~16:00 | Chroot paths fixed; FyrbyAdditive driver oops'd without SSDT (expected) |
| r59 | 2026-05-05 ~16:30 | Greeter+agent-env+initrd fixed; **live-tested OK on hardware** — NPU smoketest PASSED end-to-end |
| r60 | 2026-05-05 ~18:00 | 50-brand.sh `set +e` fix, NCX→NCZ rebrand completed |
| r61 | 2026-05-05 ~18:30 | Cockpit removed → Portainer; agent stack rewrite (set +e, mkdir for parents, agent-env baked, openclaw chown, hermes Network/--insecure); 32-quadlet-shim no-op'd (was overriding podman 5.4 native quadlet); Rheinhardt rocket-into-black-hole icon; NCZ-Help.md desktop doc. Live install validated NPU smoketest end-to-end. |
| r62 | 2026-05-05 ~19:00 | Polish pass: rocket-icon SVG generation baked into 50-brand.sh; empty `Agents/` subdir removed; Reinhardt/Rheinhardt deduplicated; agent-launcher icons themed; `dkms.service` masked (FyrbyAdditive prebuilt .ko ships at `/usr/lib/modules/<KVER>/extra/`). QEMU boot tested. |
| r63 | 2026-05-05 ~19:25 | Codex-reviewed rerun-safety pass. agent-env preserved across re-runs; hostname only overridden if blank/default; SSH keys only seeded if empty; `33-ntp-hostname.sh` set+e + dropped `--now` from `systemctl enable`; `34-fstab.sh` defensive blkid-based fstab generator; portainer-bootstrap `Requires=podman.socket`. |
| r64–r72 | 2026-05-05 evening | Iterative polish: amber GRUB, hostname=mini default, NVMe-wipe early_command, longer GRUB timeout (30s + 5s pause), preseed `seen true` syntax fixes, USB stick guidance, host-side dd verification protocol. |
| r73 | 2026-05-05 ~22:30 | First successful full install on MS-R1 (.66) end-to-end. NPU verified, 9 desktop launchers placed, agent stack auto-started. *Discovered* that auto-pulling Hermes (2.55 GB) blocked first-boot UX and that cold-RTC clock skew killed `portainer-bootstrap` on first boot. |
| **r74** | **2026-05-06** | **Ship release.** Reverses the auto-pull design: agents are now opt-in via `sudo ncz agent install` (whiptail checkbox UI). Only Claude Code pre-installed. ZeroClaw switched from pinned-digest `ghcr.io/perlowja/nclawzero-demo` → upstream `ghcr.io/zeroclaw-labs/zeroclaw:latest` (web UI baked in — `GET /` now returns 200 instead of 503). Themed agent icons (ncz-zeroclaw / ncz-openclaw / ncz-hermes) generated as inline SVGs + rsvg-convert to hicolor. Wallpaper rotator renamed `55-` → `45-` so it runs **before** 50-brand.sh — greeter background sees `/usr/share/backgrounds/ncz/default.jpg` from the start (no install-time rename). 20-desktop.sh orphan `[Desktop]` heredoc tail removed (was killing xscreensaver autostart under `set -e` in r73 and prior). xscreensaver `lock=True` (was False). `35-fstrim-fix.sh` drop-in skips vfat (kills the weekly fstrim.service failure on the Cix Sky1 ESP). Portainer no longer auto-pulled (eliminates the cold-RTC TLS-cert failure). Codex-reviewed: HIGH (screensaver conflict) + MEDIUM (Portainer non-root status visibility, hermes sed assertion, camel-case launcher names) all addressed before ship. NCZ-Help.md desktop doc rewritten with full bilingual (English / 简体中文) `ncz` CLI reference. |

### Known issues / footnotes

- `cix-noe-umd` deb postinst tries `pip install` of a Python wheel that requires Python `<3.13`; Ubuntu questing has 3.13.7. The native libraries install cleanly; the pip step fails (cosmetic). The deb is force-marked installed via a no-op postinst override during install. This affects no functionality — Python `libnoe 3.1.0` is separately available at `/usr/local/lib/python3.13/dist-packages/libnoe/` with the correct `.cpython-313-aarch64-linux-gnu.so` extension.
- `sudo-rs 0.2.8` (Ubuntu questing's default) does NOT reliably read passwords from stdin over non-TTY SSH. Use `ssh -tt` for scripts that need interactive sudo, or use the legacy `/usr/bin/sudo.ws` binary as a fallback.
- The default username `mini` (when no preseed override is set) is a placeholder — the hostname can be `cixmini` while the user is anything you set during install. The "operator user is `ncz`" rule in fleet docs applies to mass-flashed pi-gen images, **not** to interactive d-i installs of NCZ.

---

## Credits

NCZ would not exist without:

- **FyrbyAdditive/ms-r1-npu-hack** (BSD-2-Clause-Patent) — identified and fixed all four MS-R1 NPU root causes on Armbian first. NCZ integrates their patches into a Debian-installer build. Demonstrated ~640 inf/s mobilenet inference on commodity hardware. **Massive thank you.**
- **cixtech** (`cix_opensource__release__npu_driver`, branch `cix_mainline_dev`) — upstream NPU driver source under Apache-2.0.
- **cixtech** (`cix_opensource__release__edk2-platforms`) — upstream `Dsdt-NPU.asl` source under BSD-2-Clause-Patent that we vendored for the SSDT override.
- **radxa-pkg/cix-prebuilt** — published `cix-noe-umd_2.0.2_arm64.deb` userspace runtime.
- **Cix AI Model Hub** on ModelScope — pre-compiled `.cix` inference graphs.
- **Sky1-Linux** community (github.com/Sky1-Linux/sky1-firmware, kernel patches, panthor work) — the kernel-side foundation.
- **Minisforum** — for shipping the MS-R1 hardware and (mostly) open firmware.
- **Chris Larson + the OpenZaurus community** (2002-2003) — for inventing this pattern of community-built distros for OEM ARM hardware. NCZ is a direct descendant of that lineage; Sharp's PDA → Cix's mini-PC is the same dynamic, twenty-three years later.
- **Cix** — for publishing the EDK2 source, the kernel driver, and the model hub. The pattern works when vendors ship source.

---

## Resources

- **Issues / bug reports:** https://gitlab.com/nclawzero/cix-installer/-/issues
- **Source code:** https://gitlab.com/nclawzero (mirror on github.com/perlowja and ARGONAS bare repos)
- **NPU status doc on installed system:** `/usr/share/doc/ncz/NPU-STATUS.md`
- **Brand assets / wallpapers:** `/usr/share/backgrounds/ncz/`
- **Quick reference:** `~/Desktop/NCZ-Help.md`

---

*"Through and beyond!" — Dr. Hans Reinhardt, The Black Hole (1979)*

*r63-Reinhardt-thin · `9ec809af16be2c98c6c1cc7b494c807f7dc056b26f357bbbb755bc103f7d669e`*

*r62 · `7d8e29d416333e59f516e2bade6c9aced5a97694be4a77ddd73214bead10c79d`*
*r61 · `12529f38cebe93ef86bc29347a7669f134a382bcde28ef62d68a20e3020b5fa5`*
