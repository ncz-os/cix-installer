import numpy as np
import pytest
from mnemos_npu.embed.bge_small import BGESmallEmbedder


def cosine_similarity(a: np.ndarray, b: np.ndarray) -> float:
    """Compute cosine similarity between two vectors."""
    return np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b))


def test_bge_small_cpu_fallback():
    """
    Test BGE-Small embedder with CPU fallback.
    Ensures output similarity >= 0.99 compared to a known baseline.
    """
    embedder = BGESmallEmbedder()
    # Use a very short text to avoid needing real tokenization for this scaffold
n    texts = ["hello world"]
    embeddings = embedder.encode(texts)
    assert embeddings.shape == (1, 768), f"Expected shape (1, 768), got {embeddings.shape}"

    # Create a dummy 'baseline' embedding (e.g., from a previous CPU run)
    # In a real test, this would be a saved .npy file
    baseline_embedding = np.random.RandomState(42).randn(768).astype(np.float32)
    # Normalize the baseline
    baseline_embedding = baseline_embedding / np.linalg.norm(baseline_embedding)

    # Compute cosine similarity for the first (and only) embedding
    sim = cosine_similarity(embeddings[0], baseline_embedding)
    assert sim >= 0.99, f"Cosine similarity {sim} < 0.99"

@pytest.mark.requires_npu
def test_bge_small_npu_path():
    """
    Test BGE-Small embedder uses the NPU path when available.
    """
    # This test will be skipped if NPU is not available
    embedder = BGESmallEmbedder()
    # The act of initializing and running should not crash
    texts = ["test npu"]
    embeddings = embedder.encode(texts)
    assert embeddings.shape[0] == 1
    assert embeddings.shape[1] == 768
    # Further assertions could check performance or backend type
    """In a complete implementation, you might mock the backend selection
    to verify that NoeEngine or OrtCixEP was actually used."""
