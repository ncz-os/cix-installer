from fastapi import FastAPI
from pydantic import BaseModel
from typing import List, Union, Optional
import numpy as np
import sys
import time

# NOE Engine expects to be imported, we will ship the engine script with it
import NOE_Engine
from transformers import AutoTokenizer

app = FastAPI(title="CIX NPU Embeddings API - Optimized")

print("Loading Tokenizer...", flush=True)
tokenizer = AutoTokenizer.from_pretrained("sentence-transformers/all-MiniLM-L6-v2")

print("Loading NPU Model...", flush=True)
cix_model = NOE_Engine.EngineInfer("/usr/share/cix/models/minilm_128.cix")
print("NPU Model loaded successfully.", flush=True)

class EmbedRequest(BaseModel):
    input: Union[str, List[str]]
    model: Optional[str] = "minilm-l6-v2"
    encoding_format: Optional[str] = "float"

@app.post("/v1/embeddings")
def embeddings(req: EmbedRequest):
    texts = req.input if isinstance(req.input, list) else [req.input]
    
    # Tokenize the entire batch at once
    inputs = tokenizer(texts, return_tensors="np", padding="max_length", truncation=True, max_length=128)
    
    in_ids = inputs["input_ids"].astype(np.int32)
    in_mask = inputs["attention_mask"].astype(np.int32)
    in_type = inputs["token_type_ids"].astype(np.int32)
    
    data = []
    
    for i in range(len(texts)):
        out = cix_model.forward([in_ids[i:i+1], in_mask[i:i+1], in_type[i:i+1]])
        last_hidden = out[0].reshape(1, 128, 384)
        mask_expanded = np.expand_dims(in_mask[i:i+1], -1)
        
        sum_hidden = np.sum(last_hidden * mask_expanded, axis=1)
        sum_mask = np.clip(np.sum(mask_expanded, axis=1), a_min=1e-9, a_max=None)
        
        emb = sum_hidden / sum_mask
        emb = emb / np.linalg.norm(emb, axis=1, keepdims=True)
        
        data.append({
            "object": "embedding",
            "embedding": emb[0].tolist(),
            "index": i
        })
        
    return {
        "object": "list",
        "data": data,
        "model": req.model or "minilm-l6-v2",
        "usage": {"prompt_tokens": len(texts)*128, "total_tokens": len(texts)*128}
    }

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=8000, log_level="warning")
