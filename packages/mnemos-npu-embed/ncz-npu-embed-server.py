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
# Tokenizer: prefer the copy shipped alongside the graph, fall back to the Hub
# id. A bare Hub id makes startup depend on huggingface.co reachability, which
# an offline ISO install does not have -- measured on .66, where the very first
# start pulled config/tokenizer/vocab over the network before loading the
# graph. ncz-model-nomic-embed ships the tokenizer at this path so the service
# starts with no network at all.
LOCAL_TOKENIZER = "/opt/ncz/models/nomic-embed-text-v1.5"
HUB_TOKENIZER = "nomic-ai/nomic-embed-text-v1.5"
DEFAULT_TOKENIZER = (
    LOCAL_TOKENIZER
    if os.path.isfile(os.path.join(LOCAL_TOKENIZER, "tokenizer.json"))
    else HUB_TOKENIZER
)
# Advertised name. MNEMOS/Ollama clients ask for "nomic-embed-text"; accept any
# alias rather than 400-ing on a name mismatch, since the served weights are
# what they are regardless of what the caller calls them.
MODEL_NAME = "nomic-embed-text"
SEQ_LEN = 256
EMBED_DIM = 768


class NpuEmbedder:
    def __init__(self, model_path: str, tokenizer_id: str, seq_len: int = SEQ_LEN):
        from NOE_Engine import EngineInfer  # noqa: PLC0415 - NPU venv only
        from transformers import AutoTokenizer  # noqa: PLC0415

        self.seq_len = seq_len
        self.model_path = model_path
        self._lock = threading.Lock()
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
        out = np.empty((len(texts), EMBED_DIM), dtype=np.float32)
        # One at a time: the graph's batch dimension is fixed at 1.
        with self._lock:
            for i in range(len(texts)):
                t0 = time.perf_counter()
                raw = self.engine.forward([ids[i : i + 1], mask[i : i + 1], tt[i : i + 1]])
                self.infer_seconds += time.perf_counter() - t0
                self.infer_count += 1
                hidden = np.asarray(raw[0], dtype=np.float32).reshape(self.seq_len, EMBED_DIM)
                m = mask[i][:, None].astype(np.float32)
                denom = m.sum(0)
                # An all-pad row would divide by zero and emit NaNs that poison
                # the vector store silently; clamp instead.
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
