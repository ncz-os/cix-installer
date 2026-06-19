# Inference Limits & Capability Matrix — cixmini (CIX Sky1)

**Box:** Minisforum MS-R1 — CIX Sky1 (CD8180): 12-core ARMv9 Neoverse, Mali-G720
(Immortalis) GPU, Zhouyi V3 NPU (~30 TOPS INT8), 64 GB unified LPDDR.
**Kernel:** `7.0.12-cix-sky1-next`. **Measured:** 2026-05 → 2026-06 on `.66`.
Raw logs: `/mnt/argonas_backups/cixmini-bench/<ts>/` (ncnn cpu/gpu, embeddings).

---

## Headline

Per-workload accelerator hierarchy on this box:

| Workload | 1st choice | 2nd | Avoid |
|---|---|---|---|
| **Text embeddings** (encoder, ≤256 tok) | **NPU** (.cix) | CPU (fastembed/ONNX) | GPU compute |
| **Long-doc embeddings** (>256 tok) | **CPU** (fastembed/ONNX) | — | NPU (truncates), GPU |
| **Vision / CNN** (mobilenet, resnet, yolo) | **NPU** (.cix) | CPU (ncnn) | GPU compute |
| **LLM decode** (autoregressive) | **CPU** (llama.cpp) | — | NPU (no KV-cache), GPU (no coop-matrix) |
| **Display / desktop GL/Vulkan** | **GPU** (panthor) | — | — |

One line: **NPU for fixed-shape encoders, CPU for everything dynamic, GPU for
pixels — not for ML compute.**

---

## Master capability matrix

| Path | Driver stack | Model formats | Best workloads | Status | Hard limit |
|---|---|---|---|---|---|
| **NPU — Zhouyi V3** | `armchina_npu.ko` (in-tree) + `cix-noe-umd 2.0.2` / `libnoe.so.0.6.0` + `NOE_Engine`/`libnoe` py3.11 wheels | `.cix` (Compass NN AOT, INT8/INT16) | encoder embeddings, CNN/vision, OCR, Whisper, CLIP, detection | **production** (prebuilt `.cix` only) | fixed-shape graphs only; ~2 GB IOVA; py3.11/3.12; 0x23 job churn |
| **CPU — 12-core Neoverse** | native (NEON/SVE) | GGUF (llama.cpp), ONNX (fastembed/ORT), PyTorch | long-token embeddings, LLM decode, anything dynamic-shape, universal fallback | **production** | memory-bandwidth bound on big GEMM |
| **GPU compute — panvk (Vulkan)** | `panthor.ko` + Mesa panvk | GGUF (llama.cpp Vulkan) | *(none for ML)* | **not recommended** | no cooperative-matrix; non-conformant; 6–47× slower than CPU |
| **GPU compute — rusticl (OpenCL)** | `panthor.ko` + Mesa rusticl (Gallium) | OpenCL kernels (no ML framework) | raw GEMM only (~1.9 TFLOPS FP32 clpeak) | **experimental** | no ML framework targets it; slow host readback |
| **GPU compute — libmali (OpenCL, vendor)** | vendor `libmali` OpenCL | vendor blob, no ICD loader | CNN/quantized *if* you bring a framework | **experimental** | not a real ICD; integration-hostile; slow readback |
| **GPU display — panthor** | `panthor.ko` + Mesa panfrost/panvk | — | KMS, desktop GL/Vulkan, compositing | **production** | — |

---

## Embeddings (the load-bearing workload)

Single-stream, MiniLM-L6 / bge-small class, seq 128–256. Higher = better.

| Path | Engine / model | emb/s | Notes |
|---|---:|---:|---|
| **NPU** | `NOE_Engine` + `bge-small-zh-v1.5_256.cix` | **~51** | measured .66 2026-06-17; 512-dim, retrieval correct |
| **NPU** | `NOE_Engine` + `minilm_128.cix` (real tokenized) | ~56 | per-call job churn; batch/persistent-job target ~66–80 |
| **CPU** | fastembed / ONNX Runtime (optimized) | ~700 | #21 figure; ORT is *far* faster than llama.cpp for encoders |
| **CPU** | `llama.cpp` (MiniLM-L6 Q8 GGUF) | 13.3 | GGUF path is not the fast CPU path for embeddings |
| **GPU** | Mali-G720 panvk (`llama.cpp` Vulkan, MiniLM Q8) | 8.8 | slowest; readback + no coop-matrix |

**Reading this correctly:** the NPU's value is **perf-per-watt**, not raw emb/s.
CPU/ONNX (fastembed) wins on absolute throughput (~700 emb/s) but at ~80 W;
the NPU does ~51 emb/s at a fraction of that, ideal for a 24/7 always-on
appliance. For bursty/offline reindex of a large corpus, CPU/ONNX is faster
wall-clock. MNEMOS routes via `embedkit.Engine.auto()` — NPU tier wins by
default on Sky1; force CPU with `prefer_tier="cpu"` for big batch reindex.

Caching changes everything: on a real agentic mix (~50 % repeat) the box
shipped **110 emb/s** (cold-miss → NPU, cache-hit → 8 µs host lookup); full
warm cache is effectively free.

---

## Vision / CNN (ncnn `benchncnn`, avg ms, lower = better)

loop_count=8, cooling_down=1. CPU = 4 threads.

| model | CPU 4t | panvk GPU | GPU penalty | NPU (.cix) |
|---|---:|---:|---:|---:|
| squeezenet | 4.99 | 29.92 | 6× | — |
| mobilenet_v2 | 4.31 | 30.54 | 7× | **~1.5 (≈640/s)** |
| resnet18 | 6.88 | 75.34 | 11× | — |
| resnet50 | 19.40 | 189.31 | 10× | — |
| vgg16 | 37.38 | 373.94 | 10× | — |
| googlenet | 9.78 | 84.63 | 9× | — |
| mobilenet_yolo | 23.16 | 168.57 | 7× | — |
| yolov8n | — | — | — | **~14.5 (≈69/s)** |
| vision_transformer | 215.70 | 10210.6 | **47×** | — |

NPU vision numbers measured on `.66` (mobilenet_v2 2026-05, yolov8n 2026-06-17).
For everything GEMM-heavy the panvk GPU pays full dispatch/readback overhead with
no matmul acceleration → always slower than CPU, catastrophically so for ViT.

---

## LLM / autoregressive decode

**No good local accelerator path.** All three reasons are structural, not tuning:

- **NPU**: Compass NN is a *static-graph* AOT compiler — no KV-cache primitive,
  no FlashAttention, no dynamic sequence length. The model zoo stops at the
  encoder-only side. Running a decoder transformer is a research-grade project
  (extend the parser for dynamic shapes, or hand-write a static-graph LLM).
- **GPU**: Mali-G720's Vulkan exposes **no cooperative-matrix** (`fp16/int8/bf16/
  fp8-cm=0`), so attention/FFN GEMMs get no acceleration; rusticl has raw FLOPS
  (~1.9 TFLOPS FP32) but no LLM framework targets it and readback is slow.
- **CPU**: `llama.cpp` on the 12-core Neoverse is the only practical path —
  fine for small quantized models, modest tok/s. This is the fallback, not a
  showcase.

If you need real LLM throughput, generate off-box (PYTHIA / dGPU) and use Sky1
for the memory/embedding lane.

---

## Per-driver deep dives

### NPU — Zhouyi V3 (`armchina_npu` + libnoe)

- **What runs:** prebuilt `.cix` from the Cix `ai_model_hub` (ModelScope 26_Q1)
  — YOLO, MobileNet/ResNet/EfficientNet, Whisper tiny/small/medium, CLIP/SigLIP,
  SDXL-Turbo, PP-OCRv4, pose/hand, and `bge-small-zh-v1.5` embeddings.
- **Userspace pairing that works:** `cix-noe-umd 2.0.2` (libnoe 0.6.0) only.
  3.1.2 rejects the Z3 device; 1.1.1 fails job-submit (rc=20). See
  `docs/MNEMOS-NPU-EMBEDDINGS.md`.
- **Python:** the libnoe wheel ships **cp311/cp312 only** — must run in the
  `/opt/ncz/embed-venv` Python 3.11 uv venv (system Python is 3.14).
- **0x23 persistent-job bug:** `noe_job_infer_sync` times out on a reused job,
  so every inference does `create_job`/`clean_job` — leaves ~50 % of the silicon
  on the table. Fixed in newer libnoe (26Q1); ships when we land that UMD.
- **IOVA ceiling:** 32-bit bus (`bus_dma_limit 0xc0000000`), driver pinned to
  `iova_region=2` → practical working set **~2 GB** regardless of host RAM.

### GPU — panthor (Mali-G720)

- **Display: production.** KMS/GL/Vulkan/compositing all good — this is what the
  GPU is for on this box.
- **Compute: avoid for ML.** panvk is non-conformant ("testing use only"), no
  cooperative-matrix → 6–47× slower than CPU on every net tested. rusticl/libmali
  OpenCL have raw FLOPS but no ML framework consumes them and host readback is
  slow. Use only for OpenCL-native CV/image processing that keeps data on-device.

### CPU — 12-core Neoverse

- **The universal path.** Best for long-token embeddings (no 256-tok cap),
  LLM decode, dynamic-shape models, and as the fallback when NPU/GPU can't run a
  graph. fastembed/ONNX Runtime is the fast embedding engine here (~700 emb/s);
  llama.cpp GGUF is for LLM decode, not embeddings.

---

## Hard limits cheat-sheet

| Limit | Value | Impact |
|---|---|---|
| NPU graph shapes | fixed only | no LLM decode; encoders/CNN only |
| NPU working set | ~2 GB (32-bit IOVA) | big models must fit the aperture |
| NPU quant | INT8 / INT16 | FP models must be Compass-quantized |
| bge token cap | 256 tokens | long docs truncated → route to CPU |
| NPU Python | 3.11 / 3.12 | dedicated `/opt/ncz/embed-venv` |
| NPU sustained | ~50 % of silicon | 0x23 job churn until newer libnoe |
| GPU coop-matrix | none | no GEMM accel → ML compute loses |
| `.cix` compiler | not public | use prebuilt hub or 26Q1 Docker compiler |

---

## How the distro routes this

- `embedkit.Engine.auto()` picks NPU > GPU > CPU by tier, micro-benchmarking
  within tier — no vendor preference. On Sky1 it selects the `npu-cix` adapter
  automatically (`docs/MNEMOS-NPU-EMBEDDINGS.md`).
- NPU runtime + the bge `.cix` + tokenizer are baked into the ISO; models layer
  via `ncz model add` / the Cix hub (`docs/MODELSCOPE-MODELS.md`).
- GPU is wired for display only; nothing routes ML compute to it.

## References

- `docs/MNEMOS-NPU-EMBEDDINGS.md` — automatic embedding chain
- `docs/MODELSCOPE-MODELS.md` — pulling `.cix` models
- `docs/FB-POST-IS-IT-GPU-LLM-OR-NPU-MEMORY.md` — cache-aware throughput
- cixtech/cix-linux-main#21 — libnoe / `.cix` / persistent-job upstream asks
