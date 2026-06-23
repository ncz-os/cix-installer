# Codebase audit: OpenVINO + AMD XDNA vs Compass_NPU_Driver, with EP focus

**Status:** DRAFT 2026-05-07. Codex sandbox could not write or fetch (read-only filesystem + no network), so this captures Codex's verbal verdict from web reads + local Cix wrapper inspection. A deeper second pass with full repo access is a follow-up task.

---

## Verdict (one paragraph)

A **general VitisAI-style ONNX Runtime EP for Cix Sky1 NPU is NOT feasible from public Compass pieces alone today.** The blocker is that VitisAI's EP works because AMD exposes the graph compile/cache path used by `compile_onnx_model()` — i.e. AMD ships the ONNX-subgraph-to-device compilation step open-source. Public Cix exposes parser pieces (`Compass_Unified_Parser`) plus driver and runtime (`Compass_NPU_Driver`), but **not** a stable ONNX-subgraph → `.cix` compile API. The Compass NN compiler that produces `.cix` blobs is closed-source AOT-only.

That said, a **useful first EP IS feasible** as a "precompiled .cix whole-graph" EP: an ONNX facade that loads a `.cix` blob (pre-compiled offline by Compass NN), maps ORT tensor inputs to `noe_load_tensor()`, calls `noe_job_infer_sync()`, and copies output via `noe_get_tensor()`. Restrictive (caller must pre-compile every model with closed-source Compass NN), but enough to wire the entire HuggingFace `transformers` / `sentence-transformers` / `optimum` ecosystem to Sky1 NPU for any model that has a corresponding `.cix` artifact.

**Recommended first move:** a **precompiled `bge-small-zh_256.cix` EP demo**, not a scaffold-only EP. It directly tests the thesis end-to-end and exposes the real ABI, tensor descriptor, and persistent-job issues we already hit on .66 tonight.

---

## Primary sources used (Codex web reads)

- ONNX Runtime EP base: https://github.com/microsoft/onnxruntime/blob/main/include/onnxruntime/core/framework/execution_provider.h
- ORT default EP implementation: https://github.com/microsoft/onnxruntime/blob/main/onnxruntime/core/framework/execution_provider.cc
- ORT plugin EP docs: https://onnxruntime.ai/docs/execution-providers/plugin-ep-libraries.html
- AMD VitisAI EP source: https://github.com/microsoft/onnxruntime/tree/main/onnxruntime/core/providers/vitisai
- AMD VitisAI EP docs: https://onnxruntime.ai/docs/execution-providers/Vitis-AI-ExecutionProvider.html
- OpenVINO EP docs: https://onnxruntime.ai/docs/execution-providers/OpenVINO-ExecutionProvider.html
- AMD XDNA driver: https://github.com/amd/xdna-driver
- Compass NPU Driver: https://github.com/Arm-China/Compass_NPU_Driver
- Compass Unified Parser: https://github.com/Arm-China/Compass_Unified_Parser

---

## Open follow-ups for a deeper audit

1. **Verify the closed-source bottleneck.** Confirm by reading `Compass_Unified_Parser` end-to-end whether there's any path to emit a `.cix` blob from open code, or whether the parser only produces an intermediate IR that requires the closed Compass NN compiler to lower to `.cix`. If the parser CAN produce `.cix`, the EP could JIT-compile arbitrary ONNX subgraphs (full VitisAI-style).

2. **Compare AMD XDNA driver public surface to Compass_NPU_Driver.** Both Apache-2.0; both target mobile-SoC NPU; both pair AOT compiler + runtime. Where AMD made specific design choices (async InferRequest queue, dynamic shapes, tensor allocator integration) that Compass hasn't yet, that's a contribution-opportunity list.

3. **Quantify the `.cix`-only EP MVP.** What's the smallest first PR that compiles + runs `bge-small-zh_256.cix` from a stock onnxruntime caller? Mirror VitisAI EP's file layout. Effort estimate, risk register.

These are deferred to a re-run with full repo access.

---

*Skeleton committed; full text pending re-run with non-sandboxed Codex.*
