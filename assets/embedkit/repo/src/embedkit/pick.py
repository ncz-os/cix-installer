# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jason Perlow
"""auto() picker — capability tier first, measured throughput within tier.

No vendor preference. The kit ranks by measured throughput per host, not
by registry order or any static priority list.

Micro-bench: 50 short text records, single embed() per record, median
rec/sec. Result cached per (host_id, model_id, adapter_name) under
$XDG_CACHE_HOME/embedkit/bench.json (default ~/.cache/embedkit/bench.json)
so repeated Engine.auto() calls are O(1) after the first run on a host.

Cache invalidation: stale entries are kept; force a re-bench by deleting
the file or setting EMBEDKIT_BENCH_FORCE=1.
"""
from __future__ import annotations

import json
import logging
import os
import platform
import socket
import statistics
import time
from collections.abc import Iterable
from pathlib import Path
from typing import Any

from .adapters import AbstractAdapter
from .models import resolve_model

log = logging.getLogger("embedkit.pick")

# Canonical 50-record bench corpus. Short, deterministic, no external
# fetch. Lengths chosen to land under any reasonable NPU token cap so
# the bench is comparable across short-input and long-input adapters.
_BENCH_CORPUS: tuple[str, ...] = tuple(
    f"benchmark sample number {i:02d} for embedkit micro-bench throughput probe"
    for i in range(50)
)


def _cache_path() -> Path:
    base = os.environ.get("XDG_CACHE_HOME") or str(Path.home() / ".cache")
    return Path(base) / "embedkit" / "bench.json"


def _host_id() -> str:
    """Stable per-host key: hostname + machine arch."""
    return f"{socket.gethostname()}::{platform.machine()}"


def _load_cache() -> dict[str, Any]:
    p = _cache_path()
    if not p.exists():
        return {}
    try:
        return json.loads(p.read_text())
    except (OSError, ValueError) as exc:
        log.warning("bench cache unreadable at %s: %s", p, exc)
        return {}


def _save_cache(cache: dict[str, Any]) -> None:
    p = _cache_path()
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        tmp = p.with_suffix(f".{os.getpid()}.tmp")
        tmp.write_text(json.dumps(cache, indent=2, sort_keys=True))
        tmp.replace(p)
    except OSError as exc:
        log.warning("bench cache write failed at %s: %s", p, exc)


def _bench_one(
    adapter_cls: type[AbstractAdapter],
    model: str | None,
    n: int,
) -> float | None:
    """Construct, warmup, run n embed() calls, return true median rec/sec.

    Metric is per-call latency-derived throughput, suitable for one-at-a-time
    embed() calls; batch users should benchmark separately.

    Corpus is 80-char ASCII English; CJK / long-doc rankings may differ.

    Returns None on construction or runtime failure.
    """
    try:
        model_path = resolve_model(adapter_cls.name, model)
        adapter = adapter_cls(model_path=model_path)
        adapter.warmup()
    except Exception as exc:
        log.info("bench %s: construction failed (%s)", adapter_cls.name, exc)
        return None

    try:
        per_record_sec: list[float] = []
        sample = _BENCH_CORPUS[:n]
        for text in sample:
            t0 = time.perf_counter()
            adapter.embed(text)
            per_record_sec.append(time.perf_counter() - t0)
        # Use true median to suppress one-off stalls (cold cache, GC, etc).
        mid = statistics.median(per_record_sec)
        if mid <= 0:
            return None
        return 1.0 / mid
    except Exception as exc:
        log.info("bench %s: runtime failure (%s)", adapter_cls.name, exc)
        return None
    finally:
        try:
            adapter.close()
        except Exception as exc:
            log.debug("bench %s close failed: %s", adapter_cls.name, exc)


def pick_fastest_in_tier(
    candidates: Iterable[type[AbstractAdapter]],
    *,
    model: str | None = None,
    n: int = 50,
    force: bool | None = None,
) -> type[AbstractAdapter]:
    """Return the fastest adapter class for this host within the candidate set.

    Selection policy:
      1. With 0 candidates: raise RuntimeError.
      2. With 1 candidate: return it without bench (no choice to make).
      3. With 2+ candidates: consult per-host cache. On cache hit pick
         the cached winner if still present in `candidates`. On miss or
         force=True, run a 50-record micro-bench against each adapter
         and persist the result.

    Cache key: (host_id, model_id, adapter_name) -> rec_per_sec.
    Cache invalidation: delete ~/.cache/embedkit/bench.json or set
    EMBEDKIT_BENCH_FORCE=1.

    Args:
      candidates: adapter classes in the same tier whose is_available()
                  has already returned True.
      model: model spec passed to resolve_model() for each adapter.
      n: number of records to time per adapter. Default 50.
      force: ignore cache and re-bench. Defaults to env var
             EMBEDKIT_BENCH_FORCE=1 truthy check.

    Returns:
      The adapter class with the highest measured rec/sec on this host.
      Falls back to the alphabetically-first candidate if every adapter
      failed to bench (e.g. no model artifact on disk). In that case two
      WARNING log lines are emitted: one naming the fallback adapter and
      one structured summary listing all adapter names so callers can
      detect unreliable selection via log monitoring.
    """
    cands = list(candidates)
    if not cands:
        raise RuntimeError("pick_fastest_in_tier called with no candidates")
    if len(cands) == 1:
        log.info("pick_fastest_in_tier: only candidate %s", cands[0].name)
        return cands[0]

    if force is None:
        force = os.environ.get("EMBEDKIT_BENCH_FORCE", "").lower() in ("1", "true", "yes")

    model_key = model or "default"
    host_key = _host_id()
    cache = _load_cache()
    host_cache = cache.setdefault(host_key, {})
    model_cache = host_cache.setdefault(model_key, {})

    cand_names = {c.name for c in cands}
    if not force:
        # Cache hit only if every candidate has a recorded score (so a
        # newly-added adapter triggers a re-bench instead of being
        # silently skipped from the comparison).
        if cand_names.issubset(model_cache.keys()):
            scored = [(model_cache[c.name], c) for c in cands]
            scored.sort(key=lambda t: t[0], reverse=True)
            chosen = scored[0][1]
            log.info("pick_fastest_in_tier(cache hit): %s rec/s=%.2f among %s",
                     chosen.name, scored[0][0],
                     {c.name: f"{model_cache[c.name]:.2f}" for c in cands})
            return chosen
        log.info("pick_fastest_in_tier: cache miss for some candidates (have=%s, need=%s)",
                 list(model_cache.keys()), sorted(cand_names))

    # Bench every candidate. Persist whatever we measured.
    scores: dict[str, float] = {}
    for cls in cands:
        rps = _bench_one(cls, model, n=n)
        if rps is not None:
            scores[cls.name] = rps
            model_cache[cls.name] = rps
            log.info("bench %s: %.2f rec/s", cls.name, rps)

    _save_cache(cache)

    if not scores:
        # Every adapter failed to bench. Last-resort alphabetical pick
        # so Engine.auto() can still return something the user can
        # introspect via .info().
        fallback = sorted(cands, key=lambda c: c.name)[0]
        log.warning("pick_fastest_in_tier: every bench failed; fallback to %s",
                    fallback.name)
        log.warning(
            "pick_fastest_in_tier: all-failed fallback active; "
            "adapters=%s; selection may be unreliable (no timing data)",
            sorted(c.name for c in cands),
        )
        return fallback

    winner_name = max(scores, key=lambda k: scores[k])
    winner = next(c for c in cands if c.name == winner_name)
    log.info("pick_fastest_in_tier(measured): %s rec/s=%.2f among %s",
             winner_name, scores[winner_name],
             {n: f"{r:.2f}" for n, r in scores.items()})
    return winner
