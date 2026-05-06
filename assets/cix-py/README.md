# mnemos-embedder-cix-npu

Python ctypes wrapper around `libnoe.so` for Cix Sky1 / CD8180 Zhouyi Z3 NPU. Drops-in as a MNEMOS embedder backend; usable standalone for any agentic-memory workload that needs `bge-small-zh` (or compatible 256-token .cix model) embeddings on the dedicated NPU lane instead of CPU/GPU.

**Status:** runtime-validated on NCZ 26.5 r75 (Reinhardt) on a Minisforum MS-R1 (Cix CD8180). Codex-reviewed for memory-safety + cache contract. Not yet upstream — this is the candidate to submit as `mnemos/embedders/cix_npu.py` (or as a standalone `mnemos-embedder-cix-npu` pip package — TBD by mnemos-os maintainers).

---

## Performance

Validated 2026-05-06 against PYTHIA Intel iGPU baseline using a 2000-memory production corpus, single-stream LATENCY mode, content-hash embedding cache, on `bge-small-zh-v1.5` 256-token / 512-dim model (Intel ran the bge-small-en variant with the same dim):

```
                   COLD          WARM            MIX-50%
              (no cache)     (full cache)   (50% repeat)
Cix Sky1 NPU    39.55         128,670         110.51 emb/sec
Intel iGPU      42.45         534,775         105.06 emb/sec   (OpenVINO 2026.1)
Intel CPU       27.17         532,559          67.31 emb/sec
```

Cold per-inference: ~25 ms on Cix NPU, ~24 ms on Intel iGPU — within 4%. Realistic agentic workload (50% repeat) within 5%.

The dedicated NPU lane keeps the GPU/CPU free for parallel work. See `cix-installer/docs/CIX-VS-JETSON-PERF-REPORT.md` for the methodology + Jetson context.

---

## API

```python
from npu_embed_v2 import NPUEmbedder

emb = NPUEmbedder(
    cix_model_path="/opt/ncz/models/bge-small-zh_256.cix",
    libnoe_path="/usr/share/cix/lib/libnoe.so",       # optional; auto-detected if None
    tokenizer_path="/opt/ncz/models/bge-small-zh-v1.5",  # optional HF tokenizer dir
    cache_size=100_000,                                # optional FIFO bound
)

vec = emb.embed("hello world")             # np.ndarray, dtype=float32, L2-normalized
print(vec.shape)                            # (512,)
print(vec.flags.writeable)                  # False — cache-protected; copy() to mutate

stats = emb.cache_stats()
# {"hits": 0, "misses": 1, "size": 1, "hit_rate": 0.0}

emb.close()                                 # clean up libnoe context
```

## Cache contract (important)

Cached vectors are returned with `setflags(write=False)`. **Mutating a returned array in place raises `ValueError`** — protects the cache from caller-side normalize-in-place / cast-in-place bugs that would silently corrupt later cache hits for the same text.

If you need to mutate, copy first:
```python
v = emb.embed(text).copy()         # writeable copy, decoupled from cache
v *= 2.0                           # OK
```

## Tensor data_type handling

The wrapper inspects the `.cix` model's output tensor descriptor and selects the matching numpy dtype. Known map:

| `data_type` | Numpy dtype | Notes |
|---|---|---|
| 2 | `np.int8` | 1 byte/element |
| 4 | `np.uint8` | 1 byte/element |
| 5 | `np.int16` | 2 bytes/element — the bge-small-zh quantization |
| 7 | `np.float32` | 4 bytes/element |

Unknown `data_type` values raise `ValueError` rather than silently fall through to int8 (which would underallocate the output buffer for everything but the int8 case). Element count = `tensor_size_bytes // dtype.itemsize`.

---

## Runtime requirements

* aarch64 (Cix Sky1 / CD8180); will not load on x86_64 (libnoe.so is arm64-only)
* Cix `libnoe.so` 0.6.0 or newer — packaged in `cix-noe-umd` deb on NCZ Reinhardt
* `bge-small-zh_256.cix` from `cixtech/ai_model_hub_25_Q3` (or equivalent 256-token bge-small `.cix` build)
* HuggingFace tokenizer for the model (the wrapper falls back to a built-in WordPiece if `tokenizer_path` is None — slower start)
* Python 3.10+, numpy 1.24+

The wrapper does NOT depend on a kernel-side aipu module being a specific revision — it talks to `libnoe.so` userspace which abstracts the kernel interface. NCZ Reinhardt ships FyrbyAdditive-style aipu module (community port); cixtech downstream kernels also work.

## Why re-create-job per call

`_embed_uncached()` runs `noe_create_job` → load tensors → `noe_job_infer_sync` → `noe_get_tensor` → `noe_clean_job` for **every** inference call. This is the visorcraft 0x23 NOE_STATUS_TIMEOUT workaround: keeping a job alive across calls trips a TIMEOUT condition in `libnoe`'s state machine after a few seconds. Re-creating the job each call is the empirical fix that ships at sustained 39+ emb/sec.

If a future libnoe release fixes this and exposes a persistent-job API, the wrapper can swap to `noe_job_infer_sync` against a long-lived job ID and likely hit ~70-80 emb/sec sustained. That's an upstream cixtech change (closed source) or a community reverse-engineering effort, not in scope for this PR.

---

## Testing

The wrapper is end-to-end validated on real hardware in NCZ Reinhardt (`mnemos search 'r75 take-10' on PYTHIA`). For unit tests in CI:

* Mock `libnoe.so` with a stub that returns a fixed tensor descriptor + zero output buffer
* Cover: import, init, embed, cache hit, cache miss, cache eviction, write=False, dtype dispatch (int8/int16/float32), close

Test scaffolding TBD; would land alongside the upstream submission once mnemos-os/mnemos test convention is settled.

---

## Status / next steps

1. **r75 ships the wrapper** at `/opt/cix/npu_embed_v2.py` on Reinhardt + Magnetar SKUs (via `46-ncz-cli.sh` post-install hook).
2. **Upstream candidate** for `mnemos-os/mnemos` as `mnemos.embedders.cix_npu` plugin OR standalone `mnemos-embedder-cix-npu` pip package — choice deferred to mnemos-os maintainers.
3. **`ncz install mnemos`** (NCZ task #98) wires this wrapper as the default MNEMOS embedder backend on Cix-arm64 deploys via `MNEMOS_EMBEDDER=cix_npu`.

## License

Same as the rest of `cix-installer`: Apache-2.0.

Co-author credit if upstreamed: Jason Perlow (`@perlowja`), NCZ Reinhardt project maintainer. Kernel-side aipu work credit: visorcraft (`github.com/visorcraft/orange-pi-6-plus-npu`), FyrbyAdditive ms-r1-npu-hack port. Userspace `libnoe` is © Cix Technology Group.
