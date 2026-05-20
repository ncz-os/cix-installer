# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jason Perlow
"""Cix Zhouyi V3 NPU adapter via ONNX Runtime + cix-npu-onnxruntime EP.

Second NPU inference path on Cix Sky1, parallel to the Compass NN (libnoe)
adapter at `npu_cix_zhouyi`. Same kernel driver (armchina_npu, /dev/aipu),
different userspace execution provider — ONNX Runtime with the Cix custom
EP `libonnxruntime_providers_cixnpu.so` shipped by `cix-npu-onnxruntime`
(Cix proprietary userspace deb).

Why two NPU paths?
- **Compass NN**: requires Cix's Compass NN AOT compiler to produce `.cix`
  binary; best throughput; vendor-locked model format.
- **ONNX**: standardized ONNX models. Community / HuggingFace bge/jina/etc
  load directly. Slightly lower throughput than `.cix` but no AOT compile.

Selection: at runtime `Engine.auto()` may pick either NPU adapter depending
on which has the matching model artifact on disk. The hybrid
`Engine.heterogeneous(short=..., long=...)` accepts either as the short path.

Userspace deps: `onnxruntime` (Python wheel) + Cix's `cix-npu-onnxruntime`
deb registering the `CixNpuExecutionProvider`. On NCZ Magnetar/Reinhardt
both are baked at install time via 25-cix-proprietary.sh + 47-embedkit.sh.
"""
from __future__ import annotations

import logging
import os
from pathlib import Path
from typing import Any, ClassVar

import numpy as np
from numpy.typing import NDArray

from .base import AbstractAdapter

log = logging.getLogger("embedkit.adapter.cix_onnx")

CIX_EP_NAME = "CixNpuExecutionProvider"
CPU_EP_NAME = "CPUExecutionProvider"


class CixOnnxAdapter(AbstractAdapter):
    """Embedding adapter for ONNX models on Cix Zhouyi V3 NPU via ONNX Runtime."""

    name: ClassVar[str] = "cix-npu-onnx"
    tier: ClassVar[str] = "npu"
    model_format: ClassVar[str] = "onnx"

    def __init__(
        self,
        model_path: str,
        *,
        max_tokens: int = 256,
        tokenizer_path: str | None = None,
        normalize: bool = True,
        ep_options: dict[str, str] | None = None,
        intra_op_num_threads: int | None = None,
        **kwargs: Any,
    ) -> None:
        super().__init__(model_path, **kwargs)
        # Lazy import — onnxruntime is heavy and only needed when this adapter loads.
        ort = __import__("onnxruntime")
        transformers = __import__("transformers", fromlist=["AutoTokenizer"])

        self.max_tokens = max_tokens
        self._normalize = normalize
        self._closed = False

        available_eps = ort.get_available_providers()
        if CIX_EP_NAME not in available_eps:
            raise RuntimeError(
                f"{CIX_EP_NAME} not registered in onnxruntime "
                f"(available: {available_eps}). Install cix-npu-onnxruntime userspace deb."
            )

        # Session options. Restrict intra-op threads — NPU offload should not
        # need many CPU threads. Default to 1 for predictability.
        sess_opts = ort.SessionOptions()
        if intra_op_num_threads is not None:
            sess_opts.intra_op_num_threads = int(intra_op_num_threads)

        provider_options = [ep_options or {}, {}]
        self._session = ort.InferenceSession(
            model_path,
            sess_options=sess_opts,
            providers=[CIX_EP_NAME, CPU_EP_NAME],
            provider_options=provider_options,
        )

        # Inspect input/output shape. bge-style encoders typically take
        # input_ids + attention_mask; some also expect token_type_ids.
        self._input_names = [i.name for i in self._session.get_inputs()]
        self._output_names = [o.name for o in self._session.get_outputs()]

        # Embedding dimension comes from the pooled output (last hidden state
        # mean-pooled is usually the 2nd output for bge; some models expose
        # a single pooled output). Probe via a dry-run on a 1-token input.
        resolved_tokenizer = self._resolve_tokenizer_path(model_path, tokenizer_path)
        self._tokenizer: Any | None = transformers.AutoTokenizer.from_pretrained(
            str(resolved_tokenizer)
        )

        probe = self._tokenize("probe")
        feeds = self._build_feeds(probe)
        outputs = self._session.run(self._output_names[:1], feeds)
        pooled = outputs[0]
        # Expected shape (batch=1, hidden_dim) or (batch=1, seq, hidden_dim).
        if pooled.ndim == 3:
            # Take CLS-pooled equivalent — mean over seq axis.
            pooled = pooled.mean(axis=1)
        self.embed_dim = int(pooled.shape[-1])

        log.info(
            "CixOnnxAdapter loaded: model=%s ep=%s embed_dim=%d max_tokens=%d",
            model_path, CIX_EP_NAME, self.embed_dim, self.max_tokens,
        )

    @classmethod
    def is_available(cls) -> tuple[bool, str]:
        if not Path("/dev/aipu").exists():
            return False, "/dev/aipu not present (Cix NPU not in this kernel)"
        try:
            ort = __import__("onnxruntime")
        except Exception as exc:
            return False, f"onnxruntime not importable: {exc}"
        eps = ort.get_available_providers()
        if CIX_EP_NAME not in eps:
            return False, f"{CIX_EP_NAME} not registered (have: {eps})"
        return True, f"onnxruntime + {CIX_EP_NAME} + /dev/aipu present"

    def embed(self, text: str) -> list[float]:
        return self._embed_one(text)

    def embed_batch(self, texts: list[str]) -> list[list[float]]:
        return [self._embed_one(t) for t in texts]

    def warmup(self) -> None:
        for text in ("warmup", "test", "sample"):
            try:
                self._embed_one(text)
            except Exception as exc:
                log.debug("warmup '%s' failed: %s", text, exc)

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        # onnxruntime.InferenceSession releases on GC; no explicit close in API.
        self._session = None  # type: ignore[assignment]
        self._tokenizer = None

    # ----- internals -----

    def _embed_one(self, text: str) -> list[float]:
        if self._closed or self._session is None:
            raise RuntimeError("CixOnnxAdapter is closed")
        encoded = self._tokenize(text)
        feeds = self._build_feeds(encoded)
        outputs = self._session.run(self._output_names[:1], feeds)
        pooled = outputs[0]
        if pooled.ndim == 3:
            # Mean-pool over the sequence dimension (apply attention mask).
            mask = encoded["attention_mask"].astype(np.float32)[..., None]
            summed = (pooled * mask).sum(axis=1)
            counts = np.clip(mask.sum(axis=1), 1, None)
            pooled = summed / counts
        vec = pooled[0].astype(np.float32)
        if self._normalize:
            norm = np.linalg.norm(vec)
            if norm > 0:
                vec = vec / norm
        return vec.tolist()

    def _tokenize(self, text: str) -> dict[str, NDArray[Any]]:
        # padding="max_length" is intentional: CixNpuExecutionProvider requires
        # fixed-shape inputs to map onto the NPU's compiled graph. Switching to
        # padding="longest" would seem to save NPU cycles but breaks the EP's
        # static-shape contract and causes runtime errors at session.run().
        # Do NOT change this without re-validating against cix-npu-onnxruntime.
        enc = self._tokenizer(
            text,
            padding="max_length",
            truncation=True,
            max_length=self.max_tokens,
            return_tensors="np",
        )
        out: dict[str, NDArray[Any]] = {}
        for k, v in enc.items():
            # ONNX models typically expect int64 ids + mask
            out[k] = v.astype(np.int64)
        return out

    def _build_feeds(self, encoded: dict[str, NDArray[Any]]) -> dict[str, NDArray[Any]]:
        feeds: dict[str, NDArray[Any]] = {}
        for name in self._input_names:
            if name in encoded:
                feeds[name] = encoded[name]
            elif name == "token_type_ids":
                # Some bge variants require token_type_ids but tokenizer may not emit them
                ids = encoded.get("input_ids")
                if ids is not None:
                    feeds[name] = np.zeros_like(ids)
            else:
                raise ValueError(
                    f"ONNX model expects input '{name}' not produced by tokenizer "
                    f"(have: {list(encoded)})"
                )
        return feeds

    @staticmethod
    def _resolve_tokenizer_path(model_path: str, tokenizer_path: str | None) -> Path:
        if tokenizer_path is not None:
            return Path(tokenizer_path)
        env = os.environ.get("EMBEDKIT_CIX_ONNX_TOKENIZER")
        if env:
            return Path(env)

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
