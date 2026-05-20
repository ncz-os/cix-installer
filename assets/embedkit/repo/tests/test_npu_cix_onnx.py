# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jason Perlow
"""Tests for Cix Zhouyi V3 NPU adapter via ONNX Runtime.

Unit tests use monkeypatched stubs so they run on hosts without /dev/aipu.
Live smoke tests gate on EMBEDKIT_TEST_CIX_ONNX_MODEL env var (skipped
when absent).
"""
from __future__ import annotations

import os
import sys
import time
import types
from pathlib import Path
from typing import Any

import pytest

# Import the adapter module without triggering onnxruntime import.
from embedkit.adapters.npu_cix_onnx import CIX_EP_NAME, CixOnnxAdapter

MODEL_ENV = "EMBEDKIT_TEST_CIX_ONNX_MODEL"


def _model_path() -> str:
    value = os.environ.get(MODEL_ENV)
    if not value:
        pytest.skip(f"set {MODEL_ENV} to run cix-npu-onnx live smoke tests")
    if not Path(value).exists():
        pytest.skip(f"{MODEL_ENV} path does not exist: {value}")
    return value


# ---------- is_available probe ----------

def test_is_available_safe_no_aipu(monkeypatch: pytest.MonkeyPatch) -> None:
    """Without /dev/aipu, is_available returns False fast."""
    monkeypatch.setattr("embedkit.adapters.npu_cix_onnx.Path", _path_no_aipu_stub())
    ok, reason = CixOnnxAdapter.is_available()
    assert ok is False
    assert "aipu" in reason


def test_is_available_safe_repeatable(monkeypatch: pytest.MonkeyPatch) -> None:
    """is_available is cheap + side-effect free — run 1000x quickly."""
    monkeypatch.setattr("embedkit.adapters.npu_cix_onnx.Path", _path_no_aipu_stub())
    started = time.perf_counter()
    for _ in range(1000):
        ok, _ = CixOnnxAdapter.is_available()
        assert isinstance(ok, bool)
    assert time.perf_counter() - started < 1.0


def test_is_available_no_onnxruntime(monkeypatch: pytest.MonkeyPatch) -> None:
    """If onnxruntime import fails, is_available returns False with reason."""
    monkeypatch.setattr("embedkit.adapters.npu_cix_onnx.Path", _path_with_aipu_stub())
    # Force import failure
    sys_modules_backup = sys.modules.get("onnxruntime")
    monkeypatch.setitem(sys.modules, "onnxruntime", None)
    try:
        ok, reason = CixOnnxAdapter.is_available()
        assert ok is False
        assert "onnxruntime" in reason.lower()
    finally:
        if sys_modules_backup is not None:
            sys.modules["onnxruntime"] = sys_modules_backup


def test_is_available_no_cix_ep(monkeypatch: pytest.MonkeyPatch) -> None:
    """If CixNpuExecutionProvider not registered, is_available is False."""
    monkeypatch.setattr("embedkit.adapters.npu_cix_onnx.Path", _path_with_aipu_stub())
    stub_ort = _make_ort_stub(providers=["CPUExecutionProvider"])
    monkeypatch.setitem(sys.modules, "onnxruntime", stub_ort)
    ok, reason = CixOnnxAdapter.is_available()
    assert ok is False
    assert CIX_EP_NAME in reason


def test_is_available_ok(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("embedkit.adapters.npu_cix_onnx.Path", _path_with_aipu_stub())
    stub_ort = _make_ort_stub(providers=[CIX_EP_NAME, "CPUExecutionProvider"])
    monkeypatch.setitem(sys.modules, "onnxruntime", stub_ort)
    ok, reason = CixOnnxAdapter.is_available()
    assert ok is True
    assert "/dev/aipu" in reason


# ---------- adapter metadata ----------

def test_class_metadata() -> None:
    assert CixOnnxAdapter.name == "cix-npu-onnx"
    assert CixOnnxAdapter.tier == "npu"
    assert CixOnnxAdapter.model_format == "onnx"


# ---------- live smoke (skipped unless EMBEDKIT_TEST_CIX_ONNX_MODEL set) ----------

def test_live_embed_one() -> None:
    """Live smoke — requires real ONNX model + cix-npu-onnxruntime installed."""
    path = _model_path()
    adapter = CixOnnxAdapter(model_path=path)
    try:
        vec = adapter.embed("hello world")
        assert isinstance(vec, list)
        assert len(vec) == adapter.embed_dim
        assert all(isinstance(x, float) for x in vec)
    finally:
        adapter.close()


def test_live_embed_batch() -> None:
    path = _model_path()
    adapter = CixOnnxAdapter(model_path=path)
    try:
        vecs = adapter.embed_batch(["a", "b", "c"])
        assert len(vecs) == 3
        assert all(len(v) == adapter.embed_dim for v in vecs)
    finally:
        adapter.close()


def test_live_close_idempotent() -> None:
    path = _model_path()
    adapter = CixOnnxAdapter(model_path=path)
    adapter.close()
    adapter.close()  # Should not raise


# ---------- helpers ----------

def _path_no_aipu_stub() -> type:
    """Path subclass where /dev/aipu does NOT exist."""

    class _StubPath(type(Path())):  # type: ignore[misc]
        def exists(self) -> bool:
            if str(self) == "/dev/aipu":
                return False
            return Path(str(self)).exists()

    return _StubPath


def _path_with_aipu_stub() -> type:
    """Path subclass where /dev/aipu exists (pretend)."""

    class _StubPath(type(Path())):  # type: ignore[misc]
        def exists(self) -> bool:
            if str(self) == "/dev/aipu":
                return True
            return Path(str(self)).exists()

    return _StubPath


def _make_ort_stub(providers: list[str]) -> types.ModuleType:
    """Return a fake `onnxruntime` module with get_available_providers()."""
    mod = types.ModuleType("onnxruntime")
    mod.get_available_providers = lambda: providers  # type: ignore[attr-defined]

    class _SessionOptions:
        intra_op_num_threads: int = 0

    class _InferenceSession:
        def __init__(self, *args: Any, **kwargs: Any) -> None:
            raise RuntimeError("stub session — not for live invocation")

    mod.SessionOptions = _SessionOptions  # type: ignore[attr-defined]
    mod.InferenceSession = _InferenceSession  # type: ignore[attr-defined]
    return mod
