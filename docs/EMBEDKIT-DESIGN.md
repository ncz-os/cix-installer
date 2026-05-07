# embedkit — open embedding devkit for heterogeneous edge SoCs

**Status:** DESIGN draft 2026-05-07.
**Target repo:** `perlowja/embedkit` (Apache-2.0, public OSS).
**Reference implementation consumer:** `mnemos-os/mnemos` (MNEMOS embedding pipeline migrates to embedkit and ships as the canonical demo).

---

## TL;DR

A pure Python + Rust devkit that abstracts "embed text → vector" across CPU / GPU / NPU silicon from any vendor. One install. One API. One bench harness. The kit picks an adapter at runtime based on **what's installed on the host**; it does not bundle vendor drivers and does not prefer any vendor.

```
embedkit.Engine.auto()  -> picks fastest available adapter, by measured tier+throughput
embedkit.Engine("cix-npu", model="bge-small-zh-v1.5")
embedkit.Engine("nvidia-cuda", model="nomic-embed-text-v1.5")
embedkit.Engine("amd-rocm", model="nomic-embed-text-v1.5")
embedkit.Engine("intel-npu", model="bge-small-en-v1.5")
embedkit.Engine("cpu-llamacpp", model="nomic-embed-text-v1.5")
```

Vendors covered as first-class adapters (alphabetical, no ordering implied):

- **AMD ROCm GPU** (Instinct, Radeon Pro, consumer Radeon)
- **AMD XDNA NPU** (Ryzen AI 7040/8040/HX, Ryzen AI Max)
- **Apple MLX** (M1-M4 unified memory)
- **Cix Zhouyi V3 NPU** (Sky1 / CD8180 / P1)
- **Intel iGPU + NPU** (Lunar Lake, Arrow Lake, Meteor Lake via OpenVINO)
- **NVIDIA CUDA** (consumer GeForce, RTX Pro / Ada, datacenter Hopper / Blackwell)
- **NVIDIA TensorRT** (specialized fp16/int8 path on the same hardware)
- **MediaTek APU** (Genio + Dimensity)
- **Mali GPU via Vulkan** (Cix, Rockchip, Allwinner, etc.)
- **Rockchip RKNN NPU** (RK3588 / RK3576 / RK3566)
- **CPU baseline** via llama.cpp + sentence-transformers (every box, fallback)

One `embedkit.bench(corpus, engines=[...])` call produces the canonical comparison table for any host. The user picks the box, embedkit picks the silicon — by capability and measured throughput, not by vendor.

MNEMOS is the reference implementation consumer: replace its embedding helper with `embedkit.Engine(...)` and ship.

---

## What the kit is NOT

embedkit does **not bundle vendor drivers, kernel modules, or closed-source SDKs**. Those are owned by the operating system or the user's package manager:

| Layer | Owns | Examples |
|---|---|---|
| **OS / image** | Kernel modules, vendor userspace runtimes, model loader libs | NCZ Magnetar/Reinhardt bakes `cix-noe-umd 2.0.2` + `libnoe`; Ubuntu ships NVIDIA drivers via `ubuntu-drivers`; AMD ships `rocm-dkms`; Intel ships `intel-npu-driver`. |
| **OS package manager / PyPI** | Userspace SDKs and python bindings | `pip install onnxruntime-gpu` (CUDA), `pip install onnxruntime-rocm` (AMD ROCm), `pip install openvino` (Intel), `pip install mlx` (Apple). |
| **embedkit (this kit)** | Adapter shims + uniform Engine API + bench harness | `pip install embedkit[all]` (or per-vendor extras). Detects what the host has, uses it. |

This separation is intentional. Embedkit must run on any box without privilege, without rewriting `/etc`, without a custom kernel. If the host has CUDA installed, the CUDA adapter works. If it has Cix Zhouyi UMD installed, the Cix adapter works. If it has nothing but a CPU, the llama-cpp-python adapter works. **No silicon is preferred or required.**

The NCZ Magnetar/Reinhardt OS distribution is one consumer of embedkit, not a dependency. Magnetar bakes the Cix proprietary stack at install time so embedkit's `npu_cix_zhouyi` adapter has something to talk to — but embedkit ships separately as a public OSS Python package, runs on ARGOS x86, on PYTHIA x86, on bigpi ARM64, on a Mac Studio, on a CERBERUS RTX 4500 ADA box, on a Ryzen AI Max workstation, identically.

---

## Why now

The 2026-05-07 Sky1 bench session produced four real-corpus throughput numbers on the *exact same model* (`nomic-embed-text-v1.5.Q8_0` on CPU paths, `bge-small-zh_256.cix` on the NPU path) against the *exact same 8038-record MNEMOS corpus*:

| Engine | rec/s | Notes |
|---|---|---|
| PYTHIA x86 + ollama (HTTP) | 2.17 | RPC overhead included |
| PYTHIA x86 + llama-cpp-python (in-process) | 2.92 | RPC removed |
| Cix ARM64 + llama-cpp-python (in-process) | ~40 | 30W ARM crushes 80W x86 on encoder workload |
| Cix Sky1 NPU (cix-noe-umd 2.0.2 + bge-small-zh_256.cix) | ~60 | dedicated silicon, INT8 quantized |

The numbers are publishable on their own. The *meta-finding* is that nobody ships a clean abstraction — every chip vendor expects you to use their bespoke runtime, and end-users glue ten things together to test one model.

embedkit closes that gap.

---

## Architecture

```
   +----------------------------------------------------------+
   |  embedkit.Engine(text|texts) -> List[List[float]]        |
   |  embedkit.bench(corpus_path, engines=[...]) -> SummaryJSON|
   +-----+------------------+------------------+--------------+
         |                  |                  |
   +-----v-----+      +-----v-----+      +-----v-----+
   |   CPU     |      |   GPU     |      |   NPU     |
   |  adapter  |      |  adapter  |      |  adapter  |
   +-----+-----+      +-----+-----+      +-----+-----+
         |                  |                  |
   llama-cpp-python   AMD ROCm           AMD XDNA
   sentence-transf.   Apple MLX          Cix Zhouyi V3
   ONNX Runtime CPU   Intel iGPU         Intel NPU
                      NVIDIA CUDA        MediaTek APU
                      NVIDIA TensorRT    Rockchip RKNN
                      Vulkan (vendor-
                       agnostic)
```

Adapters listed alphabetically within tier. **No vendor priority.** The kit picks at runtime based on what's installed and which adapter is fastest on this host.

### File layout

```
embedkit/
├── pyproject.toml             # uv-managed, single source of truth
├── README.md
├── LICENSE                     # Apache-2.0
├── src/
│   └── embedkit/
│       ├── __init__.py
│       ├── engine.py           # Engine() class — picks adapter
│       ├── bench.py            # canonical bench harness
│       ├── corpus.py           # MNEMOS corpus loader + JSONL writers
│       ├── adapters/            # alphabetical; no vendor preference
│       │   ├── __init__.py
│       │   ├── base.py            # AbstractAdapter contract
│       │   ├── cpu_llamacpp.py    # x86 / ARM / RISC-V baseline
│       │   ├── cpu_sbert.py
│       │   ├── gpu_amd_rocm.py    # ROCm via onnxruntime-rocm
│       │   ├── gpu_apple_mlx.py
│       │   ├── gpu_intel_igpu.py  # OpenVINO iGPU plugin
│       │   ├── gpu_nvidia_cuda.py # CUDA via onnxruntime-gpu
│       │   ├── gpu_nvidia_trt.py  # TensorRT specialized path
│       │   ├── gpu_vulkan.py      # vendor-agnostic Mali/etc Vulkan
│       │   ├── npu_amd_xdna.py    # Ryzen AI / VitisAI EP
│       │   ├── npu_cix_zhouyi.py
│       │   ├── npu_intel.py
│       │   ├── npu_mediatek_apu.py
│       │   └── npu_rockchip.py
│       ├── models/
│       │   ├── registry.py     # known model metadata + download hints
│       │   └── nomic_embed.py
│       └── shims/
│           └── cix_aipu_ioctl_shim.c   # the LD_PRELOAD shim for old/new UMD
├── benches/
│   ├── corpora/                # canonical corpora (8K MNEMOS dump etc)
│   ├── results/                # JSONL results from CI runs
│   └── results.md              # auto-rendered comparison table
├── ci/
│   └── multi-host-bench.yml    # GitHub Actions matrix bench
├── tests/
└── docs/
    ├── adding-an-adapter.md
    └── reproducing-the-numbers.md
```

### Engine API contract

```python
import embedkit

# Auto-pick: probes hardware, picks fastest adapter
eng = embedkit.Engine.auto()

# Explicit:
eng = embedkit.Engine(adapter="cix-npu", model="bge-small-zh-v1.5")
eng = embedkit.Engine(adapter="cpu-llamacpp", model="nomic-embed-text-v1.5")

# Single embed
vec = eng.embed("Hello world")  # -> List[float]

# Batch
vecs = eng.embed_batch(["a", "b", "c"])  # -> List[List[float]]

# Engine introspection
eng.info()
# {"adapter": "cix-npu", "model": "bge-small-zh-v1.5_256.cix",
#  "embed_dim": 512, "max_tokens": 256, "kmd_version": "v6.1.1-2",
#  "host": {...}, "throughput_baseline": 60.0}

# Heterogeneous routing (the dual-engine pattern)
eng = embedkit.Engine.heterogeneous(
    short=("cix-npu",     {"max_tokens": 256}),
    long= ("cpu-llamacpp", {"max_tokens": 8192}),
    threshold_chars=512,
)
vec = eng.embed("...")  # routes by length
```

### Adapter contract

Each adapter implements:

```python
class AbstractAdapter:
    name: str
    model_format: str  # 'gguf' | 'onnx' | 'cix' | 'rknn' | 'xdna'
    embed_dim: int
    max_tokens: int

    def __init__(self, model_path: str, **kwargs): ...
    def embed(self, text: str) -> list[float]: ...
    def embed_batch(self, texts: list[str]) -> list[list[float]]: ...
    def warmup(self): ...
    def close(self): ...
    @classmethod
    def is_available(cls) -> tuple[bool, str]: ...  # for auto-detect
```

### Hardware probes (`embedkit.Engine.auto()`)

Two-step pick — capability tier first, then measured throughput on the host. **No vendor preference; the kit is silicon-agnostic.**

```python
TIERS = {
    "npu": ["amd-xdna", "cix-npu", "intel-npu",
            "mediatek-apu", "rockchip-rknn"],   # alphabetical within tier
    "gpu": ["amd-rocm", "apple-mlx", "intel-igpu",
            "nvidia-cuda", "nvidia-tensorrt", "vulkan"],
    "cpu": ["cpu-llamacpp", "cpu-sbert"],
}

def auto(prefer_tier: str | None = None):
    """
    Pick the fastest available adapter.

    Selection policy:
      1. Filter to adapters whose is_available() returns ok=True.
      2. Group by capability tier (NPU > GPU > CPU).
      3. Within the highest-populated tier, run a 50-record micro-bench
         on the host's measured silicon and pick the fastest. Cache the
         result per (host, model) so subsequent .auto() calls are O(1).

    The micro-bench step is what eliminates favoritism — it makes the
    pick reflect *this* box's actual numbers rather than a static
    vendor-ordered priority list. A box with both AMD ROCm and NVIDIA
    CUDA available picks whichever is faster *here*.

    Override: pass prefer_tier="cpu" to force CPU even when NPU/GPU
    exist (useful for thermal-budget tests).
    """
    available = [cls for cls in REGISTRY if cls.is_available()[0]]
    if not available:
        raise RuntimeError("no embed adapter available")
    if prefer_tier:
        available = [a for a in available if a.tier == prefer_tier]
    # tier filter: highest-tier-with-adapter wins
    for tier in ("npu", "gpu", "cpu"):
        tier_adapters = [a for a in available if a.tier == tier]
        if tier_adapters:
            return _pick_fastest_in_tier(tier_adapters)
    raise RuntimeError("no embed adapter available after tier filter")
```

---

## uv-managed self-contained engine

Single source of truth: `pyproject.toml`. `uv` picks the right Python version, resolves deps, ships a lockfile.

```toml
[project]
name = "embedkit"
version = "0.1.0"
requires-python = ">=3.11"
dependencies = [
    "numpy>=1.26",
    "transformers>=4.40",
]

# Optional extras — install only what your host can use. Listed
# alphabetically; the order has no semantic meaning. The kit itself
# does not bundle vendor drivers; these extras pull the *python
# bindings* that talk to drivers the OS already provides.
[project.optional-dependencies]
cpu-llamacpp     = ["llama-cpp-python>=0.3"]
cpu-sbert        = ["sentence-transformers>=3.0"]
# AMD
gpu-amd-rocm     = ["onnxruntime-rocm>=1.18"]
npu-amd-xdna     = ["onnxruntime-vitisai>=1.18"]   # XDNA via VitisAI EP
# Apple
gpu-apple-mlx    = ["mlx>=0.19", "mlx-lm>=0.18"]
# Cix
npu-cix          = []   # cix-noe-umd from OS apt; libnoe wheel from /usr/share/cix/pypi
# Intel
gpu-intel-igpu   = ["openvino>=2026.0"]
npu-intel        = ["openvino>=2026.0"]
# MediaTek (preview)
npu-mediatek-apu = ["mtk-genio-apu>=0.1"]
# NVIDIA
gpu-nvidia-cuda  = ["onnxruntime-gpu>=1.18"]
gpu-nvidia-trt   = ["tensorrt>=10.0", "onnxruntime-gpu>=1.18"]
# Rockchip
npu-rockchip     = ["rknn-toolkit2>=2.0"]
# Vulkan (vendor-agnostic GPU path)
gpu-vulkan       = ["llama-cpp-python>=0.3"]   # built with -DGGML_VULKAN=1

# Bundled extras — convenience installs for common box classes.
# These do NOT prefer any vendor; they reflect what tends to be
# present on a given form factor.
all-cpu          = ["embedkit[cpu-llamacpp,cpu-sbert]"]
all-x86-cuda     = ["embedkit[cpu-llamacpp,gpu-nvidia-cuda]"]
all-x86-rocm     = ["embedkit[cpu-llamacpp,gpu-amd-rocm,npu-amd-xdna]"]
all-x86-intel    = ["embedkit[cpu-llamacpp,gpu-intel-igpu,npu-intel]"]
all-arm-cix      = ["embedkit[cpu-llamacpp,npu-cix,gpu-vulkan]"]
all-arm-rockchip = ["embedkit[cpu-llamacpp,npu-rockchip,gpu-vulkan]"]
all-apple        = ["embedkit[cpu-llamacpp,cpu-sbert,gpu-apple-mlx]"]
all              = ["embedkit[all-cpu,all-x86-cuda,all-x86-rocm,all-x86-intel,all-arm-cix,all-arm-rockchip,all-apple]"]

[project.scripts]
embedkit-bench = "embedkit.bench:main"
embedkit-doctor = "embedkit.doctor:main"

[tool.uv]
managed = true
```

User flow:

```bash
# Install + run a bench in 30 seconds on any supported box
curl -LsSf https://astral.sh/uv/install.sh | sh
git clone https://github.com/perlowja/embedkit
cd embedkit
uv sync --extra cpu-llamacpp
uv run embedkit-bench --corpus benches/corpora/mnemos-8k.json
# → produces results.json + appends to leaderboard

# On a Cix box:
uv sync --extra npu-cix
uv run embedkit-bench --engine cix-npu --corpus benches/corpora/mnemos-8k.json
```

---

## MNEMOS as the reference implementation

After embedkit ships v0.1, the MNEMOS server's embedding helper:

```python
# Before — bespoke per-platform glue
def get_embedder():
    if has_npu():
        from utils.NOE_Engine import EngineInfer
        return CixNPUWrapper(EngineInfer("/opt/ncz/models/bge-small-zh_256.cix"))
    elif has_cuda():
        return SentenceTransformerWrapper("nomic-embed-text", device="cuda")
    else:
        return OllamaHTTPWrapper("nomic-embed-text")
```

Becomes:

```python
# After — one line
import embedkit
embedder = embedkit.Engine.auto()
# embedder.embed(text) returns List[float] regardless of underlying silicon
```

That single import is what we PR upstream as the canonical demo. The MNEMOS server's `EMBEDDING_BACKEND` env var becomes `EMBEDKIT_ADAPTER`. The post about embedkit can demo "swap one line, get 28x throughput on Cix Sky1." Concrete and reproducible.

---

## Phasing

**Phase 1 (this week, ~3 days):**
1. Repo scaffold with `pyproject.toml` + uv lockfile
2. `cpu-llamacpp` adapter (~50 LOC — the harness we already have)
3. `npu-cix-zhouyi` adapter (~80 LOC — wrap our working NOE_Engine flow)
4. `bench.py` (port the existing harness)
5. CI smoke on github.com/perlowja/embedkit (linux + macos x86, no NPU)
6. README + reproducible-numbers.md

**Phase 2 (~1 week):**
1. `cpu-sbert` adapter (sentence-transformers reference)
2. `gpu-onnx-cuda` adapter (NVIDIA path — TYPHON RTX 5060 baseline)
3. `gpu-onnx-vulkan` adapter (when panvk stabilizes — currently parked)
4. Heterogeneous routing (`Engine.heterogeneous(...)`)
5. `embedkit-doctor` command (audits hardware + suggests adapter)
6. Model registry with download hints

**Phase 3 (~2 weeks):**
1. `npu-intel` adapter via OpenVINO (Lunar Lake / Arrow Lake)
2. `npu-amd-xdna` adapter via VitisAI EP
3. `npu-rockchip` adapter via RKNN-Toolkit2 (RK3588)
4. MNEMOS PR cutting over to `embedkit.Engine.auto()`
5. ARGOS-hosted apt repo serves the prebuilt cix wheels

**Phase 4 (post-launch):**
1. `cix-onnxruntime-ep` proper EP that wraps our NPU path as an onnxruntime backend (per the Codex audit's recommended-first-move)
2. Submit upstream to `microsoft/onnxruntime` for inclusion in the EP list
3. Quantization helpers (run our `nomic-embed-text-v1.5.Q8_0.gguf` reference quant flow against any encoder)

---

## Why this works as a project

1. **Standalone real value**: even if no one else uses it, MNEMOS gets a 28× speedup on Sky1 hardware by switching one import.
2. **Genuinely novel**: nobody publishes per-request hardware routing across NPU + GPU + CPU on a single SoC for the embedding-service use case (per Codex's earlier audit: VitisAI is layer-level not request-level; Apple Core ML is opaque; OpenVINO HETERO is graph-partitioning).
3. **Sky1 lifeboat**: our forensic IOCTL diagnosis + the matched `cix-noe-umd 2.0.2` ship together as the canonical Sky1 stack. Nobody else has documented either.
4. **Cross-vendor reusable**: same kit runs on Intel/AMD/NVIDIA/Cix without bespoke glue per box.
5. **Publishable bench**: the same harness produces apples-to-apples numbers across every supported chip. CI matrix runs nightly. Leaderboard.

---

*Living draft. Update as Phase 1 patches land.*
