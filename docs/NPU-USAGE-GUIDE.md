# Using the CIX Sky1 Zhouyi NPU on NCZ-OS

This covers what the NPU actually is, its real hardware constraint, how
NCZ-OS wires up its Python runtime, and a real worked example. Every claim
here traces to a file in this repo or a measurement taken on real hardware
— nothing here is generic Zhouyi/NOE documentation restated from memory.

## The hard constraint: fixed-shape models only on the NOE/Zhouyi path

The Zhouyi NPU's compiler (NOE — Neural Operator Engine) bakes tensor
input/output shapes into the compiled graph at **compile time**. There is
no dynamic-shape support on this specific hardware path. This is why it
can run something like a text-embedding model (fixed max sequence length,
fixed output dimension) or the vision/audio models in CIX's own model
hub, but not an LLM's variable-length generation loop directly on NOE.

If you're coming from GPU inference where shapes are usually flexible at
runtime, this is the one thing to unlearn: for NOE, the shape is part of
the compiled artifact, not a runtime parameter. **This is a constraint of
the NOE compiler path specifically, not of the SoC's AI capability as a
whole** — see the LLM/VLM section below for how Sky1 actually runs LLMs,
via a different runtime entirely.

## The Python runtime: why a dedicated 3.12 venv is mandatory, not a preference

The NPU's userspace driver ships as two Python wheels — `libnoe` and
`NOE_Engine` (also seen as `noe_engine`, the PEP 427-normalized spelling;
the install hook matches both). These wheels declare
`Requires-Python >=3.11,<3.13`, and `libnoe/__init__.py` hard-raises on
any interpreter outside 3.11/3.12.

Debian forky (the base this project builds on) ships **only** Python 3.14
system-wide — no 3.11 or 3.12 package exists in the archive at all. That
makes a dedicated interpreter mandatory, not an isolation nicety:

```
ERROR: Package 'libnoe' requires a different Python: 3.14.6 not in '<3.13,>=3.11'
```

NCZ-OS's fix (`post-install/88-noe-umd-venv.sh`): use `uv` to install a
standalone CPython 3.12 and build a venv at **`/opt/ncz/noe-venv`**, then
install the wheels into *that* interpreter instead of the system one. A
wrapper is installed at **`/usr/local/bin/ncz-npu-python`** — always use
this instead of calling `python3` directly:

```sh
ncz-npu-python -c "import libnoe, NOE_Engine, numpy; print('NPU userspace OK')"
```

The vendor package's own postinst is rewritten in place (original kept as
`<postinst>.ncz-orig`) so a normal `apt install cix-noe-umd` lands
correctly in the venv instead of failing against the system interpreter.
`cix-noe-umd` is held (`apt-mark hold`) to protect this rewrite from being
clobbered by a routine `apt upgrade`; a `ncz-noe-venv-sync.service`
systemd oneshot re-syncs the venv automatically if the package version
ever changes, so the venv doesn't silently drift out of step with the
installed kernel/userspace driver pair.

**Driver-generation matters — the two sides of the stack must match.** As
of 2026-09-15 the validated pairing is kernel driver (KMD) **6.2.0** with
userspace driver (UMD) **3.1.4** (`3.1.4-cixdeb13-260714`). An older UMD
(2.0.x) against this KMD fails at capability query before it can load any
graph:

```
[UMD ERR] aipu.cpp:57: query capability [fail]
RuntimeError: npu: noe_init_context fail
```

This looks like a kernel or hardware fault. It's neither — it's a version
mismatch between the two driver halves. If you hit this, check
`dpkg -s cix-noe-umd` and confirm the venv actually re-synced
(`systemctl status ncz-noe-venv-sync.service`; the sync script compares
the installed package version against a stamp file and re-installs the
wheels when they differ).

## A real, working example: the MNEMOS embedding server

NCZ-OS ships a real, validated NPU workload: an OpenAI-compatible
`/v1/embeddings` server backed by a NOE-compiled embedding model, used by
MNEMOS (the fleet's memory server) for local, hardware-accelerated
embedding generation instead of calling out to a cloud API.

- **Model**: `nomic-embed-text-v1.5`, compiled to a NOE graph with a fixed
  **256-token** max sequence length — `/opt/ncz/models/nomic-embed-text-v1.5_256.cix`
- **Output**: 768-dimensional vectors
- **Accuracy, measured**: cosine similarity **0.995330** against the
  onnxruntime CPU reference implementation on the same input — validated
  on real O6N hardware, 2026-08-05
- **Throughput, measured**: **8.9 inferences/second** (112ms per call).
  Not fast in absolute terms, but every query runs entirely on-device with
  no network round-trip.
- **Interface**: OpenAI-compatible `/v1/embeddings`, served on
  `127.0.0.1:8081`
- **Service**: `ncz-npu-embed.service` (systemd), installed by
  `post-install/89-npu-embed-server.sh`, runs
  `/opt/ncz/noe-venv/bin/python /usr/local/bin/ncz-npu-embed-server.py`

This service is **shipped disabled by default** on a fresh NCZ-OS
install — it only auto-enables if the compiled `.cix` model file is
actually staged at build time. If you want it running on your box and it
isn't:

```sh
# confirm the model is present
ls -la /opt/ncz/models/nomic-embed-text-v1.5_256.cix

# if present but not running:
sudo systemctl enable --now ncz-npu-embed.service
sudo systemctl status ncz-npu-embed.service

# quick test once it's up
curl http://127.0.0.1:8081/v1/embeddings \
  -H 'Content-Type: application/json' \
  -d '{"input": "test sentence", "model": "nomic-embed-text-v1.5"}'
```

This is the reference pattern for running your own fixed-shape model on
the NPU: compile a model to a `.cix` graph at a fixed input shape, load it
through `NOE_Engine` inside the `/opt/ncz/noe-venv` interpreter, and serve
it however fits your use case (the embed server wraps it in an HTTP API;
a batch script could just call it directly).

## The CIX AI Model Hub

CIX's own model repository and toolkit for their SoCs:

- **Public upstream**: https://github.com/cixtech/ai_model_hub
- **Radxa's own docs for this on the O6 board**: https://docs.radxa.com/en/orion/o6/app-development/artificial-intelligence/ai-hub
- **Staged copy**: ARGONAS `/mnt/datapool/projects/cix-ai-model-hub/latest/` (and a dated `25_Q3/` snapshot)

Directory layout:

```
ai_model_hub/
├── models/
│   ├── Audio/            # Speech_Recognition, Speaker_Verification, TTS
│   ├── ComputeVision/    # Object_Detection, OCR, Face_Recognition/Detection,
│   │                     # Pose_Estimation, Semantic_Segmentation, Depth_Estimation,
│   │                     # Super_Resolution, Lane_Detection, BEV, Body_Analysis, ...
│   ├── Generative_AI/    # Text_Image_Search, Image_to_Text, Text_to_Image, LLM
│   └── MultiModal/       # VLM
├── demos/                # Gradio/Streamlit demo .deb packages
├── datasets/             # ImageNet/COCO/VOC download+prep scripts
├── utils/                # shared postprocessing/eval/plotting
├── scripts/              # LLM/VLM build, quantization, eval scripts
├── LLM_README.md         # the LLM/VLM-specific workflow (see below)
├── README.md / README_EN.md
├── ReleaseNote.md, EULA.md, LICENSE (Apache-2.0 for the hub itself;
│                                      EULA.md governs the models/software)
```

**Each non-LLM model directory follows the pattern this guide already
described**: `inference_npu.py` runs the compiled `.cix` binary on the
real Zhouyi NOE hardware path (fixed input/output shape, exactly the
constraint above); `inference_onnx.py` runs the same model via ONNX
Runtime on host or device for comparison. Demos install as ordinary
`.deb` packages (e.g. `sudo dpkg -i ai-demo-manager_1.0.6_arm64.deb`,
landing under `/opt/<demo-name>/`).

### LLM/VLM inference

LLM/VLM inference on Sky1 does not go through the NOE/Zhouyi NPU compiler
path — the fixed-shape limitation above applies to NOE specifically. LLMs
run via a separate, CPU/GPU-based runtime that CIX ships prebuilt on the
device:

- **`llama.cpp`**, CIX SoC-hardware-optimized build, already installed at
  **`/usr/share/cix/bin/llama-cli`**
- **`MNN`**, already installed at **`/usr/share/cix/bin/mnn/llm_demo`**,
  with a CPU backend and a GPU (OpenCL) backend

The real workflow (from `LLM_README.md`, confirmed against the staged
copy):

**On an x86 host** (build tools, convert, quantize):
```sh
# build llama.cpp per scripts/llm-gen/build_tools.sh in the model hub repo
cd llama.cpp
pip install -r requirements.txt
python3 convert_hf_to_gguf.py <MODEL_DIR>
./build/bin/llama-quantize <MODEL_DIR>/<F16_GGUF> <MODEL_ID>-Q4_0.gguf Q4_0
scp <MODEL_ID>-Q4_0.gguf user@board:/path/to/models/
```

**On the edge device** (real inference, real benchmarking):
```sh
taskset -c 0,5,6,7,8,9,10,11 llama-cli -m <MODEL_ID>-Q4_0.gguf -c 4096 -t 8 --conversation
taskset -c 0,5,6,7,8,9,10,11 llama-bench -m <MODEL_ID>-Q4_0.gguf -pg 128,128 -t 8
```

MNN follows the same host-converts/device-runs shape, with its own
export/quantize step (`llmexport.py --export mnn --quant_bit 4`) and a
GPU-backed path — set `"backend_type": "OpenCL"` in the exported
`config.json` to run on-device GPU instead of CPU:
```sh
taskset -c 0,9,10,11 /usr/share/cix/bin/mnn/llm_demo <MODEL_ID>-mnn/config.json prompt.txt
```

So: an LLM cannot run on the NOE/Zhouyi hardware path (fixed-shape), but
it runs on the same board via `llama.cpp`/`MNN` on CPU or the GPU's
OpenCL backend, both shipped prebuilt by CIX. "The NPU" (NOE) and "the
SoC's AI capability" (NOE + CPU + GPU, each suited to different model
classes) are not the same thing.

## Quick reference

| What | Where |
|---|---|
| NPU-capable Python interpreter | `/opt/ncz/noe-venv/bin/python`, or the wrapper `ncz-npu-python` |
| Runtime install hook (source) | `post-install/88-noe-umd-venv.sh` |
| Embedding server hook (source) | `post-install/89-npu-embed-server.sh` |
| Validated driver pairing (2026-09-15) | KMD 6.2.0 + UMD 3.1.4 (`3.1.4-cixdeb13-260714`) |
| Kernel device node | `/dev/aipu` (independent of the Python stack — the kernel driver and device work even if the venv is broken; you only lose Python-level inference) |
| Reference embedding model | `/opt/ncz/models/nomic-embed-text-v1.5_256.cix` (256-token fixed shape, 768-dim output) |
| Reference service | `ncz-npu-embed.service` → `127.0.0.1:8081/v1/embeddings` |
| CIX AI Model Hub (public upstream) | https://github.com/cixtech/ai_model_hub |
| CIX AI Model Hub (Radxa O6 docs) | https://docs.radxa.com/en/orion/o6/app-development/artificial-intelligence/ai-hub |
| CIX AI Model Hub (staged copy) | ARGONAS `/mnt/datapool/projects/cix-ai-model-hub/latest/` |
| CIX-optimized llama.cpp (on-device, prebuilt) | `/usr/share/cix/bin/llama-cli` |
| CIX-optimized MNN (on-device, prebuilt) | `/usr/share/cix/bin/mnn/llm_demo` |
