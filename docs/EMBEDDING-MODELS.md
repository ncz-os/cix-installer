# Embedding models for MNEMOS on NCZ-OS / CIX Sky1

NCZ-OS ships **three** embedding models as separate apt packages. None of them
are on the ISO — they install only when MNEMOS does, because a model is between
75 MB and several GB and most installs never need one.

| apt package | model | dim | NPU graph | notes |
|---|---|---|---|---|
| `ncz-model-bge-small`  | bge-small-zh-v1.5     | **512**  | `bge-small-zh_256.cix` (75 MB) | smallest, fastest; 12.5 ms/inference |
| `ncz-model-nomic-embed`| nomic-embed-text-v1.5 | **768**  | `nomic-embed-text-v1.5_256.cix` (522 MB) | default; cosine 0.995330 vs CPU reference |
| `ncz-model-bge-m3`     | BGE-M3                | **1024** | `bge-m3_256.cix` | multilingual, richest; matches the x86 fleet |

All three run on the Zhouyi NPU via `/dev/aipu`, served by
`ncz-npu-embed-server.py` on `127.0.0.1:8081`.

---

## ⚠️ Federation: every instance MUST run the same model

**If you run more than one MNEMOS in your organisation and they federate,
share, or replicate memories, they must all run the SAME embedding model.**

This is not a recommendation. An embedding is a coordinate in a vector space
that is defined by the model that produced it. Two different models do not
share a space, so a cosine similarity computed across them is not a weak
signal — it is a meaningless one. Retrieval will return confidently wrong
results rather than failing loudly, which is the worst way for this to break.

Three specific traps:

1. **Same dimension is NOT the same space.** A 1024-dim vector from BGE-M3 and
   a 1024-dim vector from All-Roberta-Large are equally incomparable to a
   768-dim one. Matching the *number* buys you nothing; only matching the
   *model* does. Dimension equality just lets the bug through the shape check.

2. **Same model, different quantisation, needs verifying.** The NPU graphs are
   compiled INT16 (`weight_bits = 16`, `activation_bits = 16`, LayerNorm and
   Softmax kept at float16). An x86 peer running the same model as GGUF `q8_0`
   is *close* but not identical. Treat them as compatible only once cosine
   against a CPU reference has been measured — 0.995330 for nomic-embed-text
   is the bar. Below roughly 0.99, do not share a store.

3. **Chunking must match too.** The NPU graphs are static with a fixed
   sequence length of 256 tokens and batch size 1. A peer embedding 8192-token
   chunks is cutting documents at different boundaries, so even with identical
   weights the stored vectors describe different text.

**Changing model means re-embedding everything.** There is no conversion
between vector spaces. Plan a migration as a full corpus re-ingest, and do not
mix old and new vectors in one collection during the transition.

---

## Choosing a size: the tradeoff is retrieval detail

Dimension is roughly how much semantic nuance a vector can carry. Bigger
vectors separate similar-but-distinct meanings better; smaller ones blur them
together. What you pay for that is storage, memory bandwidth and latency, on
every single embed and every single query.

| | 512 (bge-small) | 768 (nomic) | 1024 (BGE-M3) |
|---|---|---|---|
| bytes/vector (float32) | 2 KB | 3 KB | 4 KB |
| 100k memories | ~200 MB | ~300 MB | ~400 MB |
| 1M memories | ~2 GB | ~3 GB | ~4 GB |
| NPU graph on disk | 75 MB | 522 MB | multi-GB |
| relative embed latency | fastest | moderate | slowest |
| multilingual | Chinese-focused | English-focused | 100+ languages |

The cost is not only the vector store. A larger model is a larger graph to load
into NPU memory, and every query embeds the query text too, so latency shows up
in the interactive path, not just at ingest.

**Practical guidance:**

- **512** — large corpora of short, similar records where throughput matters
  more than nuance, or a memory-constrained board.
- **768** — the default. Best accuracy-per-byte for general English use, and
  the only one with a published cosine validation against its CPU reference.
- **1024** — multilingual corpora, long or subtle documents, or when you need
  to match an existing x86 fleet already standardised on BGE-M3.

Do not size up reflexively. Going from 768 to 1024 costs 33% more storage and
bandwidth forever, and only pays off if your corpus actually contains
distinctions the smaller model was collapsing. If retrieval quality is the
problem, check your chunking before you change model — bad chunk boundaries
degrade retrieval far more than 256 fewer dimensions do.

---

## Compiling a new model

The Compass NN compiler (`cixbuild`, from `cixbuilder-*.whl` in the CIX NOE
SDK) is **x86-only and CPython 3.10-only**. It does not run on Sky1. Build on
an x86 host (HYDRA), then ship the resulting `.cix` as an apt package.

Embedding encoders compile cleanly because they are static graphs. Note that
autoregressive LLMs do NOT — the compiler cannot express a KV-cache or
variable-length decode, which is why NPU LLMs are unavailable while NPU
embeddings work.

The vendor recipe to copy is in the AI Model Hub at
`models/Generative_AI/Text_Image_Search/onnx_bge_small_zh/`, which ships both a
`cfg/bge_small_zh_build.cfg` and — importantly — `inference_onnx.py` and
`inference_npu.py`, the A/B harness for measuring cosine between the compiled
graph and the CPU reference. **Always run that comparison before shipping a
graph.** A quantised model that loads and returns plausible-looking vectors but
sits in a slightly different space is exactly the failure this document exists
to prevent.
