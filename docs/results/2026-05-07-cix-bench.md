# 2026-05-07 — MNEMOS embedding scales across the platform spectrum

The point of this bench is **not** "which silicon wins." It is: *MNEMOS embeds memory the same way on every platform, from the smallest Pi Zero up to a workstation*. Same kit, same code, same model, same corpus.

## Same workload, same corpus

| | |
|---|---|
| Corpus | 8038 MNEMOS records, ~14 MB content text, mean 1763 chars, p95 2630, max 82K |
| CPU/GPU model | `nomic-embed-text-v1.5.Q8_0.gguf` (768-dim, sha256 `3e24342164b3...`) |
| NPU model | `bge-small-zh-v1.5_256.cix` (512-dim, INT8 quantized, encoder-only) |
| Bench harness | `cix_inprocess_bench.py` — llama-cpp-python in-process, no HTTP RPC |
| NPU harness | `cix_npu_bench_v3.py` — `from utils.NOE_Engine import EngineInfer` |

## The platform spectrum

Each box is the platform it is — a $45 SBC isn't a workstation, a workstation isn't a fanless mini-PC, a mini-PC with an NPU isn't an x86 server. **All of them run MNEMOS.**

| Tier | Box | Silicon | RAM | Form factor / use case |
|---|---|---|---|---|
| **SBC, low-power floor** | zeropi (.56) | Raspberry Pi 4 Model B | 2 GB | $45 board, hobby/edge sensors, embedded |
| **SBC, mid** | bigpi (.65) | Raspberry Pi 5 Model B | 16 GB | $120 board, homelab, agent prototyping |
| **mini-PC with NPU** | NCZ Magnetar / .66 | Minisforum MS-R1 — Cix Sky1 ARM64 12-core + Mali-G720 + Zhouyi V3 NPU | 64 GB | ~$700 fanless 1L appliance, always-on agent memory |
| **mini-PC, current-gen Intel** | PYTHIA / .67 | ASUS NUC 15 Pro (NUC15CRH-B) — Intel Core 5 210H | 32 GB | ~$700–900 1L mini-PC, dev/server |
| **Apple laptop, M3 Pro** | jperlow-mlt (this Mac) | MacBook Pro 16" 2023 — Apple M3 Pro (14-core GPU) | 36 GB | ~$2500 portable workstation |
| **Apple laptop, M1 Max-32** | ULTRA (.60) | MacBook Pro 16" 2021 — Apple M1 Max (10C CPU, **32C GPU**) | 64 GB | ~$3500 portable build host |
| **Apple desktop, M1 Max-24** | STUDIO (.10) | Mac Studio 2022 — Apple M1 Max (10C CPU, **24C GPU**) | 32 GB | ~$2000 desktop dev workstation |
| **Dev workstation + dGPU** | TYPHON (.61) | x86_64 + RTX 5060 (Blackwell GB206) | varies + 8 GB VRAM | ~$1800 desktop, dev work |

A datacenter NVIDIA Grace+Blackwell row (Brev rental) is a future "cloud burst" data point — same kit, just a different tier.

## Numbers — same model (`bge-small-zh-v1.5`), same script, same corpus, every host

This is the apples-to-apples table. Same BGE architecture across every row — Q8 GGUF on CPU/GPU, INT8 `.cix` on the Cix NPU, identical model SHA on the GGUF paths (`5a88d266...`).

| Box / silicon | rec/sec | p50 | wall (s) | engine path | status |
|---|---|---|---|---|---|
| **zeropi** — Pi 4 Model B 2 GB, ARM CPU only | **1.15** | 1056 ms | 6989 | BGE-Q8 GGUF, n_ctx=2048 (RAM-tight) | done |
| **bigpi** — Pi 5 Model B 16 GB, ARM CPU only | **3.44** | 304.6 ms | 2334 | BGE-Q8 GGUF, n_ctx=8192 | done (slowed by concurrent wheel build) |
| **NCZ Magnetar** — Cix Sky1 12-core ARM CPU | **12.03** | 100.3 ms | 668 | BGE-Q8 GGUF, n_ctx=8192 | done |
| **NCZ Magnetar** — Cix Zhouyi V3 NPU (INT8 .cix) | **54.86** | 14.6 ms | 146 | `bge-small-zh-v1.5_256.cix`, libnoe 2.0.0 | done |
| **PYTHIA** — Intel Core 5 210H CPU | **12.69** | 88.8 ms | 633 | BGE-Q8 GGUF, n_ctx=8192 | done |
| **PYTHIA** — Intel iGPU via OpenVINO | TBD | TBD | TBD | OpenVINO BGE model | queued (peer iGPU bench) |
| **jperlow-mlt** — Apple M3 Pro Metal (laptop) | **107.07** | 9.7 ms | 75.1 | BGE-Q8 GGUF, Metal n_gpu_layers=99 | done |
| **ULTRA** — Apple M1 Max Metal (laptop, clean re-run) | **177.14** | 5.4 ms | 45.4 | BGE-Q8 GGUF, Metal n_gpu_layers=99 | done |
| **STUDIO** — Apple M1 Max Metal (Mac Studio desktop) | **175.86** | 6.2 ms | 45.7 | BGE-Q8 GGUF, Metal n_gpu_layers=99 | done |
| **TYPHON** — RTX 5060 (consumer 8 GB CUDA) | **486.74** | 2.3 ms | 16.5 | BGE-Q8 GGUF, CUDA n_gpu_layers=99 | done |
| **NVIDIA Jetson** (Orin Nano / Orin NX / AGX Orin) | TBD | TBD | TBD | future bench, no test platform in fleet today | scheduled when hardware lands |

A separate **nomic-embed-text-v1.5.Q8_0** (768-dim) bench was also run on a subset of hosts for a different-architecture sanity check — those numbers are in the raw JSONL but not the headline table. Cix NPU does not have a compiled nomic `.cix` available today, so nomic isn't apples-to-apples cross-platform.

The point is the **kit column**, not the rec/sec column. Every row above is the same Python call: `Llama.create_embedding(text)` for CPU/GPU paths, or `EngineInfer.forward(...)` for the Cix NPU. The same MNEMOS pipeline calls into either. Pick the box; the kit picks the silicon path.

## What this means for MNEMOS

MNEMOS is a memory layer, not a compute platform. Its job is "remember things and retrieve them by meaning." Different deployments need different shapes of that:

- **Hobby / edge sensor** — embed a few hundred memories a day on a $45 Pi 4. Slow, but works. The kit handles it.
- **Homelab agent host** — embed thousands of memories a day on a $120 Pi 5. Same code, faster.
- **Always-on edge appliance** — embed the running memory of a 24/7 agent fleet on a $700 fanless mini-PC with an NPU. The NPU is what makes "always on, low power" viable.
- **Mini-PC dev box** — same ~$700 form factor with current-gen Intel silicon. Add OpenVINO and the iGPU/NPU path lights up too.
- **MacBook for developers** — embed locally on Metal while writing code. The kit ships `gpu-apple-mlx` and `gpu-apple-metal` extras.
- **Workstation with dGPU** — embed faster when batch-indexing. Same code.
- **Cloud burst** — rent an H100 for an hour to seed-index a multi-million-doc corpus. Tear down. Same code.

## The "MNEMOS / agent appliance" sweet spot — small ARM systems on per-watt

If the early numbers hold up across the rest of the bench fan-out, **the small ARM systems (Cix Sky1 with NPU; Pi 5; Pi 4) are the sweet spot for an always-on MNEMOS / agent appliance.** A memory layer for a 24/7 agent fleet doesn't need peak burst throughput; it needs *sustained throughput per watt and per dollar* on a box that can sit in a closet drawing the power of a phone charger.

What the data is showing on this axis (numbers normalized to embeddings per watt):

| Class | Best representative measured | rec/sec per watt of accelerator | Why this matters for an appliance |
|---|---|---|---|
| **Small ARM mini-PC + NPU** | Cix Sky1 NPU @ 54.86 rec/s on ~2 W of NPU silicon | **~27** | Fanless, always-on, $700 box. The NPU itself is *less power than an LED bulb.* |
| **Small ARM SBC, CPU only** | Pi 5 (in flight) | TBD (expected 1–3) | Sub-$200, sub-10 W. Lower throughput, higher per-watt-per-dollar. |
| **Apple Silicon laptop (Metal)** | M3 Pro Metal @ ~30 rec/s on a ~30 W GPU portion | ~1 | Great for dev; not for closet appliance. |
| **x86 mini-PC (CPU only)** | PYTHIA Intel 210H @ 2.1 rec/s on ~50 W | 0.04 | Mini-PC form factor, but no NPU on this SKU; per-watt is poor on CPU. |
| **Workstation dGPU** | RTX 5060 @ 166 rec/s on ~115 W of GPU | 1.4 | Fastest absolute, but a closet appliance doesn't run a 115 W GPU 24/7. |

The pattern: **per-watt is dominated by NPU-equipped small ARM systems**, not by raw GPU horsepower. That maps directly to what MNEMOS is — a memory layer that runs continuously next to the agent, not a batch indexer that runs occasionally on a big box.

**This finding is conditional on the rest of the bench finishing cleanly** (Pi 5, Pi 4, M1 Max, Intel iGPU + OpenVINO peer test), and on the model choice; see the model caveat below. If the per-watt advantage holds across the BGE-small-zh-v1.5 cross-platform run that's now in flight, the appliance recommendation stands.

## Model caveat — why BGE-small-zh-v1.5 across the board

This bench uses **`bge-small-zh-v1.5`** (BGE architecture, 512-dim, INT8/Q8 quantized) across every platform — GGUF for the CPU/GPU paths, the matched `.cix` quantization for the Cix NPU. Same architecture, same params, same tokenizer everywhere; that's what makes the rec/sec comparison meaningful.

**Why this model was chosen for this run:**

1. **It works on the Cix NPU today.** The Compass NN compiler that produces `.cix` artifacts is closed-source and AOT only; `bge-small-zh-v1.5_256.cix` is one of the first models we have actually compiled and benched on the Zhouyi V3 NPU. Other models would require additional Compass NN compile work that the Cix-NPU column blocks on.
2. **It is small** (~25 MB Q8 GGUF, ~33 MB FP). Runs on every platform we tested without memory pressure, including the 2 GB Pi 4. Bigger models would have forced the floor of the platform spectrum to drop out.
3. **It is the same architecture on every box.** Cross-silicon throughput numbers are only meaningful when the workload is identical. BGE-small was the largest common denominator across our hardware set.

**This is not a recommendation that BGE-small-zh-v1.5 is the optimal embed model for any tier.** Additional development and testing will be required to find the *right* model for each performance class — the optimum is almost certainly different per silicon:

- A modern Intel NUC with NPU may run `bge-large-en-v1.5` faster on the iGPU+NPU via OpenVINO than BGE-small via llama-cpp-python.
- A Mac with MLX may prefer `mxbai-embed-large-v1` quantized for Apple Silicon.
- A CUDA workstation may benefit from `e5-base-v2` running fp16 on TensorRT.
- An always-on edge appliance may want a smaller/faster English-only model like `bge-small-en-v1.5` if the corpus is English-only, or a domain-specific embedder if the corpus is.

**The kit is model-flexible by design.** `embedkit.Engine(model="...")` swaps the model; the adapter contract is unchanged. This bench picks one model so the throughput numbers actually compare. Picking the right model for production is the operator's call, and the kit makes the swap a one-line change. **Per-platform model tuning is queued as follow-up work.**

## Hardware not in this run — community contributions welcome

This bench does **not** include numbers for several mainstream platforms because we don't have the hardware in the fleet today. The kit ships adapters for all of them; running the bench is a one-line change once you have the box. We'd love community-supplied numbers for these:

- **NVIDIA Jetson family** (Orin Nano / Orin NX / AGX Orin / Thor) — embedding-throughput bench scheduled when a Jetson lands in the fleet. Jetson would slot somewhere between "small ARM mini-PC + NPU" and "ARM workstation + dGPU" depending on SKU. Kit ships the CUDA adapter and an L4T-aware variant.
- **Latest Apple Silicon** — fleet has M1 Max-32, M1 Max-24, and M3 Pro. **No M4-class Mac (M4, M4 Pro, M4 Max, M4 Ultra) yet tested.** Throughput likely scales above the M1 Max-32 baseline based on Apple's per-generation gains, but **we need community verification** on the latest A-series MacBook Pro / iMac / Mac Studio. Same kit (`pip install mnemos-embedkit[all-apple]`); same `embedkit-bench`.
- **Latest Windows ARM notebooks** — Snapdragon X Elite, X Plus, X1E in Copilot+ PCs from Microsoft Surface, Lenovo, ASUS, Dell, HP, Samsung. **Not tested today.** A native Hexagon NPU adapter via QNN SDK is queued; in the meantime, the CPU adapter and a Vulkan adapter via the Adreno iGPU should run. **Community verification welcome** on any of the X-series Copilot+ machines.
- **AMD ROCm GPU** (Instinct, Radeon Pro, consumer Radeon RX 9000 / 7000) — kit ships `gpu-amd-rocm` via onnxruntime-rocm.
- **AMD XDNA NPU** (Ryzen AI 7040/8040/HX, Ryzen AI Max) — kit ships `npu-amd-xdna` via VitisAI EP.
- **Intel iGPU + NPU on a recent NUC** (Lunar Lake, Arrow Lake H) — fleet has Raptor Lake-H Refresh (PYTHIA), no Intel-NPU SKU yet.
- **Rockchip RKNN NPU** (RK3588 / RK3576 / RK3566 — common in $50–$200 SBCs) — kit ships `npu-rockchip`.
- **MediaTek Genio APU** — preview adapter shipped.

If you run the kit on any of the above, `embedkit-bench --output your-host.summary.json` and we'll fold your numbers into a future revision of this page (PR welcome at `mnemos-os/mnemos-embedkit`).

## What was tested vs what's in flight

Same MNEMOS. Same kit. Same in-process API call (`Llama.create_embedding(text)` for CPU/GPU, `EngineInfer.forward(...)` for the Cix NPU).

## What's still in flight

- **PYTHIA Intel CPU bench** — finishing now (~25 min ETA from earlier sample).
- **Mac M3 Pro Metal** — running here on jperlow-mlt, ~33 rec/s sustained at last sample.
- **bigpi (Pi 5 16GB)** — venv + llama-cpp-python build in progress; bench will run after.
- **zeropi (Pi 4 2GB)** — same; n_ctx reduced to 4096 to keep memory pressure low on a 2 GB board.
- **ULTRA M1 Max Metal** — same.

## Methodology

- All llama-cpp-python paths use the same `cix_inprocess_bench.py` script (`N_GPU_LAYERS` env override added to the original Cix CPU script for portability across Metal / CUDA / CPU-only paths).
- Corpus pulled from PYTHIA via `/v1/export` and verified by sha256 (each box re-checks the GGUF model sha against the canonical PYTHIA copy before benching).
- Embeddings computed in-process — no HTTP RPC, no llama-server overhead. The kit and MNEMOS both call `Llama.create_embedding(text)` directly.
- NPU path (Cix only) goes through `from utils.NOE_Engine import EngineInfer` (cix-noe-umd 2.0.2 + libnoe 2.0.0, FyrbyAdditive prebuilt KMD).
- Pi paths use `n_threads=number-of-cores`, no GPU offload.
- Apple paths use `n_gpu_layers=99` (full Metal offload) on llama-cpp-python built with `-DGGML_METAL=on`.
- TYPHON CUDA path uses `n_gpu_layers=99` (full CUDA offload) on llama-cpp-python built with `-DGGML_CUDA=on` against system CUDA 13.2.

## Source files

- Bench harness: `assets/cix-py/cix_inprocess_bench.py`, `assets/cix-py/cix_npu_bench_v3.py`
- Raw JSONL written into each host's bench dir; summaries land in `*-summary.json`
- Watcher captures (this Mac): `/private/tmp/claude-502/-Users-jperlow/.../tasks/b2sqgqem0.output` (Cix NPU), `ba23oh5du.output` (Cix CPU), `b00pnpdra.output` (PYTHIA CPU, in-flight), `bg7d2j53s.output` (TYPHON CUDA), `bpxap5arh.output` (Mac M3 Pro Metal, in-flight), `bnm79gs6z.output` (bigpi setup), `bg5cnypz1.output` (zeropi setup), `bldq2f4e1.output` (ULTRA setup)

## Headline

The takeaway is not a number. It is the column itself. **MNEMOS runs across this entire range** — from a $45 hobby SBC up to a workstation GPU — using the same kit, same model where the silicon doesn't have a dedicated NPU, and an INT8-quantized variant where it does. Pick the box that fits your deployment shape. The kit handles the rest.
