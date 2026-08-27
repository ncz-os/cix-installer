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

There is no working `ncz model add`/`ncz models pull` command yet —
`ncz models pull` is a **stub** (prints `STUB (r75)` and exits 2, see
`post-install/46-ncz-cli.sh` and task #99). To add a `.cix` model today,
pull it manually from the Cix model hub and stage it in this directory —
see [`docs/MODELSCOPE-MODELS.md`](../../docs/MODELSCOPE-MODELS.md) for the
full manual procedure. `ncz models list` (no `pull`) does work today, and
shows installed `.cix` files.

Once a model is staged, `Engine.auto()` picks among installed models +
adapters by capability tier (NPU > GPU > CPU) and measured throughput
within tier. No vendor preference.

## nomic-embed-text-v1.5 for the NPU (768-dim, MNEMOS-compatible)

`nomic-embed-text-v1.5_256.cix` is **not committed** — it is ~500MB, past
GitLab's 100MB per-file limit. Stage it onto the build host at
`assets/models/` (same pattern as `assets/cix-debs/`) and the ISO bakes it in;
`post-install/89-npu-embed-server.sh` installs it and enables the service only
when the file is present.

Why this model: MNEMOS embeds with `nomic-embed-text` on x86. Compiling the
*same* model for the NPU keeps Sky1 vectors interchangeable with x86 ones —
measured **cosine 0.995330** against the onnxruntime CPU reference — so
federation needs no vector translation layer. A different 768-dim model would
be dimensionally compatible but semantically unrelated, and would force
re-embedding the whole corpus on every peer.

### Rebuilding it

The compiler (`cixbuilder`) is **x86_64 + CPython 3.10 only**, so this runs on
an x86 host (HYDRA), not on Sky1:

```sh
# wheel lives in the 2026Q2 NOE SDK on ARGONAS:
#   /mnt/datapool/archives/cix-vendor-sdk/2026q2/cix_noe_sdk_26_q2_release.tar.gz
uv venv --python 3.10 .venv
uv pip install --python .venv/bin/python ./cixbuilder-6.1.3753.3-cp310-none-linux_x86_64.whl     onnx onnxruntime numpy transformers tensorflow-cpu   # TF is imported even for ONNX input

# GBuilder's linker needs ncurses5; without it the build dies with a MISLEADING
# "Build Subgraph error! please double check the kernel function is correct."
sudo ln -sf /usr/lib/x86_64-linux-gnu/libtinfo.so.6 /usr/lib/x86_64-linux-gnu/libtinfo.so.5

.venv/bin/cixbuild nomic_build.cfg   # config modelled on cixtech/ai_model_hub bge_small_zh_build.cfg
```

Config essentials: `input = input_ids, attention_mask, token_type_ids` at
`[1,256]` each, `output = last_hidden_state`, `target = X2_1204MP3`, and
**W16A16** (`weight_bits`/`activation_bits` = 16, bias 48). Do **not** drop to
int8: measured, W8A8 collapses fidelity to **cosine 0.42** — unusable — while
buying only 29% speed.

Calibration data is an `.npz` of ~8 representative texts tokenized with the
model's own tokenizer at `max_length=256`, arrays cast to int32.

The graph emits `last_hidden_state` flattened (`256*768`); the sentence vector
is the attention-masked mean, L2-normalised. Getting that pooling wrong yields
plausible-looking vectors that quietly retrieve the wrong memories.
