# mnemos-embedkit

> Open embedding devkit. Same API, every silicon.

`embedkit` lets you embed text once and run it on whatever hardware your box has — Cix Sky1 NPU, Apple Silicon Metal/MLX, NVIDIA CUDA/TensorRT, AMD ROCm/XDNA, Intel iGPU/NPU via OpenVINO, MediaTek APU, Rockchip RKNN, or just the CPU. The kit detects what's installed and picks the fastest adapter at runtime. **No vendor preference.**

## Quick start

```python
import embedkit

eng = embedkit.Engine.auto()              # picks the fastest adapter on this host
vec = eng.embed("Hello world")            # -> List[float]
vecs = eng.embed_batch(["a", "b", "c"])   # -> List[List[float]]

eng.info()
# {"adapter": "cix-npu", "model": "bge-small-zh-v1.5_256.cix",
#  "embed_dim": 512, "max_tokens": 256, "throughput_baseline": 55.0}
```

Explicit adapter pick:

```python
eng = embedkit.Engine(adapter="cix-npu",      model="bge-small-zh-v1.5")
eng = embedkit.Engine(adapter="nvidia-cuda",  model="nomic-embed-text-v1.5")
eng = embedkit.Engine(adapter="amd-rocm",     model="bge-large-en-v1.5")
eng = embedkit.Engine(adapter="apple-mlx",    model="mxbai-embed-large-v1")
eng = embedkit.Engine(adapter="cpu-llamacpp", model="bge-small-zh-v1.5")
```

## What the kit is

A pure-Python adapter layer over vendor-specific embedding runtimes, plus a uniform `Engine.embed*` API and a canonical bench harness. **The kit does not bundle drivers or kernel modules.** It detects what the host OS already provides and binds to it:

| Host has | Kit picks via |
|---|---|
| `cix-noe-umd 2.0.2` + `libnoe` (NCZ Magnetar / cixtech apt) | `npu-cix` adapter |
| `onnxruntime-gpu` (CUDA driver from Linux distro) | `nvidia-cuda` adapter |
| `tensorrt` python (NVIDIA tar/apt) | `nvidia-trt` adapter |
| `onnxruntime-rocm` (AMD ROCm dkms) | `amd-rocm` adapter |
| `onnxruntime-vitisai` (XDNA driver) | `amd-xdna` adapter |
| `openvino` (Intel CPU/iGPU/NPU) | `intel-igpu` / `intel-npu` adapter |
| `mlx` (Apple Silicon, macOS only) | `apple-mlx` adapter |
| llama-cpp-python with Metal | `cpu-llamacpp` adapter (auto-detects Metal at runtime) |
| llama-cpp-python with `-DGGML_VULKAN=1` | `gpu-vulkan` adapter |
| `rknn-toolkit2` (Rockchip RK3588 / RK3576) | `rockchip-rknn` adapter |
| `mtk-genio-apu` (MediaTek Genio) | `mediatek-apu` adapter |
| nothing else | `cpu-llamacpp` (CPU baseline, ships GGUF) |

## Install

```bash
# Pick the form-factor bundle that matches your host:
pip install embedkit[all-cpu]                 # baseline, CPU only
pip install embedkit[all-x86-cuda]            # CPU + NVIDIA CUDA
pip install embedkit[all-x86-rocm]            # CPU + AMD ROCm + XDNA
pip install embedkit[all-x86-intel]           # CPU + Intel iGPU + NPU via OpenVINO
pip install embedkit[all-arm-cix]             # CPU + Cix NPU + Mali Vulkan
pip install embedkit[all-arm-rockchip]        # CPU + Rockchip RKNN + Mali Vulkan
pip install embedkit[all-apple]               # CPU + Apple MLX + Metal
pip install embedkit[all]                     # everything
```

The kit pulls vendor *python bindings* from PyPI. Vendor *drivers* are managed by your OS package manager (cix-noe-umd via apt, nvidia-driver via ubuntu-drivers, rocm-dkms via amdgpu-install, intel-npu-driver via apt, etc.).

## Reference bench

The canonical multi-platform bench is in `benches/`. Run on your host:

```bash
embedkit-bench --corpus benches/corpora/mnemos-8038.json --engines auto
```

See `benches/results.md` for the cross-platform numbers we have today (Cix Sky1 NPU, Apple Silicon Metal, NVIDIA CUDA, x86 + ARM CPU, Pi 5, Pi 4).

## Reference implementation consumer

`mnemos-os/mnemos` (the canonical MNEMOS memory layer) is the reference embedkit consumer. The plan is to migrate MNEMOS's embedding helper to call `embedkit.Engine(...)` directly. See `docs/mnemos-integration.md`.

## License

Apache-2.0.

## Status

**Bootstrap.** Design + cross-platform bench data exist. Adapter implementations are queued (Codex handoff prompt at `docs/CODEX-ADAPTER-HANDOFF.md`).

See `docs/DESIGN.md` for the full architecture.
