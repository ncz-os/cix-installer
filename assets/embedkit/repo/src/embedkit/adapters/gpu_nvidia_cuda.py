# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jason Perlow
"""NVIDIA CUDA adapter backed by ONNX Runtime."""
from __future__ import annotations

import importlib
import logging
from pathlib import Path
from typing import Any, cast

import numpy as np
from numpy.typing import NDArray

from .base import AbstractAdapter

log = logging.getLogger("embedkit.adapter.nvidia_cuda")


class NvidiaCUDAAdapter(AbstractAdapter):
    """Embedding adapter for ONNX models through ONNX Runtime CUDA EP."""

    name = "nvidia-cuda"
    tier = "gpu"
    model_format = "onnx"

    def __init__(
        self,
        model_path: str,
        *,
        tokenizer_path: str | None = None,
        max_tokens: int = 512,
        normalize: bool = True,
        provider_options: list[dict[str, Any]] | None = None,
        **kwargs: Any,
    ) -> None:
        super().__init__(model_path, **kwargs)
        ort = importlib.import_module("onnxruntime")
        transformers = importlib.import_module("transformers")

        providers = ["CUDAExecutionProvider", "CPUExecutionProvider"]
        available = ort.get_available_providers()
        if "CUDAExecutionProvider" not in available:
            raise RuntimeError(f"onnxruntime CUDA EP unavailable (providers: {available})")

        session_options = kwargs.get("session_options")
        self._session: Any | None = ort.InferenceSession(
            model_path,
            sess_options=session_options,
            providers=providers,
            provider_options=provider_options,
        )
        self._tokenizer: Any | None = transformers.AutoTokenizer.from_pretrained(
            str(self._resolve_tokenizer_path(model_path, tokenizer_path))
        )
        self.max_tokens = max_tokens
        self._normalize = normalize
        self._input_meta = list(self._session.get_inputs())
        self._output_names = [output.name for output in self._session.get_outputs()]

        sample = self.embed("warmup")
        self.embed_dim = len(sample)

    @classmethod
    def is_available(cls) -> tuple[bool, str]:
        try:
            ort = importlib.import_module("onnxruntime")
            providers = ort.get_available_providers()
        except ImportError as exc:
            return False, f"onnxruntime not installed: {exc}"
        except Exception as exc:
            return False, f"onnxruntime probe failed: {exc}"

        if "CUDAExecutionProvider" in providers:
            return True, "onnxruntime CUDA EP present"
        return False, f"onnxruntime found but no CUDA EP (providers: {providers})"

    def embed(self, text: str) -> list[float]:
        return self.embed_batch([text])[0]

    def embed_batch(self, texts: list[str]) -> list[list[float]]:
        if not texts:
            return []
        if self._session is None or self._tokenizer is None:
            raise RuntimeError("nvidia-cuda adapter is closed")

        encoded = self._tokenizer(
            texts,
            padding=True,
            truncation=True,
            max_length=self.max_tokens,
            return_tensors="np",
        )
        feeds = self._build_feeds(encoded)
        outputs = self._session.run(None, feeds)
        vectors = self._select_vectors(outputs, encoded.get("attention_mask"))
        vectors = self._postprocess_vectors(vectors)
        return [[float(value) for value in row] for row in vectors.tolist()]

    def warmup(self) -> None:
        self.embed_batch(["warmup", "test", "sample"])

    def close(self) -> None:
        self._session = None
        self._tokenizer = None

    @staticmethod
    def _resolve_tokenizer_path(model_path: str, tokenizer_path: str | None) -> Path:
        if tokenizer_path is not None:
            return Path(tokenizer_path)
        path = Path(model_path)
        return path if path.is_dir() else path.parent

    def _build_feeds(self, encoded: dict[str, Any]) -> dict[str, NDArray[Any]]:
        batch = int(np.asarray(encoded["input_ids"]).shape[0])
        seq_len = int(np.asarray(encoded["input_ids"]).shape[1])
        feeds: dict[str, NDArray[Any]] = {}

        for meta in self._input_meta:
            name = meta.name
            dtype = np.int32 if "int32" in str(meta.type) else np.int64
            if name in encoded:
                feeds[name] = np.asarray(encoded[name], dtype=dtype)
            elif name == "token_type_ids":
                feeds[name] = np.zeros((batch, seq_len), dtype=dtype)
            elif name == "position_ids":
                positions = np.arange(seq_len, dtype=dtype)
                feeds[name] = np.broadcast_to(positions, (batch, seq_len)).copy()
            else:
                raise RuntimeError(f"ONNX model requires unsupported input '{name}'")

        return feeds

    def _select_vectors(self, outputs: list[Any], attention_mask: Any) -> NDArray[Any]:
        named = [
            (name, np.asarray(value))
            for name, value in zip(self._output_names, outputs, strict=False)
        ]
        preferred_names = ("sentence", "embedding", "pooler")

        for token in preferred_names:
            for name, array in named:
                if token in name.lower() and array.ndim == 2:
                    return array
        for _name, array in named:
            if array.ndim == 2:
                return array
        for token in ("last_hidden", "hidden", "token"):
            for name, array in named:
                if token in name.lower() and array.ndim == 3:
                    return self._mean_pool(array, attention_mask)
        for _name, array in named:
            if array.ndim == 3:
                return self._mean_pool(array, attention_mask)

        shapes = [tuple(array.shape) for _name, array in named]
        raise RuntimeError(f"could not select embedding output from ONNX shapes {shapes}")

    @staticmethod
    def _mean_pool(hidden: NDArray[Any], attention_mask: Any) -> NDArray[Any]:
        if attention_mask is None:
            return cast(NDArray[Any], hidden.mean(axis=1))
        mask = np.asarray(attention_mask, dtype=np.float32)[:, :, None]
        denom = np.clip(mask.sum(axis=1), 1e-9, None)
        return cast(NDArray[Any], (hidden.astype(np.float32) * mask).sum(axis=1) / denom)

    def _postprocess_vectors(self, vectors: NDArray[Any]) -> NDArray[Any]:
        out = vectors.astype(np.float32, copy=False)
        if self._normalize:
            norms = np.linalg.norm(out, axis=1, keepdims=True)
            out = out / np.clip(norms, 1e-12, None)
        return cast(NDArray[Any], out)
