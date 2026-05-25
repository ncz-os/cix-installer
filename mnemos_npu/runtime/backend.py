import os
import numpy as np
from typing import Optional, Dict, Any

# Lazy imports
noe_engine = None
OrtCixEP = None


class NoeEngine:
    def __init__(self, model_path: str):
        global noe_engine
        if noe_engine is None:
            import noe_engine
        self.model_path = model_path
        self.engine = noe_engine.NoeEngine(model_path)

    def run(self, inputs: Dict[str, np.ndarray]) -> Dict[str, np.ndarray]:
        return self.engine.run(inputs)


class OrtCixEP:
    def __init__(self, model_path: str):
        global OrtCixEP
        if OrtCixEP is None:
            from onnxruntime import InferenceSession, SessionOptions
            from cix_npu_onnxruntime import CixExecutionProvider
            # Register the Cix NPU Execution Provider
            SessionOptions().add_external_initializers()  # Placeholder for actual EP setup
        self.sess = InferenceSession(model_path, sess_options=SessionOptions())

    def run(self, inputs: Dict[str, np.ndarray]) -> Dict[str, np.ndarray]:
        return self.sess.run(None, inputs)


class CpuFallback:
    def __init__(self, model_path: str):
        from onnxruntime import InferenceSession
        self.sess = InferenceSession(model_path)

    def run(self, inputs: Dict[str, np.ndarray]) -> Dict[str, np.ndarray]:
        return self.sess.run(None, inputs)


def select_backend(model_path: str, npu_enabled: bool = True):
    """
    Select and return an inference backend.

    Args:
        model_path: Path to the ONNX model file.
        npu_enabled: If True, prefer NPU backends.

    Returns:
        An initialized backend instance (NoeEngine, OrtCixEP, or CpuFallback).
    """
    if npu_enabled:
        try:
            # Try NoeEngine first
            return NoeEngine(model_path)
        except Exception as e1:
            print(f"NoeEngine failed: {e1}")
            try:
                # Fall back to OrtCixEP
                return OrtCixEP(model_path)
            except Exception as e2:
                print(f"OrtCixEP failed: {e2}")
    # Final fall back to CPU
    return CpuFallback(model_path)
