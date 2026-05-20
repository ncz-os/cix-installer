"""Adapter registry.

Adapters are imported lazily so a missing optional dependency on one
adapter (e.g. `mlx` not installed on a Linux box) does not break the
whole kit. Engine.auto() iterates the registry, calls is_available()
on each class, and picks the fastest among those that report True
within the highest-populated tier.
"""
from __future__ import annotations

from .base import AbstractAdapter

# Adapters registered alphabetically. ORDER HAS NO SEMANTIC MEANING.
# auto() picks within capability tier by measured throughput, not by
# this list order.
_REGISTRY_NAMES: list[tuple[str, str]] = [
    ("cpu_llamacpp",      "CPULlamaCppAdapter"),
    ("cpu_sbert",         "CPUSBertAdapter"),
    ("gpu_amd_rocm",      "AMDROCmAdapter"),
    ("gpu_apple_mlx",     "AppleMLXAdapter"),
    ("gpu_intel_igpu",    "IntelIGPUAdapter"),
    ("gpu_nvidia_cuda",   "NvidiaCUDAAdapter"),
    ("gpu_nvidia_trt",    "NvidiaTRTAdapter"),
    ("gpu_vulkan",        "VulkanAdapter"),
    ("npu_amd_xdna",      "AMDXDNAAdapter"),
    ("npu_cix_onnx",      "CixOnnxAdapter"),
    ("npu_cix_zhouyi",    "CixZhouyiAdapter"),
    ("npu_intel",         "IntelNPUAdapter"),
    ("npu_mediatek_apu",  "MediaTekAPUAdapter"),
    ("npu_rockchip",      "RockchipRKNNAdapter"),
]


def all_adapters() -> list[type[AbstractAdapter]]:
    """Return all registered adapter classes that can be imported on this host.

    Adapters whose import fails (missing optional deps) are skipped silently
    and surface only when the caller asks for that adapter explicitly.
    """
    out: list[type[AbstractAdapter]] = []
    for module_name, class_name in _REGISTRY_NAMES:
        try:
            module = __import__(f"embedkit.adapters.{module_name}", fromlist=[class_name])
        except Exception:
            continue
        cls = getattr(module, class_name, None)
        if cls is not None and issubclass(cls, AbstractAdapter):
            out.append(cls)
    return out


__all__ = ["AbstractAdapter", "all_adapters"]
