# MNEMOS NPU embeddings on Cix Sky1 (Zhouyi V3)

How the NCZ distro turns the Cix Zhouyi V3 NPU into MNEMOS's embedding engine,
and why embedding is **automatic** — no manual step, no per-model wiring.

---

## TL;DR

MNEMOS embeds every memory on ingest by calling `embedkit.Engine.auto()`. On a
Cix Sky1 appliance that call detects the NPU (`libnoe` + `/dev/aipu`), selects
the `npu-cix` adapter, loads `bge-small-zh-v1.5_256.cix` from `/opt/ncz/models/`,
and tokenizes with the bundled offline tokenizer. The operator does nothing.

```python
import embedkit
emb = embedkit.Engine.auto()          # picks npu-cix on Sky1, cpu/gpu elsewhere
vec = emb.embed("some memory text")   # 512-dim float vector, from the NPU
```

Verified on `.66` (7.0.12-cix-sky1-next): correct semantic retrieval, ~51 emb/s.

---

## What the ISO bakes in (driver fidelity)

`post-install/47-embedkit.sh` + `25-cix-proprietary.sh` lay down everything the
NPU embedding path needs, so it works on first boot, offline:

| Component | Path | Provided by |
|---|---|---|
| NPU kernel driver | `armchina_npu.ko` (`/dev/aipu`) | `assets/npu` + modules-load |
| NPU userspace C lib | `/usr/share/cix/lib/libnoe.so.0.6.0` | `cix-noe-umd 2.0.2` (dpkg-deb -x) |
| Python bindings | `libnoe`, `NOE_Engine` wheels | `/usr/share/cix/pypi/*.whl` |
| Python 3.11 venv | `/opt/ncz/embed-venv` | `46-python311.sh` + `uv` |
| NPU model | `/opt/ncz/models/bge-small-zh-v1.5_256.cix` | `assets/models` |
| Tokenizer | `/opt/ncz/models/bge-small-zh-v1.5/` | `assets/models` |
| GGUF fallback | `/opt/ncz/models/bge-small-zh-v1.5-q8_0.gguf` | `assets/models` |

Why Python 3.11: the `libnoe`/`NOE_Engine` wheels only ship cp311/cp312
extensions, and Ubuntu 26.04's system Python is 3.14. `46-python311.sh`
provisions a relocatable `/opt/python3.11` and the venv is built from it.
(Tracked as temporary — Cix 26Q2 adds 3.14 support; see #21.)

---

## The automatic chain (end to end)

1. **`ncz install mnemos`** brings the MNEMOS containers (ghcr.io/mnemos-os)
   and `mnemos-embedkit` into the embed venv. The NPU runtime + model are
   already on disk from the ISO.
2. **MNEMOS ingest** — whenever a memory is written, MNEMOS calls its embedder.
   The embedder is `embedkit.Engine.auto()` (MNEMOS replaced its old
   `get_embedder()` / `EMBEDDING_BACKEND` switch with this single call).
3. **`Engine.auto()` selection** — two-step, vendor-agnostic:
   - filter adapters whose `is_available()` is true (the `npu-cix` adapter's
     probe checks for `libnoe` + `/dev/aipu`);
   - pick by capability tier (NPU > GPU > CPU), micro-benchmarking within tier.
   On Sky1 the NPU tier wins → `npu-cix`.
4. **`npu-cix` adapter** loads `bge-small-zh-v1.5_256.cix` from
   `/opt/ncz/models/`, tokenizes (max 256 tokens) with the bundled tokenizer,
   submits to the three Zhouyi cores via `NOE_Engine`, and returns `out[1]` —
   the 512-dim pooled sentence embedding.
5. **MNEMOS** stores the vector for semantic search. Done — no manual step.

The pick is cached per `(host, model)`, so subsequent `Engine.auto()` calls
are O(1).

---

## Model I/O contract

- Inputs: `input_ids`, `attention_mask`, `token_type_ids`, each `int32 [1,256]`.
- Outputs: `out[0]` token hidden states `[1,256,512]`; **`out[1]` the 512-dim
  pooled embedding** (this is the one to use).
- Embedding dim 512, max 256 tokens. Longer text is truncated — for long-doc
  workloads `Engine.auto()` can route to the GGUF/CPU path (8192 tokens).

---

## Verify on an appliance

```bash
# 1. NPU device + driver
ls -l /dev/aipu && lsmod | grep armchina

# 2. binding imports in the venv
LD_LIBRARY_PATH=/usr/share/cix/lib \
  /opt/ncz/embed-venv/bin/python -c "import libnoe, NOE_Engine; print('ok')"

# 3. embedkit picks the NPU (once embedkit is installed)
embedkit-doctor          # audits hardware + shows chosen adapter

# 4. end-to-end smoke (bundled test, no torch/transformers needed)
cd /home/<user>/bge-npu-test && \
  LD_LIBRARY_PATH=/usr/share/cix/lib \
  /opt/ncz/embed-venv/bin/python npu_bge_test.py
# expect: out[1] shape (512,), query->doc0 top match, ~50 emb/s
```

The standalone smoke uses the lightweight `tokenizers` lib + `NOE_Engine`
directly, so it validates **driver fidelity** without the MNEMOS/embedkit app
layer.

---

## Performance notes

- ~51 emb/s single-text on `.66` (Zhouyi V3, libnoe 0.6.0). The CPU ONNX path
  (fastembed on the 12-core Neoverse) is faster per-second (~700 emb/s) but the
  NPU is far better per-watt — the right tradeoff for a 24/7 always-on
  appliance.
- The per-call `noe_create_job` / `noe_clean_job` log spam is the **0x23
  persistent-job** pattern (#21): each `forward()` rebuilds the job, leaving
  ~50% of the silicon on the table. Cix reports this fixed in newer libnoe
  (26Q1); when we ship that UMD the throughput rises with no model change.

---

## References

- `assets/models/MODELS-README.md` — what's in the model store.
- `docs/MODELSCOPE-MODELS.md` — pulling `.cix` models from the Cix hub.
- `docs/EMBEDKIT-DESIGN.md` — the silicon-agnostic adapter design.
- cixtech/cix-linux-main#21 — the SDK/`.cix`/libnoe open-source request.
