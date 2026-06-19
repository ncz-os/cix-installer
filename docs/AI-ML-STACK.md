# NCZ Agentic Linux — AI/ML Stack Reference (Cix Sky1)

> What ships on the system, what each binary/library is for, how to run
> inference on the four compute engines (CPU / NPU / GPU / VPU), how they
> perform, how to choose the right engine for a workload, and how to pull
> new models.
>
> Target hardware: **Cix Sky1 (CP8180)** — 12-core Armv9 CPU, **Mali-G720
> MC10** GPU (panthor), **ArmChina Zhouyi V3** NPU, **Linlon/amvx** VPU.
> **Unified memory (UMA, shared by all engines): 64 GB on this "jumbo"
> MS-R1, 32 GB on the standard MS-R1.** (The GPU driver exposes ~46.85 GiB
> of that as its allocatable pool after kernel/firmware reservations.)
>
> Status legend: ✅ validated on the `.66` reference board · ⚠️ works with
> caveats · 🧪 dev/optional.

---

## 0. The four engines at a glance

| Engine | Hardware | Best at | Precision | Peak (measured) | Programming surface |
|---|---|---|---|---|---|
| **CPU** | 12× Armv9 (NEON/SVE2) | LLM **decode**, control flow, OCR, glue | FP32/FP16/INT8 | ~18.8 tok/s Gemma-E2B decode | llama.cpp, MNN, any binary |
| **NPU** | Zhouyi V3 (3 cores) | fixed-shape **CNN/vision**, **embeddings** | INT8 (AOT) | ResNet50 ~1.9k img/s; MobileNetV2 ~640 inf/s | libnoe (`.cix` graphs) |
| **GPU** | Mali-G720 MC10 (10 CU) | **prefill**, batched GEMM, CV, GPGPU | FP16/FP32/INT | FP16 ~3.6 TFLOPS, FP32 ~1.98 TFLOPS | Vulkan (panvk), OpenCL (rusticl) |
| **VPU** | Linlon/amvx | H.264/H.265 **transcode** | — | real-time multi-stream | GStreamer/V4L2 (media, not ML) |

**One-sentence routing rule:** *embeddings & vision → NPU; LLM token
generation → CPU; LLM prompt-ingest / batched math / image preprocessing →
GPU; video → VPU.* Details and the "why" are in §6.

Everything shares one unified memory pool (**64 GB on this jumbo unit, 32 GB
on the standard MS-R1**), so there is **no host↔device copy cost** — but it
also means a big model on one engine reduces headroom for the others.

---

## 1. CIX userspace runtime (the proprietary substrate)

Installed from the Cix factory `.deb` set by `25-cix-proprietary.sh`.
Lives under `/usr/share/cix/`.

| Library | Path | Purpose / target app |
|---|---|---|
| `libnoe.so.0.6.0` | `/usr/share/cix/lib/` | ✅ **NPU userspace driver (UMD)** — loads/runs AOT-compiled `.cix` graphs on Zhouyi. The foundation of all NPU inference. |
| `libnoe.a` | `/usr/share/cix/lib/` | static variant for embedding the UMD in a binary |
| `libMNN.so` + `libMNN_CL.so` + `libMNN_Vulkan.so` | `/usr/share/cix/lib/` | ⚠️ **Alibaba MNN** inference engine — CPU + OpenCL + Vulkan backends for CNN/transformer models (`.mnn` format) |
| `libMNNOpenCV.so` | `/usr/share/cix/lib/` | MNN's built-in OpenCV-compatible image ops |
| `libllm.so` | `/usr/share/cix/lib/` | MNN-LLM runtime (on-device LLM via MNN) |
| `libdiffusion.so` | `/usr/share/cix/lib/` | MNN Stable-Diffusion pipeline |
| `cix-gpu-umd` → `libmali.so`, `libOpenCL.so` | `/opt/cixgpu-pro/` | ⚠️ **proprietary Mali driver** — **disabled** on this image (incompatible with the panthor kernel). Replaced by Mesa rusticl/panvk. See §3. |
| `cix-libdrm`, `cix-libglvnd` | system | DRM + GL vendor-neutral dispatch shims |

**Python NPU bindings** (cp311/cp312 only) ship as wheels at
`/usr/share/cix/pypi/`:
- `libnoe-2.0.0-…aarch64.whl` — ctypes/cpython binding for `libnoe`
- `NOE_Engine-2.0.0-…aarch64.whl` — higher-level `EngineInfer` wrapper

> **Version lock:** only `cix-noe-umd 2.0.2` (this `libnoe 0.6.0` +
> `libnoe/NOE_Engine 2.0.0` wheels) is validated against our in-tree
> `armchina_npu` kernel driver. UMD 1.1.1 and 3.1.2 fail job-submit. The
> wheels are cpython-3.11/3.12 ABI-locked — that is why the embedding venv
> is built on Python 3.11, not the system 3.14 (see §4).

---

## 2. Prebuilt AI binaries (ready to run)

### 2.1 llama.cpp — `cix-llama-cpp` → `/usr/share/cix/bin/`
GGUF LLM + multimodal runtime. CPU and Vulkan (Mali) backends.

| Binary | Use |
|---|---|
| `llama-cli` | interactive / one-shot text generation |
| `llama-server` | OpenAI-compatible HTTP server (`/v1/...`) |
| `llama-bench` | throughput benchmark (prefill `pp` + decode `tg`) |
| `llama-perplexity` | quality eval |
| `llama-quantize` | convert/quantize GGUF |
| `llama-llava-cli`, `llama-minicpmv-cli`, `llama-qwen2vl-cli` | **vision-language** chat (image + text) |

```bash
# CPU decode (best for batch-1 token generation)
/usr/share/cix/bin/llama-cli -m model.gguf -ngl 0 -p "Hello" -n 128
# GPU offload via Mesa Vulkan/panvk (best for prompt ingest)
/usr/share/cix/bin/llama-cli -m model.gguf -ngl 99 -p "..." -n 128
```

### 2.2 MNN — `cix-mnn` (libraries above)
Alibaba's mobile inference engine. Strong on Mali via its OpenCL backend;
includes an LLM runtime (`libllm.so`) and a diffusion pipeline
(`libdiffusion.so`). Use for `.mnn` models, on-device Stable Diffusion, or
when you want a single engine spanning CPU+OpenCL+Vulkan.

### 2.3 whisper.cpp — `cix-whisper-cpp` → `/usr/share/cix/bin/`
Speech-to-text (Whisper). `talk-llama` chains Whisper STT → llama.cpp →
(optional TTS) for a voice assistant loop.

### 2.4 GPU / compute tools (Mesa 26.1.3 stack — see §3)
`vulkaninfo`, `clinfo`, `glslangValidator`, `spirv-val/-dis`, `glmark2`.
Installed by `47-llm-stack.sh` + `16-mesa-gpu-2613.sh`.

---

## 3. GPU compute drivers (Mesa 26.1.3 — NCZ build)

We ship a **from-source Mesa 26.1.3** under `/opt/mesa-26.1.3`, redirected
to be the system Vulkan + OpenCL provider (desktop GL stays on stock Mesa).
Full rationale in `/usr/share/doc/ncz/GPU-STATUS.md`.

| Driver | API | ICD / how it's selected | Use |
|---|---|---|---|
| **panvk** | Vulkan 1.4 | `VK_DRIVER_FILES` (set in `/etc/environment`) | ✅ llama.cpp `-ngl`, WebGPU/Dawn, Vulkan compute |
| **rusticl** | OpenCL 3.0 | `/etc/OpenCL/vendors/rusticl.icd` + `RUSTICL_ENABLE=panfrost` | ✅ OpenCV OpenCL, clpeak, MNN-CL, TVM, custom kernels |

Why our build and not stock 26.0.3:
- Stock panvk hard-failed GPU compute (`VK_ERROR_OUT_OF_DEVICE_MEMORY`,
  16-entry storage-buffer cap) — broke Dawn/WebGPU and large dispatches.
- The base image shipped **no GPU OpenCL at all** (`mesa-opencl-icd`
  removed → only CPU pocl). Our rusticl **restores** GPU OpenCL.

```bash
vulkaninfo | grep -E 'deviceName|driverInfo'      # Mali-G720 / Mesa 26.1.3
clinfo     | grep -E 'Device Name|Driver Version'  # Mali-G720 (Panfrost) / 26.1.3
```

> **Not shipped: Teflon.** Mesa's TFLite delegate only targets Ethos-U /
> VeriSilicon / Rockchip NPUs — it cannot drive the Mali GPU or the Zhouyi
> NPU, and fails with "Couldn't open kernel device" here. Use the
> Zhouyi/libnoe path for NPU instead.

🧪 **Apache TVM** (dev tool, not in the default image) compiles models to
OpenCL and runs on rusticl — validated (VADD + GEMM correct). Use it for
auto-tuned custom operators targeting Mali.

---

## 4. The embedding stack (MNEMOS / agent memory)

The agent memory system (`mnemos`) needs fast text embeddings. That path is
prebuilt and runs on the **NPU**:

| Component | Path | Role |
|---|---|---|
| embedkit venv (Python 3.11) | `/opt/ncz/embed-venv` | `mnemos-embedkit` + `libnoe` + `llama-cpp-python` |
| `npu_embed_v2.py` | `/opt/cix/` | ctypes wrapper around `libnoe.so` (direct NPU embeddings) |
| `bge-small-zh-v1.5_256.cix` | `/opt/ncz/models/` | ✅ NPU embedding model (INT8 AOT, 512-dim, 256-tok) |
| `bge-small-zh-v1.5-q8_0.gguf` | `/opt/ncz/models/` | CPU/GPU fallback embedding model |
| `embedkit-bench`, `embedkit-doctor` | `/usr/local/bin/` | benchmark + diagnose adapter selection |

`embedkit.Engine.auto()` picks the best available adapter at runtime
(**NPU > GPU > CPU**) — no code change needed. Direct use:

```python
import sys; sys.path.insert(0, "/opt/cix")
from npu_embed_v2 import NPUEmbedder
e = NPUEmbedder("/opt/ncz/models/bge-small-zh-v1.5_256.cix",
                "/usr/share/cix/lib/libnoe.so")
v = e.embed("hello cix")          # 512-dim vector, computed on the NPU
```

---

## 5. CIX NPU inference + getting new models

### 5.1 How NPU inference works
The Zhouyi NPU runs **ahead-of-time compiled** graphs (`.cix` / `noe.cix`),
not arbitrary models. Pipeline:

```
trained model (ONNX/TFLite)  ──Compass NN compiler──▶  noe.cix (INT8)
                                                          │
                              libnoe.so  ◀──load/run──────┘   →  /dev/aipu
```

You **cannot** load an ONNX/PyTorch model directly on the NPU — it must be
compiled to `.cix` first (by Cix's Compass NN toolchain, offline/x86).
Pre-compiled `.cix` models are distributed via the **Cix AI Model Hub**.

### 5.2 Models already on the system
- Embedding: `/opt/ncz/models/bge-small-zh-v1.5_256.cix`
- Test graphs: `/usr/share/cix/testdata/npu/` — `tflite_resnet50_1core`,
  `tflite_resnet50_3core_3batch`, `onnx_resnet50_3core`,
  `tflite_alexnet_1core/3core` (each a `noe.cix` + input/golden bins).

Run a shipped test graph directly via `libnoe` (see `/opt/cix/npu_embed_v2.py`
for the ctypes pattern, or `vision_demo.py` for ResNet50 classification).

### 5.3 Pulling new models from the repo
The model hub is `cixtech/ai_model_hub_25_Q3` (Git LFS). Two ways:

```bash
# (a) NCZ CLI helper
ncz models pull            # → /opt/ncz/models   (fetches the .cix bundle)
ncz models list            # show installed .cix files

# (b) Manual (full hub: YOLOv8n, CLIP, Whisper, ResNet50, SDXL-Turbo, ...)
sudo apt install -y git git-lfs python3-numpy python3-pillow
git lfs install
git clone https://www.modelscope.cn/cix/ai_model_hub_25_Q3.git
cd ai_model_hub_25_Q3
git lfs pull --include="models/ComputeVision/Image_Classification/onnx_mobilenet_v2/*"
cd models/ComputeVision/Image_Classification/onnx_mobilenet_v2
python3 run_onnx.py        # runs the .cix on the NPU
```

For GGUF (CPU/GPU) models, pull from Hugging Face and run with llama.cpp:
```bash
huggingface-cli download <repo> <file.gguf> --local-dir /opt/ncz/models
/usr/share/cix/bin/llama-cli -m /opt/ncz/models/<file.gguf> -p "..."
```

> NPU LLMs are **not** available: the Compass NN compiler is static-graph
> only, so transformer KV-cache / variable-length decode does not compile.
> Run LLMs on CPU/GPU (llama.cpp / MNN). Vision, audio (Whisper), embeddings,
> and image-gen all work on the NPU. (See `/usr/share/doc/ncz/NPU-STATUS.md`.)

---

## 6. Performance & how to choose an engine

All numbers measured on the `.66` board, kernel `7.0.12-cix-sky1-main`,
Mesa 26.1.3.

### 6.1 Measured performance

**NPU (Zhouyi V3, INT8 AOT)** — the throughput king for fixed-shape vision:
- ResNet50 classification: **~1,879 img/s** (1-core graph)
- MobileNetV2: **~640 inf/s** (~1.5 ms/inference)
- BGE-small embeddings: real-time for agent memory; lowest energy/inference
- Constraint: static shapes, INT8, must be `.cix`-compiled. No LLMs.

**GPU (Mali-G720 MC10, Mesa 26.1.3)**:
- clpeak: **FP16 ~3.6 TFLOPS, FP32 ~1.98 TFLOPS, INT ~313 GIOPS**, BW ~44.8 GB/s
- llama.cpp Vulkan vs CPU: GPU **wins prefill** (`pp`), CPU **wins decode** (`tg`)
- 26.1.3 vs stock 26.0.3: **+20.6% prefill, +12.9% decode**
- LiteRT-LM (Dawn→Vulkan): functional on 26.1.3 (was broken on 26.0.3), 7.5 tok/s
- Caveat: very large single dispatches (e.g. llama.cpp `pp512`) can still
  crash panvk; cooperative-matrix/tensor cores are absent.

**CPU (12-core Armv9)**:
- Gemma-4 E2B decode: **~18.8 tok/s** (faster than GPU for batch-1 decode)
- Small-model `tg`: ~43 tok/s; great latency, no warm-up
- The default and most flexible engine; OCR (tesseract), tokenization,
  orchestration, and any not-yet-accelerated workload land here.

**VPU (Linlon/amvx)**: hardware H.264/H.265 encode+decode (real-time,
multi-stream) via GStreamer/V4L2. It is a **media** engine, not an ML one —
use it to free CPU/GPU during video transcode or camera pipelines.

### 6.2 Decision guide — route the workload to the right engine

| Your workload | Use | Why |
|---|---|---|
| Text/image **embeddings** | **NPU** | fixed-shape, INT8, lowest latency+energy (1.9k/s class) |
| **Image classification / detection** (ResNet, YOLO, MobileNet) | **NPU** | what Compass NN + Zhouyi are built for |
| **OCR** | **CPU** (tesseract) | irregular control flow; CPU is simplest/robust |
| **LLM token generation** (chat, batch=1) | **CPU** (llama.cpp `-ngl 0`) | decode is memory-bandwidth-bound; CPU caches win |
| **LLM prompt ingest / long context / batched** | **GPU** (`-ngl 99`) | prefill is compute-bound; GPU is ~3× CPU there |
| **Image preprocessing / CV** (blur, resize, color) | **GPU** (OpenCV OpenCL→rusticl) | data-parallel pixel math |
| **Custom GPGPU kernels / autotuned ops** | **GPU** (rusticl/panvk, TVM) | OpenCL 3.0 + Vulkan compute available |
| **Stable Diffusion / image-gen** | **GPU or NPU** | MNN `libdiffusion` (GPU) or SDXL-Turbo `.cix` (NPU) |
| **Speech-to-text** | **CPU/NPU** | whisper.cpp (CPU) or Whisper `.cix` (NPU) |
| **Video transcode / camera** | **VPU** | dedicated codec block; offloads CPU/GPU |

### 6.3 Practical guidance for builders
- **Start on CPU.** It always works and is the baseline; only move to an
  accelerator when a profile shows it's the bottleneck.
- **For agents:** route a "vision tool" across engines — NPU for
  recognition, CPU for OCR, GPU for CV preprocessing — they run concurrently
  out of shared memory (validated in `vision_demo.py`).
- **For LLMs:** keep decode on CPU, optionally offload prefill to GPU. Don't
  expect the NPU to run LLMs.
- **Watch the shared memory pool** (64 GB jumbo / 32 GB standard MS-R1). A
  4 GB model on the GPU is 4 GB the NPU and CPU no longer have — and on a
  32 GB unit, concurrent large models contend much sooner. Size accordingly.
- **Energy:** for repeated fixed-shape inference (embeddings, classification),
  the NPU is by far the most power-efficient — prefer it for always-on agent
  tasks.

### 6.4 CPU core allocation (big.LITTLE) & agent pinning

Sky1's 12-core CPU is heterogeneous: **8× Cortex-A720 "big"** cores and
**4× Cortex-A520 "little"/efficiency** cores. Logical CPU mapping on the `.66`
reference board:

| Logical CPUs | Core | Max clock | Capacity | Role |
|---|---|---|---|---|
| **2, 3, 4, 5** | Cortex-A520 | 1.8 GHz | 279 | little / efficiency |
| 0, 1 | Cortex-A720 (prime) | 2.6 GHz | 1024 | big |
| 10, 11 | Cortex-A720 | 2.5 GHz | 984 | big |
| 6, 7 | Cortex-A720 | 2.3 GHz | 905 | big |
| 8, 9 | Cortex-A720 | 2.2 GHz | 866 | big |

**The always-on agent (zeroclaw) is biased toward the little cores.** Its hot
path is an orchestration / poll / MCP-gateway loop, not heavy math, so the
A520 cluster is plenty — and that keeps the eight A720 big cores clear for the
latency-sensitive work this guide routes to CPU (**LLM prefill/decode**) plus
NPU job orchestration and the desktop.

We ship this as a **soft bias, not a hard pin** — the `zeroclaw.container`
quadlet sets `CPUWeight=20` + `Nice=10` (not `AllowedCPUs=2-5`). Energy-Aware
Scheduling already prefers little cores for low-utilization tasks; the low
weight + positive nice reinforce that and make zeroclaw **yield** big-core time
to inference under load, while still letting it **burst** onto big cores if it
ever needs to (a hard cpuset cannot burst, and would throttle a CPU fallback).

To inspect or override on a running box:

```bash
# see where it runs / its weight
systemctl show zeroclaw -p AllowedCPUs -p CPUWeight -p Nice
# hard-pin instead (Magnetar appliance, deterministic):
#   add to the [Service] section of /etc/containers/systemd/zeroclaw.container:
#   AllowedCPUs=2-5
# then: systemctl daemon-reload && systemctl restart zeroclaw
```

---

## 7. Quick reference — where everything lives

```
/usr/share/cix/lib/        libnoe.so* (NPU UMD), libMNN*, libllm.so, libdiffusion.so
/usr/share/cix/bin/        llama-* (cix-llama-cpp), talk-llama (whisper)
/usr/share/cix/pypi/       libnoe / NOE_Engine wheels (cp311/cp312)
/usr/share/cix/testdata/npu/   shipped .cix test graphs (resnet50, alexnet)
/opt/mesa-26.1.3/          panvk (Vulkan) + rusticl (OpenCL) 26.1.3
/opt/ncz/models/           bge-small-zh (.cix NPU + .gguf CPU/GPU)
/opt/ncz/embed-venv/       Python 3.11 embedding runtime
/opt/cix/npu_embed_v2.py   direct NPU embedding wrapper
/usr/local/bin/ncz         operator CLI (models pull, status, install)
/usr/share/doc/ncz/        GPU-STATUS.md, NPU-STATUS.md (deep dives)
/dev/aipu*                 NPU char device   /dev/dri/renderD128  GPU node
```

Check live status any time:
```bash
ncz status     # kernel, NPU/GPU presence, Vulkan devices, model count
```
