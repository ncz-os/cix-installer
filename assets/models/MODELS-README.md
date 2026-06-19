# Models bundled in NCZ ISOs

This directory ships at `/opt/ncz/models/` on the installed system (staged by
`post-install/47-embedkit.sh`). Models here are loaded by mnemos-embedkit's
adapters at runtime: the NPU adapter (`npu-cix`) uses the `.cix` variant, the
CPU/GPU fallback adapters (`cpu-llamacpp`, `gpu-vulkan`) use the GGUF. Both
share the bundled tokenizer.

| File | Provenance | Adapter | Embed dim | License |
|---|---|---|---|---|
| `bge-small-zh-v1.5_256.cix` | Cix `ai_model_hub` (ModelScope, **26_Q1**), Compass NN AOT-compiled INT8, 256-token | `npu-cix` (Zhouyi V3) | 512 | Apache-2.0 (BAAI/bge-small-zh-v1.5 weights + Cix Compass artifact) |
| `bge-small-zh-v1.5-q8_0.gguf` | CompendiumLabs/bge-small-zh-v1.5-gguf (community GGUF) | `cpu-llamacpp`, `gpu-vulkan` | 512 | MIT |
| `bge-small-zh-v1.5/` | BAAI/bge-small-zh-v1.5 tokenizer (BERT WordPiece, vocab + `tokenizer.json`) | shared (offline tokenize) | — | MIT |

## Provenance of the `.cix` (NPU model)

The `.cix` is the AOT-compiled NPU artifact. There is no public Compass NN
compiler, so we ship the **prebuilt** blob from the Cix model hub rather than
compile it locally. Pulled from ModelScope:

    https://www.modelscope.cn/models/cix/ai_model_hub  (version 26_Q1)
    path: models/Generative_AI/Text_Image_Search/onnx_bge_small_zh/bge-small-zh_256.cix
    sha: see assets/kernel-manifest / git blob

Vendored here as `bge-small-zh-v1.5_256.cix` (the `npu-cix` adapter name);
`47-embedkit.sh` also drops a `bge-small-zh_256.cix` compat symlink for older
embedkit/MNEMOS revisions. See `docs/MODELSCOPE-MODELS.md` for how to pull
other `.cix` models from the hub.

This `.cix` was the production-blocker in cixtech/cix-linux-main#21 — it was
compiled in an early session, cached, and lost on a reinstall with no way to
regenerate. It is now committed to this repo so it can never be lost again.

## Verified (2026-06-17, NCZ .66 / Zhouyi V3, 7.0.12-cix-sky1-next)

- Loads + runs on the NPU via `libnoe` 0.6.0 + `NOE_Engine` in the py3.11 venv.
- Outputs: `out[0]` token hidden states `[1,256,512]`; `out[1]` the **512-dim**
  pooled sentence embedding (the canonical BGE vector).
- Retrieval correct: query "什么是机器学习？" → top match "关于机器学习的文章"
  (cos 0.817, clear separation from distractors).
- Throughput ~51 emb/s single-text. (Per-call `noe_create_job` is the known
  0x23 persistent-job pattern from #21; persistent-job is fixed in newer libnoe.)

## How embedding is automatic with MNEMOS

MNEMOS embeds every memory on ingest via `embedkit.Engine.auto()`, which:
1. probes hardware, sees `libnoe` + `/dev/aipu`, selects the `npu-cix` adapter;
2. loads `bge-small-zh-v1.5_256.cix` from this directory;
3. tokenizes with the bundled `bge-small-zh-v1.5/` tokenizer (offline).

No manual embedding step, no per-model wiring. See
`docs/MNEMOS-NPU-EMBEDDINGS.md`.

## Adding models

    ncz model add <huggingface-id-or-path>

`Engine.auto()` picks among installed models + adapters by capability tier
(NPU > GPU > CPU) and measured throughput within tier. No vendor preference.
