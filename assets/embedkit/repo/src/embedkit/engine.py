"""Engine — the user-facing facade.

Quick start:

    eng = embedkit.Engine.auto()        # picks fastest adapter on this host
    vec = eng.embed("Hello world")

Explicit adapter pick:

    eng = embedkit.Engine(adapter="cix-npu", model="bge-small-zh-v1.5")

Heterogeneous routing (short→NPU, long→CPU/GPU):

    eng = embedkit.Engine.heterogeneous(
        short=("cix-npu",      {"model": "bge-small-zh-v1.5"}),
        long= ("cpu-llamacpp", {"model": "nomic-embed-text-v1.5"}),
        threshold_chars=512,
    )
    vec = eng.embed("...")              # auto-routes by length
"""
from __future__ import annotations

import logging
from typing import Any

from .adapters import AbstractAdapter, all_adapters
from .models import resolve_model

log = logging.getLogger("embedkit.engine")


class Engine:
    """User-facing wrapper. Holds one bound adapter for the lifetime of the call.

    The kit is silicon-agnostic. Engine.auto() picks by capability tier
    (NPU > GPU > CPU) and measured throughput within tier, NOT by vendor.
    """

    def __init__(self, adapter: str | None = None, model: str | None = None, **kwargs: Any) -> None:
        if adapter is None:
            raise ValueError(
                "Engine() requires either adapter='...' or use Engine.auto()"
            )
        cls = self._lookup(adapter)
        if cls is None:
            raise ValueError(
                f"Unknown adapter '{adapter}'. Use embedkit.Engine.auto() to list options."
            )
        ok, why = cls.is_available()
        if not ok:
            raise RuntimeError(f"Adapter '{adapter}' is not available on this host: {why}")
        model_path = resolve_model(adapter, model)
        self._adapter: AbstractAdapter = cls(model_path=model_path, **kwargs)
        self._adapter.warmup()

    @classmethod
    def auto(
        cls,
        prefer_tier: str | None = None,
        model: str | None = None,
        **kwargs: Any,
    ) -> Engine:
        """Pick the fastest available adapter on this host.

        Selection policy:
          1. Filter to adapter classes whose is_available() returns ok=True.
          2. Group by capability tier (NPU > GPU > CPU).
          3. Within the highest-populated tier, run a 50-record micro-bench
             on the host and pick the fastest. Cache per (host, model).

        prefer_tier="cpu" forces CPU even if NPU/GPU exist (useful for
        thermal-budget tests).
        """
        from .pick import pick_fastest_in_tier  # local import to break cycle

        candidates = [a for a in all_adapters() if a.is_available()[0]]
        if not candidates:
            raise RuntimeError(
                "No embed adapter available on this host. "
                "Install at minimum: pip install mnemos-embedkit[cpu-llamacpp]"
            )
        if prefer_tier:
            candidates = [a for a in candidates if a.tier == prefer_tier]
            if not candidates:
                raise RuntimeError(f"No adapter available in tier '{prefer_tier}'.")
        for tier in ("npu", "gpu", "cpu"):
            in_tier = [a for a in candidates if a.tier == tier]
            if in_tier:
                cls_pick = pick_fastest_in_tier(in_tier, model=model)
                eng = cls.__new__(cls)
                model_path = resolve_model(cls_pick.name, model)
                eng._adapter = cls_pick(model_path=model_path, **kwargs)
                eng._adapter.warmup()
                return eng
        raise RuntimeError("No adapter available after tier filter.")

    @classmethod
    def heterogeneous(
        cls,
        short: tuple[str, dict[str, Any]],
        long: tuple[str, dict[str, Any]],
        threshold_chars: int = 512,
    ) -> Engine:
        """Dual-adapter router: short text -> `short` adapter, long text -> `long`.

        Use case: NPU encoder caps at 256 input tokens (e.g. bge-small-zh-v1.5
        on Cix Sky1 Zhouyi V3). Route short queries to the NPU for ~60 rec/s
        throughput; spill long-context queries to a CPU/GPU adapter with an
        8K+ context model so they don't silently truncate.

        Both adapters are loaded + warmed at construction time. Routing uses
        character count (cheap, tokenizer-free) — assumes ~4 chars/token as a
        conservative rule of thumb. Override `threshold_chars` if your short
        adapter has a different ceiling.

        Args:
          short: (adapter_name, kwargs) for the short-text path. kwargs
                 accepts `model` and adapter-specific options.
          long:  (adapter_name, kwargs) for the long-text path.
          threshold_chars: route texts with len(text) <= threshold to `short`,
                           > threshold to `long`. Default 512 chars
                           (~128 tokens) leaves headroom under a 256-token NPU.

        Returns:
          Engine instance with `.embed()` / `.embed_batch()` that auto-route.

        Embed semantics:
          - embed(text): route based on len(text)
          - embed_batch(texts): partition by length, run two batches under the
            hood, reassemble result list in the original input order.

        info() reports both bound adapters + the threshold for introspection.
        """
        threshold = int(threshold_chars)
        if threshold < 0:
            raise ValueError("threshold_chars must be >= 0")

        short_name, short_kwargs = short
        long_name, long_kwargs = long

        short_eng = cls(adapter=short_name, **short_kwargs)
        try:
            long_eng = cls(adapter=long_name, **long_kwargs)
        except Exception:
            short_eng._adapter.close()
            raise

        eng = cls.__new__(cls)
        eng._adapter = None  # type: ignore[assignment]
        eng._short = short_eng._adapter
        eng._long = long_eng._adapter
        # threshold=0 routes "" to short and every non-empty string to long.
        eng._threshold_chars = threshold
        eng._heterogeneous = True
        log.info(
            "Engine.heterogeneous bound: short=%s long=%s threshold=%dchars",
            short_name, long_name, threshold,
        )
        return eng

    def _route(self, text: str) -> AbstractAdapter:
        if getattr(self, "_heterogeneous", False):
            return self._short if len(text) <= self._threshold_chars else self._long
        return self._adapter

    def embed(self, text: str) -> list[float]:
        return self._route(text).embed(text)

    def embed_batch(self, texts: list[str]) -> list[list[float]]:
        if not getattr(self, "_heterogeneous", False):
            return self._adapter.embed_batch(texts)

        # Partition by length, run two batches, reassemble in original order.
        short_items: list[tuple[int, str]] = []
        long_items: list[tuple[int, str]] = []
        for idx, t in enumerate(texts):
            (short_items if len(t) <= self._threshold_chars else long_items).append((idx, t))

        results: list[list[float] | None] = [None] * len(texts)
        if short_items:
            vecs = self._short.embed_batch([t for _, t in short_items])
            for (idx, _), v in zip(short_items, vecs):
                results[idx] = v
        if long_items:
            vecs = self._long.embed_batch([t for _, t in long_items])
            for (idx, _), v in zip(long_items, vecs):
                results[idx] = v
        # Safety: every slot must be populated
        for i, v in enumerate(results):
            if v is None:
                raise RuntimeError(f"heterogeneous embed_batch: index {i} not filled")
        return results  # type: ignore[return-value]

    def info(self) -> dict[str, Any]:
        if getattr(self, "_heterogeneous", False):
            return {
                "routing": "heterogeneous",
                "threshold_chars": self._threshold_chars,
                "short": dict(self._short.info()),
                "long": dict(self._long.info()),
            }
        return dict(self._adapter.info())

    def close(self) -> None:
        if getattr(self, "_heterogeneous", False):
            errors: list[Exception] = []
            for label, adapter in (("short", self._short), ("long", self._long)):
                try:
                    adapter.close()
                except Exception as exc:
                    if errors:
                        log.exception("Error closing heterogeneous %s adapter", label)
                    errors.append(exc)
            if errors:
                raise errors[0]
            return
        self._adapter.close()

    def __enter__(self) -> Engine:
        return self

    def __exit__(self, *exc: Any) -> None:
        self.close()

    @staticmethod
    def _lookup(name: str) -> type[AbstractAdapter] | None:
        for cls in all_adapters():
            if cls.name == name:
                return cls
        return None

    @staticmethod
    def list_adapters() -> list[dict[str, Any]]:
        """Return [{name, tier, available, reason}] for every registered adapter."""
        out: list[dict[str, Any]] = []
        for cls in all_adapters():
            ok, why = cls.is_available()
            out.append({"name": cls.name, "tier": cls.tier, "available": ok, "reason": why})
        return out
