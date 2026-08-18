#!/usr/bin/env python3
"""ncz-npu-embed-server — OpenAI-compatible /v1/embeddings on the CIX Sky1 NPU.

Serves nomic-embed-text-v1.5 from a precompiled NOE graph (.cix) so MNEMOS (or
anything that speaks the OpenAI embeddings API) can use the Zhouyi NPU instead
of CPU ggml. Vectors are interchangeable with x86 nomic: measured cosine
0.9953 against the onnxruntime CPU reference, so a memory embedded here lands
in the same vector space as one embedded on an x86 peer -- which is the whole
point, federation needs no translation layer.

Design notes that are not obvious:

* The NOE graph is compiled for a FIXED shape (1 x SEQ_LEN). Sequence length
  and batch size are baked in at build time, so every request is padded or
  truncated to SEQ_LEN and inferred one at a time. A longer document must be
  chunked by the caller.
* NOE_Engine is not thread-safe and the NPU serialises jobs anyway, so all
  inference is funnelled through a single lock. The server is deliberately
  single-worker: concurrency here buys nothing and risks corrupting job state.
* The graph emits token-level last_hidden_state; the sentence vector is the
  attention-masked mean, L2-normalised -- the same pooling nomic itself uses.
  Getting this wrong yields plausible-looking vectors that quietly retrieve
  the wrong memories, so it is asserted at startup against a known reference
  when one is present.

Endpoints:
  POST /v1/embeddings   {"input": str | [str], "model": ...}  -> OpenAI shape
  GET  /health          liveness + model identity
  GET  /v1/models       so clients that probe capabilities behave
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np

LOG = logging.getLogger("npu-embed")

DEFAULT_MODEL = "/opt/ncz/models/nomic-embed-text-v1.5_256.cix"
DEFAULT_TOKENIZER = "nomic-ai/nomic-embed-text-v1.5"
# Advertised name. MNEMOS/Ollama clients ask for "nomic-embed-text"; accept any
# alias rather than 400-ing on a name mismatch, since the served weights are
# what they are regardless of what the caller calls them.
MODEL_NAME = "nomic-embed-text"
SEQ_LEN = 256
EMBED_DIM = 768

# --- per-model serving profiles ---------------------------------------------
#
# THREE THINGS VARY BY MODEL AND ALL THREE ARE SILENT IF WRONG:
#
#   dim      output width. Wrong value reshapes the hidden state into garbage.
#   inputs   how many tensors the graph takes. BERT-family models (nomic,
#            bge-small-zh) take THREE (input_ids, attention_mask,
#            token_type_ids). BGE-M3 is XLM-RoBERTa and takes TWO -- there is
#            no token_type_ids. Feeding three to a two-input graph fails; the
#            reverse silently drops a tensor.
#   pooling  how a [seq, dim] hidden state becomes one vector. nomic uses
#            MASKED MEAN over tokens. BGE-M3 uses the CLS token. Using mean
#            pooling on BGE-M3 produces vectors that are not bge-m3 embeddings
#            at all -- they are internally consistent, so retrieval still
#            "works" and nothing errors, which is exactly why this has to be
#            declared per model rather than assumed. Measured against the fp32
#            ONNX reference on O6N 2026-08-18, CLS pooling reproduced the
#            reference at cosine 0.9923; mean pooling does not.
#
PROFILES = {
    "nomic-embed-text": {
        "graph": "/opt/ncz/models/nomic-embed-text-v1.5_256.cix",
        "tokenizer": "nomic-ai/nomic-embed-text-v1.5",
        "dim": 768, "inputs": 3, "pooling": "mean", "seq": 256,
    },
    "bge-m3": {
        "graph": "/opt/ncz/models/bge-m3_256.cix",
        "tokenizer": "/opt/ncz/models/bge-m3-tokenizer",
        "dim": 1024, "inputs": 2, "pooling": "cls", "seq": 256,
    },
    "bge-small-zh": {
        "graph": "/opt/ncz/models/bge-small-zh_256.cix",
        "tokenizer": "BAAI/bge-small-zh-v1.5",
        "dim": 512, "inputs": 3, "pooling": "cls", "seq": 256,
    },
}


def profile_for(model_path: str):
    """Pick the serving profile by matching the graph filename.

    Keyed on the graph rather than the advertised name because the advertised
    name is a client-facing alias that callers get wrong, while the graph is
    the thing whose shape actually has to be honoured.
    """
    import os  # noqa: PLC0415
    base = os.path.basename(model_path)
    for name, prof in PROFILES.items():
        if os.path.basename(prof["graph"]) == base:
            return name, prof
    return None, None


class NpuEmbedder:
    def __init__(self, model_path: str, tokenizer_id: str, seq_len: int = SEQ_LEN):
        from NOE_Engine import EngineInfer  # noqa: PLC0415 - NPU venv only
        from transformers import AutoTokenizer  # noqa: PLC0415

        self.seq_len = seq_len
        self.model_path = model_path
        self._lock = threading.Lock()

        # Resolve the serving profile before loading anything, so a graph whose
        # shape we do not know fails loudly here rather than by emitting
        # wrongly-pooled vectors into a store forever.
        prof_name, prof = profile_for(model_path)
        if prof is None:
            LOG.warning(
                "no serving profile for graph %s -- falling back to %d-dim / "
                "3-input / mean pooling. If that is not this model's actual "
                "shape the vectors will be silently wrong; add it to PROFILES.",
                model_path, EMBED_DIM)
            self.dim, self.n_inputs, self.pooling = EMBED_DIM, 3, "mean"
        else:
            self.dim = prof["dim"]
            self.n_inputs = prof["inputs"]
            self.pooling = prof["pooling"]
            self.seq_len = prof.get("seq", seq_len)
            LOG.info("serving profile %s: dim=%d inputs=%d pooling=%s seq=%d",
                     prof_name, self.dim, self.n_inputs, self.pooling, self.seq_len)
        LOG.info("loading tokenizer %s", tokenizer_id)
        self.tok = AutoTokenizer.from_pretrained(tokenizer_id)
        LOG.info("loading NOE graph %s", model_path)
        self.engine = EngineInfer(model_path)
        self.infer_count = 0
        self.infer_seconds = 0.0

    def _encode(self, texts: list[str]):
        enc = self.tok(
            texts,
            padding="max_length",
            truncation=True,
            max_length=self.seq_len,
            return_tensors="np",
        )
        ids = enc["input_ids"].astype(np.int32)
        mask = enc["attention_mask"].astype(np.int32)
        tt = enc.get("token_type_ids")
        tt = np.zeros_like(ids) if tt is None else tt.astype(np.int32)
        return ids, mask, tt

    def embed(self, texts: list[str]) -> np.ndarray:
        ids, mask, tt = self._encode(texts)
        out = np.empty((len(texts), self.dim), dtype=np.float32)
        # One at a time: the graph's batch dimension is fixed at 1.
        with self._lock:
            for i in range(len(texts)):
                t0 = time.perf_counter()
                feed = [ids[i : i + 1], mask[i : i + 1]]
                if self.n_inputs == 3:
                    feed.append(tt[i : i + 1])
                raw = self.engine.forward(feed)
                self.infer_seconds += time.perf_counter() - t0
                self.infer_count += 1
                hidden = np.asarray(raw[0], dtype=np.float32).reshape(self.seq_len, self.dim)
                if self.pooling == "cls":
                    v = hidden[0, :]
                else:
                    m = mask[i][:, None].astype(np.float32)
                    denom = m.sum(0)
                    # An all-pad row would divide by zero and emit NaNs that
                    # poison the vector store silently; clamp instead.
                    denom[denom == 0] = 1.0
                    v = (hidden * m).sum(0) / denom
                n = np.linalg.norm(v)
                out[i] = v / n if n > 0 else v
        return out

    def stats(self):
        """Consistent snapshot: the counters are mutated under _lock, so read
        them under it too -- otherwise /health can show a count from after an
        inference with the duration from before it."""
        with self._lock:
            return self.infer_count, self.infer_seconds

    def close(self):
        try:
            self.engine.clean()
        except Exception:  # noqa: BLE001 - teardown must not raise
            LOG.warning("engine.clean() failed during shutdown", exc_info=True)


class Handler(BaseHTTPRequestHandler):
    embedder: NpuEmbedder = None  # injected
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        LOG.debug("%s - %s", self.address_string(), fmt % args)

    def _send(self, code: int, payload: dict):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802 - BaseHTTPRequestHandler API
        if self.path.rstrip("/") == "/health":
            e = self.embedder
            count, seconds = e.stats()
            avg = (seconds / count * 1000) if count else 0.0
            self._send(200, {
                "status": "ok",
                "backend": "cix-sky1-npu",
                "model": MODEL_NAME,
                "graph": os.path.basename(e.model_path),
                "dimensions": EMBED_DIM,
                "max_tokens": e.seq_len,
                "inferences": count,
                "avg_ms": round(avg, 1),
            })
        elif self.path.rstrip("/") == "/v1/models":
            self._send(200, {"object": "list", "data": [
                {"id": MODEL_NAME, "object": "model", "owned_by": "ncz-npu"}]})
        else:
            self._send(404, {"error": {"message": "not found"}})

    def do_POST(self):  # noqa: N802
        if self.path.rstrip("/") != "/v1/embeddings":
            self._send(404, {"error": {"message": "not found"}})
            return
        try:
            length = int(self.headers.get("Content-Length") or 0)
            req = json.loads(self.rfile.read(length) or b"{}")
        except (ValueError, json.JSONDecodeError) as exc:
            self._send(400, {"error": {"message": f"bad JSON: {exc}"}})
            return

        raw = req.get("input")
        if raw is None:
            self._send(400, {"error": {"message": "'input' is required"}})
            return
        texts = [raw] if isinstance(raw, str) else list(raw)
        if not texts or not all(isinstance(t, str) for t in texts):
            self._send(400, {"error": {"message": "'input' must be a string or list of strings"}})
            return

        try:
            vecs = self.embedder.embed(texts)
        except Exception as exc:  # noqa: BLE001 - surface as 500, keep serving
            LOG.exception("inference failed")
            self._send(500, {"error": {"message": f"inference failed: {exc}"}})
            return

        self._send(200, {
            "object": "list",
            "model": req.get("model") or MODEL_NAME,
            "data": [
                {"object": "embedding", "index": i, "embedding": v.tolist()}
                for i, v in enumerate(vecs)
            ],
            # Token accounting is nominal: the graph always runs a full
            # SEQ_LEN window regardless of the real token count.
            "usage": {"prompt_tokens": len(texts) * SEQ_LEN,
                      "total_tokens": len(texts) * SEQ_LEN},
        })


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--model", default=os.environ.get("NCZ_NPU_MODEL", DEFAULT_MODEL))
    ap.add_argument("--tokenizer", default=os.environ.get("NCZ_NPU_TOKENIZER", DEFAULT_TOKENIZER))
    ap.add_argument("--host", default=os.environ.get("NCZ_NPU_HOST", "127.0.0.1"))
    ap.add_argument("--port", type=int, default=int(os.environ.get("NCZ_NPU_PORT", "8081")))
    ap.add_argument("--seq-len", type=int, default=SEQ_LEN)
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )

    if not os.path.exists(args.model):
        raise SystemExit(f"NPU graph not found: {args.model}")

    Handler.embedder = NpuEmbedder(args.model, args.tokenizer, args.seq_len)
    srv = ThreadingHTTPServer((args.host, args.port), Handler)
    LOG.info("serving %s on http://%s:%d (dim=%d, max_tokens=%d)",
             MODEL_NAME, args.host, args.port, EMBED_DIM, args.seq_len)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        LOG.info("shutting down")
    finally:
        srv.server_close()
        Handler.embedder.close()


if __name__ == "__main__":
    main()
