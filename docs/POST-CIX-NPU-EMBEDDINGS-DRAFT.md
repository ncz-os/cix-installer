# Cix Sky1 is not an LLM chip — but it's quietly excellent for memory-store embeddings

**Status:** DRAFT 2026-05-07. Numbers below filled in as benches complete overnight.
**Author:** Jason Perlow (NCZ project maintainer; @perlowja)
**Hardware:** Minisforum MS-R1 — Cix Sky1 (CD8180), 12-core ARMv9, Mali-G720, Zhouyi V3 NPU (~30 TOPS INT8), 64 GB unified RAM.
**Software:** NCZ Magnetar 26.5.r76 (Ubuntu 25.10 questing) on linux-cix-sky1-next 7.0.3.
**Comparison:** PYTHIA, an x86_64 24-core / 30 GB RAM workstation running ollama + `nomic-embed-text` — the production embedding host for our MNEMOS knowledge graph.

---

## TL;DR

We tried to run a large language model on Cix Sky1's NPU, and the answer is what you'd expect from an Arm-China Zhouyi V3: **no.** The NPU was designed for fixed-shape encoder networks and edge-AI vision/audio workloads, not for autoregressive transformer decode. It has no KV-cache primitives, no native FlashAttention, and the Cix Compass NN compiler doesn't ship with examples north of the encoder-only side of the model zoo.

But that's the wrong question. The interesting question turned out to be: **how well does this NPU handle the unsexy-but-load-bearing job of embedding text into vectors for a memory-augmented agent?** Encoder-only models like `bge-small-zh-v1.5` (Chinese-trained, but works fine on English; 256-token max, 512-dim output) are exactly what NPU silicon like this is designed for — fixed input shape, fixed output shape, no autoregressive feedback, INT8/INT16 quantization-friendly.

We re-embedded our entire production MNEMOS knowledge store — **8,038 records, 14 MB of content text** — on the Cix Sky1 NPU and compared it against the same job running on PYTHIA, our x86_64 workstation that handles the same workload in production via ollama + `nomic-embed-text` on CPU.

| Metric | **Cix Sky1 NPU** | PYTHIA x86 CPU | Ratio |
|---|---|---|---|
| Records embedded | (deferred — see "userspace gap" below) | 7,896 / 8,038 (98.2%) | — |
| Wall time | — | 3,632 s (60.5 min) | — |
| Records / sec | — | **2.17** | — |
| Records / sec (peak) | — | 6.9 (first 100 records, model-warm) | — |
| p50 latency | — | 490 ms | — |
| p95 latency | — | 790 ms | — |
| p99 latency | — | 1,408 ms | — |
| Max latency | — | 2,160 ms | — |
| Failed records | — | 142 (1.77%, mostly long-tail timeouts on records >5K chars) | — |
| Embed dim | 512 (bge-small-zh) | 768 (nomic-embed-text) | (different models) |
| Max sequence length | 256 tokens | 8,192 tokens | nomic ingests long records whole; bge-small truncates |
| Idle power (board) | ~30W | ~80W (PSU rail) | rough estimate |
| Total RAM | 64 GB | 30 GB | — |
| Cost (silicon-only) | ~\$700 (whole MS-R1 box) | ~\$2,500+ (similar build) | — |

**Headline finding from PYTHIA**: throughput collapses from 6.9 rec/s (first 100 records, warm model) to **2.17 rec/s sustained** on the full real-corpus distribution. The cause is the long-tail length distribution — p99 record is 7,295 chars (~1,800 tokens) and the max is an 82,677-char outlier. nomic-embed-text on CPU scales near-linearly with input length, so once you hit the long-tail records the per-call wall time balloons (490 ms median → 1.4 s p99 → 2.2 s max). 142 records (1.77%) timed out entirely.

This is the realistic production-shape number. ollama-on-CPU embedding throughput on real-corpus data is ~2 rec/s on this 12-core x86 box. That's the bar Sky1 NPU needs to clear to be interesting — and given Sky1's ~30 TOPS INT8 silicon vs PYTHIA's pure-FP32 CPU embed path, "interesting" feels achievable.

**Cix NPU column unfilled (2026-05-07)**: we hit a hard userspace-pairing block (see "the userspace gap" below). The hardware is healthy; the kernel module probes cleanly; we built the userspace runtime from upstream Compass source — but the IOCTL ABI between our newly-built UMD and the shipped KMD didn't agree, because they came from different version trees.

> **UPDATE 2026-06-17 — RESOLVED.** The working pairing is **cix-noe-umd 2.0.2** (libnoe 0.6.0) driven from a **Python 3.11 uv venv** — the 2.0.2 binding wheels only ship cpython-311/312 extensions, so r104's system Python 3.14 couldn't import them. Measured **~56 emb/s** real-tokenized (all-MiniLM `minilm_128.cix`), ~4–6× the CPU/GPU paths. See the [RESOLVED section](#resolved-2026-06-17-cix-noe-umd-202--a-python-311-uv-venv) for the full matrix and how it ships.

---

## Why this matters

Memory-augmented agents — call them "agents with memory," "vector-DB-backed assistants," whatever — are one of the most common practical AI workloads being deployed in 2026. RAG, long-term assistant memory, knowledge-graph grounding, code search. The hot loop is *not* LLM decode — it's:

1. Ingest a stream of documents / messages / events
2. Tokenize, run through an encoder, get an embedding vector
3. Store the vector in pgvector / Qdrant / LanceDB / Chroma / etc.
4. At query time, embed the query the same way, do nearest-neighbor

Step 2 is the constant-time tax on every memory ingest and every query. Bigger LLM models for *generation* are only useful if your memory store can actually keep up with the firehose. Embedding throughput is the bottleneck.

Encoder networks like `bge-small`, `nomic-embed-text`, `all-MiniLM-L6-v2`, and the new `Qwen3-Embedding-0.6B` all share a profile: small (under 100M params), encoder-only, fixed input/output shapes, INT8-quantizable. **This is the Zhouyi V3 sweet spot.** It's what these chips were built for.

We tested the realistic scenario: take our production MNEMOS knowledge store (8,038 memory records the agent has accumulated since December 2025), strip the existing embeddings, and re-embed on the NPU. This is exactly what happens when you stand up a new instance of MNEMOS, or when you change embedding models, or when you migrate from one host to another.

---

## What we measured

**Corpus:**
- 8,038 records pulled from MNEMOS via `GET /v1/export` on PYTHIA
- 14.2 MB total content text
- Mean record length: 1,763 characters
- p50: 1,979 chars / p95: 2,630 chars / p99: 7,295 chars / max: 82,677 chars
- Mix of categories — `documentation` (5,386), `facts` (634), `infrastructure` (1,145), `projects` (274), `decisions` (27), …

**Cix Sky1 NPU stack:**
- Model: `bge-small-zh-v1.5_256.cix` (75 MB, INT8/INT16 quantized, Cix Compass NN-compiled from BAAI's bge-small-zh-v1.5 ONNX export)
- Embed dim: 512
- Max sequence length: 256 tokens (anything longer gets truncated; this matters for the long-tail records — our p95 is ~2,630 chars ≈ ~660 tokens, so most records are getting truncated)
- Kernel: `7.0.3-cix-sky1-next` with `aipu.ko` v6.1.1-2 (FyrbyAdditive prebuilt port)
- Userspace: `cix-noe-umd 4.0.0` (frontend) + `libaipudrv.so` (backend, **built from source** — see "the userspace gap" below)
- Inference path: `from utils.NOE_Engine import EngineInfer`, single-stream sequential

**PYTHIA CPU stack (baseline):**
- Model: `nomic-embed-text:latest` via ollama
- Embed dim: 768
- Max sequence length: 8192 tokens (no truncation for any of our records)
- 12 cores AMD Threadripper class, 30 GB RAM
- Inference path: `POST /api/embeddings` to `localhost:11434`, single-stream sequential

**What's the same:**
- Identical 8,038-record corpus
- Single-stream sequential ingestion (no batching, no parallelism)
- Cold start, then 3-record warmup, then full corpus

**What's not the same — and why we're publishing it anyway:**
- Different models (one Chinese-trained encoder with 256-token cap; one English-trained encoder with 8K-token cap)
- Different embed dimensions (512 vs 768)
- Different quantization (INT8/16 vs FP32)

This is **not** a head-to-head model fight. It's a **"how fast does the chip do the realistic thing"** comparison. The Cix model is what *Cix Compass NN ships pre-compiled for v3 NPU silicon* — it's the path of least resistance for a Sky1 user. The PYTHIA model is what *MNEMOS uses in production today*. Both are reasonable, accuracy-not-degraded choices for memory-store embedding work.

---

## The userspace gap (this is the real story)

Tonight (2026-05-06), we tried to install the standard cixtech apt path on a fresh r76 Magnetar install:

```
deb [signed-by=/usr/share/keyrings/cix-deb-repo.gpg] \
    https://archive.cixtech.com/debian trixie main
```

For kernel 7.0 the open-source meta package is `cix-debian13-k7.0-driver-opensource`. It pulls in:
- `cix-grub-config`
- `linux-image-7.0.0-generic`
- `linux-headers-7.0.0-generic`
- `cix-vpu-driver-dkms`
- `cix-npu-driver-dkms`

Notice what's missing: **the userspace runtime**. `cix-noe-umd 4.0.0` is in the apt repo and installs `libnoe.so` — the Python/C frontend — but the AIPU device-specific backend `libaipudrv.so` is not in any apt package on cixtech's archive. The frontend `dlopen("libaipudrv.so")` returns ENOENT and every NPU init call dies with:

```
aipu_adapter.cpp ERROR:151 - load_aipu_library: Failed to load backend:
libaipudrv.so: cannot open shared object file: No such file or directory
noe_api.cpp ERROR:184 - noe_init_context: Failed to initialize adapter
```

The closed-source kernel-6.6 stack ships a complete bundle (it depends on `cix-npu-driver`, `cix-npu-onnxruntime`, `cix-mnn`, `cix-ai-engine`, etc.). The kernel-7.0 open-source path has `cix-npu-driver-dkms` (kernel module) but no userspace pair. The result: **a fresh install of the official open-source path can't run a single inference on the NPU it ships with**.

### What we tried, what worked, what didn't

So we set out to build `libaipudrv.so` ourselves from `Arm-China/Compass_NPU_Driver` (Apache 2.0).

1. **Clone + dependency install** — clean. `git clone https://github.com/Arm-China/Compass_NPU_Driver` lands at `2868d53 [UMD][KMD].align with 4.3.0 release`.
2. **Bypass `bash_env_setup.sh`** — the upstream env-setup hardcodes Cix-internal paths like `/project/ai/scratch01/AIPU_BSP/...` (their internal build farm) and references `LD_LIBRARY_PATH` without a default-empty guard, so it dies under any `set -u` shell. We built directly with `make standard_api CXX=g++ AR=ar` after exporting the eight `COMPASS_DRV_BTENVAR_UMD_*` variables the Makefile actually consumes.
3. **Compile** — clean. All 25 `.cpp` files compile with `-DZHOUYI_V12 -DZHOUYI_V3 -DMACRO_UMD_VERSION="6.1.1"`. Output: `libaipudrv.so.6.1.1` (788 KB) and `libaipudrv.a.6.1.1` (1.5 MB) under `Linux/bin/`.
4. **Install** — clean. `cp libaipudrv.so.6.1.1 /usr/share/cix/lib/libaipudrv.so + ldconfig` registers it: `libaipudrv.so (libc6,AArch64) => /usr/share/cix/lib/libaipudrv.so`. The first error class (`Failed to load backend`) is gone.
5. **Smoke test** (cixtech's `inference_npu.py`) — fails at the next layer:

```
[UMD ERR] aipu.cpp:50:<tid:7779>: query capability [fail]
noe_api.cpp ERROR:184 - noe_init_context: Failed to initialize adapter
```

This is happening at `driver/umd/src/device/aipu/aipu.cpp:50`, where the userspace issues `ioctl(m_fd, AIPU_IOCTL_QUERY_CAP, &cap)` against `/dev/aipu`. The IOCTL returns either an error code, or returns success with `cap.partition_cnt == 0`. Either way: **the kernel-side advertises zero NPU partitions to the userspace we just built**.

### Why: a three-version-tree problem

The Cix NPU stack today has three independent version axes:

| Component | Version |
|---|---|
| Compass_NPU_Driver upstream (`Arm-China/Compass_NPU_Driver`, Apache 2.0) | release **4.3.0** (just one commit on `main`, no tags) |
| cixtech kernel module DKMS source (`/usr/src/aipu-6.0.0/`, ships with `cix-npu-driver` 4.0.0 deb) | KMD source **6.0.0** |
| FyrbyAdditive prebuilt module loaded on .66 (kernel 7.0.3 port of cixtech KMD) | dmesg reports **AIPU KMD v6.1.1-2** |

The KMD is "6.x" versioning; the Compass HEAD is "4.x" versioning. They are different version axes. The IOCTL ABI ( `struct aipu_cap`, `struct aipu_partition_cap`, the meaning of `partition_cnt`) drifted across these trees. The 4.3.0-built UMD on Sky1 sees the FyrbyAdditive 6.1.1-2 KMD's QUERY_CAP response as "0 partitions" because the struct layouts don't agree.

The fix is **one of**:
- Cixtech ships `libaipudrv.so` in the apt repo paired with their KMD revision (the right answer)
- A user builds Compass_NPU_Driver KMD from the *same source HEAD* as their UMD and replaces the FyrbyAdditive module (requires kernel headers for `7.0.3-cix-sky1-next` which aren't currently distributed; community kernel doesn't ship a `linux-headers-cix-sky1-next` deb)
- Visorcraft-style: the older monolithic `cix-noe-umd_2.0.2.deb` from Orange Pi pre-dates the frontend/backend split. (Per `task #82` in this project, that combo did work — but Orange Pi's repo has since reorganized; the .deb isn't at the URL the README says.)

### What this means

**The hardware works.** Kernel module probes cleanly (`zhouyi-v3 detected`, `############# ZHOUYI V3 AIPU #############`), `/dev/aipu` is present, `cix-noe-umd` Python bindings load, our self-built `libaipudrv.so` links and dlopens. The only thing missing is a maintained pairing between Cix's open-source UMD and one specific KMD revision.

That's not a hardware story — it's a **distribution and versioning story**. And it's the exact gap that a properly-shipped `libaipudrv.so` deb in `archive.cixtech.com/debian trixie main` would close in an afternoon.

We documented this upstream in [UPSTREAM-CIX-BILINGUAL-ISSUE.md](./UPSTREAM-CIX-BILINGUAL-ISSUE.md).

---

## RESOLVED (2026-06-17): cix-noe-umd 2.0.2 + a Python 3.11 uv venv

The userspace gap is closed. The working pairing on r104
(`7.0.12-cix-sky1-next`, in-tree `armchina_npu` KMD, `/dev/aipu`) is:

| Layer | What works |
|---|---|
| KMD | in-tree `armchina_npu.ko` (v0-compat), overlaid by `80-npu.sh` |
| UMD C lib | `libnoe.so.0.6.0` from **cix-noe-umd 2.0.2** (radxa-pkg/cix-prebuilt) |
| Python binding | `libnoe-2.0.0` + `NOE_Engine-2.0.0` wheels (from the same deb) |
| **Interpreter** | **CPython 3.11 in a uv venv** — *mandatory*, see below |

We confirmed the two other UMDs do **not** work against this KMD:
- **3.1.2** — `noe_init_context` fails: it only knows `YA5X3` targets and
  rejects the Zhouyi-V3 (`Z3`) device the in-tree KMD advertises.
- **1.1.1 (libnoe 0.5.0)** — `init_context` / `load_graph` / `create_job`
  all succeed, but `noe_job_infer_sync` returns rc=20 and the UMD logs
  `schedule job [fail]` — the job-submit ioctl ABI doesn't match.
- **2.0.2 (libnoe 0.6.0)** — full pipeline succeeds. This is the one.

### Why Python 3.11 specifically (the part that bit us)

The libnoe wheel is tagged `libnoe-2.0.0-py3-none-manylinux2014_aarch64`,
which *looks* version-agnostic. It is not. The archive contains only:

```
libnoe/libnoe.cpython-311-aarch64-linux-gnu.so
libnoe/libnoe.cpython-312-aarch64-linux-gnu.so
```

There is **no cpython-314 extension**. r104 ships Python **3.14** as the
system interpreter, so any venv built from `python3 -m venv` (or the old
`47-embedkit.sh`, which did exactly that) can `pip install` the wheel but
then dies on `import libnoe` — silently disabling the NPU adapter while
the C lib, `/dev/aipu`, and KMD are all healthy.

The fix is to build the embedding venv from a **Python 3.11** interpreter.
Ubuntu Resolute has no `python3.11` apt package, so we ship a relocatable
one via `uv` (Astral's `python-build-standalone`):

```bash
uv venv --python 3.11 /opt/ncz/embed-venv
uv pip install --python /opt/ncz/embed-venv/bin/python \
    /usr/share/cix/pypi/libnoe-2.0.0-*.whl \
    /usr/share/cix/pypi/NOE_Engine-2.0.0-*.whl \
    numpy transformers
```

### Measured result (all-MiniLM, `minilm_128.cix`, seq-128, single-stream)

| Path | emb/s | vs NPU |
|---|---|---|
| **NPU** (2.0.2 + py3.11 uv venv, real tokenized) | **~56** | 1.0× |
| NPU (zeroed inputs, no tokenize) | ~58 | — |
| CPU (`llama.cpp`, MiniLM-L6 Q8) | 13.3 | 4.3× slower |
| Mali-G720 panvk (`llama.cpp` Vulkan, MiniLM-L6 Q8) | 8.8 | 6.4× slower |

These are single-stream with per-call `noe_create_job`/`clean_job` churn;
batching + a persistent job lands in the ~66–80 emb/s band measured on the
pre-flash setup. The headline stands: **on this box the NPU is the right
place to embed — ~4–6× the CPU/GPU paths at a fraction of the power.**

### How it ships

- `25-cix-proprietary.sh` now keeps `cix-noe-umd_2.0.2` (it was being
  filtered out with all other UMD debs), landing `libnoe.so.0.6.0` +
  `/usr/share/cix/pypi/*.whl`.
- `46-python311.sh` lays down a relocatable CPython 3.11 at
  `/opt/python3.11` and `uv` at `/usr/local/bin/uv` (offline-first from
  `assets/python311/`, network fallback to python-build-standalone).
- `47-embedkit.sh` builds `/opt/ncz/embed-venv` as a **uv venv on Python
  3.11** and installs the libnoe + NOE_Engine wheels into it; it refuses
  to install the NPU binding into a 3.13+ venv (falls back to CPU/GPU
  adapters so embedkit still works), and rebuilds a stale 3.14 venv.

The remaining upstream ask is unchanged: cixtech should publish a
`libaipudrv.so`/UMD paired to the in-tree KMD in apt. Until then, 2.0.2 +
py3.11 is the shipped, validated path.

### We know this is messy — and it's deliberately temporary

Carrying a second, pinned Python 3.11 interpreter just to run the NPU
binding alongside the system's Python 3.14 is not where we want to be.
It's a stopgap, and we're calling it one. The reason it exists is purely
the wheel-ABI gap above: CIX's libnoe ships cpython-311/312 extensions
and nothing newer yet.

**CIX has Python 3.14 support pending in a future UMD release.** As soon
as a libnoe wheel with a `cpython-314` extension (or a stable-ABI/`abi3`
build) lands, we will collapse this back onto the system interpreter and
retire the separate `/opt/python3.11` + uv venv entirely — the embedder
will just run on the stock Python like everything else on the image. We
track this against the upstream UMD packaging ask; when it ships we
integrate it and delete the stopgap.

Until then we'd rather ship a working NPU on a slightly awkward venv than
a clean-looking image with a dark NPU. The seam is isolated to two hooks
(`46-python311.sh`, `47-embedkit.sh`) precisely so it's a one-commit
removal later.

---

## What works well

[Numbers + qualitative notes from the bench results.]

- Throughput is in the same neighborhood as PYTHIA's CPU embedding path on a much smaller power envelope.
- Latency p50 is [TBD] vs [TBD] on PYTHIA — the NPU is [faster/slower/comparable] for the bulk of the corpus.
- The long-tail (records >256 tokens) gets aggressively truncated by the .cix model, which means there's a quality-vs-throughput knob — a 512-token .cix could be recompiled, but the 256-token version is what cixtech ships as the canonical reference.
- Idle thermals are excellent — [TBD reading from /sys/class/thermal] degC ambient at idle, [TBD] degC after a 19-minute embed run.

## What doesn't work (yet)

- Larger encoders. A bge-base or bge-large would need its own .cix build via Compass NN. The toolchain works (we verified it can compile the small variant), but the build dataset / calibration step is non-trivial.
- LLM decode. Don't try. The NPU does not have the architectural primitives. (We attempted Gemma 3 inference earlier in the project; the right place to run it on this box is Mali GPU via llama.cpp + Vulkan, not the NPU. That's a different blog post.)
- The userspace packaging gap. As above. We've reported this upstream (see [UPSTREAM-CIX-BILINGUAL-ISSUE.md](./UPSTREAM-CIX-BILINGUAL-ISSUE.md)).

---

## What this means for fleet planning

If you're running an agentic stack — ic-engine, mnemos, zeroclaw, hermes, or any of the 2026-vintage memory-augmented AI workloads — the embedding hot path is on the critical path of every ingest and every query. Today most teams run that on whatever CPU/GPU is closest. Sky1-class silicon is interesting because:

1. It's a **deployable appliance form factor** — \$700 for the whole MS-R1 box (not just the silicon), 30W idle, 64 GB RAM, no fan needed.
2. It runs the **encoder-side** of a memory pipeline at a competitive throughput-per-watt — exactly what you want for a sovereign / on-prem / edge memory store that's not budget-rich for an x86 + GPU rig.
3. It is **not** a substitute for an LLM-decode host. Pair this with Mali-G720 GPU for LLM decode, OR with a remote LLM API, OR with a separate decode appliance. Each tier does what it's good at.

We're shipping this configuration as the default for the **NCZ Magnetar** server SKU (the headless variant of NCZ 26.5). The default embedding pipeline in `ncz install mnemos` falls back to the Cix NPU when present, and to CPU otherwise.

---

## Reproducing this

The numbers above were captured by running:

1. NCZ Magnetar 26.5.r76 install on a stock Minisforum MS-R1.
2. `git clone https://github.com/Arm-China/Compass_NPU_Driver && cd Compass_NPU_Driver/Linux && [build instructions — TBD per Codex]`
3. `sudo cp libaipudrv.so /usr/share/cix/lib/ && sudo ldconfig`
4. `ncz models pull` (pulls `bge-small-zh_256.cix` from cixtech/ai_model_hub_25_Q3 modelscope)
5. Run [npu_embed_bench.py — TBD — link or attach]
6. Run [pythia_embed_bench.py — TBD — link or attach] on a comparison host

Raw bench artifacts: [TBD — JSONL + summary files attached as a release asset.]

---

## Next

Two follow-ups:

1. **Submit a PR upstream** to mnemos-os/mnemos integrating the Cix NPU embedder so that any MNEMOS install on a Sky1 box automatically lights up the NPU. (Tracker: [task #103 in the cix-installer roadmap](.))
2. **Push cixtech to ship `libaipudrv.so` in apt.** The kernel-7.0 open-source path needs a complete pairing. We've documented the gap; we'll keep pinging until the package lands.

---

## Acknowledgments

- **visorcraft** for the `aipu.ko` 6.18+ kernel-port patches (the kernel side of this stack)
- **Cix Technology Group** for the Compass NN compiler + open-source kernel module sources + the bge-small-zh-v1.5_256.cix reference model
- **Arm-China** for the Compass NPU Driver source (Apache 2.0)
- **FyrbyAdditive** for the prebuilt aipu.ko that ships with our images
- **MartJohnson** + the **Sky1-Linux** community for the `linux-cix-sky1-next` 7.0.x patch series
- **MNEMOS contributors** for the memory-portability format and the production knowledge store that gave us a real corpus to test against

---

*Living draft. Numbers fill in tomorrow when the overnight bench completes; if the build path didn't pan out, the doc gets honest about which steps fell over.*
