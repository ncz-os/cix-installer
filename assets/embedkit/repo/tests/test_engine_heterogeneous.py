# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jason Perlow
"""Unit tests for Engine.heterogeneous() dual-adapter routing.

Uses two in-process fake adapters so the test runs anywhere without real
silicon. The fakes record which embeds went to which adapter so the test
can assert routing by length threshold.
"""
from __future__ import annotations

from typing import ClassVar

import pytest

from embedkit.adapters import base
from embedkit.engine import Engine


class _FakeAdapter(base.AbstractAdapter):
    """In-process fake. Records every call into class-level lists."""

    name: ClassVar[str] = "fake-base"
    tier: ClassVar[str] = "cpu"
    model_format: ClassVar[str] = "gguf"

    def __init__(self, model_path: str = "fake-model", **kwargs: object) -> None:
        super().__init__(model_path=model_path, **kwargs)
        self.embed_dim = 4
        self.max_tokens = 256
        self.calls: list[str] = []

    def embed(self, text: str) -> list[float]:
        self.calls.append(text)
        return [float(len(text)), 0.0, 0.0, 0.0]

    def embed_batch(self, texts: list[str]) -> list[list[float]]:
        return [self.embed(t) for t in texts]

    def warmup(self) -> None:
        return None

    def close(self) -> None:
        return None

    @classmethod
    def is_available(cls) -> tuple[bool, str]:
        return True, "fake always available"


class FakeShort(_FakeAdapter):
    name: ClassVar[str] = "fake-short"
    tier: ClassVar[str] = "npu"


class FakeLong(_FakeAdapter):
    name: ClassVar[str] = "fake-long"
    tier: ClassVar[str] = "cpu"


@pytest.fixture
def register_fakes(monkeypatch: pytest.MonkeyPatch) -> None:
    """Register the fake adapters in the embedkit registry for the test."""
    from embedkit import adapters as adapters_mod

    def _all_adapters() -> list[type[base.AbstractAdapter]]:
        return [FakeShort, FakeLong]

    monkeypatch.setattr(adapters_mod, "all_adapters", _all_adapters)
    # engine.py imports all_adapters by name — patch there too
    from embedkit import engine as engine_mod
    monkeypatch.setattr(engine_mod, "all_adapters", _all_adapters)
    # resolve_model: bypass the real registry
    monkeypatch.setattr(engine_mod, "resolve_model", lambda name, model: "fake-model")


def test_short_routes_to_short_adapter(register_fakes: None) -> None:
    eng = Engine.heterogeneous(
        short=("fake-short", {}),
        long=("fake-long", {}),
        threshold_chars=10,
    )
    vec = eng.embed("hi")
    assert isinstance(vec, list)
    assert eng._short.calls == ["hi"]  # type: ignore[attr-defined]
    assert eng._long.calls == []  # type: ignore[attr-defined]


def test_long_routes_to_long_adapter(register_fakes: None) -> None:
    eng = Engine.heterogeneous(
        short=("fake-short", {}),
        long=("fake-long", {}),
        threshold_chars=10,
    )
    payload = "x" * 200
    eng.embed(payload)
    assert eng._short.calls == []  # type: ignore[attr-defined]
    assert eng._long.calls == [payload]  # type: ignore[attr-defined]


def test_threshold_boundary_inclusive_short(register_fakes: None) -> None:
    """len(text) == threshold goes to short (<= comparison)."""
    eng = Engine.heterogeneous(
        short=("fake-short", {}),
        long=("fake-long", {}),
        threshold_chars=5,
    )
    eng.embed("abcde")  # len=5, inclusive
    eng.embed("abcdef")  # len=6, over
    assert eng._short.calls == ["abcde"]  # type: ignore[attr-defined]
    assert eng._long.calls == ["abcdef"]  # type: ignore[attr-defined]


def test_negative_threshold_raises(register_fakes: None) -> None:
    with pytest.raises(ValueError, match="threshold_chars must be >= 0"):
        Engine.heterogeneous(
            short=("fake-short", {}),
            long=("fake-long", {}),
            threshold_chars=-1,
        )


def test_zero_threshold_empty_string(register_fakes: None) -> None:
    eng = Engine.heterogeneous(
        short=("fake-short", {}),
        long=("fake-long", {}),
        threshold_chars=0,
    )
    eng.embed("")
    assert eng._short.calls == [""]  # type: ignore[attr-defined]
    assert eng._long.calls == []  # type: ignore[attr-defined]


def test_zero_threshold_nonempty_string(register_fakes: None) -> None:
    eng = Engine.heterogeneous(
        short=("fake-short", {}),
        long=("fake-long", {}),
        threshold_chars=0,
    )
    eng.embed("a")
    assert eng._short.calls == []  # type: ignore[attr-defined]
    assert eng._long.calls == ["a"]  # type: ignore[attr-defined]


def test_embed_batch_preserves_order(register_fakes: None) -> None:
    """Mixed-length batch must come back in original input order."""
    eng = Engine.heterogeneous(
        short=("fake-short", {}),
        long=("fake-long", {}),
        threshold_chars=10,
    )
    inputs = ["a", "x" * 200, "bc", "y" * 100, "def"]
    vecs = eng.embed_batch(inputs)
    assert len(vecs) == 5
    # vector[0] is len of input text under our fake impl
    expected_lens = [float(len(t)) for t in inputs]
    actual_lens = [v[0] for v in vecs]
    assert actual_lens == expected_lens


def test_embed_batch_handles_all_short(register_fakes: None) -> None:
    eng = Engine.heterogeneous(
        short=("fake-short", {}),
        long=("fake-long", {}),
        threshold_chars=100,
    )
    vecs = eng.embed_batch(["a", "b", "c"])
    assert len(vecs) == 3
    assert eng._long.calls == []  # type: ignore[attr-defined]


def test_embed_batch_handles_all_long(register_fakes: None) -> None:
    eng = Engine.heterogeneous(
        short=("fake-short", {}),
        long=("fake-long", {}),
        threshold_chars=1,
    )
    vecs = eng.embed_batch(["aa", "bb", "cc"])
    assert len(vecs) == 3
    assert eng._short.calls == []  # type: ignore[attr-defined]


def test_info_reports_both_adapters(register_fakes: None) -> None:
    eng = Engine.heterogeneous(
        short=("fake-short", {}),
        long=("fake-long", {}),
        threshold_chars=512,
    )
    info = eng.info()
    assert info["routing"] == "heterogeneous"
    assert info["threshold_chars"] == 512
    assert info["short"]["adapter"] == "fake-short"
    assert info["long"]["adapter"] == "fake-long"


def test_close_closes_both(register_fakes: None) -> None:
    eng = Engine.heterogeneous(
        short=("fake-short", {}),
        long=("fake-long", {}),
        threshold_chars=10,
    )
    # Should not raise
    eng.close()


def test_close_both_adapters_called_when_first_raises(
    register_fakes: None,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    eng = Engine.heterogeneous(
        short=("fake-short", {}),
        long=("fake-long", {}),
        threshold_chars=10,
    )
    calls: list[str] = []

    def short_close() -> None:
        calls.append("short")
        raise RuntimeError("short close failed")

    def long_close() -> None:
        calls.append("long")

    monkeypatch.setattr(eng._short, "close", short_close)
    monkeypatch.setattr(eng._long, "close", long_close)

    with pytest.raises(RuntimeError, match="short close failed"):
        eng.close()
    assert calls == ["short", "long"]


def test_homogeneous_engine_unchanged_by_heterogeneous_code(register_fakes: None) -> None:
    """Plain Engine() still works (no _heterogeneous attr) — regression guard."""
    eng = Engine(adapter="fake-short")
    eng.embed("hello")
    info = eng.info()
    assert info["adapter"] == "fake-short"
    assert "routing" not in info
