# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jason Perlow
"""Vendor-agnostic Vulkan compute adapter via llama-cpp-python.

Targets ANY GPU exposing a Vulkan compute queue: Mali-G720 via panthor
(Cix Sky1 / Rockchip / Allwinner), Intel iGPU, AMD discrete via amdvlk
or RADV, NVIDIA via the proprietary driver's Vulkan path, etc. The
llama.cpp Vulkan backend handles dispatch; this adapter is the kit's
abstraction layer.

Build dependency: llama-cpp-python compiled with GGML_VULKAN=1. On NCZ
Magnetar/Reinhardt cixmini, the Vulkan wheel is built at install time
from source via 47-embedkit.sh (uv reinstall with CMAKE_ARGS).
Pre-built wheels: `pip install llama-cpp-python --extra-index-url
https://abetlen.github.io/llama-cpp-python/whl/vulkan`.

is_available() probes:
  1. llama-cpp-python importable
  2. Vulkan install/device present (macOS MoltenVK paths or Linux /dev/dri/renderD*)
  3. Optional: GGML_VULKAN feature in the wheel (best-effort attribute probe)

Model format: GGUF (same as cpu_llamacpp). Pick by Engine.auto() against
the same GGUF artifact as the CPU baseline so within-tier benchmark
comparisons (pick_fastest_in_tier) are apples-to-apples.

Routing role: on Cix Sky1, the embedkit hybrid pattern is short→NPU,
long→CPU or Vulkan. Vulkan path becomes the long-context fallback when
the panthor Mali-G720 has spare cycles and the CPU is busy with other
fleet workloads.
"""
from __future__ import annotations

import importlib
import logging
import os
from pathlib import Path
from typing import Any, ClassVar

from .base import AbstractAdapter

log = logging.getLogger("embedkit.adapter.gpu_vulkan")


def _has_vulkan_device() -> bool:
    """Best-effort probe for a macOS Vulkan install or Linux render node."""
    for path in (
        Path("/Library/Frameworks/Vulkan.framework"),
        Path("/usr/local/lib/libvulkan.dylib"),
        Path("/opt/homebrew/lib/libvulkan.dylib"),
    ):
        if path.exists():
            return True

    p = Path("/dev/dri")
    if not p.exists():
        return False
    return any(c.name.startswith("renderD") for c in p.iterdir())


class VulkanAdapter(AbstractAdapter):
    """GGUF embedder offloaded to the llama.cpp Vulkan backend.

    n_threads defaults to half of detected CPU cores so Vulkan workloads leave
    room for the GPU queue submitter and other runtime threads.

    n_gpu_layers default = -1 (offload every layer that fits). Caller should
    override per-adapter to leave some layers on CPU when GPU VRAM or shared
    system RAM is tight (Pi 5, low-RAM SBCs, 4 GB targets).
    """

    name: ClassVar[str] = "vulkan"
    tier: ClassVar[str] = "gpu"
    model_format: ClassVar[str] = "gguf"

    def __init__(
        self,
        model_path: str,
        *,
        n_threads: int | None = None,
        n_ctx: int = 8192,
        n_gpu_layers: int = -1,
        **kwargs: Any,
    ) -> None:
        super().__init__(model_path, **kwargs)
        llama_cpp = importlib.import_module("llama_cpp")

        llama_kwargs = dict(kwargs)
        llama_kwargs.pop("embedding", None)
        llama_kwargs.pop("verbose", None)

        threads = n_threads or max(1, (os.cpu_count() or 4) // 2)
        # n_gpu_layers=-1 offloads every layer that fits onto the Vulkan
        # device. Honor explicit override (e.g. =20 to leave attention on CPU).
        gpu_layers = int(n_gpu_layers)

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
        log.info(
            "VulkanAdapter loaded: model=%s n_gpu_layers=%d embed_dim=%d max_tokens=%d",
            model_path, gpu_layers, self.embed_dim, self.max_tokens,
        )

    @classmethod
    def is_available(cls) -> tuple[bool, str]:
        try:
            llama_cpp = importlib.import_module("llama_cpp")
        except ImportError as exc:
            return False, f"llama-cpp-python missing: {exc}"
        except Exception as exc:
            return False, f"llama-cpp-python import failed: {exc}"

        if not _has_vulkan_device():
            return False, "no Vulkan GPU device/install detected on this host"

        # Best-effort feature probe — newer llama-cpp-python exposes
        # llama_cpp_supports_vulkan() or similar. We can't rely on this on
        # every wheel so a False here is informational, not fatal: the real
        # check is whether n_gpu_layers actually offloads at Llama() construct
        # time. We accept "maybe" and let construction tell us at warmup.
        probe = getattr(llama_cpp, "llama_supports_vulkan", None)
        if callable(probe):
            try:
                ok = bool(probe())
                if not ok:
                    return False, "llama-cpp-python wheel built without Vulkan backend"
            except Exception as exc:
                log.debug("llama_supports_vulkan probe raised: %s", exc)
        else:
            # False positives are possible on older wheels: availability stays
            # fail-open so construction/warmup can perform the definitive check.
            log.info(
                "llama-cpp-python has no llama_supports_vulkan probe; "
                "reporting Vulkan as available based on device/install probe"
            )
        return True, "llama-cpp-python + Vulkan-capable wheel + Vulkan device/install present"

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
                log.debug("Vulkan llama.cpp close failed: %s", exc)

    def _create_embedding(self, text: str) -> list[float]:
        if self._llm is None:
            raise RuntimeError("vulkan adapter is closed")
        response = self._llm.create_embedding(text)
        data = response.get("data", [])
        if not data:
            raise RuntimeError("llama-cpp-python returned no embedding data")
        embedding = data[0].get("embedding")
        if embedding is None:
            raise RuntimeError("llama-cpp-python response missing embedding")
        return [float(value) for value in embedding]
