import os
import numpy as np
from typing import List
from .runtime.backend import select_backend


class BGESmallEmbedder:
    """
    BGE-Small text embedder with NPU acceleration and CPU fallback.
    """
    def __init__(self, model_path: str = None):
        if model_path is None:
            model_path = os.getenv(
                'BGE_SMALL_MODEL_PATH',
                '/mnt/argonas/datapool/projects/cix-ai-model-hub/bge-small-onnx/model.onnx'
            )
        self.model_path = model_path
        self.backend = None  # Lazy initialization

    def _ensure_backend(self):
        """Lazy initialize the backend on first call."""
        if self.backend is None:
            self.backend = select_backend(self.model_path)

    def encode(self, texts: List[str]) -> np.ndarray:
        """
        Encode a list of texts into 768-dimensional vectors.

        Args:
            texts: List of input texts.

        Returns:
            Array of shape (len(texts), 768) containing embeddings.
        """
        self._ensure_backend()
        # Preprocess: tokenize and create ONNX inputs (simplified)
        # In practice, use a proper tokenizer
        # Placeholder for tokenization
        input_ids = np.random.randint(0, 10000, (len(texts), 512), dtype=np.int64)  # Dummy
        attention_mask = np.ones((len(texts), 512), dtype=np.int64)  # Dummy

        inputs = {
            'input_ids': input_ids,
            'attention_mask': attention_mask
        }
        outputs = self.backend.run(inputs)
        # Assume output is named 'embedding'
        embedding = outputs['embedding']  # Shape: (batch, 768)
        # Normalize embeddings (common for BGE)
        embedding = embedding / np.linalg.norm(embedding, axis=1, keepdims=True)
        return embedding
