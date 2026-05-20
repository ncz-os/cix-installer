# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jason Perlow
"""Cix Zhouyi V3 NPU adapter backed by libnoe."""
from __future__ import annotations

import ctypes
import ctypes.util
import logging
import os
from ctypes import (
    POINTER,
    Structure,
    byref,
    c_char_p,
    c_float,
    c_int,
    c_int32,
    c_uint32,
    c_uint64,
    c_void_p,
)
from pathlib import Path
from typing import Any

import numpy as np
from numpy.typing import NDArray

from .base import AbstractAdapter

log = logging.getLogger("embedkit.adapter.cix_zhouyi")

NOE_TENSOR_TYPE_INPUT = 0
NOE_TENSOR_TYPE_OUTPUT = 1


class context_handler_t(Structure):  # noqa: N801
    _fields_ = [("handle", c_uint32)]


class graph_config_npu_t(Structure):  # noqa: N801
    _fields_ = [("opaque", ctypes.c_uint8 * 256)]


class graph_config_t(Structure):  # noqa: N801
    _fields_ = [("conf_g_npu", POINTER(graph_config_npu_t))]


class job_config_npu_t(Structure):  # noqa: N801
    _fields_ = [("opaque", ctypes.c_uint8 * 256)]


class job_config_t(Structure):  # noqa: N801
    _fields_ = [("conf_j_npu", POINTER(job_config_npu_t))]


class tensor_desc_t(Structure):  # noqa: N801
    _fields_ = [
        ("id", c_uint32),
        ("size", c_uint32),
        ("scale", c_float),
        ("zero_point", c_int32),
        ("data_type", c_int),
    ]


class CixZhouyiAdapter(AbstractAdapter):
    """Embedding adapter for precompiled Cix Compass NN ``.cix`` models."""

    name = "cix-npu"
    tier = "npu"
    model_format = "cix"

    _DTYPE_MAP = {
        2: np.int8,
        4: np.uint8,
        5: np.int16,
        7: np.float32,
    }

    def __init__(
        self,
        model_path: str,
        *,
        max_tokens: int = 256,
        tokenizer_path: str | None = None,
        lib_path: str | None = None,
        timeout_ms: int = 5000,
        normalize: bool = True,
        **kwargs: Any,
    ) -> None:
        super().__init__(model_path, **kwargs)
        transformers = __import__("transformers", fromlist=["AutoTokenizer"])

        self.max_tokens = max_tokens
        self._timeout_ms = timeout_ms
        self._normalize = normalize
        self._closed = False
        self._lib_path = lib_path or self._find_libnoe_path() or "libnoe.so"
        self._lib = ctypes.CDLL(self._lib_path, mode=ctypes.RTLD_GLOBAL)
        self._bind()

        resolved_tokenizer = self._resolve_tokenizer_path(model_path, tokenizer_path)
        self._tokenizer: Any | None = transformers.AutoTokenizer.from_pretrained(
            str(resolved_tokenizer)
        )

        self._ctx = POINTER(context_handler_t)()
        self._chk(self._lib.noe_init_context(byref(self._ctx)), "init_context")

        graph_npu = graph_config_npu_t()
        graph_config = graph_config_t(conf_g_npu=ctypes.pointer(graph_npu))
        self._graph_id = c_uint64(0)
        self._chk(
            self._lib.noe_load_graph(
                self._ctx,
                os.fsencode(model_path),
                byref(self._graph_id),
                byref(graph_config),
            ),
            "load_graph",
        )

        desc = tensor_desc_t()
        self._chk(
            self._lib.noe_get_tensor_descriptor(
                self._ctx,
                self._graph_id,
                NOE_TENSOR_TYPE_OUTPUT,
                1,
                byref(desc),
            ),
            "get_pooled_desc",
        )
        self._scale = desc.scale if desc.scale != 0 else 1.0
        self._zero_point = desc.zero_point
        self._pooled_size = int(desc.size)
        if desc.data_type not in self._DTYPE_MAP:
            known = sorted(self._DTYPE_MAP)
            raise ValueError(f"NPU descriptor data_type={desc.data_type} not in known map {known}")
        self._pooled_dtype = self._DTYPE_MAP[desc.data_type]
        itemsize = np.dtype(self._pooled_dtype).itemsize
        if self._pooled_size % itemsize != 0:
            raise ValueError(
                f"NPU output buffer size {self._pooled_size} not divisible by "
                f"dtype itemsize {itemsize}"
            )
        self.embed_dim = self._pooled_size // itemsize

    @classmethod
    def is_available(cls) -> tuple[bool, str]:
        if not Path("/dev/aipu").exists():
            return False, "/dev/aipu not present (Cix NPU not in this kernel)"
        lib_path = cls._find_libnoe_path()
        if lib_path is None:
            return False, "libnoe not found in dynamic loader path or Cix install paths"
        return True, f"libnoe + /dev/aipu present ({lib_path})"

    def embed(self, text: str) -> list[float]:
        return self._embed_uncached(text)

    def embed_batch(self, texts: list[str]) -> list[list[float]]:
        return [self.embed(text) for text in texts]

    def warmup(self) -> None:
        for text in ("warmup", "test", "sample"):
            self.embed(text)

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        lib = getattr(self, "_lib", None)
        ctx = getattr(self, "_ctx", None)
        graph_id = getattr(self, "_graph_id", None)
        try:
            if lib is not None and ctx is not None and graph_id is not None:
                lib.noe_unload_graph(ctx, graph_id)
                lib.noe_deinit_context(ctx)
        except Exception as exc:
            log.debug("Cix NPU close failed: %s", exc)
        self._tokenizer = None

    @staticmethod
    def _resolve_tokenizer_path(model_path: str, tokenizer_path: str | None) -> Path:
        if tokenizer_path is not None:
            return Path(tokenizer_path)

        model = Path(model_path)
        stem_without_len = model.stem.rsplit("_", 1)[0]
        candidates = [
            model.parent,
            model.with_suffix(""),
            model.parent / model.stem,
            model.parent / stem_without_len,
        ]
        for candidate in candidates:
            if (
                (candidate / "tokenizer.json").exists()
                or (candidate / "tokenizer_config.json").exists()
            ):
                return candidate
        return model.parent

    @staticmethod
    def _find_libnoe_path() -> str | None:
        env_path = os.environ.get("EMBEDKIT_CIX_LIBNOE")
        if env_path:
            return env_path

        found = ctypes.util.find_library("noe")
        if found:
            return found

        candidates = [
            "/usr/share/cix/lib/libnoe.so",
            "/usr/lib/libnoe.so",
            "/usr/local/lib/libnoe.so",
            "/usr/lib/aarch64-linux-gnu/libnoe.so",
        ]
        for candidate in candidates:
            if Path(candidate).exists():
                return candidate
        return None

    def _bind(self) -> None:
        lib = self._lib
        lib.noe_init_context.argtypes = [POINTER(POINTER(context_handler_t))]
        lib.noe_init_context.restype = c_int
        lib.noe_deinit_context.argtypes = [POINTER(context_handler_t)]
        lib.noe_deinit_context.restype = c_int
        lib.noe_load_graph.argtypes = [
            POINTER(context_handler_t),
            c_char_p,
            POINTER(c_uint64),
            POINTER(graph_config_t),
        ]
        lib.noe_load_graph.restype = c_int
        lib.noe_unload_graph.argtypes = [POINTER(context_handler_t), c_uint64]
        lib.noe_unload_graph.restype = c_int
        lib.noe_create_job.argtypes = [
            POINTER(context_handler_t),
            c_uint64,
            POINTER(c_uint64),
            POINTER(job_config_t),
        ]
        lib.noe_create_job.restype = c_int
        lib.noe_clean_job.argtypes = [POINTER(context_handler_t), c_uint64]
        lib.noe_clean_job.restype = c_int
        lib.noe_load_tensor.argtypes = [POINTER(context_handler_t), c_uint64, c_uint32, c_void_p]
        lib.noe_load_tensor.restype = c_int
        lib.noe_get_tensor.argtypes = [
            POINTER(context_handler_t),
            c_uint64,
            c_int,
            c_uint32,
            c_void_p,
        ]
        lib.noe_get_tensor.restype = c_int
        lib.noe_job_infer_sync.argtypes = [POINTER(context_handler_t), c_uint64, c_int32]
        lib.noe_job_infer_sync.restype = c_int
        lib.noe_get_tensor_descriptor.argtypes = [
            POINTER(context_handler_t),
            c_uint64,
            c_int,
            c_uint32,
            POINTER(tensor_desc_t),
        ]
        lib.noe_get_tensor_descriptor.restype = c_int

    @staticmethod
    def _chk(status: int, label: str) -> None:
        if status != 0:
            raise RuntimeError(f"{label} returned 0x{status:x}")

    def _tokenize(self, text: str) -> tuple[NDArray[Any], NDArray[Any], NDArray[Any]]:
        if self._tokenizer is None:
            raise RuntimeError("cix-npu adapter is closed")
        encoded = self._tokenizer(
            text,
            max_length=self.max_tokens,
            padding="max_length",
            truncation=True,
            return_tensors="np",
        )
        input_ids = np.ascontiguousarray(encoded["input_ids"].astype(np.int32).reshape(-1))
        attention_mask = np.ascontiguousarray(
            encoded["attention_mask"].astype(np.int32).reshape(-1)
        )
        if "token_type_ids" in encoded:
            token_type_ids = np.ascontiguousarray(
                encoded["token_type_ids"].astype(np.int32).reshape(-1)
            )
        else:
            token_type_ids = np.zeros_like(input_ids, dtype=np.int32)
        return input_ids, attention_mask, token_type_ids

    def _embed_uncached(self, text: str) -> list[float]:
        if self._closed:
            raise RuntimeError("cix-npu adapter is closed")

        input_ids, attention_mask, token_type_ids = self._tokenize(text)
        job_npu = job_config_npu_t()
        job_config = job_config_t(conf_j_npu=ctypes.pointer(job_npu))
        job_id = c_uint64(0)
        self._chk(
            self._lib.noe_create_job(self._ctx, self._graph_id, byref(job_id), byref(job_config)),
            "create_job",
        )
        try:
            self._chk(
                self._lib.noe_load_tensor(self._ctx, job_id, 0, c_void_p(input_ids.ctypes.data)),
                "load[0]",
            )
            self._chk(
                self._lib.noe_load_tensor(
                    self._ctx,
                    job_id,
                    1,
                    c_void_p(attention_mask.ctypes.data),
                ),
                "load[1]",
            )
            self._chk(
                self._lib.noe_load_tensor(
                    self._ctx,
                    job_id,
                    2,
                    c_void_p(token_type_ids.ctypes.data),
                ),
                "load[2]",
            )
            self._chk(
                self._lib.noe_job_infer_sync(self._ctx, job_id, self._timeout_ms),
                "infer",
            )

            pooled = np.zeros(self.embed_dim, dtype=self._pooled_dtype)
            self._chk(
                self._lib.noe_get_tensor(
                    self._ctx,
                    job_id,
                    NOE_TENSOR_TYPE_OUTPUT,
                    1,
                    c_void_p(pooled.ctypes.data),
                ),
                "get_pooled",
            )
        finally:
            self._lib.noe_clean_job(self._ctx, job_id)

        vector = (pooled.astype(np.float32) + self._zero_point) * self._scale
        if self._normalize:
            norm = np.linalg.norm(vector)
            if norm > 0:
                vector = vector / norm
        return [float(value) for value in vector.tolist()]
