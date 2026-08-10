# mnemos-npu-embed — NPU embeddings for MNEMOS that preserve the vector space

OpenAI-compatible `/v1/embeddings` served from a precompiled NOE graph on the
Zhouyi V3 NPU, so MNEMOS can offload embedding to the NPU **without changing
which vector space its memories live in**.

Captured from the O6N (192.168.207.3) on 2026-08-10, where it had been
hand-installed on 2026-08-05 and existed nowhere else.

## The invariant

nomic-embed-text-v1.5 at **768 dimensions** — exactly what the stock MNEMOS
image embeds with in-process. Same model, same width, so switching to it is a
drop-in: no migration, no re-embedding, and the host still federates with x86
peers. Measured cosine **0.9953** against the onnxruntime CPU reference, so a
memory embedded here lands in the same space as one embedded on an x86 peer.

That invariant is load-bearing and must be checked, never assumed. MNEMOS
stores vectors in a fixed-width column; an embedder of a different width does
not fail loudly, it just stops retrieving everything written before the switch.
`ncz_npu_embedder_ready()` in `post-install/46-ncz-cli.sh` therefore refuses to
wire MNEMOS to this service unless a live request returns exactly 768 floats,
and falls back to the CPU embedder with a printed reason otherwise.

## Cost

* ~1 GB RSS resident once the graph is loaded
* 522 MB for the graph (378 MB compressed in `ncz-model-nomic-embed`)

The interpreter costs nothing extra: this runs on `/opt/ncz/embed-venv`, the
Python 3.11 venv `47-embedkit.sh` already builds for the NPU (libnoe and
NOE_Engine ship cp311/cp312 extensions only, so 3.11 is mandatory, not a
preference). It is deliberately NOT a second private venv -- an earlier revision
pointed at `/opt/ncz/noe-venv`, a path nothing on the image ever creates, so the
unit could not start on a fresh install.

The unit is `ConditionPathExists=/dev/aipu` **and**
`ConditionPathExists=/opt/ncz/embed-venv/bin/python`, so it cannot restart-loop
on a board without an NPU, nor on an image where the embedkit hook never ran.

## Wiring

`ncz install mnemos` calls `ncz_npu_embedder_ready()`, and on success writes
into the MNEMOS quadlet **before first start**, so MNEMOS never embeds a memory
on CPU and then switches mid-database:

```
MNEMOS_EMBED_BACKEND=http
MNEMOS_EMBED_HTTP_URL=http://127.0.0.1:8081/v1/embeddings
MNEMOS_EMBED_HTTP_MODEL=nomic-embed-text
MNEMOS_EMBEDDING_DIM=768
```

Taken from MNEMOS's own `mnemos/core/config.py`. Two traps live there:
`MNEMOS_EMBED_HTTP_URL` wants the full `/v1/embeddings` path rather than a base
URL, and the width key is `MNEMOS_EMBEDDING_DIM` — `MNEMOS_DATABASE_EMBEDDING_DIM`
is not read by MNEMOS and surfaces later as a vector cast error. The quadlet is
`Network=host`, so `127.0.0.1` reaches the host service.

## Files

* `ncz-npu-embed-server.py` — the server (768-dim, single-worker; NOE_Engine is
  not thread-safe and the NPU serialises jobs anyway)
* `ncz-npu-embed.service` — systemd unit, gated on `/dev/aipu`
* `ncz-npu-python` — interpreter shim; the system python is too new for the
  cix-noe-umd wheels, which pin `>=3.11,<3.13`
