# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jason Perlow
"""Unit tests for pick_fastest_in_tier — micro-bench + per-host cache."""
from __future__ import annotations

import json
import logging
import os
import time
from pathlib import Path
from typing import ClassVar

import pytest

from embedkit import pick as pick_mod
from embedkit.adapters import base
from embedkit.pick import pick_fastest_in_tier


class _BenchableAdapter(base.AbstractAdapter):
    """Fake adapter that takes a configurable delay per embed()."""

    name: ClassVar[str] = "base-bench"
    tier: ClassVar[str] = "cpu"
    model_format: ClassVar[str] = "gguf"
    embed_delay_sec: ClassVar[float] = 0.001

    def __init__(self, model_path: str = "fake-model", **kwargs: object) -> None:
        super().__init__(model_path=model_path, **kwargs)
        self.embed_dim = 4

    def embed(self, text: str) -> list[float]:
        time.sleep(self.embed_delay_sec)
        return [1.0, 0.0, 0.0, 0.0]

    def embed_batch(self, texts: list[str]) -> list[list[float]]:
        return [self.embed(t) for t in texts]

    def warmup(self) -> None:
        return None

    def close(self) -> None:
        return None

    @classmethod
    def is_available(cls) -> tuple[bool, str]:
        return True, "fake always available"


class FastFake(_BenchableAdapter):
    name: ClassVar[str] = "fast-fake"
    embed_delay_sec: ClassVar[float] = 0.0005


class SlowFake(_BenchableAdapter):
    name: ClassVar[str] = "slow-fake"
    embed_delay_sec: ClassVar[float] = 0.005


class BrokenFake(_BenchableAdapter):
    name: ClassVar[str] = "broken-fake"

    def embed(self, text: str) -> list[float]:
        raise RuntimeError("broken adapter")


@pytest.fixture
def isolated_cache(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    cache = tmp_path / "embedkit" / "bench.json"
    monkeypatch.setenv("XDG_CACHE_HOME", str(tmp_path))
    monkeypatch.delenv("EMBEDKIT_BENCH_FORCE", raising=False)
    # Bypass real resolve_model — accept any name, return a fake path.
    monkeypatch.setattr(pick_mod, "resolve_model", lambda name, model: "fake-model")
    return cache


def test_single_candidate_returns_without_bench(isolated_cache: Path) -> None:
    chosen = pick_fastest_in_tier([FastFake])
    assert chosen is FastFake
    assert not isolated_cache.exists()


def test_two_candidates_bench_picks_faster(isolated_cache: Path) -> None:
    chosen = pick_fastest_in_tier([SlowFake, FastFake], n=5)
    assert chosen is FastFake
    # Cache file written
    assert isolated_cache.exists()
    cache = json.loads(isolated_cache.read_text())
    # cache layout: {host: {model_key: {adapter_name: rec_per_sec}}}
    only_host = next(iter(cache.values()))
    model_cache = only_host["default"]
    assert "fast-fake" in model_cache
    assert "slow-fake" in model_cache
    assert model_cache["fast-fake"] > model_cache["slow-fake"]


def test_cache_hit_skips_bench(isolated_cache: Path) -> None:
    # First call: bench + persist
    pick_fastest_in_tier([SlowFake, FastFake], n=3)
    # Patch embed to raise — if cache miss this would fail
    original = FastFake.embed
    FastFake.embed = lambda self, text: (_ for _ in ()).throw(  # type: ignore[assignment]
        RuntimeError("should not be invoked on cache hit")
    )
    try:
        chosen = pick_fastest_in_tier([SlowFake, FastFake], n=3)
        assert chosen is FastFake
    finally:
        FastFake.embed = original  # type: ignore[assignment]


def test_force_rebench(isolated_cache: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    pick_fastest_in_tier([SlowFake, FastFake], n=3)
    monkeypatch.setenv("EMBEDKIT_BENCH_FORCE", "1")
    counter = {"calls": 0}
    original = FastFake.embed

    def counting_embed(self: FastFake, text: str) -> list[float]:
        counter["calls"] += 1
        return original(self, text)

    FastFake.embed = counting_embed  # type: ignore[assignment]
    try:
        pick_fastest_in_tier([SlowFake, FastFake], n=3)
        assert counter["calls"] >= 3
    finally:
        FastFake.embed = original  # type: ignore[assignment]


def test_new_candidate_triggers_rebench(isolated_cache: Path) -> None:
    """If the candidate set changes, a partial-cache hit must re-bench
    the new adapter rather than silently skip it."""
    pick_fastest_in_tier([SlowFake, FastFake], n=3)
    # Add a third candidate
    counter = {"calls": 0}
    original = BrokenFake.embed
    # BrokenFake throws — but we want to confirm we attempted to bench it.
    # Wrap embed to count instead of raising for this test.
    BrokenFake.embed = lambda self, text: [counter.setdefault("c", 0) or 0.0]  # type: ignore[assignment]
    BrokenFake.embed = lambda self, text: (counter.__setitem__("calls", counter["calls"] + 1) or [0.0, 0.0, 0.0, 0.0])  # type: ignore[assignment]
    try:
        pick_fastest_in_tier([SlowFake, FastFake, BrokenFake], n=3)
        assert counter["calls"] >= 1
    finally:
        BrokenFake.embed = original  # type: ignore[assignment]


def test_all_broken_falls_back_alphabetical(
    isolated_cache: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(pick_mod, "resolve_model", lambda name, model: "fake-model")
    chosen = pick_fastest_in_tier([BrokenFake, BrokenFake], n=3)
    # Same class twice — alphabetical fallback returns first
    assert chosen is BrokenFake


def test_empty_candidates_raises(isolated_cache: Path) -> None:
    with pytest.raises(RuntimeError, match="no candidates"):
        pick_fastest_in_tier([])


def test_cache_partition_by_model(isolated_cache: Path) -> None:
    pick_fastest_in_tier([SlowFake, FastFake], n=3, model="m1")
    pick_fastest_in_tier([SlowFake, FastFake], n=3, model="m2")
    cache = json.loads(isolated_cache.read_text())
    only_host = next(iter(cache.values()))
    assert "m1" in only_host
    assert "m2" in only_host


def test_cache_partition_by_host(
    isolated_cache: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(pick_mod, "_host_id", lambda: "host-a::arm64")
    pick_fastest_in_tier([SlowFake, FastFake], n=3)
    monkeypatch.setattr(pick_mod, "_host_id", lambda: "host-b::x86_64")
    pick_fastest_in_tier([SlowFake, FastFake], n=3)
    cache = json.loads(isolated_cache.read_text())
    assert "host-a::arm64" in cache
    assert "host-b::x86_64" in cache


def test_cache_corrupt_file_recovers(isolated_cache: Path) -> None:
    isolated_cache.parent.mkdir(parents=True, exist_ok=True)
    isolated_cache.write_text("not-json")
    # Should not raise; falls back to fresh cache + bench
    chosen = pick_fastest_in_tier([SlowFake, FastFake], n=3)
    assert chosen is FastFake


def test_one_broken_one_working_picks_working(isolated_cache: Path) -> None:
    chosen = pick_fastest_in_tier([BrokenFake, FastFake], n=3)
    assert chosen is FastFake

def test_all_failed_emits_warning(
    isolated_cache: 'Path', caplog: pytest.LogCaptureFixture
) -> None:
    """When all adapters fail to bench, two WARNING lines must be emitted:
    one naming the fallback, one structured summary with adapter names."""
    with caplog.at_level(logging.WARNING, logger="embedkit.pick"):
        chosen = pick_fastest_in_tier([BrokenFake], n=3)
    # BrokenFake is the only candidate — single-candidate fast-path returns
    # without benching, so use two BrokenFakes to force the all-failed branch.
    caplog.clear()
    # Use a second distinct broken adapter to have 2 candidates so bench runs.
    class AnotherBroken(_BenchableAdapter):
        name: ClassVar[str] = "another-broken"

        def embed(self, text: str) -> list[float]:
            raise RuntimeError("also broken")

    with caplog.at_level(logging.WARNING, logger="embedkit.pick"):
        chosen = pick_fastest_in_tier([BrokenFake, AnotherBroken], n=3)

    warning_msgs = [r.message for r in caplog.records if r.levelno == logging.WARNING]
    assert any("every bench failed" in m for m in warning_msgs), (
        "Expected 'every bench failed' WARNING not emitted"
    )
    assert any("all-failed fallback active" in m for m in warning_msgs), (
        "Expected structured all-failed WARNING not emitted"
    )
    assert any("unreliable" in m for m in warning_msgs), (
        "Expected 'unreliable' in structured WARNING"
    )
    # Returned adapter must be one of the candidates (alphabetical fallback)
    assert chosen.name in {"broken-fake", "another-broken"}
