# Using the CIX Sky1 Zhouyi NPU on NCZ-OS

This covers what the NPU actually is, its real hardware constraint, how
NCZ-OS wires up its Python runtime, and a real worked example. Every claim
here traces to a file in this repo or a measurement taken on real hardware
— nothing here is generic Zhouyi/NOE documentation restated from memory.

## The hard constraint: fixed-shape models only, not LLMs

The Zhouyi NPU's compiler (NOE — Neural Operator Engine) bakes tensor
input/output shapes into the compiled graph at **compile time**. There is
no dynamic-shape support. This is why it can run something like a
text-embedding model (fixed max sequence length, fixed output dimension)
but cannot run an LLM (variable-length input, variable-length generation —
the exact case NOE's ahead-of-time compilation model doesn't support).

If you're coming from GPU inference where shapes are usually flexible at
runtime, this is the one thing to unlearn: for the NPU, the shape is part
of the compiled artifact, not a runtime parameter.

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

## "The CIX model hub"

If you've been pointed at "the CIX model hub" for getting models onto the
NPU and are stuck — **we could not find any reference to this in this
repository, in MNEMOS, or on live NCZ-OS systems.** It may be a real,
separate CIX vendor tool or portal that exists outside what this project
tracks, but we can't confirm what it is or how it's meant to be used from
what's documented here. If you have a link or more context on what it
actually is, that would help close this gap for real rather than guessing
at it.

What we *can* confirm works, end to end, on real hardware, is the path
above: compile your model to a fixed-shape `.cix` graph (via CIX's NOE
compiler toolchain — the compilation step itself is not covered by this
guide, only the runtime side that NCZ-OS packages), place it under
`/opt/ncz/models/`, and load it through `NOE_Engine` inside
`/opt/ncz/noe-venv`.

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
