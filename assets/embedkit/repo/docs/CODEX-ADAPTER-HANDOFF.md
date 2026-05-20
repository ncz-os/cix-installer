# Codex handoff — implement embedkit adapters

**Audience:** Codex (gpt-5.5 via the codex-companion CLI).
**Goal:** Implement all 13 silicon adapters defined in `src/embedkit/adapters/__init__.py` against the `AbstractAdapter` contract in `src/embedkit/adapters/base.py`.

## Authoritative inputs

Read these first. All design decisions are settled; do not redesign.

1. **`docs/DESIGN.md`** — full architecture. Adapter table, Engine API, OS-vs-kit separation, no-favoritism policy.
2. **`benches/results.md`** — cross-platform throughput data. Each adapter's expected baseline is listed there (Cix NPU ~55 rec/s, RTX 5060 CUDA ~487 rec/s, M1 Max Metal ~177 rec/s, Pi 5 CPU ~3.4 rec/s, etc.). Use these to sanity-check your `embed_batch` returns.
3. **`benches/scripts/cix_inprocess_bench.py`** — the existing bench harness. Your adapters must work end-to-end with this script when invoked as `MODEL=... python cix_inprocess_bench.py`. Same in-process API, same output format.
4. **`src/embedkit/adapters/base.py`** — the contract. Every adapter is a subclass of `AbstractAdapter`.
5. **`src/embedkit/engine.py`** + `src/embedkit/adapters/__init__.py` — Engine.auto() and the registry. Adapters are discovered alphabetically; the Engine ranks by capability tier and measured throughput, NOT by registry order.

## Hard rules (do not violate)

1. **No vendor preference.** Throughput-per-watt and absolute throughput are properties of the silicon; the kit MUST NOT favor any vendor in adapter ordering, default selection, or doc tone.
2. **No bundled drivers.** Adapters detect what the OS has installed (cix-noe-umd, nvidia-driver, rocm-dkms, intel-npu-driver, etc.). Adapters import vendor python bindings (onnxruntime-gpu, openvino, mlx, llama-cpp-python, etc.) declared as `[project.optional-dependencies]` extras in `pyproject.toml`.
3. **`is_available()` MUST be cheap.** It must NOT load a model, init a CUDA context, or open a device handle. It should only:
   - Try to import the python binding (`import onnxruntime_gpu`, `import mlx`, etc.)
   - Probe a sentinel (file path, env var, sysctl, `/proc/...`)
   - Return `(False, "reason")` on any exception
4. **All adapters share the same `embed()` / `embed_batch()` semantics.** Input is `str` / `list[str]`. Output is `list[float]` / `list[list[float]]` (lists of Python floats, not numpy arrays — keep the public surface JSON-serializable). Internally use numpy if you want, convert at the boundary.
5. **`warmup()` does ~3 dummy embeds** to prime caches and weight loads. Do not skip.
6. **`close()` releases device resources.** No leaked CUDA contexts, NPU handles, Metal command buffers.
7. **No `print()` to stdout.** Use `logging.getLogger("embedkit.adapter.<name>")`. The bench harness writes its own progress; adapters must not pollute stdout.
8. **Apache-2.0 headers** on every new `.py` file:
   ```python
   # SPDX-License-Identifier: Apache-2.0
   # Copyright (c) 2026 Jason Perlow
   ```

## Adapter list — implementation order

Implement in this order so the bench can validate each as it lands:

| # | Adapter file | Class | Tier | Backing runtime | Reference bench number |
|---|---|---|---|---|---|
| 1 | `cpu_llamacpp.py`     | `CPULlamaCppAdapter`  | cpu | `llama_cpp.Llama(embedding=True, n_gpu_layers=int(os.environ.get("N_GPU_LAYERS","0")))` | varies — see `benches/results.md` |
| 2 | `npu_cix_zhouyi.py`   | `CixZhouyiAdapter`    | npu | `from utils.NOE_Engine import EngineInfer` (Cix Compass NN runtime; cix-noe-umd 2.0.2 + libnoe 2.0.0). Model is `.cix` not GGUF. | Cix Sky1 NPU 54.86 rec/s |
| 3 | `gpu_nvidia_cuda.py`  | `NvidiaCUDAAdapter`   | gpu | `onnxruntime` with `CUDAExecutionProvider` | RTX 5060 ~487 rec/s (via llama-cpp-python — onnxruntime path will differ) |
| 4 | `gpu_apple_mlx.py`    | `AppleMLXAdapter`     | gpu | `mlx` + `mlx_lm` (Apple Silicon only) | M1 Max Metal ~177 rec/s (via llama-cpp-python — pure-MLX path will differ) |
| 5 | `gpu_intel_igpu.py`   | `IntelIGPUAdapter`    | gpu | `openvino` with `device_name="GPU"` | TBD (Intel iGPU on PYTHIA NUC15 — bench queued) |
| 6 | `npu_intel.py`        | `IntelNPUAdapter`     | npu | `openvino` with `device_name="NPU"` (Lunar Lake / Arrow Lake H only) | TBD (no Intel-NPU SKU in fleet today) |
| 7 | `gpu_amd_rocm.py`     | `AMDROCmAdapter`      | gpu | `onnxruntime` with `ROCMExecutionProvider` | TBD (community contribution) |
| 8 | `npu_amd_xdna.py`     | `AMDXDNAAdapter`      | npu | `onnxruntime` with VitisAI EP | TBD (community contribution) |
| 9 | `gpu_nvidia_trt.py`   | `NvidiaTRTAdapter`    | gpu | `tensorrt` python (specialized fp16/int8 path) | TBD |
| 10 | `gpu_vulkan.py`      | `VulkanAdapter`       | gpu | llama-cpp-python built with `-DGGML_VULKAN=1` (vendor-agnostic Mali / Intel iGPU / etc) | TBD |
| 11 | `npu_rockchip.py`    | `RockchipRKNNAdapter` | npu | `rknn_toolkit2` (RK3588 / RK3576 / RK3566) | TBD (community contribution) |
| 12 | `npu_mediatek_apu.py`| `MediaTekAPUAdapter`  | npu | `mtk-genio-apu` (preview) | TBD |
| 13 | `cpu_sbert.py`       | `CPUSBertAdapter`     | cpu | `sentence-transformers` | reference numpy CPU path |

The first three (cpu-llamacpp, npu-cix, nvidia-cuda) are highest priority — they unblock the cross-platform bench reproduction. Apple MLX is fourth so the dev-laptop path lights up.

## Per-adapter implementation notes

### `cpu_llamacpp.py` (priority 1)

```python
from llama_cpp import Llama

class CPULlamaCppAdapter(AbstractAdapter):
    name = "cpu-llamacpp"
    tier = "cpu"
    model_format = "gguf"

    @classmethod
    def is_available(cls):
        try:
            import llama_cpp  # noqa: F401
            return True, "llama-cpp-python installed"
        except ImportError as e:
            return False, f"llama-cpp-python missing: {e}"

    def __init__(self, model_path, *, n_threads=None, n_ctx=8192, n_gpu_layers=None, **kwargs):
        super().__init__(model_path, **kwargs)
        n_threads = n_threads or os.cpu_count() or 4
        # n_gpu_layers honors N_GPU_LAYERS env, defaults to 0 (pure CPU).
        n_gpu_layers = n_gpu_layers if n_gpu_layers is not None else int(os.environ.get("N_GPU_LAYERS", "0"))
        self._llm = Llama(
            model_path=model_path,
            n_ctx=n_ctx,
            n_threads=n_threads,
            n_gpu_layers=n_gpu_layers,
            embedding=True,
            verbose=False,
        )
        # Inspect first embed to populate embed_dim
        sample = self._llm.create_embedding("warmup")
        self.embed_dim = len(sample["data"][0]["embedding"])
        self.max_tokens = n_ctx

    def embed(self, text):
        return self._llm.create_embedding(text)["data"][0]["embedding"]

    def embed_batch(self, texts):
        # llama-cpp-python embeds per-call; iterate.
        return [self.embed(t) for t in texts]

    def warmup(self):
        for s in ("warmup", "test", "sample"):
            self._llm.create_embedding(s)

    def close(self):
        self._llm = None
```

This is the canonical reference adapter — it covers CPU + Metal (Apple) + Vulkan (Mali, etc.) + CUDA (when llama-cpp-python is built with `-DGGML_CUDA=on`) all through the same code path. The other GPU adapters layer on top of vendor-specific runtimes for specialized paths.

### `npu_cix_zhouyi.py` (priority 2)

```python
class CixZhouyiAdapter(AbstractAdapter):
    name = "cix-npu"
    tier = "npu"
    model_format = "cix"   # Compass NN AOT-compiled blob

    @classmethod
    def is_available(cls):
        # Probe libnoe + the dev node. Both must be present.
        if not Path("/dev/aipu").exists():
            return False, "/dev/aipu not present (Cix NPU not in this kernel)"
        try:
            sys.path.insert(0, "/usr/share/cix/lib")  # libnoe location on NCZ Magnetar
            import libnoe  # noqa: F401
            return True, "libnoe + /dev/aipu present"
        except ImportError as e:
            return False, f"libnoe not importable: {e}"

    def __init__(self, model_path, *, max_tokens=256, **kwargs):
        # model_path is the .cix path. The companion tokenizer must live next to it.
        # See benches/scripts/cix_npu_bench.py for the canonical load + forward pattern.
        ...
```

The canonical Cix NPU load + forward pattern is in `benches/scripts/cix_npu_bench.py`. Lift the relevant parts. The .cix model is AOT-compiled by Cix Compass NN; the kit does NOT compile models, only loads pre-compiled `.cix` artifacts.

### `gpu_nvidia_cuda.py` (priority 3)

```python
class NvidiaCUDAAdapter(AbstractAdapter):
    name = "nvidia-cuda"
    tier = "gpu"
    model_format = "onnx"

    @classmethod
    def is_available(cls):
        try:
            import onnxruntime as ort
            providers = ort.get_available_providers()
            if "CUDAExecutionProvider" in providers:
                return True, "onnxruntime CUDA EP present"
            return False, f"onnxruntime found but no CUDA EP (providers: {providers})"
        except ImportError as e:
            return False, f"onnxruntime not installed: {e}"
    ...
```

Adapter loads an ONNX model (e.g. `bge-small-zh-v1.5.onnx` from `optimum`-converted HF artifacts). The kit ships a small model registry (`src/embedkit/models/registry.py`) that resolves `model="bge-small-zh-v1.5"` to a downloadable ONNX URL.

### Apple MLX (priority 4) — see `mlx-embeddings` for prior art

For BGE / nomic / mxbai models on Apple Silicon, the canonical MLX inference path is in `mlx-embeddings`. The adapter should wrap that.

### Remaining adapters

For #5–#13, follow the same pattern: import the vendor python binding in `is_available()`, load the model at `__init__`, implement `embed()` / `embed_batch()` / `warmup()` / `close()`. Don't try to be clever; the contract is intentionally narrow.

## Tests

Each adapter ships a unit test at `tests/test_<adapter_name>.py`:

1. `test_is_available_safe()` — calling `is_available()` 1000 times in a row must not leak handles or burn CPU.
2. `test_embed_dim_consistent()` — `embed(short)` and `embed(long)` return the same `embed_dim`.
3. `test_close_idempotent()` — calling `close()` twice does not raise.

Skip a test if the adapter is not available on the test host (`@pytest.mark.skipif(not AdapterCls.is_available()[0], reason="adapter unavailable")`).

## Bench validation

After all adapters land, run:

```bash
embedkit-bench --corpus benches/corpora/mnemos-8038.json --engines all
```

Output should match the numbers in `benches/results.md` within ±15%. If a number is off by more than that, suspect a bug in the adapter or in test methodology — investigate before publishing.

## Anti-patterns to avoid

- **Don't print throughput claims in the adapter or in `info()`.** Throughput is host-dependent and the kit must not advertise specific numbers.
- **Don't add a "preferred" or "default" adapter.** auto() picks; that is the contract.
- **Don't bundle vendor SDKs into the wheel.** Every vendor binding is an optional dependency declared in `pyproject.toml`. The kit imports them, never ships them.
- **Don't write code that only works on one OS or chip.** Each adapter is responsible for its own `is_available()` gate; importing the adapter module on a host where it can't run must NOT raise (the `__init__.py` registry uses try/except for exactly this).
- **Don't write to `print(...)`.** Use `logging`.
- **Don't reach across adapters.** No cross-imports. Each adapter is a standalone unit.

## Convergence

Codex will iterate adapter implementations through `codex-companion adversarial-review` rounds. Stop when:

- All adapters in the priority 1-4 list pass their unit tests on at least one host.
- `embedkit-bench` reproduces ±15% of the reference `benches/results.md` numbers on the available silicon.
- `pip install mnemos-embedkit[all-cpu]` followed by `python -c "import embedkit; embedkit.Engine.auto()"` works on a clean Python 3.11 + Linux x86_64 + 0 GPUs box.

Adapters 5-13 land via subsequent rounds or community contributions (no Intel iGPU/NPU/AMD/Rockchip/MediaTek hardware in the fleet today; bench data is community-supplied).

## Don't redesign

If anything in `docs/DESIGN.md` reads ambiguous to you while implementing, stop and surface it as a question to the maintainer — don't change the design unilaterally.
