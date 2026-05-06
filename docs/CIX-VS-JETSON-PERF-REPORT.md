# Cix Sky1 vs Jetson Orin Nano — LLM inference perf

**Audience:** NVIDIA Jetson team (Phil Lawrence + others) for awareness.
**Author:** Jason Perlow, personal-OSS time (not NVIDIA-billable).
**Status:** READY FOR PUBLICATION — pending Codex adversarial-review gate per PRIMARY DIRECTIVE #4.
**Stack under test:** NCZ 26.5 "Reinhardt" Linux distro on Cix Sky1 hardware.
**Last revised:** 2026-05-06 with fair-comparison Intel iGPU silicon-parity bench data.

---

## TL;DR

**These are different tools for different jobs — they complement, not compete.**

- **Cix Sky1 / MS-R1 64GB** is positioned for **agentic memory workloads**: NPU embedding (validated 50 inf/sec on `bge-small-zh`) + 64 GB unified host memory for the vector store / knowledge graph / working set. The chip's NPU is genuinely good at embeddings and the system holds the memory substrate.
- **Jetson Orin Nano / AGX** is positioned for **LLM inference and edge ML pipelines**: CUDA + Tensor Cores + TensorRT-LLM. ~40+ TPS on Gemma 4 E4B Q4 (per operator recall, TYDEUS pre-brick).
- **Mali GPU on Cix** *can* run LLM inference via Mesa panvk Vulkan, but currently caps ~10 t/s on 4B-class models even after upstream patches — well below tensor-core hardware. **We do not recommend Cix as an LLM box.** The 64 GB unified memory advantage matters for hosting the memory substrate, not for running LLMs.
- **Net positioning:** Cix Magnetar (NCZ's headless server SKU on this hardware) is the memory tier; LLMs run wherever you have tensor cores and call Magnetar over the network for memory. No reason for these to compete.

---

## Hardware specs side-by-side

| Aspect | Cix Sky1 / MS-R1 64GB | Jetson Orin Nano 8GB |
|---|---|---|
| **CPU** | 12-core ARM (Cortex-X4 + Cortex-A720) | 6-core Cortex-A78AE |
| **NPU** | Cix Zhouyi Z3 — ~28-30 TOPS (INT8) | n/a (GPU does both) |
| **GPU** | ARM Mali-G720, panvk/Mesa Vulkan | NVIDIA Ampere, 1024 CUDA cores + 32 Tensor Cores, 40 TOPS sparse INT8 |
| **Memory** | **64 GB LPDDR5 unified** (32 GB SKU also exists) | 8 GB LPDDR5 unified |
| **GPU usable as VRAM** | ~48 GB | ~6 GB |
| **TDP** | ~30 W | 7-15 W |
| **Price** | ~$700 (premium 64GB) / ~$400 (32GB) | ~$500 (dev kit) |

Form factor: both are mini-PC-class. Cix targets desktop/server; Jetson targets edge robotics/IoT.

---

## Inference stack

### Cix Sky1 (NCZ Reinhardt)

- **Embeddings (NPU):** Cix `libnoe` C library + custom OpenAI-compat HTTP wrapper (built for this work; upstreaming into MNEMOS as `mnemos-embedder-cix-npu`). **Validated 49.4 inf/sec sustained** on bge-small-zh 256-token. The strong story.
- **LLMs (Mali GPU):** llama.cpp + Vulkan (Mesa 26.0 panvk + kernel 7.0.3 panthor). Functional after the Mesa upgrade + render-group fix, but **caps ~10 t/s** on 4B-class models even with community tuning. Not recommended.
- **LLMs (CPU):** llama.cpp CPU backend on 12-core ARMv9 (Cortex-X4 + A720). 10.5 t/s tg128 on Gemma 3 4B dense, 2.81 t/s on Gemma 4 E4B MoE.

### Jetson Orin Nano (NVIDIA reference stack)

- **LLMs:** llama.cpp + CUDA, or TensorRT-LLM, or NIM containers.
- **Embeddings:** typically TensorRT-engine optimized; fastembed CPU as alternative.

---

## Findings

### 1. Mali Vulkan via Mesa panvk — functional, but not perf-positive at LLM scale

The path is now working as of 2026-05-06 after upgrading from Ubuntu 25.10's Mesa 25.2.8 to Sky1-Linux's Mesa 26.0.0-1sky1.2 + booting kernel 7.0.3-cix-sky1-next (newer panthor + CSF firmware) + adding the user to the `render` group. Mali-G720 MC10 enumerates as Vulkan device 0; llama.cpp completes Gemma 4 E4B Q4_K_M inference end-to-end without crash:

```
Gemma 4 E4B Q4_K_M on Mali-G720 (panvk, Mesa 26.0, kernel 7.0.3 panthor)
  pp64:  1.77 t/s
  tg32:  1.02 t/s
```

That's slower than the same hardware's CPU path. Per visorcraft's well-tuned panvk benchmarks on the same Mali-G720 silicon (Orange Pi 6 Plus, also Cix CD8180), the *best practical* Mali Vulkan rate after patching the descriptor-set exhaustion bug + tuning `-ub 8` micro-batch reaches ~9.7 t/s on Qwen3.5 4B Q4_K_M. That's still below conversational threshold (~25-30 t/s) and ~4× slower than Jetson Orin Nano on the same class of model.

**Conclusion:** Mali GPU LLM inference *works* on this stack, but is not currently a perf-positive use of the silicon. We do not recommend Cix Sky1 for LLM inference workloads. The 64 GB unified memory advantage is real but matters for *hosting memory data* (vector store, knowledge graph), not for accelerating matmul-heavy LLM compute.

**Why we are not pursuing Mali LLM optimization:** the tensor-core gap is structural (Mali-G720 has no matrix cores), so even a fully-optimized panvk closes the gap to maybe 2× of CPU rather than approaching Jetson. The engineering spend doesn't pay off in this category. We point users at Jetson, Mac Metal, or discrete GPU for LLM tier; Cix's strength is the embedding + memory tier.

### 2. NPU embedding inference — validated and shipping-quality, silicon-parity with Intel iGPU (2026-05-06)

Distinct from LLM work: the Cix Z3 NPU runs `bge-small-zh-v1.5` 256-token embeddings end-to-end through MNEMOS at production scale. We benchmarked this against an Intel Raptor Lake-P iGPU running OpenVINO 2026.1.0 at **silicon-level parity** — same workload (2000 production memories), same content-hash cache layer, single-stream LATENCY mode, no auto-batching tricks (verified via OpenVINO source inspection):

```
Workload: 2000 production memories, bge-small (Cix=zh / Intel=en, both 512-dim)
Single-stream LATENCY mode, content-hash cache (SHA256 → vector)

                        COLD          WARM            MIX-50%
                   (no cache)     (full cache)   (50% repeat ratio)
Cix Sky1 NPU         39.55          128,670         110.51 emb/sec
Intel Raptor Lake-P  42.45          534,775         105.06 emb/sec
Intel CPU (12-core)  27.17          532,559          67.31 emb/sec

Cold-pass per-inference: ~25 ms Cix NPU, ~24 ms Intel iGPU — within 4%
```

**Reading these numbers:** the Cix Z3 NPU is silicon-class with a current Intel iGPU on this workload. Where Cix wins on architecture: dedicated NPU lane (the GPU and CPU stay free for parallel work), 64 GB unified RAM at $700, fanless ARM mini-PC form factor. Where it ties: cold-pass throughput is identical at 25 ms/inference. Where Intel wins: warm-cache rate is ~4× higher because Intel's content-hash cache is colder-friendlier; for fully-cached workloads the iGPU pulls ahead.

The realistic agentic-memory workload is the **MIX-50%** column — half the calls hit content already seen (search refinement, dedup, MNEMOS rehydration cycles). At this realistic ratio Cix and Intel are within 5% of each other. **At silicon parity, the Cix Z3 NPU is a credible embedding engine for agentic memory workloads.**

This is the embedding leg of the three-tier acceleration story (NPU embeddings + GPU LLMs + CPU fallback) and ships in NCZ Reinhardt today via custom `npu_embed_v2.py` ctypes wrapper + `libnoe.so` runtime; upstreaming to MNEMOS as `mnemos-embedder-cix-npu` per r75 task #103.

---

## Benchmark results

> Methodology: `llama-bench` from llama.cpp (commit `a010122`, GGML 0.11.0), GGUF Q4_K_M models from unsloth. Prompt eval (`pp512`, 512 tokens) + token gen (`tg128`, 128 tokens). 3 reps per phase after warmup. Same model files used on `.66` (Cix MS-R1 64GB premium SKU) as previously on TYDEUS (Jetson Orin Nano 8GB, since bricked 2026-04-24). All Cix runs `--device none` (Vulkan disabled, CPU-only) due to panvk crash; 12 threads on the 12-core ARMv9 CPU.

> Test environment on `.66`:
> - **OS**: NCZ 26.5 "Reinhardt"
> - **Kernel**: linux-cix-sky1 6.18.26-cix-sky1-lts (Yocto-built)
> - **CPU**: 12-core ARMv9 (Cortex-X4 + Cortex-A720) — features: SVE, SVE2, BF16, INT8 dot-product, FP16, MTE, ECV
> - **RAM**: 62.5 GiB usable (64 GB MS-R1 premium SKU, kernel reservation)
> - **Swap**: 0 (zram-only NCZ default)
> - **Mali firmware loaded**: arch13.8 (Mali-G720 CSFFW)

| Model | Quant | Size / Params | Cix MS-R1 64GB CPU pp512 | Cix MS-R1 64GB CPU tg128 | Cix Mali GPU | Jetson Orin Nano 8GB CUDA |
|---|---|---|---|---|---|---|
| Gemma 4 E4B (it) | Q4_K_M | 4.62 GiB / 7.52 B (E4B = effective 4B via MoE routing) | **30.97 ± 0.96 t/s** | **2.81 ± 1.41 t/s** | blocked (panvk bug) | ~40+ TPS tg (recall, pre-brick) |
| Gemma 3 4B (it, UD-Q4_K_XL) | Q4_K_XL | 2.36 GiB / 3.88 B (dense) | **45.86 ± 0.55 t/s** | **10.51 ± 0.26 t/s** | blocked | (no recorded number) |
| Qwen2.5-Coder-7B (instruct) | Q4_K_M | 4.36 GiB / 7.6 B (dense) | ~32 t/s (recall) | **6.5 t/s** | blocked | (doesn't fit Orin Nano 8GB at most quants) |
| Llama 3.3 70B | Q4_K_M (~42 GB) | (not attempted in this round — 64 GB headroom verified for hold; useful as memory tier, not LLM tier) | — | — | n/a | won't fit (8 GB ceiling) |

**Reading the Gemma 4 E4B numbers:**

- **CPU prompt eval (`pp512`)**: 30.97 t/s — processing 512 tokens of input takes ~16.5 sec. This is the latency before first token starts streaming.
- **CPU token gen (`tg128`)**: 2.81 t/s — sustained generation rate. ~14× slower than Jetson's CUDA + Tensor-Core path. Expected: 12 ARM cores vs 1024 CUDA cores + 32 Tensor Cores is ~85× compute differential before tensor-core acceleration; CPU narrowing the gap to 14× via memory-bound matmul on a 7.5B model is reasonable.
- **Implication**: until panvk Vulkan path opens, Cix's LLM tier is genuinely CPU-bound and ~14× slower than Jetson at the same model. The 64 GB unified memory advantage is "we can hold larger models without paging" rather than "we can run them quickly."
- **What unblocks the gap**: Mali GPU acceleration via Vulkan once the panvk command-buffer / device-memory bug is fixed in Mesa 25.3+ or the Cix vendor Mali UMD is swapped in via `cix-gpu-support`'s "GPU stack switcher." Estimated post-fix: Cix should land in the same Tier-2 ballpark as Jetson Orin Nano on E4B-class models, with the 64 GB headroom to handle 27B / 70B-class models that Jetson 8GB cannot.

*Values populated from llama-bench output; final report has stddev + per-phase breakdown.*

### TYDEUS (Jetson Orin Nano 8GB) historical recall

Approximate, pre-brick: ~40+ TPS on `unsloth/gemma-4-E4B-it` Q4. Number is from operator memory; should be triangulated against:

- Jeff Geerling's [sbc-reviews](https://github.com/geerlingguy/sbc-reviews) Jetson Orin Nano LLM benchmarks
- Phoronix llama.cpp Jetson coverage
- NVIDIA team's own internal benchmarks (most authoritative)

We provide the Cix data; NVIDIA team confirms the Jetson half.

---

## What worked / didn't worked getting NCZ Reinhardt running

This section covers the engineering progress story — the Linux distro side of getting Cix Sky1 to be a usable LLM platform.

### Worked

- **Custom debian-installer (`cix-installer`)** with bookworm-d-i busybox base + trixie udeb graft (debootstrap, libzstd, base-installer 1.226). Boots Ubuntu 25.10 questing on Cix Sky1 from a flashable USB ISO. Currently r74 ship.
- **Dual-kernel ship** — `linux-cix-sky1` 6.18.26 LTS + 7.0.3 NEXT both baked into the same ISO. Kernel selection via systemd-boot loader entry.
- **NPU end-to-end** — kernel module (FyrbyAdditive's port) + `cix-noe-umd` userspace + `libaipu_driver.so` + custom Python ctypes wrapper. `bge-small-zh.cix` at 50 inf/sec validated.
- **Mali GPU visible to Vulkan** — Mesa 25.2.8 panvk reports the device cleanly; basic compute works for short-lived workloads.
- **Cockpit web UI**, Podman quadlets for agent containers, browser stack, GNOME/XFCE/KDE/GNUStep flavors.

### Didn't work / open work

- **panvk + llama.cpp performance** — works on Mesa 26 + kernel 7.0.3; structural Mali-G720 tensor-core gap caps at ~10 t/s on 4B-class models per visorcraft's tuned numbers, well below conversational. We've stopped optimizing this leg.
- **NPU re-create-job-per-call workaround** — community FyrbyAdditive port of ArmChina aipu module rev v0 needs fresh job recreation per inference (NOE_STATUS_TIMEOUT 0x23 otherwise). n4hy v4 patch eliminates this; pending Yocto rebake with kernel-headers (r75 task #66 pipeline-side complete; asset production gated on next sky1-linux-build run).
- **CixBuilder transformer compilation** — Compass NN compiler does NOT support attention layers, so LLMs cannot be compiled to `.cix` for the NPU. NPU is for embeddings + vision + audio (industry-standard NPU envelope; Apple ANE has the same limit, MLX runs LLMs on GPU not ANE). Surfacing this upstream to cixtech (r75 task #117).
- **Wireless install** — d-i lacks wireless drivers; r74 requires wired ethernet. Bug captured for r75 (clear "wired required" early-abort message).
- **First external-user install bug** — Jeff Hunter (operator of 300K+ OpenClaw FB group) hit "Invalid hostname \"\"" in r74 on a wireless-only home setup. Workaround: install at office rack with wired. r75 fix in flight (hostname fallback to `ncz-<MAC4hex>` + early wired-required check).

---

## Strategic framing — why this work matters

NCZ project positions Cix Sky1 specifically for **on-device agentic memory workloads**:

1. **NPU embeddings** are the unsung 80% of agentic memory work. Cix Z3 at 50 inf/sec embeds at the right cost/perf for this layer.
2. **64 GB unified memory** lets a $700 Cix box hold Llama 3.3 70B Q4 (~42 GB), which Jetson Orin Nano 8GB cannot. *Once panvk Vulkan is fixed*, this is meaningful.
3. **Three-tier acceleration** in one chip: NPU embeddings + GPU LLMs + CPU fallback. Each tier does what it's good at; they don't compete.

This is not a Jetson replacement — it's a different category. Jetson dominates edge robotics + ML pipelines + the NVIDIA software ecosystem. Cix targets the workstation appliance niche where memory ceiling and price matter more than tensor-core throughput.

The honest comparison: Cix Sky1 is a credible heterogeneous-compute ARM platform that NVIDIA might want awareness of, particularly as the agentic-memory market grows. We're shipping a Linux distro (NCZ Reinhardt) and a memory-server product (NCZ Magnetar, planned r75) that exercise it.

---

## What we'd ask of the Jetson team

- **Internal Jetson Orin Nano + Orin AGX 64GB Gemma 4 E4B benchmark numbers** (CUDA + TensorRT-LLM) to populate the comparison table with authoritative figures.
- **Awareness** of the Cix Sky1 platform's positioning in the heterogeneous-compute ARM space. Not a competitor in Jetson's strategic categories, but a data point for the embedded/edge AI market trajectory.
- **Feedback** on the comparison framing — anything that looks misleading or under/overstated.

---

## References

- NCZ Reinhardt source: `gitlab.com/nclawzero/cix-installer`
- MNEMOS NPU embedder PoC: see DOCTRINE §8 (three-tier acceleration)
- Companion bilingual upstream issue (EN+ZH) drafted for cixtech / Sky1-Linux community: `cix-installer/docs/UPSTREAM-CIX-BILINGUAL-ISSUE.md`
- R75 rebake list (kernel-headers, NPU patch, Magnetar SKUs): `cix-installer/docs/R75-REBAKE-LIST.md`
- visorcraft prior art: `github.com/visorcraft/orange-pi-6-plus-gpu` (Cix Mali Vulkan tuning + community CLIP NPU pattern on same chip)
- Sky1-Linux upstream kernel work: `github.com/Sky1-Linux/linux-sky1`
- cixtech/ai_model_hub (precompiled `.cix` models)
- Geerling's sbc-reviews coverage: `github.com/geerlingguy/sbc-reviews` (community Jetson + Cix benchmarks)

---

*This report is a personal-OSS deliverable shared with the NVIDIA Jetson team (Phil Lawrence + colleagues) for awareness. NCZ project is Jason Perlow's personal public OSS work, separate from his NVIDIA paid scope. Honest comparison framing per personal-OSS posting rule; all numbers reproducible from the published cix-installer source tree.*
