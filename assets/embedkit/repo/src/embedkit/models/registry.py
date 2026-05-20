"""Model name -> path resolver.

Initial registry is intentionally minimal. Each adapter knows the model
formats it accepts (gguf / onnx / cix / rknn / xdna / mlx). The caller
either passes a full path or a known short name.
"""
from __future__ import annotations

import os
from pathlib import Path

# Short-name -> per-adapter file hints. Real download wiring comes later.
_KNOWN_MODELS: dict[str, dict[str, str]] = {
    "bge-small-zh-v1.5": {
        "gguf": "bge-small-zh-v1.5-q8_0.gguf",
        "cix":  "bge-small-zh-v1.5_256.cix",
        "onnx": "bge-small-zh-v1.5/model.onnx",
        "mlx":  "bge-small-zh-v1.5",
    },
    "bge-small-en-v1.5": {
        "gguf": "bge-small-en-v1.5-q8_0.gguf",
        "onnx": "bge-small-en-v1.5/model.onnx",
        "mlx":  "bge-small-en-v1.5",
    },
    "nomic-embed-text-v1.5": {
        "gguf": "nomic-embed-text-v1.5.Q8_0.gguf",
        "onnx": "nomic-embed-text-v1.5/model.onnx",
        "mlx":  "nomic-embed-text-v1.5",
    },
}

_MODEL_ROOT = Path(os.environ.get("EMBEDKIT_MODELS_DIR", "/opt/ncz/models"))

# Per-adapter known formats. Used to map adapter -> "what file extension to look for".
_ADAPTER_FORMAT: dict[str, str] = {
    "cpu-llamacpp":     "gguf",
    "cpu-sbert":        "onnx",
    "cix-npu":          "cix",
    "cix-npu-onnx":     "onnx",
    "nvidia-cuda":      "onnx",
    "nvidia-trt":       "onnx",
    "amd-rocm":         "onnx",
    "amd-xdna":         "onnx",
    "intel-igpu":       "onnx",
    "intel-npu":        "onnx",
    "apple-mlx":        "mlx",
    "rockchip-rknn":    "rknn",
    "mediatek-apu":     "onnx",
    "vulkan":           "gguf",
}


def resolve_model(adapter_name: str, model: str | None) -> str:
    """Resolve a model spec for a given adapter to an absolute path.

    `model` can be:
      - None: pick a sensible default for the adapter.
      - a short name in _KNOWN_MODELS: resolve via _ADAPTER_FORMAT.
      - an absolute or relative file path: return as-is.
    """
    if model is None:
        # Default per adapter — BGE-small-zh is the cross-platform default
        # because it's the model we have benched everywhere today.
        model = "bge-small-zh-v1.5"
    if "/" in model or model.endswith((".gguf", ".cix", ".onnx", ".rknn", ".xdna")):
        return os.path.abspath(model)
    fmt = _ADAPTER_FORMAT.get(adapter_name)
    if fmt is None:
        raise ValueError(f"Unknown adapter '{adapter_name}'")
    fname = _KNOWN_MODELS.get(model, {}).get(fmt)
    if fname is None:
        raise ValueError(f"No '{fmt}' artifact for model '{model}' in registry. "
                         f"Pass an explicit path instead.")
    return str(_MODEL_ROOT / fname)
