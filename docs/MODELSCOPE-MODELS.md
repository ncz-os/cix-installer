# Pulling `.cix` NPU models from the Cix ai_model_hub (ModelScope)

The Cix Zhouyi NPU runs **`.cix`** models — AOT-compiled INT8 graphs produced by
the (closed) Compass NN compiler. The compiler is not public, so for most
models you **download the prebuilt `.cix`** from the Cix model hub rather than
compile it. This doc covers where the hub lives, how to pull a single model or
the whole repo, and how to add a pulled model to the NCZ distro.

> Why this matters: the bge embedding `.cix` was lost on a reinstall once with no
> way to regenerate (cixtech/cix-linux-main#21). The prebuilt hub is the
> recovery path; the NCZ repo now also commits the bge `.cix` directly.

---

## Two repos, don't confuse them

| Repo | Host | Contents |
|---|---|---|
| `cixtech/ai_model_hub` | github.com | **Recipes only** — `cfg/`, `script/`, `inference_*.py`, tokenizers. No `.cix` blobs. |
| `cix/ai_model_hub` | modelscope.cn | **Prebuilt `.cix`** (+ ONNX, weights) via Git LFS. This is where the binaries are. |

ModelScope versions the hub by quarter. Current public: **`26_Q1`**
(`25_Q3` also exists). Browse:

    https://www.modelscope.cn/models/cix/ai_model_hub/files?version=26_Q1

The directory tree mirrors the GitHub recipe layout, e.g. the bge embedding:

    models/Generative_AI/Text_Image_Search/onnx_bge_small_zh/bge-small-zh_256.cix

---

## Option A — pull a single model file (fast, what we use)

ModelScope's `resolve` endpoint returns an HTML stub linking to the CDN LFS
object; follow redirects with `curl -L`:

```bash
BASE="https://www.modelscope.cn/models/cix/ai_model_hub/resolve/26_Q1"
P="models/Generative_AI/Text_Image_Search/onnx_bge_small_zh/bge-small-zh_256.cix"
curl -fL "$BASE/$P" -o bge-small-zh_256.cix
# sanity: ~75 MB, starts with flatbuffer magic (not '<a href')
ls -l bge-small-zh_256.cix && xxd bge-small-zh_256.cix | head -1
```

You also want the tokenizer (BERT WordPiece) for offline inference — grab it
from the same recipe dir (these are small, non-LFS):

```bash
for f in tokenizer.json vocab.txt tokenizer_config.json special_tokens_map.json config.json; do
  curl -fL "$BASE/models/Generative_AI/Text_Image_Search/onnx_bge_small_zh/bge-small-zh-v1.5/$f" \
       -o "bge-small-zh-v1.5/$f"
done
```

---

## Option B — clone the whole hub (Git LFS)

Skip the LFS smudge on clone (pointers only), then pull just the blobs you
want:

```bash
git lfs install
GIT_LFS_SKIP_SMUDGE=1 git clone https://www.modelscope.cn/cix/ai_model_hub.git
cd ai_model_hub
git checkout 26_Q1                      # the quarter you want
git lfs pull --include="models/Generative_AI/Text_Image_Search/onnx_bge_small_zh/*.cix"
```

(For 25_Q3 the repo is `https://www.modelscope.cn/cix/ai_model_hub_25_Q3.git`.)

The hub ships prebuilt `.cix` for YOLO, MobileNet/ResNet/EfficientNet, Whisper
tiny/small/medium, CLIP/SigLIP, SDXL-Turbo, PP-OCRv4, pose/hand, and the
`bge-small-zh-v1.5` 256-token embedding model used by MNEMOS.

---

## Adding a pulled `.cix` to the NCZ distro

1. Drop the blob in `assets/models/` using the adapter's expected name, e.g.
   `bge-small-zh-v1.5_256.cix`. Add the tokenizer under
   `assets/models/<model>/` if the adapter tokenizes offline.
2. Add a row to `assets/models/MODELS-README.md` (provenance + license).
3. If the staging name differs from what embedkit/MNEMOS loads, add a compat
   symlink in `post-install/47-embedkit.sh` (see the bge example there).
4. Commit the blob (the repo tracks model blobs directly — no LFS — so they can
   never be lost again). Large files: GitHub's hard limit is 100 MB.

The model is then staged to `/opt/ncz/models/` on install and picked up by
`embedkit.Engine.auto()` automatically.

---

## Compiling your own `.cix` (custom architectures)

For models not in the hub (e.g. `bge-m3`, `jina-embeddings-v3`), Cix ships a
**Compass NN compiler Docker image** in the NOE SDK (26Q1+) at
<https://developer.cixtech.com/>. The flow (per the hub recipes):

```bash
python3 script/01convert_to_onnx.py      # export HF model -> ONNX
python3 script/02gen_calib_data.py       # quant calibration set (~11 samples)
cixbuild cfg/<model>_build.cfg           # ONNX -> .cix (in the compiler container)
python3 inference_npu.py                 # validate on the NPU
```

The `.cix` format spec itself is slated for public docs in 26Q3. Until then the
prebuilt hub + the compiler container are the supported paths.

---

## References

- ModelScope hub: https://www.modelscope.cn/models/cix/ai_model_hub
- GitHub recipes: https://github.com/cixtech/ai_model_hub
- NOE SDK + compiler: https://developer.cixtech.com/
- `docs/MNEMOS-NPU-EMBEDDINGS.md` — how MNEMOS uses the bge `.cix`.
