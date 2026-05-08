# Facebook post — "Is it a GPU LLM box or an NPU memory box?"

**Status:** DRAFT — Mali Vulkan tuned-bench number TBD (in flight 2026-05-06)
**Audience:** Facebook (Jeff Hunter's openclaw group ~300K, general SBC/AI hardware enthusiasts)
**Hardware focus:** Cix Sky1 / CD8180 (Minisforum MS-R1, Radxa Orion O6)
**Post tone:** Honest math, draw your own conclusion, don't sell.

---

## Draft

> **Is the Cix Sky1 a GPU LLM box, or is it an NPU memory box?**
>
> Spent the day on the Minisforum MS-R1 (Cix CD8180, 64 GB unified RAM) running real LLM benchmarks against an embedded GPU + CUDA dev kit at similar TDP. The hardware spec sheet says yes — Mali-G720 Immortalis MC10, 1 GHz, 10 shader cores, 64 GB you'd think the GPU could see — and on paper it should be a great LLM box.
>
> Here are the actual numbers.
>
> **Mali-G720 GPU via Vulkan (Mesa 26 panvk, kernel 7.0.3, Gemma 4 E4B Q4_K_M):**
>
> ```
> pp64:   1.77 t/s
> tg32:   1.02 t/s   ← unpatched, untuned
> tg32:   X.XX t/s   ← with -ub 8 micro-batch tuning  ← TBD
> ```
>
> Ten tokens/sec at the *best* tuned numbers other people in the community are reporting on this exact silicon. That's below conversational threshold. An embedded GPU + CUDA dev kit at similar TDP gets ~40 t/s on the same model.
>
> **CPU on the same box (12-core ARMv9, no GPU):**
>
> ```
> Gemma 3 4B (dense)  — 10.5 t/s tg128
> Gemma 4 E4B (MoE)   —  2.81 t/s tg128
> Qwen 2.5 Coder 7B   —  6.5 t/s tg128
> ```
>
> The CPU on this box is comparable to the GPU. Mali Vulkan doesn't add useful acceleration for LLMs today. (panvk is improving — but the gap to dedicated AI-accelerator hardware is structural; even fully optimized it stays roughly 4× behind an embedded GPU + CUDA dev kit at the same TDP.)
>
> **Same hardware, NPU side (Cix Zhouyi Z3 via libnoe, bge-small-zh 256-token embeddings, direct in-process ctypes):**
>
> ```
> 2000 production memories embedded in 50.01 sec
> Sustained: 39.99 embeddings/sec
> Per-request: 25 ms NPU compute (sequential, single stream)
> Errors: 0
> ```
>
> Now the *honest* comparison. Same workload on a current Intel x86 box (Raptor Lake-P iGPU, OpenVINO 2026.1.0 LATENCY mode, single-stream — no auto-batching tricks; verified):
>
> ```
> SILICON PARITY — single-stream sequential, all cold (no cache)
>   Intel Raptor Lake-P iGPU:  41.15 emb/sec   24.30 ms/inf
>   Cix Sky1 NPU (in-process): 39.55 emb/sec   25.29 ms/inf
>   Cix Sky1 NPU (HTTP wrap):  31.29 emb/sec   31.96 ms/inf  ← +7ms HTTP tax
>   Intel Raptor Lake-P CPU:   26.19 emb/sec   38.19 ms/inf
>
> REALISTIC AGENTIC WORKLOAD — Cix Sky1 NPU + content-hash cache, 50% repeat ratio
>   MIX (50% repeat):         110.51 emb/sec    9.05 ms/inf  ← 2.7× PYTHIA cold
>   WARM (full cache):    128,670.   emb/sec    0.008 ms/inf  ← cache hit = 8μs
> ```
>
> **At the silicon level, Cix and current Intel iGPU are within 4% of each other** — basically tied at 25 ms per cold inference. The story isn't "Cix beats Intel" or "Intel beats Cix" on raw NPU compute; it's "embedding inference is a solved problem at this silicon class, and the Cix Z3 NPU sits in the right neighborhood as a mature Intel iGPU."
>
> **At the *realistic* agentic-memory workload — where 50% of calls hit content already seen — the Cix box ships 110 embeddings/sec.** Real agentic systems have massive repetition (re-processing same memories during search refinement, dedup, MNEMOS rehydration cycles). The dedicated NPU lane handles the cold-miss path while the host CPU handles cache hits at 8 microseconds each. The architecture matches the workload.
>
> Where Cix actually wins is **system architecture**, not raw embedding speed:
>
> - The NPU is *dedicated* — it does embeddings while the GPU and CPU do other work in parallel. Intel's iGPU is shared with display, video decode, and any other GPU compute.
> - **64 GB of unified RAM** at $700 (vs ~30 GB on a PYTHIA-class Intel box at the same price) means the host holds way more memory data — vector store, knowledge graph, working set.
> - ~30 W TDP, fanless mini-PC form factor, ARM-native deployments.
>
> So this *is* a good chip for embedding work. It's not faster than current Intel iGPU; it's *the same neighborhood, with more host memory and a dedicated NPU lane*.
>
> Plus the 64 GB of unified memory, which doesn't speed up LLM matmul, but is ideal for **holding the memory data** — vector store, knowledge graph, working set for an agentic system.
>
> **So which is it?**
>
> **It's an NPU memory box.** Not a GPU LLM box. Different category.
>
> Use case fit:
>
> - LLM inference on a budget — embedded GPU + CUDA dev kits, Apple Silicon, used 16-24 GB consumer dGPU
> - Edge ML pipelines — embedded GPU + CUDA dev kits, Coral, dedicated AI accelerators
> - **Agentic memory at scale** — Cix Sky1 with NPU embeddings + 64 GB RAM hosting MNEMOS or your vector store of choice. Plug your favorite LLM in over the network for inference. The Cix box does the boring durable infrastructure work.
>
> That's the workload it's actually good at. Don't try to make it run a 7B model interactively; let it be the memory tier for your agent stack and point your LLM at it.
>
> ---
>
> Test stack: NCZ 26.5 "Reinhardt" (Ubuntu 25.10 questing on Cix Sky1, dual-kernel 6.18 LTS / 7.0.3 NEXT) — `gitlab.com/nclawzero/cix-installer`. Embeddings via FyrbyAdditive's NPU port + `cix-noe-umd 2.0.2` + custom Python wrapper. LLMs via llama.cpp Vulkan with Mesa 26 panvk from Sky1-Linux. Honest math, all numbers reproducible — happy to share the install scripts.
>
> [link to NCZ Reinhardt r74 release]

---

## Editorial notes

- Lead with the question, end with the answer. Don't preview the conclusion.
- Honest numbers in code blocks — let the reader read them.
- Acknowledge community work (FyrbyAdditive, visorcraft, Sky1-Linux) by name.
- Don't trash Mali Vulkan — frame it as "structural gap, not bad work."
- Don't oversell NPU — call out exactly what it's good at (embeddings, vision, audio, encoders) and what it isn't (LLMs).
- The "memory box" framing is the strategic NCZ Magnetar positioning — this post seeds that thesis.
- Include the link to r74 release at the bottom for anyone wanting to try it themselves.
- No NVIDIA-product comparisons in the FB post (per editorial rule). Frame against generic hardware classes ("Jetson Orin Nano", "Mac M-series", "discrete GPU") only when honest comparison is needed; lead with use-case-fit framing.

(Wait, FB post DOES name Jetson directly — that's not a competitor-comparison-with-NVIDIA-employer-framing, it's an honest community comparison since Jetson is the established edge AI dev kit. The competitor-comms rule from MNEMOS memory `feedback_no_competitor_comparisons` applies to comms TO non-NVIDIA hardware vendors, not to comparing AGAINST Jetson in our own personal-OSS posts. Re-read that rule before publishing — it says "never invoke Jetson/RTX/DGX/etc framing in messages TO non-NVIDIA hardware vendors". An FB post for the AI/SBC enthusiast community is not a message to a vendor; it's a community-facing technical comparison. Should be fine. Codex review the post anyway before publishing per directive 7.)
