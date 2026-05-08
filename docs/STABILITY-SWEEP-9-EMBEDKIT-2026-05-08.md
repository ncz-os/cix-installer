# Stability Sweep 9 - mnemos-embedkit - 2026-05-08

## 1. Executive summary

- Verdict: the primary GitHub clone was blocked by DNS, but the fallback checkout at `/Users/jperlow/embedkit` was available at `4de750dc6e8e0b9ec90a92b6c5f05843866fc9fb`.
- Counts: HIGH 3, MEDIUM 7, LOW 5; patched cix-installer H1 in `post-install/47-embedkit.sh`, but staging was blocked by non-writable `.git/`; embedkit is outside the writable sandbox.
- Highest risk: the NCZ hook can exit success with no bundled embedkit package and no Cix `.cix` NPU model, so an installed system can silently lack the NPU embedding path.
- Runtime risk: `Engine.auto()` enforces NPU > GPU > CPU at the tier loop, but adapter import/probe failures are silent and selected-adapter initialization failures are not retried or logged as fallbacks.
- Packaging risk: advertised `embedkit-bench` and `embedkit-doctor` console scripts point to missing modules, model SHA verification is absent, server mode on port 5040 is not present, and the runtime cache exists only in a bench prototype.

## 2. HIGH findings

### H1 - NCZ embedkit hook can report success without installing embedkit or the NPU model

File: `cix-installer:post-install/47-embedkit.sh:26`, `cix-installer:post-install/47-embedkit.sh:52`, `cix-installer:post-install/47-embedkit.sh:59`, `cix-installer:post-install/47-embedkit.sh:63`, `cix-installer:post-install/47-embedkit.sh:94`, `cix-installer:post-install/47-embedkit.sh:103`, `cix-installer:post-install/47-embedkit.sh:111`, `cix-installer:post-install/47-embedkit.sh:156`

Pre-patch root cause: the hook ran under `set -uo pipefail`, not `set -euo pipefail`; it only warned when no bundled wheel/source existed; it only warned when the `.cix` model was absent; and the smoke import was explicitly non-fatal. In this checkout, `assets/embedkit/` is empty and `assets/models/` contains only `bge-small-zh-v1.5-q8_0.gguf`, not `bge-small-zh-v1.5_256.cix`.

Why HIGH: this is the direct "installed system cannot do NPU embeddings" failure mode. The hook can leave `/opt/ncz/embed-venv` without `mnemos-embedkit`, leave `/opt/ncz/models` without the NPU artifact, and still print `done`. The next layer can then fall to CPU or fail later, outside the installer log context.

Concrete diff applied in the working tree:

- Switch to `set -euo pipefail`.
- If no bundled wheel/source exists, attempt `pip install mnemos-embedkit` instead of silently skipping.
- Verify `import embedkit` immediately after package installation.
- Treat missing `bge-small-zh-v1.5_256.cix` as fatal unless an explicit `EMBEDKIT_DEFER_NPU=1` flag is set.
- Make the `Engine.list_adapters()` smoke test fatal instead of warn-only.
- Remaining follow-up: add model SHA256 recording once the `.cix` artifact is present in the payload.

### H2 - `Engine.auto()` can silently hide adapter failures and then crash instead of cleanly falling through

File: `embedkit:src/embedkit/adapters/__init__.py:33`, `embedkit:src/embedkit/adapters/__init__.py:41`, `embedkit:src/embedkit/adapters/__init__.py:43`, `embedkit:src/embedkit/engine.py:67`, `embedkit:src/embedkit/engine.py:77`, `embedkit:src/embedkit/engine.py:80`, `embedkit:src/embedkit/engine.py:83`, `embedkit:src/embedkit/adapters/npu_cix_zhouyi.py:150`, `embedkit:src/embedkit/adapters/npu_cix_zhouyi.py:151`, `embedkit:src/embedkit/adapters/npu_cix_zhouyi.py:153`, `embedkit:src/embedkit/adapters/npu_cix_zhouyi.py:156`

Root cause: `all_adapters()` catches every import exception and continues without logging or returning the reason. `Engine.auto()` filters only `is_available()[0]`, logs no unavailable adapter reasons, and after choosing a class it instantiates once. If that instantiation fails because `libnoe.so` cannot actually load, has missing dependent libraries, lacks symbols, or the selected provider cannot initialize, no lower-tier adapter is attempted. The Cix availability check is only `/dev/aipu` plus a library path, not `ctypes.CDLL` plus symbol binding or a tiny runtime health check.

Why HIGH: this is the direct "NPU import fails" and "falls through silently" class. If the NPU adapter import fails due missing Python deps, the adapter disappears from the list with no log. If the C library path exists but `ctypes.CDLL` or `noe_init_context` fails, `Engine.auto()` selects Cix NPU and crashes instead of logging the failed NPU candidate and moving to GPU/CPU. Operators then cannot distinguish "no accelerator installed" from "accelerator path broken."

Concrete diff recommendation:

- Change registry discovery to preserve import errors: return adapter classes plus a `ProbeFailure(module, reason)` list, and expose those in `Engine.list_adapters()`.
- In `CixZhouyiAdapter.is_available()`, run a no-model `ctypes.CDLL` probe and verify required `noe_*` symbols exist. Keep actual model load out of `is_available()` to preserve cheap probing.
- In `Engine.auto()`, iterate candidates within the chosen tier; if adapter construction or warmup fails for runtime/provider reasons, log `WARNING` with adapter name and reason and try the next candidate in the same tier, then the next tier.
- Do not fall back on model integrity failures. Missing hash, hash mismatch, or corrupt selected model should raise a model error and stop.
- Add tests that monkeypatch two fake adapters: NPU import fail -> GPU chosen with log, NPU init fail -> GPU chosen with log, corrupt model -> no fallback.

### H3 - Model integrity is not verified before inference

File: `embedkit:src/embedkit/models/registry.py:12`, `embedkit:src/embedkit/models/registry.py:13`, `embedkit:src/embedkit/models/registry.py:32`, `embedkit:src/embedkit/models/registry.py:52`, `embedkit:src/embedkit/models/registry.py:60`, `embedkit:src/embedkit/models/registry.py:64`, `embedkit:src/embedkit/models/registry.py:69`, `embedkit:src/embedkit/models/registry.py:73`, `embedkit:benches/scripts/cix_inprocess_bench.py:106`

Root cause: the registry maps model names to local path hints only. There is no expected SHA256, no file-size check, no cache metadata, no download provenance, and no cache invalidation rule. The only SHA256 calculation in the repo is in the standalone CPU bench summary, after the model has already been loaded and used.

Why HIGH: the requested contract says a corrupted model should fail fast and should not silently fall back to a slower path with the same logical model. Today `resolve_model()` returns `/opt/ncz/models/...` without confirming existence or digest. The adapter may fail later, or worse, run an unintended artifact if a stale or wrong file exists at that path.

Concrete diff recommendation:

- Replace string-only `_KNOWN_MODELS` values with metadata objects: `path`, `sha256`, `size_bytes`, `source`, `format`, `embed_dim`, and `max_tokens`.
- Add `resolve_model(..., verify=True)` that checks path existence, regular-file/dir shape, file size, and SHA256 before adapter construction.
- Raise a typed `ModelIntegrityError` on mismatch. `Engine.auto()` must not catch this as an accelerator fallback.
- Store model cache entries under a content-addressed path, or write a sidecar manifest such as `<model>.embedkit.json` containing SHA256 and source URL. Invalidate on missing sidecar or digest mismatch.
- Add tests for missing file, hash mismatch, stale cache sidecar, and explicit path with optional hash.

## 3. MEDIUM findings

### M1 - Tier order is deterministic, but "fastest in tier" is not implemented

File: `embedkit:src/embedkit/engine.py:77`, `embedkit:src/embedkit/engine.py:80`, `embedkit:src/embedkit/pick.py:16`, `embedkit:src/embedkit/pick.py:23`, `embedkit:src/embedkit/pick.py:30`, `embedkit:src/embedkit/pick.py:31`

`Engine.auto()` does choose the first populated tier in `("npu", "gpu", "cpu")`, so the top-level tier policy is deterministic. Within the chosen tier, `pick_fastest_in_tier()` sorts by adapter name and returns the first candidate. That contradicts the docstring promise of a 50-record micro-bench and host-specific throughput cache.

Impact: a multi-GPU or multi-NPU host can choose the wrong adapter even when a faster adapter is available. This is less severe than H2 because it does not by itself force CPU fallback, but it weakens the vendor-neutral "measured throughput" claim.

Concrete diff recommendation: implement a small benchmark over a fixed corpus with timeout and result cache keyed by host fingerprint, Python version, adapter name, model digest, and package version. If the benchmark fails for a candidate, log and continue.

### M2 - Registry advertises adapters that do not ship in this package checkout

File: `embedkit:src/embedkit/adapters/__init__.py:16`, `embedkit:src/embedkit/adapters/__init__.py:19`, `embedkit:src/embedkit/adapters/__init__.py:21`, `embedkit:src/embedkit/adapters/__init__.py:23`, `embedkit:src/embedkit/adapters/__init__.py:25`, `embedkit:src/embedkit/adapters/__init__.py:27`, `embedkit:src/embedkit/adapters/__init__.py:29`

The registry lists 13 adapters, but the tracked source contains only `cpu_llamacpp.py`, `gpu_apple_mlx.py`, `gpu_nvidia_cuda.py`, and `npu_cix_zhouyi.py`. Missing modules are swallowed by `all_adapters()`, so `Engine(adapter="amd-rocm")` is reported as unknown rather than known-but-unimplemented or unavailable.

Impact: advertised extras and docs overstate the runtime surface. Operators cannot use `Engine.list_adapters()` to see why AMD ROCm, Intel OpenVINO, Vulkan, Rockchip, or MediaTek paths are missing.

Concrete diff recommendation: register metadata separately from implementation modules, and show status as `missing module`, `missing dependency`, `unavailable hardware`, or `available`.

### M3 - Console scripts point to missing modules

File: `embedkit:pyproject.toml:74`, `embedkit:pyproject.toml:75`, `embedkit:pyproject.toml:76`, `cix-installer:post-install/47-embedkit.sh:128`, `cix-installer:post-install/47-embedkit.sh:129`

`pyproject.toml` installs `embedkit-bench = "embedkit.bench:main"` and `embedkit-doctor = "embedkit.doctor:main"`, but `src/embedkit/bench.py` and `src/embedkit/doctor.py` do not exist. The NCZ hook then symlinks those entry points into `/usr/local/bin`.

Impact: the installed diagnostics and benchmark commands fail at runtime. This slows recovery from exactly the accelerator-selection problems this sweep is trying to catch.

Concrete diff recommendation: either add `bench.py` and `doctor.py`, or remove the scripts until they exist. The doctor should run adapter probes, model hash checks, and a one-record smoke when a verified model exists.

### M4 - Server mode on port 5040 is absent

File: `embedkit:pyproject.toml:24`, `embedkit:pyproject.toml:33`, `embedkit:src/embedkit/__init__.py:13`, `cix-installer:post-install/47-embedkit.sh:125`, `cix-installer:docs/FB-POST-IS-IT-GPU-LLM-OR-NPU-MEMORY.md:52`, `cix-installer:docs/FB-POST-IS-IT-GPU-LLM-OR-NPU-MEMORY.md:53`

There is no FastAPI, uvicorn, HTTP wrapper, route implementation, or systemd unit in the embedkit package. The docs and prior benchmark notes distinguish in-process NPU calls from an HTTP wrapper with about 7 ms overhead, but that wrapper is not shipped here and `47-embedkit.sh` does not install a service on `:5040`.

Impact: in-process `Engine.auto()` is the only shipped package mode. Any MNEMOS path expecting a local HTTP embedder on port 5040 will fail to bind, fail to connect, or require an out-of-tree wrapper.

Concrete diff recommendation: add an optional `server` extra with FastAPI/uvicorn, expose `embedkit-server`, use the same `Engine.auto()` construction path, and fail clearly when bind to `:5040` fails.

### M5 - Runtime content-hash cache is not integrated into the package

File: `embedkit:src/embedkit/adapters/npu_cix_zhouyi.py:158`, `embedkit:src/embedkit/adapters/npu_cix_zhouyi.py:159`, `embedkit:benches/scripts/cix_npu_bench.py:1`, `embedkit:benches/scripts/cix_npu_bench.py:52`, `embedkit:benches/scripts/cix_npu_bench.py:55`, `embedkit:benches/scripts/cix_npu_bench.py:186`, `embedkit:benches/scripts/cix_npu_bench.py:198`, `embedkit:benches/scripts/cix_npu_bench.py:206`

The Cix package adapter always calls `_embed_uncached()`. A bounded SHA256 cache exists only in `benches/scripts/cix_npu_bench.py`. That prototype bounds the cache at `cache_size`, evicts oldest 10 percent, and exposes stats, but it is not in `src/embedkit`.

Impact: the published 50 percent repeat-ratio path is not available to embedkit consumers. Cold NPU speed may still be good, but the package cannot reproduce the 110 emb/sec mixed-cache behavior.

Concrete diff recommendation: add an optional cache wrapper at the Engine layer so all adapters can share it. Include `cache_max_entries`, immutable vectors, hit/miss stats, and a test for bounded growth.

### M6 - Python 3.13 support is declared, but dependency support is uneven

File: `embedkit:pyproject.toml:12`, `embedkit:pyproject.toml:17`, `embedkit:pyproject.toml:19`, `embedkit:pyproject.toml:24`, `embedkit:pyproject.toml:34`, `embedkit:pyproject.toml:37`, `embedkit:pyproject.toml:38`, `embedkit:pyproject.toml:44`, `embedkit:pyproject.toml:47`, `embedkit:pyproject.toml:52`, `cix-installer:post-install/25-cix-ppa.sh:98`, `cix-installer:post-install/25-cix-ppa.sh:128`

`mnemos-embedkit` declares Python 3.13 support. Current PyPI metadata indicates `numpy`, `transformers`, `sentence-transformers`, `llama-cpp-python`, `onnxruntime`, `onnxruntime-gpu`, `onnxruntime-rocm`, `openvino`, `mlx`, and `mlx-lm` have Python 3.13 paths as of 2026-05-08. Gaps remain: `rknn-toolkit2` documents support only through Python 3.12, `onnxruntime-vitisai` and `mtk-genio-apu` were not confirmed on PyPI, and TensorRT Python support depends on NVIDIA's package matrix outside this checkout.

The known `cix-noe-umd` Python 3.13 postinst break is mostly avoided by embedkit itself because `npu_cix_zhouyi.py` uses `ctypes.CDLL("libnoe.so")`, not `import libnoe`. The NCZ hook still owns dpkg recovery by patching the package postinst's `pip install libnoe` line.

Concrete diff recommendation: add a CI matrix for Python 3.11, 3.12, and 3.13 with extras that are realistically installable per platform. Mark unavailable extras with environment markers or move preview-only packages out of the `all` extra.

External compatibility references checked:

- https://pypi.org/project/numpy/
- https://pypi.org/project/transformers/
- https://pypi.org/project/sentence-transformers/
- https://pypi.org/project/llama-cpp-python/
- https://pypi.org/project/onnxruntime/
- https://pypi.org/project/onnxruntime-gpu/
- https://pypi.org/project/onnxruntime-rocm/
- https://pypi.org/project/openvino/
- https://pypi.org/project/mlx/
- https://pypi.org/project/mlx-lm/
- https://pypi.org/project/rknn-toolkit2/

### M7 - Tests are smoke tests, not dispatch or boundary tests

File: `embedkit:tests/test_cpu_llamacpp.py:26`, `embedkit:tests/test_cpu_llamacpp.py:36`, `embedkit:tests/test_gpu_nvidia_cuda.py:34`, `embedkit:tests/test_gpu_nvidia_cuda.py:44`, `embedkit:tests/test_gpu_apple_mlx.py:26`, `embedkit:tests/test_gpu_apple_mlx.py:36`, `embedkit:tests/test_npu_cix_zhouyi.py:34`, `embedkit:tests/test_npu_cix_zhouyi.py:44`

Current tests verify `is_available()` shape/speed and, when env vars are present, basic embedding dimension and idempotent close. There are no tests for `Engine.auto()`, tier ordering, fallback logging, model corruption, hash mismatch, server bind failure, cache bounds, missing modules, or Python 3.13 install.

Concrete diff recommendation: add fake adapters for deterministic unit tests, plus hardware-gated smoke jobs for Cix, CUDA, MLX, and CPU. Make the fake adapter tests run without optional vendor dependencies.

## 4. LOW findings + recommendations

### L1 - Public install docs use inconsistent package names

File: `embedkit:README.md:54`, `embedkit:README.md:61`, `embedkit:README.md:86`, `embedkit:docs/DESIGN.md:4`, `embedkit:pyproject.toml:6`, `embedkit:pyproject.toml:79`

`pyproject.toml` names the package `mnemos-embedkit`, but README examples use `pip install embedkit[...]`, and the design doc still says the target repo is `perlowja/embedkit`. Align docs to `pip install mnemos-embedkit[...]` and the `mnemos-os/mnemos-embedkit` repo.

### L2 - Adapter name is inconsistent in NCZ docs

File: `embedkit:src/embedkit/adapters/npu_cix_zhouyi.py:69`, `cix-installer:post-install/47-embedkit.sh:23`, `cix-installer:post-install/47-embedkit.sh:109`, `cix-installer:post-install/47-embedkit.sh:122`

The adapter class name is `cix-npu`, while hook comments and the generated model README say `npu-cix`. The explicit override example correctly uses `cpu-llamacpp`, but the Cix name should be one spelling everywhere.

### L3 - Device-node probe assumes `/dev/aipu`

File: `embedkit:src/embedkit/adapters/npu_cix_zhouyi.py:151`, `cix-installer:post-install/80-npu.sh:130`, `cix-installer:docs/STABILITY-SWEEP-8-CIX-PROP-NCZ-CLI-2026-05-08.md:121`

The Cix adapter checks only `/dev/aipu`. The NPU hook docs also use `/dev/aipu`, but sweep 8 noted `ncz status` checks `/dev/aipu0` and `/dev/cix-noe0`. If real targets differ by kernel package, `is_available()` can under-report the NPU.

Recommendation: check the actual target devices on the next ISO and either normalize the node path or probe all known names.

### L4 - `cix_npu_bench.py` imports `lru_cache` but does not use it

File: `embedkit:benches/scripts/cix_npu_bench.py:5`, `embedkit:benches/scripts/cix_npu_bench.py:16`, `embedkit:benches/scripts/cix_npu_bench.py:137`, `embedkit:benches/scripts/cix_npu_bench.py:139`

The header claims tokenization cache, but `_tokenize()` calls `_tokenize_uncached()` directly. Either add the `@lru_cache` wrapper or remove the claim from the bench script.

### L5 - No lockfile or build provenance for the pip package

File: `embedkit:docs/DESIGN.md:247`, `embedkit:pyproject.toml:1`, `embedkit:pyproject.toml:83`

The design doc says `uv` manages Python version, dependencies, and lockfile, but no lockfile is present in the checkout. For an appliance path that depends on Python 3.13 wheels and hardware-specific extras, a lockfile or wheelhouse manifest is important release evidence.

Recommendation: ship a lockfile for dev/test and a wheelhouse manifest for the NCZ installer payload.

## 5. Test plan

Validation run locally:

```sh
git clone https://github.com/mnemos-os/mnemos-embedkit.git /tmp/mnemos-embedkit-audit
# failed: Could not resolve host: github.com

git -C /Users/jperlow/embedkit rev-parse HEAD
# 4de750dc6e8e0b9ec90a92b6c5f05843866fc9fb

find /Users/jperlow/embedkit/src /Users/jperlow/embedkit/tests -type f | sort
git -C /Users/jperlow/embedkit ls-files src/embedkit/adapters | sort

PYTHONPYCACHEPREFIX=/tmp/embedkit-pycache python3 -m compileall -q src tests
bash -n /Users/jperlow/cix-installer/post-install/47-embedkit.sh

PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=src python3 - <<'PY'
import embedkit
print(embedkit.__version__)
print(embedkit.Engine.list_adapters())
PY

PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=src python3 - <<'PY'
for mod in ["embedkit.bench", "embedkit.doctor"]:
    try:
        __import__(mod)
        print(mod, "ok")
    except Exception as exc:
        print(mod, type(exc).__name__, exc)
PY

find /Users/jperlow/cix-installer/assets/models -maxdepth 2 -type f -print -exec shasum -a 256 {} \;
```

Observed local limits:

- `python3 -m pytest -q` could not run because pytest is not installed in the local Python 3.14 environment.
- A plain `python3 -m compileall` attempted to write pyc files under `/Users/jperlow/embedkit` and failed due sandbox permissions; rerun with `PYTHONPYCACHEPREFIX=/tmp/embedkit-pycache` passed.
- Local Python was 3.14.4, not 3.13, so this was not a Python 3.13 runtime validation.
- Hardware smoke tests were not run: no Cix `/dev/aipu`, CUDA, MLX, OpenVINO, or model files were available in this environment.

Target tests to run on the next NCZ image:

```sh
# Installer payload
test -f /usr/local/lib/cix-installer/assets/embedkit/mnemos_embedkit-*.whl -o \
     -d /usr/local/lib/cix-installer/assets/embedkit/repo
test -f /usr/local/lib/cix-installer/assets/models/bge-small-zh-v1.5_256.cix
sha256sum /usr/local/lib/cix-installer/assets/models/bge-small-zh-v1.5_256.cix

# Hook behavior
bash /usr/local/lib/cix-installer/post-install/47-embedkit.sh
/opt/ncz/embed-venv/bin/python - <<'PY'
import embedkit
print(embedkit.__version__)
for adapter in embedkit.Engine.list_adapters():
    print(adapter)
PY

# Model integrity
/opt/ncz/embed-venv/bin/python - <<'PY'
from embedkit.models import resolve_model
for adapter in ("cix-npu", "cpu-llamacpp"):
    print(adapter, resolve_model(adapter, None))
PY
sha256sum /opt/ncz/models/bge-small-zh-v1.5_256.cix /opt/ncz/models/bge-small-zh-v1.5-q8_0.gguf

# Cix direct path
test -e /dev/aipu -o -e /dev/aipu0
find /usr -name 'libnoe.so*' -print
EMBEDKIT_MODELS_DIR=/opt/ncz/models /opt/ncz/embed-venv/bin/python - <<'PY'
import embedkit
eng = embedkit.Engine.auto(prefer_tier="npu")
print(eng.info())
vec = eng.embed("hello")
print(len(vec), vec[:3])
eng.close()
PY

# Fallback behavior
EMBEDKIT_CIX_LIBNOE=/missing/libnoe.so EMBEDKIT_MODELS_DIR=/opt/ncz/models \
  /opt/ncz/embed-venv/bin/python - <<'PY'
import logging, embedkit
logging.basicConfig(level=logging.INFO)
print(embedkit.Engine.list_adapters())
eng = embedkit.Engine.auto()
print(eng.info())
PY

# Server mode, once implemented
/opt/ncz/embed-venv/bin/embedkit-server --host 127.0.0.1 --port 5040 &
curl -fsS http://127.0.0.1:5040/health
curl -fsS http://127.0.0.1:5040/embed -H 'content-type: application/json' \
  -d '{"input":"hello"}'
```

Release-gate tests to add upstream:

- Unit: fake NPU/GPU/CPU adapters prove tier order and fallback logging.
- Unit: false-positive `is_available()` followed by init failure falls through to next adapter.
- Unit: `ModelIntegrityError` stops dispatch and does not fall back.
- Unit: cache hit returns immutable vector and cache size stays bounded.
- Integration: `embedkit-bench` and `embedkit-doctor` import and exit with actionable diagnostics.
- Matrix: Python 3.11, 3.12, 3.13 import and unit tests with no optional vendor extras.
