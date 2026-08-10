#!/bin/bash
# Package the NPU embedding server as two .debs (arm64):
#
#   ncz-npu-embed          the server, unit and interpreter shim (~5 KB)
#   ncz-model-nomic-embed  the nomic-embed-text-v1.5 NOE graph (~378 MB packed)
#
# They are split because the graph is 500 MB on disk and versions on the MODEL,
# while the server versions on the CODE. Shipping one package would mean
# re-downloading half a gigabyte to fix a typo in the HTTP handler.
#
# WHY THIS EXISTS AT ALL: MNEMOS embeds in-process with nomic-embed-text-v1.5 at
# 768 dimensions. This server runs the same model at the same width on the
# Zhouyi NPU, so it is a drop-in — no re-embedding, and vectors stay comparable
# with x86 peers (measured cosine 0.9953 vs the onnxruntime CPU reference). A
# different width would not fail loudly; it would silently strand every memory
# already written. That is why nothing here enables the service: activation
# belongs to ncz_npu_embedder_ready() in post-install/46-ncz-cli.sh, which
# probes the live endpoint and refuses to wire MNEMOS to anything but 768.
#
# The .cix graph is NOT in this repo (500 MB binary). Compass NN AOT output;
# staged copy lives on cixmini (.66) at ~/npu-stage/.
#
# Usage: make-deb.sh <path/to/nomic-embed-text-v1.5_256.cix> [outdir] [tokenizer-dir]
#        make-deb.sh --code-only [outdir]
#
# The tokenizer directory is OPTIONAL but strongly wanted: without it the server
# resolves "nomic-ai/nomic-embed-text-v1.5" from huggingface.co on first start,
# which an offline ISO install cannot do. Point it at a HF snapshot dir, e.g.
#   ~/.cache/huggingface/hub/models--nomic-ai--nomic-embed-text-v1.5/snapshots/<sha>
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$(cd "$HERE/../../packages/mnemos-npu-embed" && pwd)"

CODE_VER=1.0.0
MODEL_VER=1.5.0
GRAPH=""
CODE_ONLY=0

if [ "${1:-}" = "--code-only" ]; then
    CODE_ONLY=1
    shift
else
    GRAPH="${1:?path to nomic-embed-text-v1.5_256.cix (or --code-only)}"
    shift || true
fi
OUT="${1:-$PWD}"
shift || true
TOKENIZER_DIR="${1:-}"
mkdir -p "$OUT"

for f in ncz-npu-embed-server.py ncz-npu-embed.service ncz-npu-python; do
    [ -f "$SRC/$f" ] || { echo "missing source: $SRC/$f" >&2; exit 1; }
done

# The unit's interpreter must be a path something on the image actually
# creates. 47-embedkit.sh builds exactly one NPU-capable venv,
# /opt/ncz/embed-venv (Python 3.11 — the libnoe wheels ship cp311/cp312 .so
# only). An earlier revision pointed ExecStart at /opt/ncz/noe-venv, which no
# hook ever provisions, so the service could not start on a fresh install.
# Fail the BUILD rather than ship that again.
grep -q '^ExecStart=/opt/ncz/embed-venv/bin/python ' "$SRC/ncz-npu-embed.service" || {
    echo "ncz-npu-embed.service ExecStart does not use /opt/ncz/embed-venv — refusing to build" >&2
    grep '^ExecStart=' "$SRC/ncz-npu-embed.service" >&2
    exit 1
}
grep -q '^exec /opt/ncz/embed-venv/bin/python ' "$SRC/ncz-npu-python" || {
    echo "ncz-npu-python shim does not use /opt/ncz/embed-venv — refusing to build" >&2
    exit 1
}

# ----------------------------------------------------------------------
# ncz-npu-embed (code)
# ----------------------------------------------------------------------
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/DEBIAN" "$STAGE/usr/local/bin" "$STAGE/lib/systemd/system" \
         "$STAGE/usr/share/doc/ncz-npu-embed"
install -m 0755 "$SRC/ncz-npu-embed-server.py" "$STAGE/usr/local/bin/ncz-npu-embed-server.py"
install -m 0755 "$SRC/ncz-npu-python"          "$STAGE/usr/local/bin/ncz-npu-python"
install -m 0644 "$SRC/ncz-npu-embed.service"   "$STAGE/lib/systemd/system/ncz-npu-embed.service"
[ -f "$SRC/README.md" ] && install -m 0644 "$SRC/README.md" \
    "$STAGE/usr/share/doc/ncz-npu-embed/README.md"

cat > "$STAGE/DEBIAN/control" <<EOF
Package: ncz-npu-embed
Version: $CODE_VER
Architecture: arm64
Maintainer: Jason Perlow <jperlow@gmail.com>
Depends: cix-noe-umd, python3
Recommends: ncz-model-nomic-embed
Section: utils
Priority: optional
Description: OpenAI-compatible embeddings on the CIX Sky1 Zhouyi NPU
 Serves /v1/embeddings from a precompiled NOE graph so MNEMOS can offload
 embedding to the NPU. Runs nomic-embed-text-v1.5 at 768 dimensions, the same
 model and width MNEMOS embeds with in-process, so it is a drop-in that needs
 no re-embedding and keeps vectors interchangeable with x86 peers (measured
 cosine 0.9953 against the onnxruntime CPU reference).
 .
 Runs on /opt/ncz/embed-venv, the Python 3.11 NPU venv that the image's
 embedkit hook provisions; the libnoe and NOE_Engine wheels ship cp311/cp312
 extensions only, so the system python cannot drive the NPU.
 .
 The unit is gated on /dev/aipu and is NOT enabled by this package; enabling it
 is the job of the MNEMOS install path, which additionally verifies the served
 vector width before pointing MNEMOS at it.
EOF

cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
# Deliberately NOT enabled here. A wrong-width embedder strands memories
# silently, so activation belongs to `ncz install mnemos`, which probes the
# live endpoint and only wires MNEMOS up when it returns 768 floats.
[ -x /usr/bin/systemctl ] && systemctl daemon-reload || true
exit 0
EOF
chmod 0755 "$STAGE/DEBIAN/postinst"

CODE_DEB="$OUT/ncz-npu-embed_${CODE_VER}_arm64.deb"
dpkg-deb --build --root-owner-group "$STAGE" "$CODE_DEB" >/dev/null
echo "built $CODE_DEB ($(stat -c%s "$CODE_DEB") bytes)"

[ "$CODE_ONLY" = "1" ] && exit 0

# ----------------------------------------------------------------------
# ncz-model-nomic-embed (graph)
# ----------------------------------------------------------------------
[ -f "$GRAPH" ] || { echo "no such graph: $GRAPH" >&2; exit 1; }

MSTAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE" "$MSTAGE"' EXIT
mkdir -p "$MSTAGE/DEBIAN" "$MSTAGE/opt/ncz/models"
install -m 0644 "$GRAPH" "$MSTAGE/opt/ncz/models/nomic-embed-text-v1.5_256.cix"

# Ship the tokenizer next to the graph so the server never reaches for the Hub.
# transformers only needs the JSON/vocab side-files here, not the weights -- the
# actual model IS the .cix graph.
if [ -n "$TOKENIZER_DIR" ]; then
    [ -f "$TOKENIZER_DIR/tokenizer.json" ] || {
        echo "no tokenizer.json under $TOKENIZER_DIR — refusing to build a half-offline package" >&2
        exit 1; }
    mkdir -p "$MSTAGE/opt/ncz/models/nomic-embed-text-v1.5"
    for f in config.json tokenizer.json tokenizer_config.json vocab.txt \
             special_tokens_map.json added_tokens.json; do
        # cp -L, not install: HF snapshot entries are symlinks into ../../blobs
        # and GNU install has no dereference flag, so a plain install copies a
        # dangling link into the package.
        if [ -e "$TOKENIZER_DIR/$f" ]; then
            cp -L "$TOKENIZER_DIR/$f" "$MSTAGE/opt/ncz/models/nomic-embed-text-v1.5/$f"
            chmod 0644 "$MSTAGE/opt/ncz/models/nomic-embed-text-v1.5/$f"
        fi
    done
    echo "  staged tokenizer: $(ls "$MSTAGE/opt/ncz/models/nomic-embed-text-v1.5" | tr '\n' ' ')"
else
    echo "  WARN: no tokenizer dir given — the server will fetch it from huggingface.co"
    echo "        on first start, which an offline install cannot do."
fi

cat > "$MSTAGE/DEBIAN/control" <<EOF
Package: ncz-model-nomic-embed
Version: $MODEL_VER
Architecture: arm64
Maintainer: Jason Perlow <jperlow@gmail.com>
Section: utils
Priority: optional
Description: nomic-embed-text-v1.5 NPU graph (768-dim, SEQ_LEN 256)
 Compass NN AOT-compiled graph for the Zhouyi V3 NPU, used by ncz-npu-embed.
 768 dimensions to match MNEMOS's in-process embedder exactly. Split from the
 server package because it is large and versions on the model, not the code.
EOF

MODEL_DEB="$OUT/ncz-model-nomic-embed_${MODEL_VER}_arm64.deb"
dpkg-deb --build --root-owner-group "$MSTAGE" "$MODEL_DEB" >/dev/null
echo "built $MODEL_DEB ($(stat -c%s "$MODEL_DEB") bytes)"
