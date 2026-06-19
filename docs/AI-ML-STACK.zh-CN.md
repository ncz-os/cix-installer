# NCZ 智能体 Linux —— AI/ML 软件栈参考（Cix Sky1）

> 系统中随附了什么、每个二进制/库的用途、如何在四个计算引擎
> （CPU / NPU / GPU / VPU）上运行推理、它们的性能表现、如何为某项工作负载
> 选择正确的引擎，以及如何拉取新模型。
>
> 目标硬件：**Cix Sky1 (CP8180)** —— 12 核 Armv9 CPU、**Mali-G720 MC10**
> GPU（panthor）、**ArmChina Zhouyi V3** NPU、**Linlon/amvx** VPU。
> **统一内存（UMA，由所有引擎共享）：本"超大杯"MS-R1 为 64 GB，标准 MS-R1
> 为 32 GB。**（GPU 驱动在扣除内核/固件预留后，将其中约 46.85 GiB 暴露为
> 可分配池。）
>
> 状态图例：✅ 已在 `.66` 参考主板上验证 · ⚠️ 可用但有注意事项 · 🧪 开发/可选。

---

## 0. 四个引擎一览

| 引擎 | 硬件 | 最擅长 | 精度 | 峰值（实测） | 编程接口 |
|---|---|---|---|---|---|
| **CPU** | 12× Armv9（NEON/SVE2） | LLM **解码**、控制流、OCR、粘合逻辑 | FP32/FP16/INT8 | Gemma-E2B 解码约 18.8 tok/s | llama.cpp、MNN、任意二进制 |
| **NPU** | Zhouyi V3（3 核） | 固定形状 **CNN/视觉**、**嵌入** | INT8（AOT） | ResNet50 约 1.9k img/s；MobileNetV2 约 640 inf/s | libnoe（`.cix` 图） |
| **GPU** | Mali-G720 MC10（10 CU） | **prefill**、批量 GEMM、CV、GPGPU | FP16/FP32/INT | FP16 约 3.6 TFLOPS，FP32 约 1.98 TFLOPS | Vulkan（panvk）、OpenCL（rusticl） |
| **VPU** | Linlon/amvx | H.264/H.265 **转码** | — | 实时多路 | GStreamer/V4L2（媒体，非 ML） |

**一句话路由规则：** *嵌入和视觉 → NPU；LLM 词元生成 → CPU；LLM 提示摄入 /
批量数学 / 图像预处理 → GPU；视频 → VPU。* 细节和"为什么"见 §6。

所有引擎共享同一个统一内存池（**本超大杯为 64 GB，标准 MS-R1 为 32 GB**），
因此**没有主机↔设备的拷贝开销** —— 但这也意味着某个引擎上的大模型会减少留给
其他引擎的余量。

---

## 1. CIX 用户态运行时（专有底层）

由 `25-cix-proprietary.sh` 从 Cix 出厂 `.deb` 集安装。位于 `/usr/share/cix/` 下。

| 库 | 路径 | 用途 / 目标应用 |
|---|---|---|
| `libnoe.so.0.6.0` | `/usr/share/cix/lib/` | ✅ **NPU 用户态驱动（UMD）** —— 在 Zhouyi 上加载/运行 AOT 编译的 `.cix` 图。所有 NPU 推理的基础。 |
| `libnoe.a` | `/usr/share/cix/lib/` | 静态变体，用于将 UMD 嵌入二进制 |
| `libMNN.so` + `libMNN_CL.so` + `libMNN_Vulkan.so` | `/usr/share/cix/lib/` | ⚠️ **阿里巴巴 MNN** 推理引擎 —— 面向 CNN/transformer 模型（`.mnn` 格式）的 CPU + OpenCL + Vulkan 后端 |
| `libMNNOpenCV.so` | `/usr/share/cix/lib/` | MNN 内置的 OpenCV 兼容图像算子 |
| `libllm.so` | `/usr/share/cix/lib/` | MNN-LLM 运行时（通过 MNN 的设备端 LLM） |
| `libdiffusion.so` | `/usr/share/cix/lib/` | MNN Stable-Diffusion 流水线 |
| `cix-gpu-umd` → `libmali.so`、`libOpenCL.so` | `/opt/cixgpu-pro/` | ⚠️ **专有 Mali 驱动** —— 在本镜像中**已禁用**（与 panthor 内核不兼容）。由 Mesa rusticl/panvk 取代。见 §3。 |
| `cix-libdrm`、`cix-libglvnd` | 系统 | DRM + GL 厂商中立分发垫片 |

**Python NPU 绑定**（仅 cp311/cp312）以 wheel 形式随附于 `/usr/share/cix/pypi/`：
- `libnoe-2.0.0-…aarch64.whl` —— `libnoe` 的 ctypes/cpython 绑定
- `NOE_Engine-2.0.0-…aarch64.whl` —— 更高层的 `EngineInfer` 封装

> **版本锁定：** 只有 `cix-noe-umd 2.0.2`（即本 `libnoe 0.6.0` +
> `libnoe/NOE_Engine 2.0.0` wheel）针对我们的内树 `armchina_npu` 内核驱动
> 通过了验证。UMD 1.1.1 和 3.1.2 提交任务失败。这些 wheel 锁定 cpython-3.11/3.12
> ABI —— 这就是为什么嵌入虚拟环境构建在 Python 3.11 上，而非系统的 3.14
> （见 §4）。

---

## 2. 预编译 AI 二进制（开箱即用）

### 2.1 llama.cpp —— `cix-llama-cpp` → `/usr/share/cix/bin/`
GGUF LLM + 多模态运行时。CPU 与 Vulkan（Mali）后端。

| 二进制 | 用途 |
|---|---|
| `llama-cli` | 交互式 / 一次性文本生成 |
| `llama-server` | OpenAI 兼容的 HTTP 服务器（`/v1/...`） |
| `llama-bench` | 吞吐基准（prefill `pp` + decode `tg`） |
| `llama-perplexity` | 质量评估 |
| `llama-quantize` | 转换/量化 GGUF |
| `llama-llava-cli`、`llama-minicpmv-cli`、`llama-qwen2vl-cli` | **视觉-语言**对话（图像 + 文本） |

```bash
# CPU 解码（最适合 batch-1 的词元生成）
/usr/share/cix/bin/llama-cli -m model.gguf -ngl 0 -p "Hello" -n 128
# 通过 Mesa Vulkan/panvk 进行 GPU 卸载（最适合提示摄入）
/usr/share/cix/bin/llama-cli -m model.gguf -ngl 99 -p "..." -n 128
```

### 2.2 MNN —— `cix-mnn`（上述库）
阿里巴巴的移动端推理引擎。通过其 OpenCL 后端在 Mali 上表现强劲；包含一个 LLM
运行时（`libllm.so`）和一个扩散流水线（`libdiffusion.so`）。用于 `.mnn` 模型、
设备端 Stable Diffusion，或当你想要一个横跨 CPU+OpenCL+Vulkan 的单一引擎时。

### 2.3 whisper.cpp —— `cix-whisper-cpp` → `/usr/share/cix/bin/`
语音转文字（Whisper）。`talk-llama` 将 Whisper STT → llama.cpp →（可选 TTS）
串联成一个语音助手循环。

### 2.4 GPU / 计算工具（Mesa 26.1.3 栈 —— 见 §3）
`vulkaninfo`、`clinfo`、`glslangValidator`、`spirv-val/-dis`、`glmark2`。
由 `47-llm-stack.sh` + `16-mesa-gpu-2613.sh` 安装。

---

## 3. GPU 计算驱动（Mesa 26.1.3 —— NCZ 构建）

我们在 `/opt/mesa-26.1.3` 下随附一份**从源码构建的 Mesa 26.1.3**，将其重定向
为系统的 Vulkan + OpenCL 提供者（桌面 GL 仍保留在自带 Mesa 上）。完整理由见
`/usr/share/doc/ncz/GPU-STATUS.md`。

| 驱动 | API | ICD / 如何选用 | 用途 |
|---|---|---|---|
| **panvk** | Vulkan 1.4 | `VK_DRIVER_FILES`（在 `/etc/environment` 中设置） | ✅ llama.cpp `-ngl`、WebGPU/Dawn、Vulkan 计算 |
| **rusticl** | OpenCL 3.0 | `/etc/OpenCL/vendors/rusticl.icd` + `RUSTICL_ENABLE=panfrost` | ✅ OpenCV OpenCL、clpeak、MNN-CL、TVM、自定义内核 |

为什么用我们的构建而非自带的 26.0.3：
- 自带 panvk 的 GPU 计算硬性失败（`VK_ERROR_OUT_OF_DEVICE_MEMORY`，16 项
  存储缓冲区上限）—— 破坏了 Dawn/WebGPU 与大型分派。
- 基础镜像**完全不提供 GPU OpenCL**（`mesa-opencl-icd` 被移除 → 只有 CPU
  pocl）。我们的 rusticl **恢复**了 GPU OpenCL。

```bash
vulkaninfo | grep -E 'deviceName|driverInfo'      # Mali-G720 / Mesa 26.1.3
clinfo     | grep -E 'Device Name|Driver Version'  # Mali-G720 (Panfrost) / 26.1.3
```

> **未随附：Teflon。** Mesa 的 TFLite 委托仅面向 Ethos-U / VeriSilicon /
> Rockchip NPU —— 它无法驱动 Mali GPU 或 Zhouyi NPU，在本机上会以
> "Couldn't open kernel device" 失败。NPU 请改用 Zhouyi/libnoe 路径。

🧪 **Apache TVM**（开发工具，不在默认镜像中）可将模型编译为 OpenCL 并在
rusticl 上运行 —— 已验证（VADD + GEMM 结果正确）。用于面向 Mali 的自动调优
自定义算子。

---

## 4. 嵌入栈（MNEMOS / 智能体记忆）

智能体记忆系统（`mnemos`）需要快速的文本嵌入。该路径已预编译，运行在 **NPU** 上：

| 组件 | 路径 | 角色 |
|---|---|---|
| embedkit venv（Python 3.11） | `/opt/ncz/embed-venv` | `mnemos-embedkit` + `libnoe` + `llama-cpp-python` |
| `npu_embed_v2.py` | `/opt/cix/` | 围绕 `libnoe.so` 的 ctypes 封装（直接 NPU 嵌入） |
| `bge-small-zh-v1.5_256.cix` | `/opt/ncz/models/` | ✅ NPU 嵌入模型（INT8 AOT，512 维，256 词元） |
| `bge-small-zh-v1.5-q8_0.gguf` | `/opt/ncz/models/` | CPU/GPU 回退嵌入模型 |
| `embedkit-bench`、`embedkit-doctor` | `/usr/local/bin/` | 基准测试 + 诊断适配器选择 |

`embedkit.Engine.auto()` 在运行时挑选最佳可用适配器（**NPU > GPU > CPU**）——
无需改动代码。直接使用：

```python
import sys; sys.path.insert(0, "/opt/cix")
from npu_embed_v2 import NPUEmbedder
e = NPUEmbedder("/opt/ncz/models/bge-small-zh-v1.5_256.cix",
                "/usr/share/cix/lib/libnoe.so")
v = e.embed("hello cix")          # 512 维向量，在 NPU 上计算
```

---

## 5. CIX NPU 推理 + 获取新模型

### 5.1 NPU 推理如何工作
Zhouyi NPU 运行**提前编译（AOT）**的图（`.cix` / `noe.cix`），而非任意模型。
流水线：

```
训练好的模型 (ONNX/TFLite)  ──Compass NN 编译器──▶  noe.cix (INT8)
                                                       │
                            libnoe.so  ◀──加载/运行────┘   →  /dev/aipu
```

你**不能**在 NPU 上直接加载 ONNX/PyTorch 模型 —— 必须先（用 Cix 的 Compass NN
工具链，离线/x86）编译为 `.cix`。预编译的 `.cix` 模型通过 **Cix AI Model Hub**
分发。

### 5.2 系统中已有的模型
- 嵌入：`/opt/ncz/models/bge-small-zh-v1.5_256.cix`
- 测试图：`/usr/share/cix/testdata/npu/` —— `tflite_resnet50_1core`、
  `tflite_resnet50_3core_3batch`、`onnx_resnet50_3core`、
  `tflite_alexnet_1core/3core`（各含一个 `noe.cix` + 输入/标准答案 bin）。

可通过 `libnoe` 直接运行随附的测试图（ctypes 用法见 `/opt/cix/npu_embed_v2.py`，
ResNet50 分类见 `vision_demo.py`）。

### 5.3 从仓库拉取新模型
模型库为 `cixtech/ai_model_hub_25_Q3`（Git LFS）。两种方式：

```bash
# (a) NCZ CLI 辅助命令
ncz models pull            # → /opt/ncz/models   （拉取 .cix 包）
ncz models list            # 显示已安装的 .cix 文件

# (b) 手动（完整库：YOLOv8n、CLIP、Whisper、ResNet50、SDXL-Turbo……）
sudo apt install -y git git-lfs python3-numpy python3-pillow
git lfs install
git clone https://www.modelscope.cn/cix/ai_model_hub_25_Q3.git
cd ai_model_hub_25_Q3
git lfs pull --include="models/ComputeVision/Image_Classification/onnx_mobilenet_v2/*"
cd models/ComputeVision/Image_Classification/onnx_mobilenet_v2
python3 run_onnx.py        # 在 NPU 上运行该 .cix
```

对于 GGUF（CPU/GPU）模型，从 Hugging Face 拉取并用 llama.cpp 运行：
```bash
huggingface-cli download <repo> <file.gguf> --local-dir /opt/ncz/models
/usr/share/cix/bin/llama-cli -m /opt/ncz/models/<file.gguf> -p "..."
```

> NPU 上**无法**运行 LLM：Compass NN 编译器仅支持静态图，因此 transformer 的
> KV-cache / 变长解码无法编译。LLM 请在 CPU/GPU 上运行（llama.cpp / MNN）。
> 视觉、音频（Whisper）、嵌入和图像生成都可在 NPU 上工作。
> （见 `/usr/share/doc/ncz/NPU-STATUS.md`。）

---

## 6. 性能 & 如何选择引擎

所有数字均在 `.66` 主板、内核 `7.0.12-cix-sky1-main`、Mesa 26.1.3 上实测。

### 6.1 实测性能

**NPU（Zhouyi V3，INT8 AOT）** —— 固定形状视觉的吞吐之王：
- ResNet50 分类：**约 1,879 img/s**（单核图）
- MobileNetV2：**约 640 inf/s**（约 1.5 ms/次推理）
- BGE-small 嵌入：满足智能体记忆的实时需求；每次推理能耗最低
- 约束：静态形状、INT8、必须编译为 `.cix`。不支持 LLM。

**GPU（Mali-G720 MC10，Mesa 26.1.3）**：
- clpeak：**FP16 约 3.6 TFLOPS，FP32 约 1.98 TFLOPS，INT 约 313 GIOPS**，
  带宽约 44.8 GB/s
- llama.cpp Vulkan vs CPU：GPU **在 prefill（`pp`）胜出**，CPU **在 decode
  （`tg`）胜出**
- 26.1.3 vs 自带 26.0.3：**prefill +20.6%，decode +12.9%**
- LiteRT-LM（Dawn→Vulkan）：在 26.1.3 上可用（26.0.3 上不可用），7.5 tok/s
- 注意：超大单次分派（如 llama.cpp `pp512`）仍可能使 panvk 崩溃；不具备
  协作矩阵/张量核心。

**CPU（12 核 Armv9）**：
- Gemma-4 E2B 解码：**约 18.8 tok/s**（在 batch-1 解码上快于 GPU）
- 小模型 `tg`：约 43 tok/s；延迟极佳、无预热
- 默认且最灵活的引擎；OCR（tesseract）、分词、编排，以及任何尚未加速的工作
  负载都落在这里。

**VPU（Linlon/amvx）**：通过 GStreamer/V4L2 进行硬件 H.264/H.265 编解码
（实时、多路）。它是一个**媒体**引擎，而非 ML 引擎 —— 用它在视频转码或摄像头
流水线期间释放 CPU/GPU。

### 6.2 决策指南 —— 把工作负载路由到正确的引擎

| 你的工作负载 | 使用 | 原因 |
|---|---|---|
| 文本/图像**嵌入** | **NPU** | 固定形状、INT8、延迟+能耗最低（约 1.9k/s 量级） |
| **图像分类 / 检测**（ResNet、YOLO、MobileNet） | **NPU** | 正是 Compass NN + Zhouyi 的设计目标 |
| **OCR** | **CPU**（tesseract） | 不规则控制流；CPU 最简单/最稳健 |
| **LLM 词元生成**（对话，batch=1） | **CPU**（llama.cpp `-ngl 0`） | 解码受内存带宽限制；CPU 缓存胜出 |
| **LLM 提示摄入 / 长上下文 / 批量** | **GPU**（`-ngl 99`） | prefill 受计算限制；GPU 约为 CPU 的 3 倍 |
| **图像预处理 / CV**（模糊、缩放、色彩） | **GPU**（OpenCV OpenCL→rusticl） | 数据并行的像素运算 |
| **自定义 GPGPU 内核 / 自动调优算子** | **GPU**（rusticl/panvk、TVM） | 可用 OpenCL 3.0 + Vulkan 计算 |
| **Stable Diffusion / 图像生成** | **GPU 或 NPU** | MNN `libdiffusion`（GPU）或 SDXL-Turbo `.cix`（NPU） |
| **语音转文字** | **CPU/NPU** | whisper.cpp（CPU）或 Whisper `.cix`（NPU） |
| **视频转码 / 摄像头** | **VPU** | 专用编解码块；卸载 CPU/GPU |

### 6.3 给构建者的实用建议
- **从 CPU 起步。** 它总能工作，是基线；只有当性能分析显示它是瓶颈时才迁移到
  加速器。
- **对于智能体：** 把一个"视觉工具"跨引擎路由 —— NPU 做识别、CPU 做 OCR、
  GPU 做 CV 预处理 —— 它们从共享内存中并发运行（已在 `vision_demo.py` 中验证）。
- **对于 LLM：** 解码保留在 CPU 上，可选地把 prefill 卸载到 GPU。不要指望
  NPU 运行 LLM。
- **关注共享内存池**（超大杯 64 GB / 标准 MS-R1 32 GB）。GPU 上一个 4 GB 的
  模型就意味着 NPU 和 CPU 少了 4 GB —— 在 32 GB 的机器上，并发的大模型会更早
  发生争用。请据此规划。
- **能耗：** 对于重复的固定形状推理（嵌入、分类），NPU 是迄今能效最高的 ——
  常驻型智能体任务优先选它。

### 6.4 CPU 核心分配（big.LITTLE）与智能体绑定

Sky1 的 12 核 CPU 是异构的：**8× Cortex-A720"大"核** + **4× Cortex-A520
"小"/能效核**。`.66` 参考板上的逻辑 CPU 映射：

| 逻辑 CPU | 核心 | 最高频率 | 容量 | 角色 |
|---|---|---|---|---|
| **2、3、4、5** | Cortex-A520 | 1.8 GHz | 279 | 小核 / 能效 |
| 0、1 | Cortex-A720（主） | 2.6 GHz | 1024 | 大核 |
| 10、11 | Cortex-A720 | 2.5 GHz | 984 | 大核 |
| 6、7 | Cortex-A720 | 2.3 GHz | 905 | 大核 |
| 8、9 | Cortex-A720 | 2.2 GHz | 866 | 大核 |

**常驻智能体（zeroclaw）被偏置到小核上。** 它的热路径是编排 / 轮询 / MCP 网关
循环，而非重计算，因此 A520 集群足够用 —— 这样就能让 8 个 A720 大核保持空闲，
留给本指南路由到 CPU 的延迟敏感工作（**LLM 预填充/解码**）以及 NPU 作业编排和
桌面。

我们以**软偏置而非硬绑定**的方式实现 —— `zeroclaw.container` quadlet 设置
`CPUWeight=20` + `Nice=10`（而不是 `AllowedCPUs=2-5`）。能耗感知调度（EAS）本就
偏好把低利用率任务放到小核；低权重 + 正 nice 强化这一点，并让 zeroclaw 在负载下
把大核时间**让给**推理，同时在需要时仍能**突发**到大核（硬 cpuset 无法突发，会
拖慢 CPU 回退路径）。

在运行中的机器上查看或覆盖：

```bash
# 查看运行位置 / 权重
systemctl show zeroclaw -p AllowedCPUs -p CPUWeight -p Nice
# 改为硬绑定（Magnetar 设备，确定性）：
#   在 /etc/containers/systemd/zeroclaw.container 的 [Service] 段添加：
#   AllowedCPUs=2-5
# 然后：systemctl daemon-reload && systemctl restart zeroclaw
```

---

## 7. 速查 —— 各组件位置

```
/usr/share/cix/lib/        libnoe.so*（NPU UMD）、libMNN*、libllm.so、libdiffusion.so
/usr/share/cix/bin/        llama-*（cix-llama-cpp）、talk-llama（whisper）
/usr/share/cix/pypi/       libnoe / NOE_Engine wheel（cp311/cp312）
/usr/share/cix/testdata/npu/   随附的 .cix 测试图（resnet50、alexnet）
/opt/mesa-26.1.3/          panvk（Vulkan）+ rusticl（OpenCL）26.1.3
/opt/ncz/models/           bge-small-zh（.cix NPU + .gguf CPU/GPU）
/opt/ncz/embed-venv/       Python 3.11 嵌入运行时
/opt/cix/npu_embed_v2.py   直接 NPU 嵌入封装
/usr/local/bin/ncz         运维 CLI（models pull、status、install）
/usr/share/doc/ncz/        GPU-STATUS.md、NPU-STATUS.md（深入文档）
/dev/aipu*                 NPU 字符设备   /dev/dri/renderD128  GPU 节点
```

随时查看实时状态：
```bash
ncz status     # 内核、NPU/GPU 存在性、Vulkan 设备、模型数量
```
