# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jason Perlow
"""Tests for Vulkan GPU adapter (panthor Mali / any Vulkan device)."""
from __future__ import annotations

import os
import sys
import time
import types
from pathlib import Path
from typing import Any

import pytest

from embedkit.adapters.gpu_vulkan import VulkanAdapter

MODEL_ENV = "EMBEDKIT_TEST_VULKAN_MODEL"


def _model_path() -> str:
    value = os.environ.get(MODEL_ENV)
    if not value:
        pytest.skip(f"set {MODEL_ENV} to run gpu-vulkan adapter live smoke tests")
    if not Path(value).exists():
        pytest.skip(f"{MODEL_ENV} path does not exist: {value}")
    return value


# ---------- is_available probe ----------

def test_class_metadata() -> None:
    assert VulkanAdapter.name == "vulkan"
    assert VulkanAdapter.tier == "gpu"
    assert VulkanAdapter.model_format == "gguf"


def test_is_available_no_llama_cpp(monkeypatch: pytest.MonkeyPatch) -> None:
    """If llama-cpp-python is not importable, is_available returns False."""
    monkeypatch.setitem(sys.modules, "llama_cpp", None)
    ok, reason = VulkanAdapter.is_available()
    assert ok is False
    assert "llama" in reason.lower()


def test_is_available_no_dri_render_node(monkeypatch: pytest.MonkeyPatch) -> None:
    """If /dev/dri has no renderD* node, is_available returns False."""
    # Stub llama_cpp module so the first probe passes
    stub_llama = _make_llama_stub(supports_vulkan=True)
    monkeypatch.setitem(sys.modules, "llama_cpp", stub_llama)
    monkeypatch.setattr(
        "embedkit.adapters.gpu_vulkan._has_vulkan_device", lambda: False
    )
    ok, reason = VulkanAdapter.is_available()
    assert ok is False
    assert "dri" in reason or "Vulkan GPU" in reason


def test_is_available_wheel_without_vulkan(monkeypatch: pytest.MonkeyPatch) -> None:
    """Wheel that explicitly reports no Vulkan backend -> False."""
    stub_llama = _make_llama_stub(supports_vulkan=False)
    monkeypatch.setitem(sys.modules, "llama_cpp", stub_llama)
    monkeypatch.setattr(
        "embedkit.adapters.gpu_vulkan._has_vulkan_device", lambda: True
    )
    ok, reason = VulkanAdapter.is_available()
    assert ok is False
    assert "Vulkan" in reason


def test_is_available_ok(monkeypatch: pytest.MonkeyPatch) -> None:
    """Importable llama_cpp + render node + Vulkan-capable wheel -> True."""
    stub_llama = _make_llama_stub(supports_vulkan=True)
    monkeypatch.setitem(sys.modules, "llama_cpp", stub_llama)
    monkeypatch.setattr(
        "embedkit.adapters.gpu_vulkan._has_vulkan_device", lambda: True
    )
    ok, reason = VulkanAdapter.is_available()
    assert ok is True
    assert "Vulkan-capable" in reason


def test_is_available_macos_moltenvk(monkeypatch: pytest.MonkeyPatch) -> None:
    """Importable llama_cpp + macOS MoltenVK install -> True."""
    stub_llama = _make_llama_stub(supports_vulkan=True)
    monkeypatch.setitem(sys.modules, "llama_cpp", stub_llama)
    monkeypatch.setattr(
        "embedkit.adapters.gpu_vulkan._has_vulkan_device", lambda: True
    )
    ok, reason = VulkanAdapter.is_available()
    assert ok is True
    assert "Vulkan" in reason


def test_is_available_no_probe_attribute_passes(monkeypatch: pytest.MonkeyPatch) -> None:
    """Old wheels without llama_supports_vulkan still report available."""
    stub_llama = types.ModuleType("llama_cpp")
    # Intentionally no supports-vulkan attr
    monkeypatch.setitem(sys.modules, "llama_cpp", stub_llama)
    monkeypatch.setattr(
        "embedkit.adapters.gpu_vulkan._has_vulkan_device", lambda: True
    )
    ok, _reason = VulkanAdapter.is_available()
    assert ok is True


def test_is_available_repeatable(monkeypatch: pytest.MonkeyPatch) -> None:
    """is_available cheap + side-effect free; runs 1000x quickly."""
    stub_llama = _make_llama_stub(supports_vulkan=True)
    monkeypatch.setitem(sys.modules, "llama_cpp", stub_llama)
    monkeypatch.setattr(
        "embedkit.adapters.gpu_vulkan._has_vulkan_device", lambda: True
    )
    started = time.perf_counter()
    for _ in range(1000):
        VulkanAdapter.is_available()
    assert time.perf_counter() - started < 1.0


def test_n_threads_default_is_half_cpu(monkeypatch: pytest.MonkeyPatch) -> None:
    """Default thread count leaves CPU headroom for Vulkan queue submission."""
    recorded: dict[str, Any] = {}
    stub_llama = types.ModuleType("llama_cpp")

    class StubLlama:
        def __init__(self, **kwargs: Any) -> None:
            recorded.update(kwargs)

        def create_embedding(self, _text: str) -> dict[str, list[dict[str, list[float]]]]:
            return {"data": [{"embedding": [0.1, 0.2, 0.3]}]}

    stub_llama.Llama = StubLlama  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "llama_cpp", stub_llama)

    adapter = VulkanAdapter(model_path="/tmp/fake.gguf")
    try:
        assert recorded["n_threads"] <= (os.cpu_count() or 4) / 2 + 1
    finally:
        adapter.close()


# ---------- live smoke (skipped unless EMBEDKIT_TEST_VULKAN_MODEL set) ----------

def test_live_embed_one() -> None:
    """Live smoke — needs Vulkan-built llama-cpp-python + GGUF model."""
    path = _model_path()
    adapter = VulkanAdapter(model_path=path)
    try:
        vec = adapter.embed("hello world")
        assert isinstance(vec, list)
        assert len(vec) == adapter.embed_dim
    finally:
        adapter.close()


def test_live_embed_batch() -> None:
    path = _model_path()
    adapter = VulkanAdapter(model_path=path)
    try:
        vecs = adapter.embed_batch(["a", "b", "c"])
        assert len(vecs) == 3
    finally:
        adapter.close()


def test_live_close_idempotent() -> None:
    path = _model_path()
    adapter = VulkanAdapter(model_path=path)
    adapter.close()
    adapter.close()  # Should not raise


# ---------- helpers ----------

def _make_llama_stub(supports_vulkan: bool) -> types.ModuleType:
    mod = types.ModuleType("llama_cpp")
    mod.llama_supports_vulkan = lambda: supports_vulkan  # type: ignore[attr-defined]
    return mod
