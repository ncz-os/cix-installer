# HANDOFF — embedding fingerprint + accept-or-rebuild federation

**Status:** design agreed 2026-08-18, NOT implemented. Scheduled for the next
major MNEMOS feature release. Until it lands, **Sky1 NPU embeddings are
LOCAL-VECTOR-ONLY** (see "What ships today").

## The problem this solves

Vectors are backend-specific artifacts. The Sky1 Zhouyi NPU executes only
Compass-compiled INT16 `.cix` graphs; the x86 fleet runs bge-m3 GGUF `q8_0`
under llama.cpp. Same trained weights, different engine and quantisation, so
the vectors differ.

Measured on O6N 2026-08-18, BGE-M3 INT16 `.cix` vs the fp32 ONNX reference:

```
mean cosine 0.992333   min 0.990197   retrieval rank order identical
determinism: bit-identical across 5 repeats and interleaved inputs
latency 227 ms per 256-token chunk
```

That gap is **irrelevant for a store whose vectors and queries both come from
the same embedder** — such a space is internally self-consistent. It matters
only when vectors from two different backends land in the same collection, or
a query from one backend hits a store built by the other.

## The design

NOT a negotiation handshake — no round trip, no shared state. A **content
fingerprint plus a local accept-or-rebuild decision**:

* The sender always ships the source text. Vectors are an OPTIONAL payload.
* Attached vectors carry an embedding fingerprint.
* The receiver compares that fingerprint to its own:
  * exact match  -> accept the vectors as-is (free, no recompute)
  * anything else -> discard vectors, keep text, re-embed locally

Two identical x86 nodes then share vectors for free, while a Sky1 node quietly
rebuilds. Zero loss in both cases, and no wasted compute where it is not
needed.

## Fingerprint fields

Everything that moves the vector must be covered, or the tag gives false
confidence:

| field | why |
|---|---|
| model weights hash | NOT the name — two "bge-m3" downloads can differ |
| engine + quant | `llama.cpp/q8_0` vs `compass/int16` |
| pooling | `cls` vs `mean` — see the real bug below |
| normalization | L2 on/off |
| seq_len | 256 on the NPU graphs |
| tokenizer hash | |
| chunker version + params | **the one people forget** |

Chunking belongs in the fingerprint as much as quantisation does: identical
embedders fed different chunk boundaries produce different vectors for the
"same" memory. Omit it and you will accept vectors that describe different
text.

## Rules

1. **Fail closed.** Untagged, unknown or unparsable fingerprint -> rebuild.
   Never accept an untagged vector.
2. **Never convert.** There is no mapping between vector spaces. Accept or
   rebuild; nothing in between.
3. **Store the fingerprint on local vectors too.** That is what makes an
   embedder upgrade incremental: moving a node from nomic-768 to bge-m3-1024
   finds exactly the stale vectors and rebuilds those, instead of dropping the
   whole index.

The same mechanism therefore covers federation AND local model migration.
Build it once.

## First implementation step

Check whether MNEMOS 6.1's replication path already carries ANY embedding
metadata. That decides whether this is an addition or a modification. It was
not verified before this handoff was written — do not assume either way.

## What ships today (the interim constraint)

**Sky1 <-> Sky1 vector federation is PERMITTED. Sky1 <-> non-Sky1 is NOT.**

The boundary is the backend, not the machine. Two Sky1 nodes running the same
`.cix` graph on the same Zhouyi hardware occupy the same vector space by
construction, so they may exchange vectors directly. A Sky1 node and any
non-Sky1 node (llama.cpp q8_0, CUDA, CPU) do not, and must exchange CONTENT
only, each embedding locally.

This rests on the determinism measurement, not on assumption: the NPU returned
BIT-IDENTICAL output across 5 repeats and across interleaved inputs, with zero
delta and no state leakage. A fixed-point static graph has no accumulation
order to vary.

Conditions for the Sky1 <-> Sky1 path — all must hold, and they are exactly the
fingerprint fields:

* identical `.cix` artifact (compare sha256 — a RECOMPILE may not be
  bit-identical even from the same ONNX, so pin the built file, not the recipe)
* identical tokenizer, pooling, normalization, seq_len
* identical chunker version and parameters

### UNVERIFIED: cross-board determinism

Determinism was proven WITHIN a single board (O6N). It was NOT possible to
verify that a SECOND Sky1 board produces byte-identical vectors from the same
graph, because cixmini (.66) cannot load the graph at all — "query capability
[fail]", the stale v5.11.0 `cix-npu-kmd` still winning the aipu.ko file there.

Fixed-point execution of a static graph should be board-independent, and the
graph targets a fixed `X2_1204MP3`, so identical output is EXPECTED. But
expected is not measured. **Before enabling Sky1 <-> Sky1 vector federation in
production, run the same text through two different Sky1 boards and compare
bit-for-bit.** The harness to do it is `/tmp/npu_determinism.py`; it needs only
a second board with the correct aipu/6.2.0 driver (v10 installs it).

If that check fails, fall back to content-only replication everywhere — which
is safe by construction, since nothing then compares vectors across machines.

## A live bug this uncovered — pooling is per-model

`ncz-npu-embed-server.py` used masked-mean pooling unconditionally. That is
correct for nomic-embed and **wrong for BGE-M3, which uses CLS**. Mean-pooled
BGE-M3 vectors are not bge-m3 embeddings at all — but they are internally
consistent, so retrieval still "works" and nothing errors. That is exactly the
failure class this whole document is about: silently different vectors that
look fine.

Fixed by making the server profile-driven (dim / input count / pooling per
model) with a loud warning on an unknown graph rather than a silent default.
Note also that BGE-M3 is XLM-RoBERTa and takes TWO inputs — there is no
`token_type_ids`, unlike the BERT-family nomic and bge-small-zh graphs which
take three.

## Reference artifacts

* NPU graph: `bge-m3_256.cix`, 1.3 GB, built on HYDRA with Compass
  `cixbuilder-6.1.3753.3` (x86-only, CPython 3.10 only).
* Build recipe: `~/cix-compass/bge-m3/cfg/bge_m3_build.cfg` on HYDRA, adapted
  from the vendor `onnx_bge_small_zh` recipe in the CIX AI Model Hub.
* Compiler fidelity self-check at build time: cosine 0.998080, MSE 0.002997.
* Validation harness: `/tmp/npu_bge_m3.py` and `/tmp/npu_determinism.py` on
  O6N; fp32 reference `reference.npz` generated on HYDRA.
