# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jason Perlow
"""llama-cpp-python adapter for GGUF embedding models."""
from __future__ import annotations

import importlib
import logging
import os
from typing import Any

from .base import AbstractAdapter

log = logging.getLogger("embedkit.adapter.cpu_llamacpp")


class CPULlamaCppAdapter(AbstractAdapter):
    """Embedding adapter backed by llama-cpp-python.

    This path covers CPU execution and any llama.cpp accelerator backend
    compiled into the local llama-cpp-python wheel, controlled by
    ``n_gpu_layers`` / ``N_GPU_LAYERS``.
    """

    name = "cpu-llamacpp"
    tier = "cpu"
    model_format = "gguf"

    def __init__(
        self,
        model_path: str,
        *,
        n_threads: int | None = None,
        n_ctx: int = 8192,
        n_gpu_layers: int | None = None,
        **kwargs: Any,
    ) -> None:
        super().__init__(model_path, **kwargs)
        llama_cpp = importlib.import_module("llama_cpp")

        llama_kwargs = dict(kwargs)
        llama_kwargs.pop("embedding", None)
        llama_kwargs.pop("verbose", None)

        threads = n_threads or os.cpu_count() or 4
        gpu_layers = (
            n_gpu_layers
            if n_gpu_layers is not None
            else int(os.environ.get("N_GPU_LAYERS", "0"))
        )

        self.max_tokens = n_ctx
        self._llm: Any | None = llama_cpp.Llama(
            model_path=model_path,
            n_ctx=n_ctx,
            n_threads=threads,
            n_gpu_layers=gpu_layers,
            embedding=True,
            verbose=False,
            **llama_kwargs,
        )

        sample = self._create_embedding("warmup")
        self.embed_dim = len(sample)

    @classmethod
    def is_available(cls) -> tuple[bool, str]:
        try:
            importlib.import_module("llama_cpp")
        except ImportError as exc:
            return False, f"llama-cpp-python missing: {exc}"
        except Exception as exc:
            return False, f"llama-cpp-python import failed: {exc}"
        return True, "llama-cpp-python installed"

    def embed(self, text: str) -> list[float]:
        return self._create_embedding(text)

    def embed_batch(self, texts: list[str]) -> list[list[float]]:
        return [self.embed(text) for text in texts]

    def warmup(self) -> None:
        for text in ("warmup", "test", "sample"):
            self._create_embedding(text)

    def close(self) -> None:
        llm = self._llm
        self._llm = None
        if llm is None:
            return
        close = getattr(llm, "close", None)
        if callable(close):
            try:
                close()
            except Exception as exc:
                log.debug("llama.cpp close failed: %s", exc)

    def _create_embedding(self, text: str) -> list[float]:
        if self._llm is None:
            raise RuntimeError("cpu-llamacpp adapter is closed")
        response = self._llm.create_embedding(text)
        data = response.get("data", [])
        if not data:
            raise RuntimeError("llama-cpp-python returned no embedding data")
        embedding = data[0].get("embedding")
        if embedding is None:
            raise RuntimeError("llama-cpp-python response missing embedding")
        return [float(value) for value in embedding]
