"""Abstract adapter contract.

Every silicon adapter (CPU / GPU / NPU) must implement this interface.
The Engine's auto() picks among adapters whose is_available() returns True
within the highest-populated capability tier (npu > gpu > cpu).

No vendor preference. The kit is silicon-agnostic.
"""
from __future__ import annotations

from abc import ABC, abstractmethod
from typing import ClassVar


class AbstractAdapter(ABC):
    """Contract every embedkit adapter must satisfy.

    Subclasses set the class-level metadata (name, tier, model_format) at
    class-definition time so registry probing does not require an
    instantiation. is_available() must be cheap and side-effect-free.
    """

    name: ClassVar[str]                    # canonical kit name, e.g. "cix-npu"
    tier: ClassVar[str]                    # "npu" | "gpu" | "cpu"
    model_format: ClassVar[str]            # "gguf" | "onnx" | "cix" | "rknn" | "xdna" | "mlx"
    embed_dim: int = 0                     # populated after model load
    max_tokens: int = 0                    # populated after model load

    def __init__(self, model_path: str, **kwargs: object) -> None:
        self.model_path = model_path
        self._kwargs = kwargs

    @abstractmethod
    def embed(self, text: str) -> list[float]:
        """Return a single embedding vector for `text`."""

    @abstractmethod
    def embed_batch(self, texts: list[str]) -> list[list[float]]:
        """Return embedding vectors for each entry in `texts`."""

    @abstractmethod
    def warmup(self) -> None:
        """Run a couple of dummy embeds to populate caches / load weights."""

    @abstractmethod
    def close(self) -> None:
        """Release any device handles, threads, or subprocesses."""

    @classmethod
    @abstractmethod
    def is_available(cls) -> tuple[bool, str]:
        """Return (ok, reason).

        ok=True iff this adapter's runtime + driver are present on the host
        and a model load is expected to succeed. reason is a short string
        for the doctor / debug output.

        This MUST be cheap (no model load, no GPU init beyond a probe).
        """

    def info(self) -> dict[str, object]:
        """Introspection blob for `Engine.info()`."""
        return {
            "adapter": self.name,
            "tier": self.tier,
            "model_format": self.model_format,
            "model_path": self.model_path,
            "embed_dim": self.embed_dim,
            "max_tokens": self.max_tokens,
        }
