"""NPU embedder v2 — adds content-hash embedding cache + tokenization cache.

Drop-in replacement for npu_embed.py with the same NPUEmbedder API plus:
- self.embed() now checks SHA256(text)→vec cache before calling NPU
- _tokenize() uses functools.lru_cache for repeated text
- Stats counters expose hit-rate

Backward compatible: NPUEmbedder.embed(text) still returns np.ndarray L2-normalized.
"""
from __future__ import annotations

import ctypes
import hashlib
import os
from ctypes import c_int, c_int32, c_uint32, c_uint64, c_float, c_void_p, c_char_p, POINTER, byref, Structure
from functools import lru_cache
from typing import Dict

import numpy as np


class context_handler_t(Structure):
    _fields_ = [("handle", c_uint32)]

class graph_config_npu_t(Structure):
    _fields_ = [("opaque", ctypes.c_uint8 * 256)]

class graph_config_t(Structure):
    _fields_ = [("conf_g_npu", POINTER(graph_config_npu_t))]

class job_config_npu_t(Structure):
    _fields_ = [("opaque", ctypes.c_uint8 * 256)]

class job_config_t(Structure):
    _fields_ = [("conf_j_npu", POINTER(job_config_npu_t))]

class tensor_desc_t(Structure):
    _fields_ = [
        ("id",         c_uint32),
        ("size",       c_uint32),
        ("scale",      c_float),
        ("zero_point", c_int32),
        ("data_type",  c_int),
    ]

NOE_TENSOR_TYPE_INPUT = 0
NOE_TENSOR_TYPE_OUTPUT = 1


class NPUEmbedder:
    def __init__(self, model_path, lib_path="libnoe.so", tokenizer_path=None, max_len=256,
                 cache_size: int = 100_000):
        self.max_len = max_len
        self.cache_size = cache_size
        self._cache: Dict[str, np.ndarray] = {}
        self.cache_hits = 0
        self.cache_misses = 0

        self.lib = ctypes.CDLL(lib_path, mode=ctypes.RTLD_GLOBAL)
        self._bind()

        if tokenizer_path is None:
            raise ValueError("tokenizer_path required")
        from transformers import AutoTokenizer
        self.tok = AutoTokenizer.from_pretrained(tokenizer_path)

        self.ctx = POINTER(context_handler_t)()
        self._chk(self.lib.noe_init_context(byref(self.ctx)), "init_context")

        gn = graph_config_npu_t()
        gc = graph_config_t(conf_g_npu=ctypes.pointer(gn))
        self.graph_id = c_uint64(0)
        self._chk(self.lib.noe_load_graph(self.ctx, model_path.encode(),
                                           byref(self.graph_id), byref(gc)),
                  "load_graph")

        d = tensor_desc_t()
        self._chk(self.lib.noe_get_tensor_descriptor(
                    self.ctx, self.graph_id, NOE_TENSOR_TYPE_OUTPUT, 1, byref(d)),
                  "get_pooled_desc")
        self.scale = d.scale if d.scale != 0 else 1.0
        self.zero_point = d.zero_point
        self.pooled_size = d.size
        # Cix NoE tensor data_type values (from libnoe headers):
        #   2 = int8, 4 = uint8, 5 = int16, 7 = float32
        # Reject unknown values explicitly rather than defaulting to int8 —
        # a hidden mismatch would let noe_get_tensor write past the numpy
        # buffer (Codex r75 review HIGH).
        _DTYPE_MAP = {2: np.int8, 4: np.uint8, 5: np.int16, 7: np.float32}
        if d.data_type not in _DTYPE_MAP:
            raise ValueError(f"NPU descriptor data_type={d.data_type} not in known map {sorted(_DTYPE_MAP)}; refusing to embed")
        self.pooled_dtype = _DTYPE_MAP[d.data_type]

    def _bind(self):
        L = self.lib
        L.noe_init_context.argtypes = [POINTER(POINTER(context_handler_t))]
        L.noe_init_context.restype  = c_int
        L.noe_deinit_context.argtypes = [POINTER(context_handler_t)]
        L.noe_deinit_context.restype  = c_int
        L.noe_load_graph.argtypes = [POINTER(context_handler_t), c_char_p,
                                     POINTER(c_uint64), POINTER(graph_config_t)]
        L.noe_load_graph.restype  = c_int
        L.noe_unload_graph.argtypes = [POINTER(context_handler_t), c_uint64]
        L.noe_unload_graph.restype  = c_int
        L.noe_create_job.argtypes = [POINTER(context_handler_t), c_uint64,
                                     POINTER(c_uint64), POINTER(job_config_t)]
        L.noe_create_job.restype  = c_int
        L.noe_clean_job.argtypes = [POINTER(context_handler_t), c_uint64]
        L.noe_clean_job.restype  = c_int
        L.noe_load_tensor.argtypes = [POINTER(context_handler_t), c_uint64,
                                      c_uint32, c_void_p]
        L.noe_load_tensor.restype  = c_int
        L.noe_get_tensor.argtypes  = [POINTER(context_handler_t), c_uint64,
                                      c_int, c_uint32, c_void_p]
        L.noe_get_tensor.restype   = c_int
        L.noe_job_infer_sync.argtypes = [POINTER(context_handler_t), c_uint64, c_int32]
        L.noe_job_infer_sync.restype  = c_int
        L.noe_get_tensor_descriptor.argtypes = [POINTER(context_handler_t), c_uint64,
                                                c_int, c_uint32, POINTER(tensor_desc_t)]
        L.noe_get_tensor_descriptor.restype  = c_int

    @staticmethod
    def _chk(s, label):
        if s != 0:
            raise RuntimeError(f"{label} returned 0x{s:x}")

    def _tokenize_uncached(self, text: str):
        out = self.tok(text, max_length=self.max_len, padding="max_length",
                       truncation=True, return_tensors="np")
        ids   = out["input_ids"].astype(np.int32).reshape(-1)
        mask  = out["attention_mask"].astype(np.int32).reshape(-1)
        ttype = np.zeros_like(ids)
        if "token_type_ids" in out:
            ttype = out["token_type_ids"].astype(np.int32).reshape(-1)
        return ids, mask, ttype

    def _tokenize(self, text: str):
        # Tokenizer call is fast (~100us) but cacheable when texts repeat
        return self._tokenize_uncached(text)

    def _embed_uncached(self, text: str) -> np.ndarray:
        """Run the actual NPU inference. Re-creates job per call (visorcraft 0x23 workaround)."""
        ids, mask, ttype = self._tokenize(text)

        jn = job_config_npu_t()
        jc = job_config_t(conf_j_npu=ctypes.pointer(jn))
        job_id = c_uint64(0)
        self._chk(self.lib.noe_create_job(self.ctx, self.graph_id, byref(job_id), byref(jc)),
                  "create_job")
        try:
            self._chk(self.lib.noe_load_tensor(self.ctx, job_id, 0, ids.ctypes.data),   "load[0]")
            self._chk(self.lib.noe_load_tensor(self.ctx, job_id, 1, mask.ctypes.data),  "load[1]")
            self._chk(self.lib.noe_load_tensor(self.ctx, job_id, 2, ttype.ctypes.data), "load[2]")
            self._chk(self.lib.noe_job_infer_sync(self.ctx, job_id, 5000), "infer")

            # r75 Codex review HIGH fix: compute element count from dtype
            # itemsize, not hardcoded /2. The /2 was correct only for int16
            # outputs and would underallocate by half for int8 models, letting
            # noe_get_tensor write past the numpy buffer into adjacent memory.
            itemsize = np.dtype(self.pooled_dtype).itemsize
            if self.pooled_size % itemsize != 0:
                raise ValueError(f"NPU output buffer size {self.pooled_size} not divisible by dtype itemsize {itemsize}")
            pooled = np.zeros(self.pooled_size // itemsize, dtype=self.pooled_dtype)
            self._chk(self.lib.noe_get_tensor(self.ctx, job_id, NOE_TENSOR_TYPE_OUTPUT,
                                              1, pooled.ctypes.data), "get_pooled")
        finally:
            self.lib.noe_clean_job(self.ctx, job_id)

        f = (pooled.astype(np.float32) + self.zero_point) * self.scale
        n = np.linalg.norm(f)
        if n > 0:
            f = f / n
        return f

    def embed(self, text: str) -> np.ndarray:
        """Embed text. Cache hit returns immediately; miss runs NPU.

        Cache contract (r75 Codex round-2 MED): cached vectors are stored
        with WRITEABLE=False. Callers that mutate the returned array in
        place (e.g. in-place L2-normalize, dtype cast on top of the
        buffer) will get a numpy ValueError instead of silently
        corrupting the cache for that text. To mutate, copy first:
            v = embedder.embed(text).copy()
        """
        # SHA256 of the bytes — collision-resistant + stable across processes
        key = hashlib.sha256(text.encode("utf-8", errors="replace")).hexdigest()
        v = self._cache.get(key)
        if v is not None:
            self.cache_hits += 1
            return v
        self.cache_misses += 1
        v = self._embed_uncached(text)
        # Lock the cached vector against in-place mutation. The flag is
        # propagated through views, so a caller doing `v[:] = something`
        # also fails. Copies they make are writeable as expected.
        v.setflags(write=False)
        # Bound the cache to avoid runaway growth
        if len(self._cache) >= self.cache_size:
            # Drop oldest 10% (FIFO eviction; insertion-ordered dict)
            drop = max(1, len(self._cache) // 10)
            for k in list(self._cache.keys())[:drop]:
                del self._cache[k]
        self._cache[key] = v
        return v

    def cache_stats(self):
        total = self.cache_hits + self.cache_misses
        rate = (self.cache_hits / total) if total else 0.0
        return {"hits": self.cache_hits, "misses": self.cache_misses,
                "size": len(self._cache), "hit_rate": rate}

    def close(self):
        try:
            self.lib.noe_unload_graph(self.ctx, self.graph_id)
            self.lib.noe_deinit_context(self.ctx)
        except Exception:
            pass
