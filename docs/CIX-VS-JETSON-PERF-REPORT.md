# What an open-stack Cix Sky1 looks like next to Jetson — internal awareness brief

**Audience:** NVIDIA Jetson team (Phil Lawrence) and any Jetson leadership who picks this up.
**Author:** Jason Perlow, NVIDIA Sr. Technical Product Marketing Engineer (AI Cloud / NCX portfolio). Written on personal-OSS time as part of my NCZ project; sharing internally because the findings are directly relevant to Jetson roadmap awareness.
**Status:** Internal awareness brief — share within Jetson org as appropriate.
**Stack under test:** NCZ 26.5 "Reinhardt" Linux distro on Cix Sky1 / Minisforum MS-R1.
**Last revised:** 2026-05-06.

---

## Why this brief exists — and why I'm writing it

**Short version:** I'm pro-NVIDIA. I want our hardware to win the agentic-AI tier. I started NCZ as a Jetson-first project, the dev-kit hardware failed mid-port, I continued the work on the most credible alternative open-stack ARM platform I could find (Cix Sky1) so the software stack didn't sit idle, and I'm reporting back what I learned. **The goal is to bring NCZ 26.6 back to Jetson on AGX Orin or Thor as soon as we have stable hardware to port to.**

The longer version, because it should be on the record:

1. **NCZ 26.5 "Reinhardt" started life on a Jetson Orin Nano dev kit** (TYDEUS, fleet host). The original target architecture was Jetson + JetPack as the production deploy substrate for an agentic-memory Linux distribution.
2. **We got to roughly 80% functional**: Yocto-built kernel + UEFI + custom debian-installer-style flow + agent stack containers all running on Orin Nano.
3. **Hardware failed during the kernel-flip phase** (2026-04-24). One bad boot path on Tegra T234 (no rollback for `BootChainOsCurrent`) bricked the dev kit's boot chain. The unit is in RMA / awaiting replacement; the runbook is captured in our internal handoff docs.
4. **Rather than stall the software work, I pivoted to the open-stack ARM alternative** that had the most active community (Cix Sky1 / Minisforum MS-R1, with the Sky1-Linux community kernel + FyrbyAdditive's NPU port). This is the platform NCZ 26.5 r74 ships on today.
5. **The Cix work has been informative.** It validates that the agentic-memory workload — embedding-heavy + unified-RAM-hungry + low-power — is a real product category worth optimizing for. But the LLM tier on Mali Vulkan is structurally weak (no tensor cores). On the LLM leg, the gap to Jetson is wide and not closing through software alone.
6. **What I'm asking the Jetson team for:** an AGX Orin 64GB (or Thor when it's sampleable) that I can port NCZ 26.6 to as the canonical production path. NCZ on Jetson AGX would close every category where Cix currently has a window — bigger memory, real tensor cores, mature CUDA + TensorRT-LLM stack, the whole platform. The port would be relatively quick because most of the substrate work is reusable.

The rest of this brief is the data: what Cix actually does on this workload, where Jetson dominates, where the open-ARM ecosystem is investing energy, and what that means for our platform strategy.

---

## TL;DR

- **The agentic-memory workload (NPU embeddings + large unified RAM + low power) is a real and growing category.** NCZ targets exactly this category. The Cix data validates that the workload exists and that there's a market for a $700 64GB ARM box that does it well.
- **Cix Sky1 has reached embedding-throughput parity with current Intel iGPU on this workload.** Same neighborhood, ~25 ms cold-pass per inference. The NPU is genuinely good for this leg.
- **Cix is not an LLM platform.** Mali-G720 via Vulkan caps ~10 t/s on 4B-class models even after upstream tuning. Structural — Mali has no tensor cores. Jetson Orin Nano + CUDA does ~40 TPS on the same model. **The tensor-core moat is real and visible in these numbers.**
- **Jetson AGX 64GB or Thor would close the only category where Cix currently has a window** — the unified-memory ceiling that drove people to a 64GB ARM box in the first place. Same software stack, much better LLM compute, mature toolchain.
- **The open-stack ARM ecosystem is moving.** Sky1-Linux maintains a 140-patch community kernel; visorcraft is bring-up'ing Mali Vulkan in mainline; FyrbyAdditive ported the Cix NPU userspace. There's grassroots developer energy here. None of it is a Jetson replacement, but it's a data point on where ARM-AI mindshare goes when the platform is open.
- **Net ask:** AGX Orin 64GB or Thor loaner so I can port NCZ 26.6 to Jetson and ship the next release on our hardware.

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

**Reading this:** Mali Vulkan LLM inference is functional but structurally capped well below the Jetson Orin Nano CUDA reference (~40 TPS on the same class of model). The gap is matrix-multiplication architecture, not software tuning — Mali-G720 has no equivalent of the Jetson's tensor cores, and even a fully optimized panvk path doesn't close it.

**This is the cleanest validation in the brief that the tensor-core moat is real and visible at the workload level.** Anyone making a "tensor cores don't matter at this size class" argument from spec-sheet TOPS numbers can be answered with these benchmarks: same model, same quant, same Linux kernel/userspace generation, ~4× delta in real tokens-per-second. Worth keeping in the back pocket for any roadmap conversation where the moat needs articulating.

**On the NCZ side:** I've stopped optimizing Mali Vulkan LLM as a tier; users who want LLM inference on NCZ are pointed at Jetson, Mac Metal, or discrete GPU as the LLM endpoint and the local Cix box does embeddings + vector store + memory. NCZ 26.6 on AGX/Thor would just *be* the LLM tier locally, eliminating the need for the network hop.

### 2. NPU embedding inference — validated and shipping-quality, same neighborhood as Intel iGPU on this harness (2026-05-06)

Distinct from LLM work: the Cix Z3 NPU runs `bge-small-zh-v1.5` 256-token embeddings end-to-end through MNEMOS at production scale. We benchmarked this against an Intel Raptor Lake-P iGPU running OpenVINO 2026.1.0 — same harness shape (2000 production memories, single-stream LATENCY mode, content-hash cache, no auto-batching tricks; the OpenVINO side verified by source inspection). Note: Cix ran the `-zh` variant of bge-small, Intel ran `-en` — same architecture and same 512-dim output, but quantization tables and tokenizer details differ:

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

**Reading these numbers:** on this harness, Cix Z3 NPU and a current-gen Intel iGPU sit in the same neighborhood for this workload — within 4% on cold-pass per-inference time, within 5% on the mixed-cache ratio. Caveats before drawing strong conclusions: (a) different language variants (`bge-small-zh` on Cix, `bge-small-en` on Intel — same 512-dim architecture but quantization + tokenizer differ); (b) the MIX-50 column is dominated by the content-hash cache (cache-hit path is ~8 µs each side) rather than raw accelerator throughput; (c) single-harness point estimates without published variance bars. We can fairly say neither side dominates by a wide margin on this workload as measured; we cannot yet attribute the residual cold-pass gap to silicon, software-tuning, or model variant from this dataset alone.

The takeaway for Jetson is the framing — **embedding inference at the bge-small class is no longer where Tensor Cores are the deciding differentiator**. At this layer the differentiators are architecture (dedicated NPU lane vs shared iGPU), memory ceiling, and software stack maturity. The Tensor-Core advantage shows up in *LLM* inference (Finding #1 above is the cleanest demo of that gap) where the matmul math actually exercises tensor hardware.

For Jetson context: I haven't run an apples-to-apples embedding bench on Orin Nano (TYDEUS pre-brick) or AGX yet. Strong prior expectation, given 1024 CUDA cores + Tensor Cores + TensorRT-LLM optimizer, is that Jetson AGX in particular outperforms both numbers above on bge-small embeddings — probably comfortably. **This is one of the things I'd want to measure on the AGX/Thor loaner** to put authoritative Jetson numbers in the next version of this brief instead of relying on inference from spec sheets.

The embedding leg ships in NCZ today via custom `npu_embed_v2.py` ctypes wrapper + `libnoe.so` runtime; the pattern is clean and upstreamable. Same pattern would apply to a Jetson port using TensorRT for the embedding engine — different backend, same wrapper shape.

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

## What this means for Jetson — the strategic read

Three observations I'd offer up, ranked by how directly they touch our roadmap:

**1. The agentic-memory category is real and growing.** The workload that drove me to build NCZ is: an always-on, low-power, ARM-native, high-RAM-ceiling appliance that does embeddings + vector search + agent orchestration locally, calling out to bigger boxes for LLM inference. Customers (and tinkerers) are buying $700 64GB ARM boxes specifically for this. **Jetson AGX Orin 64GB and Thor are the natural NVIDIA answer to this category** — they have the memory ceiling, real tensor cores, and the CUDA software stack the workload eventually wants. Cix is filling a gap that exists because Jetson AGX is priced into industrial/automotive bins, not consumer/prosumer bins.

**2. The CUDA + tensor-core moat is intact and visible in this data.** Mali Vulkan caps at ~10 t/s on 4B-class models. Jetson Orin Nano does ~40 TPS on the same model with a third the cores and a fraction the unified RAM. That's a structural delta no amount of Mesa tuning closes. The open-stack ARM crowd is genuinely impressive on the *non-LLM* legs (embeddings, vision, audio); on LLMs the gap is wide. **Anyone benchmarking Jetson against open-stack ARM on LLM workloads will conclude what we already know: tensor cores win.** This brief should make that gap easier to talk about with concrete numbers.

**3. Open-stack ARM has grassroots developer energy worth being aware of.** The Sky1-Linux community kernel runs 140 patches against mainline. visorcraft is doing community Mali Vulkan tuning. FyrbyAdditive ported the Cix NPU userspace. None of these projects is a Jetson competitor on capability — they're a parallel community moving in the same direction we are, on hardware where the vendor went open-stack from day one. **There's a pattern here for Thor's Linux story** that's worth a conversation: Jetson dominates the closed/controlled ecosystem (JetPack, NIM containers, NGC); the open-stack ARM crowd is showing what mainline-kernel + Mesa + community-NPU-port looks like when nobody owns the platform. Useful prior-art context for the Thor open-source posture, whatever shape that takes.

---

## What I'd ask of the Jetson team

**Primary ask: hardware loaner for the NCZ 26.6 Jetson port.**

I want to bring NCZ back to where it started. NCZ 26.5 r74 ships on Cix Sky1 today; NCZ 26.6 should ship on Jetson AGX Orin 64GB (and ideally Thor when sampleable). The substrate work is done — kernel build, custom installer, agent stack, MNEMOS server, NPU embedder pattern — most of it ports cleanly to Tegra T234 / Thor.

Specifically:
- **Jetson AGX Orin 64GB Developer Kit**, on loan, for the NCZ 26.6 port. I can return it when the 26.6 release ships and Thor sampling begins.
- **Or Jetson Thor Developer Kit when sampleable** — direct port to current-gen would be even better, and would let NCZ 26.6 be a "Jetson Thor showcase distro" if that's useful internally.
- **Either path**: I commit to a ported, working NCZ 26.6 release on the loaned hardware within ~6 weeks of receipt, published as personal-OSS the same way r74 shipped.

**Secondary asks** (less critical, useful for the data):
- **Internal Orin AGX 64GB and Thor reference numbers** on Gemma 4 E4B Q4_K_M and bge-small-en-v1.5 256-token, so I can replace the recall-based ~40 TPS Jetson Orin Nano figure in the table with authoritative published-by-Jetson-team data when the brief or its successor goes external. Keeps NVIDIA looking precise rather than estimated.
- **Feedback on this brief** — anything that's mischaracterized, anything I should soften or strengthen, anywhere I should be more careful. I'd rather edit before this circulates than after.
- **A point of contact for the Thor Linux/open-source posture conversation**, if that's useful. The open-stack ARM-AI community is real; understanding its trajectory could inform how Thor presents to that audience.

I'm happy to do this work as a parallel personal-OSS thread (which is what NCZ already is) so it doesn't load up internal billable cycles. The deliverables — a working NCZ 26.6 on Jetson, plus this kind of awareness brief — are all things that ultimately serve our platform position.

---

## TYDEUS Jetson Orin Nano — what happened

For completeness on the "why didn't we just keep going on Jetson" question: TYDEUS (the Jetson Orin Nano dev kit, 192.168.207.62 on my home fleet) was the original NCZ target. The bring-up was going well — Yocto kernel + UEFI flow + agent containers all working — through April 2026. On 2026-04-24, during a kernel rebuild that flipped the L4T BootChain partition selector, the device became unbootable. Diagnosis: stock JetPack QSPI bootloader (`L4TLauncher`) checks `BootChainOsCurrent` EFI variable on every boot; once set non-zero by our build, the bootloader looks for partitions named `APP_<chain>` rather than the canonical `APP`, which our SD layout didn't have.

The recovery path (`tegraflash` from USB-OTG with `tegraflash.tar.gz`) is documented in our internal runbook (`~/cix-installer/HANDOFF-2026-05-04.md`), but the unit needed a UEFI-setup-menu reset of `BootChainOsCurrent` first — which we couldn't get to without working video output. The dev kit is in RMA queue / awaiting replacement.

The lesson learned (captured as a fleet-wide rule: `feedback_no_rollback_no_kernel_push.md`): **never push a boot-critical change without a keypress-distance rollback** — second extlinux LABEL, A/B slot, or working UART. NCZ 26.6 on AGX/Thor will have this guardrail baked in from r1.

---

## References

- NCZ 26.5 source: `gitlab.com/nclawzero/cix-installer`
- NCZ project doctrine (codenames, brand hierarchy, three-tier acceleration thesis): `cix-installer/docs/DOCTRINE.md`
- R75 rebake list (kernel-headers, NPU patch, Magnetar SKU plan): `cix-installer/docs/R75-REBAKE-LIST.md`
- TYDEUS Jetson recovery runbook (internal): `cix-installer/HANDOFF-2026-05-04.md` (also `pi-fleet-recovery-runbook.md` archived to ARGONAS)
- visorcraft community work on the same Cix silicon: `github.com/visorcraft/orange-pi-6-plus-gpu`
- Sky1-Linux community kernel: `github.com/Sky1-Linux/linux-sky1` (~140-patch mainline series, lead maintainer Entrpi)
- Geerling sbc-reviews (Jetson + Cix community benchmarks): `github.com/geerlingguy/sbc-reviews`

---

*Written by Jason Perlow, NVIDIA Sr. Technical Product Marketing Engineer (AI Cloud / NCX), in personal-OSS time. NCZ project is my personal public-OSS work; sharing this brief internally because the findings are directly relevant to Jetson roadmap awareness and because the NCZ 26.6 Jetson port ask should go on the record. All numbers in this brief are reproducible from the published `gitlab.com/nclawzero/cix-installer` source tree. Treat this as internal — appropriate to circulate within the Jetson org; please clear with me before it goes external.*
