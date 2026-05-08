#!/bin/bash
# 47-embedkit.sh — install mnemos-embedkit + stage NPU runtime + ship
# the canonical bench artifacts so MNEMOS embedding works out of the box.
#
# This is the kit's appliance install path. The NCZ Magnetar / Reinhardt
# ISO is the EXEMPLAR way to run MNEMOS (per operator doctrine 2026-05-07);
# baking embedkit into the ISO means an `ncz install mnemos` post-flash
# delivers a working MNEMOS appliance with the NPU adapter live by the
# time the user's first agent comes up.
#
# Layout this hook lays down on /:
#
#   /opt/ncz/embed-venv/                 — Python 3.13 venv, owned by ncz user
#   /opt/ncz/embed-venv/bin/embedkit-bench
#   /opt/ncz/models/bge-small-zh-v1.5_256.cix       (NPU model, INT8)
#   /opt/ncz/models/bge-small-zh-v1.5-q8_0.gguf     (CPU/GPU fallback)
#   /opt/ncz/models/MODELS-README.md     — what's here, where to add more
#
# NPU runtime is already laid down by 25-cix-proprietary.sh
# (cix-noe-umd 2.0.2 + libnoe). This hook only adds the kit's Python
# bindings.
#
# embedkit Engine.auto() picks at runtime: on Cix Sky1 it sees libnoe
# + /dev/aipu and selects the npu-cix adapter; on a hypothetical x86
# variant of this image it would fall back to cpu-llamacpp.
set -euo pipefail

ASSETS=/usr/local/lib/cix-installer/assets/embedkit
MODELS_SRC=/usr/local/lib/cix-installer/assets/models
VENV=/opt/ncz/embed-venv
MODELS=/opt/ncz/models

echo "[47] embedkit install + NPU runtime stage"

# ----------------------------------------------------------------------
# 1. Python venv at /opt/ncz/embed-venv (system-wide, /opt is read-only-
#    after-install convention; the venv is rebuilt by the operator if
#    they want to upgrade embedkit out of band)
# ----------------------------------------------------------------------
if [ ! -d "$VENV" ]; then
    echo "[47]   creating venv at $VENV"
    python3 -m venv "$VENV" 2>&1 | tail -3
fi

# Pip + wheel + setuptools refresh
"$VENV/bin/pip" install --quiet --upgrade pip wheel setuptools 2>&1 | tail -2

# ----------------------------------------------------------------------
# 2. Install embedkit from the bundled wheel (or git clone if the wheel
#    isn't shipped). The wheel is preferred — no internet dependency.
# ----------------------------------------------------------------------
if ls "$ASSETS"/mnemos_embedkit-*.whl >/dev/null 2>&1; then
    echo "[47]   installing embedkit from bundled wheel"
    "$VENV/bin/pip" install --quiet "$ASSETS"/mnemos_embedkit-*.whl 2>&1 | tail -2
elif [ -d "$ASSETS/repo" ]; then
    echo "[47]   installing embedkit from bundled source"
    "$VENV/bin/pip" install --quiet "$ASSETS/repo" 2>&1 | tail -2
else
    echo "[47]   WARN: no embedkit wheel/repo bundled; trying PyPI"
    "$VENV/bin/pip" install --quiet mnemos-embedkit 2>&1 | tail -2
fi

"$VENV/bin/python" - << 'PY'
import embedkit
print(f"[47]   embedkit import OK: {getattr(embedkit, '__version__', 'unknown')}")
PY

# ----------------------------------------------------------------------
# 3. Vendor python bindings for the on-device adapters.
#    On Cix Sky1: libnoe wheel (Cix-shipped at /usr/share/cix/pypi/) +
#    llama-cpp-python (CPU fallback adapter).
# ----------------------------------------------------------------------
LIBNOE_WHL=/usr/share/cix/pypi/libnoe-2.0.0-py3-none-manylinux2014_aarch64.whl
if [ -f "$LIBNOE_WHL" ]; then
    echo "[47]   installing libnoe (Cix NPU userspace binding)"
    "$VENV/bin/pip" install --quiet "$LIBNOE_WHL" 2>&1 | tail -2
fi

# llama-cpp-python — CPU baseline + Vulkan fallback. Use the prebuilt
# CPU wheel index so we don't compile from source on the install host.
echo "[47]   installing llama-cpp-python (CPU baseline)"
"$VENV/bin/pip" install --quiet \
    --extra-index-url=https://abetlen.github.io/llama-cpp-python/whl/cpu \
    llama-cpp-python 2>&1 | tail -2

# ----------------------------------------------------------------------
# 4. Stage models at /opt/ncz/models/.
#    The .cix model is the NPU artifact (Compass NN AOT-compiled, INT8).
#    The .gguf model is the CPU/Mali-Vulkan fallback.
#    Operator can add more models via `ncz model add ...` post-install.
# ----------------------------------------------------------------------
mkdir -p "$MODELS"
missing_models=()
for m in bge-small-zh-v1.5_256.cix bge-small-zh-v1.5-q8_0.gguf; do
    src="$MODELS_SRC/$m"
    dst="$MODELS/$m"
    if [ -f "$src" ] && [ ! -f "$dst" ]; then
        cp "$src" "$dst"
        echo "[47]   staged $m -> $dst ($(stat -c%s "$dst") bytes)"
    elif [ -f "$dst" ]; then
        echo "[47]   already present: $dst"
    else
        echo "[47]   ERROR: $src not in image - missing $m"
        missing_models+=("$m")
    fi
done

if [ "${EMBEDKIT_DEFER_NPU:-0}" != "1" ]; then
    for missing in "${missing_models[@]}"; do
        if [ "$missing" = "bge-small-zh-v1.5_256.cix" ]; then
            echo "[47]   ERROR: required Cix NPU model missing; set EMBEDKIT_DEFER_NPU=1 only for explicit defer builds" >&2
            exit 1
        fi
    done
fi

# README so the operator knows what's in /opt/ncz/models/
cat > "$MODELS/MODELS-README.md" << 'EOF'
# /opt/ncz/models — embedkit model store

Models shipped with this NCZ image:

| File | Format | Adapter | Embed dim | Notes |
|---|---|---|---|---|
| `bge-small-zh-v1.5_256.cix` | Cix Compass NN AOT INT8 | `npu-cix` (Cix Sky1 Zhouyi V3) | 512 | 256-token max |
| `bge-small-zh-v1.5-q8_0.gguf` | llama.cpp Q8 GGUF | `cpu-llamacpp`, `gpu-vulkan` (Mali) | 512 | CPU/Vulkan fallback |

Add more models with:

    ncz model add <huggingface-id-or-path>

The kit's `Engine.auto()` picks among installed models + adapters at
runtime by capability tier (NPU > GPU > CPU) and measured throughput
within tier. No vendor preference.

To override:

    embedkit.Engine(adapter="cpu-llamacpp", model="bge-small-zh-v1.5")
EOF

# ----------------------------------------------------------------------
# 5. Wire embedkit into PATH + record provenance for diagnostics.
# ----------------------------------------------------------------------
ln -sf "$VENV/bin/embedkit-bench"  /usr/local/bin/embedkit-bench  2>/dev/null || true
ln -sf "$VENV/bin/embedkit-doctor" /usr/local/bin/embedkit-doctor 2>/dev/null || true

mkdir -p /var/log/cix-install
"$VENV/bin/pip" list --format=columns 2>/dev/null \
    | grep -E "^(mnemos-embedkit|llama-cpp-python|libnoe|numpy|transformers)" \
    > /var/log/cix-install/47-embedkit-installed.log || true

# ----------------------------------------------------------------------
# 6. Smoke test (fatal - a missing package must not look installed)
# ----------------------------------------------------------------------
echo "[47]   smoke: embedkit.Engine.list_adapters()"
if ! "$VENV/bin/python" - 2>&1 << 'PY' | tee /var/log/cix-install/47-embedkit-smoke.log; then
import embedkit
for a in embedkit.Engine.list_adapters():
    print(f"    {a['tier']:3s} {a['name']:18s} {a['available']!s:5s} {a['reason']}")
PY
    echo "[47]   ERROR: embedkit smoke failed" >&2
    exit 1
fi

echo "[47] done — $(ls $MODELS 2>/dev/null | wc -l) models, venv at $VENV"
exit 0
