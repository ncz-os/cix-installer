# Models bundled in NCZ ISOs

This directory ships at /opt/ncz/models/ on the installed system. Models
listed below are loaded by mnemos-embedkit's adapters at runtime; the
NPU adapter uses the .cix variant, the CPU/GPU fallback adapters use
the GGUF.

| File | Provenance | Adapter | License |
|---|---|---|---|
| `bge-small-zh-v1.5_256.cix` | Cix ai_model_hub_25_Q3 (Compass NN AOT-compiled, INT8) | `npu-cix` | MIT (BAAI/bge-small-zh-v1.5 weights, Cix Compass artifact) |
| `bge-small-zh-v1.5-q8_0.gguf` | CompendiumLabs/bge-small-zh-v1.5-gguf (community GGUF conversion) | `cpu-llamacpp`, `gpu-vulkan` | MIT |

The `.cix` model lives at task #99 (pull from cixtech/ai_model_hub_25_Q3
LFS) — not yet in this directory. The .gguf lives here today.

To add the .cix at bake time, `99-pull-models.sh` (TBD) clones the
ai_model_hub_25_Q3 LFS subset and copies the `.cix` artifacts into this
directory.
