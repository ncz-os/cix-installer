# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jason Perlow
from __future__ import annotations

import os
import time
from pathlib import Path

import pytest

from embedkit.adapters.gpu_nvidia_cuda import NvidiaCUDAAdapter

AVAILABLE = NvidiaCUDAAdapter.is_available()[0]
MODEL_ENV = "EMBEDKIT_TEST_NVIDIA_CUDA_MODEL"
TOKENIZER_ENV = "EMBEDKIT_TEST_NVIDIA_CUDA_TOKENIZER"


def _model_path() -> str:
    value = os.environ.get(MODEL_ENV)
    if not value:
        pytest.skip(f"set {MODEL_ENV} to run nvidia-cuda adapter smoke tests")
    if not Path(value).exists():
        pytest.skip(f"{MODEL_ENV} path does not exist: {value}")
    return value


def _tokenizer_path() -> str | None:
    value = os.environ.get(TOKENIZER_ENV)
    if value and not Path(value).exists():
        pytest.skip(f"{TOKENIZER_ENV} path does not exist: {value}")
    return value


def test_is_available_safe() -> None:
    started = time.perf_counter()
    for _ in range(1000):
        ok, reason = NvidiaCUDAAdapter.is_available()
        assert isinstance(ok, bool)
        assert isinstance(reason, str)
        assert reason
    assert time.perf_counter() - started < 10.0


@pytest.mark.skipif(not AVAILABLE, reason="adapter unavailable")
def test_embed_dim_consistent() -> None:
    adapter = NvidiaCUDAAdapter(
        _model_path(),
        tokenizer_path=_tokenizer_path(),
        max_tokens=128,
    )
    try:
        short = adapter.embed("hello")
        long = adapter.embed("this is a longer embedding input " * 64)
        assert len(short) == adapter.embed_dim
        assert len(long) == adapter.embed_dim
    finally:
        adapter.close()


@pytest.mark.skipif(not AVAILABLE, reason="adapter unavailable")
def test_close_idempotent() -> None:
    adapter = NvidiaCUDAAdapter(
        _model_path(),
        tokenizer_path=_tokenizer_path(),
        max_tokens=128,
    )
    adapter.close()
    adapter.close()
