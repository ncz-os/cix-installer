# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jason Perlow
"""Apple Silicon MLX adapter."""
from __future__ import annotations

import importlib
import logging
import platform
from typing import Any, cast

import numpy as np
from numpy.typing import NDArray

from .base import AbstractAdapter

log = logging.getLogger("embedkit.adapter.apple_mlx")


class AppleMLXAdapter(AbstractAdapter):
    """Embedding adapter for MLX models on Apple Silicon."""

    name = "apple-mlx"
    tier = "gpu"
    model_format = "mlx"

    def __init__(
        self,
        model_path: str,
        *,
        max_tokens: int = 512,
        normalize: bool = True,
        **kwargs: Any,
    ) -> None:
        super().__init__(model_path, **kwargs)
        self._mx: Any | None = importlib.import_module("mlx.core")
        load = self._resolve_mlx_load()

        load_kwargs = dict(kwargs)
        self._model, self._tokenizer = load(model_path, **load_kwargs)
        self.max_tokens = max_tokens
        self._normalize = normalize

        sample = self.embed("warmup")
        self.embed_dim = len(sample)

    @classmethod
    def is_available(cls) -> tuple[bool, str]:
        if platform.system() != "Darwin" or platform.machine() != "arm64":
            return False, "Apple MLX requires Apple Silicon macOS"
        try:
            importlib.import_module("mlx.core")
            importlib.import_module("mlx_lm")
        except ImportError as exc:
            return False, f"mlx/mlx_lm missing: {exc}"
        except Exception as exc:
            return False, f"mlx/mlx_lm probe failed: {exc}"
        return True, "mlx + mlx_lm present on Apple Silicon"

    def embed(self, text: str) -> list[float]:
        return self.embed_batch([text])[0]

    def embed_batch(self, texts: list[str]) -> list[list[float]]:
        if not texts:
            return []
        if self._mx is None or self._model is None or self._tokenizer is None:
            raise RuntimeError("apple-mlx adapter is closed")

        input_ids, attention_mask = self._tokenize_batch(texts)
        mx_input_ids = self._mx.array(input_ids)
        mx_attention_mask = self._mx.array(attention_mask)
        outputs = self._call_model(mx_input_ids, mx_attention_mask)
        vectors = self._select_vectors(outputs, attention_mask)
        vectors = self._postprocess_vectors(vectors)
        return [[float(value) for value in row] for row in vectors.tolist()]

    def warmup(self) -> None:
        self.embed_batch(["warmup", "test", "sample"])

    def close(self) -> None:
        mx = self._mx
        self._model = None
        self._tokenizer = None
        self._mx = None
        if mx is None:
            return
        try:
            metal = getattr(mx, "metal", None)
            clear_cache = getattr(metal, "clear_cache", None)
            if callable(clear_cache):
                clear_cache()
        except Exception as exc:
            log.debug("MLX cache clear failed: %s", exc)

    @staticmethod
    def _resolve_mlx_load() -> Any:
        mlx_lm = importlib.import_module("mlx_lm")
        load = getattr(mlx_lm, "load", None)
        if callable(load):
            return load
        mlx_lm_utils = importlib.import_module("mlx_lm.utils")
        load = getattr(mlx_lm_utils, "load", None)
        if not callable(load):
            raise RuntimeError("mlx_lm does not expose a load() helper")
        return load

    def _tokenize_batch(self, texts: list[str]) -> tuple[NDArray[Any], NDArray[Any]]:
        tokenizer = self._tokenizer
        try:
            encoded = tokenizer(
                texts,
                padding=True,
                truncation=True,
                max_length=self.max_tokens,
                return_tensors="np",
            )
            input_ids = np.asarray(encoded["input_ids"], dtype=np.int32)
            if "attention_mask" in encoded:
                attention_mask = np.asarray(encoded["attention_mask"], dtype=np.int32)
            else:
                attention_mask = np.ones_like(input_ids, dtype=np.int32)
            return input_ids, attention_mask
        except TypeError:
            pass

        encode = getattr(tokenizer, "encode", None)
        if not callable(encode):
            raise RuntimeError("MLX tokenizer does not support batch calls or encode()")

        pad_id = getattr(tokenizer, "pad_token_id", None)
        if pad_id is None:
            pad_id = getattr(tokenizer, "eos_token_id", 0)
        rows: list[list[int]] = []
        for text in texts:
            token_ids = list(encode(text))
            rows.append(token_ids[: self.max_tokens])

        width = max(len(row) for row in rows)
        input_ids = np.full((len(rows), width), int(pad_id or 0), dtype=np.int32)
        attention_mask = np.zeros((len(rows), width), dtype=np.int32)
        for index, row in enumerate(rows):
            input_ids[index, : len(row)] = row
            attention_mask[index, : len(row)] = 1
        return input_ids, attention_mask

    def _call_model(self, input_ids: Any, attention_mask: Any) -> Any:
        try:
            outputs = self._model(
                input_ids,
                attention_mask=attention_mask,
                output_hidden_states=True,
            )
        except TypeError:
            try:
                outputs = self._model(input_ids, attention_mask=attention_mask)
            except TypeError:
                outputs = self._model(input_ids)

        eval_fn = getattr(self._mx, "eval", None)
        if callable(eval_fn):
            try:
                eval_fn(outputs)
            except TypeError:
                pass
        return outputs

    def _select_vectors(self, outputs: Any, attention_mask: NDArray[Any]) -> NDArray[Any]:
        arrays = self._collect_named_arrays(outputs)
        preferred_names = ("sentence", "embedding", "pooler")
        for token in preferred_names:
            for name, array in arrays:
                if token in name.lower() and array.ndim == 2:
                    self._reject_logits(array)
                    return array
        for _name, array in arrays:
            if array.ndim == 2:
                self._reject_logits(array)
                return array
        for token in ("last_hidden", "hidden", "token"):
            for name, array in arrays:
                if token in name.lower() and array.ndim == 3:
                    self._reject_logits(array)
                    return self._mean_pool(array, attention_mask)
        for _name, array in arrays:
            if array.ndim == 3:
                self._reject_logits(array)
                return self._mean_pool(array, attention_mask)

        shapes = [(name, tuple(array.shape)) for name, array in arrays]
        raise RuntimeError(f"could not select embedding output from MLX shapes {shapes}")

    def _collect_named_arrays(self, value: Any) -> list[tuple[str, NDArray[Any]]]:
        names = (
            "sentence_embedding",
            "embeddings",
            "pooler_output",
            "last_hidden_state",
            "hidden_states",
            "logits",
        )
        arrays: list[tuple[str, NDArray[Any]]] = []

        if isinstance(value, dict):
            for name, item in value.items():
                arrays.extend(
                    (f"{name}.{child}", array)
                    for child, array in self._collect_named_arrays(item)
                )
            return arrays

        for name in names:
            if hasattr(value, name):
                arrays.extend(
                    (f"{name}.{child}", array)
                    for child, array in self._collect_named_arrays(getattr(value, name))
                )

        if isinstance(value, (list, tuple)):
            for index, item in enumerate(value):
                arrays.extend(
                    (f"{index}.{child}", array)
                    for child, array in self._collect_named_arrays(item)
                )
            return arrays

        array = self._as_numpy(value)
        if array is not None:
            arrays.append(("output", array))
        return arrays

    @staticmethod
    def _as_numpy(value: Any) -> NDArray[Any] | None:
        if not hasattr(value, "shape"):
            return None
        try:
            return cast(NDArray[Any], np.asarray(value))
        except Exception:
            return None

    def _reject_logits(self, array: NDArray[Any]) -> None:
        vocab_size = getattr(self._tokenizer, "vocab_size", None)
        if vocab_size is not None and array.shape[-1] == int(vocab_size):
            raise RuntimeError(
                "MLX model returned token logits, not embeddings; use an MLX embedding model"
            )

    @staticmethod
    def _mean_pool(hidden: NDArray[Any], attention_mask: NDArray[Any]) -> NDArray[Any]:
        mask = attention_mask.astype(np.float32)[:, :, None]
        denom = np.clip(mask.sum(axis=1), 1e-9, None)
        return cast(NDArray[Any], (hidden.astype(np.float32) * mask).sum(axis=1) / denom)

    def _postprocess_vectors(self, vectors: NDArray[Any]) -> NDArray[Any]:
        out = vectors.astype(np.float32, copy=False)
        if self._normalize:
            norms = np.linalg.norm(out, axis=1, keepdims=True)
            out = out / np.clip(norms, 1e-12, None)
        return cast(NDArray[Any], out)
