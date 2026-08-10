# mnemos-npu-embed — NPU embeddings for MNEMOS that preserve the vector space

OpenAI-compatible `/v1/embeddings` served from a precompiled NOE graph on the
Zhouyi V3 NPU, so MNEMOS can offload embedding to the NPU **without changing
which vector space its memories live in**.

Captured from the O6N (192.168.207.3) on 2026-08-10, where it had been
hand-installed on 2026-08-05 and existed nowhere else. It is checked in here so
it stops being stranded on one board; it is **not** yet wired into any install
path (see "Open decision" below).

## Why this exists alongside `mnemos-cix-integration`

The two are not interchangeable, and picking the wrong one silently corrupts
retrieval:

| | `mnemos-cix-integration` | this |
|---|---|---|
| model | all-MiniLM-L6-v2 | nomic-embed-text-v1.5 |
| dimensions | **384** | **768** |
| port | 8000 | 8081 |
| unit | `cix-npu-embedder.service` | `ncz-npu-embed.service` |
| graph | `minilm_128.cix` | `nomic-embed-text-v1.5_256.cix` (522 MB) |

MNEMOS's own in-process embedder is nomic-embed-text-v1.5 at 768 dimensions.
`ncz install mnemos` currently prints a note telling the operator to
`apt install mnemos-cix-integration` and repoint MNEMOS at it — which swaps
both the model AND the dimensionality underneath an existing database. Memories
written before the switch are not merely less accurate, they are in a different
space and a different width, so they stop being retrievable, and the host no
longer federates with x86 peers.

This server exists to make the NPU offload safe: measured cosine **0.9953**
against the onnxruntime CPU reference, i.e. a memory embedded here lands in the
same space as one embedded on an x86 peer, so federation needs no translation
layer.

## Cost, which is why it must stay optional

* ~1 GB RSS resident once the graph is loaded
* 522 MB for the graph, plus a ~237 MB Python 3.11 venv (`/opt/ncz/noe-venv`)

Nothing in the shipped ISO enables it. `47-embedkit.sh` and `47-llm-stack.sh`
stage artifacts only and register no unit; the image carries the 101 MB
bge-small models, not the nomic graph. The unit here is
`ConditionPathExists=/dev/aipu` so it cannot restart-loop on a board without an
NPU, but it is `WantedBy=multi-user.target` and must only be enabled by an
explicit MNEMOS install step, never by a desktop hook.

## Open decision before this can be wired into `ncz install mnemos`

The 522 MB graph does not fit the ISO's current budget (the whole models
payload today is 101 MB). Either:

1. ship the graph in the ISO and accept ~+520 MB, or
2. fetch it at `ncz install mnemos` time from the dist mirror, which makes the
   NPU path network-dependent while MNEMOS itself installs offline from a
   bundled container image.

That is a sizing/product call, not an implementation detail, so it is left
open rather than guessed at.

## Files

* `ncz-npu-embed-server.py` — the server (768-dim, single-worker; NOE_Engine is
  not thread-safe and the NPU serialises jobs anyway)
* `ncz-npu-embed.service` — systemd unit, gated on `/dev/aipu`
* `ncz-npu-python` — interpreter shim; the system python is too new for the
  cix-noe-umd wheels, which pin `>=3.11,<3.13`
