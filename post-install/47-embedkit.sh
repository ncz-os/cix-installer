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
#   /opt/ncz/embed-venv/                 — Python 3.11 venv (NPU binding needs
#                                          cp311/cp312; see below)
#   /opt/ncz/embed-venv/bin/embedkit-bench
#   /opt/ncz/models/bge-small-zh-v1.5_256.cix       (NPU model, INT8)
#   /opt/ncz/models/bge-small-zh-v1.5-q8_0.gguf     (CPU/GPU fallback)
#   /opt/ncz/models/MODELS-README.md     — what's here, where to add more
#
# NPU runtime (libnoe.so.0.6.0 + /usr/share/cix/pypi wheels) is laid down
# by 25-cix-proprietary.sh from cix-noe-umd 2.0.2. This hook adds the kit's
# Python bindings INTO A PYTHON 3.11 VENV.
#
# PYTHON 3.11 IS REQUIRED, NOT OPTIONAL: the libnoe-2.0.0 wheel only ships
# cpython-311/312 .so extensions (no 3.14), so a venv built from r104's
# system python3 (3.14) cannot `import libnoe` and the NPU adapter goes
# dark. 46-python311.sh provisions /opt/python3.11 for exactly this; we
# build the venv from it. Validated ~56 emb/s (all-MiniLM) on .66.
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
#
#    Interpreter selection: the NPU libnoe wheel only has cp311/cp312
#    extensions, so we MUST build from a 3.11/3.12 interpreter. Prefer
#    the relocatable /opt/python3.11 from 46-python311.sh; then any
#    python3.11/python3.12 on PATH; only fall back to the system python3
#    if it happens to be 3.11/3.12. A 3.13+ system python is refused for
#    the NPU path (embedkit still loads, but its npu-cix adapter will be
#    unavailable and Engine.auto() falls back to CPU/GPU).
# ----------------------------------------------------------------------
PYBIN=""
NPU_PY_OK=1
for cand in /opt/python3.11/bin/python3.11 \
            "$(command -v python3.11 2>/dev/null)" \
            "$(command -v python3.12 2>/dev/null)"; do
    if [ -n "$cand" ] && [ -x "$cand" ]; then PYBIN="$cand"; break; fi
done
if [ -z "$PYBIN" ]; then
    SYS_MINOR=$(python3 -c 'import sys;print(sys.version_info[1])' 2>/dev/null || echo 0)
    if [ "$SYS_MINOR" = "11" ] || [ "$SYS_MINOR" = "12" ]; then
        PYBIN=$(command -v python3)
    else
        echo "[47]   WARN: no python3.11/3.12 found (system python3 is 3.${SYS_MINOR});"
        echo "[47]         NPU libnoe binding cannot be imported. Building CPU/GPU-only"
        echo "[47]         venv from system python3 so embedkit still works."
        PYBIN=$(command -v python3)
        NPU_PY_OK=0
    fi
fi
echo "[47]   venv interpreter: $PYBIN ($("$PYBIN" --version 2>&1))"

# uv is the preferred venv builder + installer (fast, resolves offline
# against local wheels). 46-python311.sh provisions it at /usr/local/bin/uv;
# we fall back to stdlib venv + pip if uv is somehow absent.
UV=""
for cand in /usr/local/bin/uv "$(command -v uv 2>/dev/null)" /opt/uv/bin/uv; do
    if [ -n "$cand" ] && [ -x "$cand" ]; then UV="$cand"; break; fi
done
[ -n "$UV" ] && echo "[47]   using uv: $UV ($("$UV" --version 2>&1))" \
             || echo "[47]   uv not found — falling back to stdlib venv + pip"

# If the existing venv was built with a different interpreter, rebuild it
# (e.g. an older r104 install baked a 3.14 venv that can't load libnoe).
if [ -d "$VENV" ] && [ -x "$VENV/bin/python" ]; then
    VENV_MINOR=$("$VENV/bin/python" -c 'import sys;print(sys.version_info[1])' 2>/dev/null || echo x)
    WANT_MINOR=$("$PYBIN" -c 'import sys;print(sys.version_info[1])' 2>/dev/null || echo y)
    if [ "$VENV_MINOR" != "$WANT_MINOR" ]; then
        echo "[47]   existing venv is 3.$VENV_MINOR but want 3.$WANT_MINOR — rebuilding"
        rm -rf "$VENV"
    fi
fi
if [ ! -d "$VENV" ]; then
    if [ -n "$UV" ]; then
        echo "[47]   creating uv venv at $VENV (python $PYBIN)"
        "$UV" venv --python "$PYBIN" "$VENV" 2>&1 | tail -3
    else
        echo "[47]   creating stdlib venv at $VENV"
        "$PYBIN" -m venv "$VENV" 2>&1 | tail -3
    fi
fi

# Installer helper: uv venvs ship no pip, so route through `uv pip`.
# Stdlib venvs use their bundled pip.
pip_install() {
    if [ -n "$UV" ]; then
        "$UV" pip install --python "$VENV/bin/python" "$@"
    else
        "$VENV/bin/pip" install "$@"
    fi
}

# Base tooling refresh only matters for stdlib venvs (uv manages its own).
if [ -z "$UV" ]; then
    "$VENV/bin/pip" install --quiet --upgrade pip wheel setuptools 2>&1 | tail -2
fi

# ----------------------------------------------------------------------
# 2. Install embedkit (OPTIONAL app layer). Prefer a bundled wheel/source,
#    fall back to PyPI. embedkit is the MNEMOS convenience layer — it is
#    NOT required for NPU driver fidelity (libnoe + NOE_Engine, installed
#    in step 3, are). So this whole block is best-effort: if no wheel is
#    baked and PyPI is unreachable we WARN and continue, and `ncz install
#    mnemos` can layer embedkit + models post-flash.
#
#    (Historical: this used to be fatal — a missing embedkit wheel aborted
#    the hook under `set -e` BEFORE step 3, shipping an ISO with a working
#    py3.11 venv but no libnoe in it, i.e. a dark NPU. Driver fidelity must
#    not depend on an app-layer artifact that may not be baked.)
# ----------------------------------------------------------------------
EMBEDKIT_OK=0
if ls "$ASSETS"/mnemos_embedkit-*.whl >/dev/null 2>&1; then
    echo "[47]   installing embedkit from bundled wheel"
    pip_install --quiet "$ASSETS"/mnemos_embedkit-*.whl 2>&1 | tail -2 && EMBEDKIT_OK=1 || true
elif [ -d "$ASSETS/repo" ]; then
    echo "[47]   installing embedkit from bundled source"
    pip_install --quiet "$ASSETS/repo" 2>&1 | tail -2 && EMBEDKIT_OK=1 || true
else
    echo "[47]   WARN: no embedkit wheel/repo bundled; trying PyPI (best-effort)"
    pip_install --quiet mnemos-embedkit 2>&1 | tail -2 && EMBEDKIT_OK=1 || \
        echo "[47]   WARN: embedkit not installed (offline / not on PyPI) — continuing; NPU runtime is installed below and can be used directly, embedkit can be layered via 'ncz install mnemos'"
fi

if [ "$EMBEDKIT_OK" = "1" ]; then
    "$VENV/bin/python" -c "import embedkit; print('[47]   embedkit import OK:', getattr(embedkit,'__version__','unknown'))" 2>&1 \
        || { echo "[47]   WARN: embedkit installed but import failed — continuing"; EMBEDKIT_OK=0; }
fi

# ----------------------------------------------------------------------
# 3. Vendor python bindings for the on-device adapters.
#    On Cix Sky1: libnoe wheel (Cix-shipped at /usr/share/cix/pypi/) +
#    llama-cpp-python (CPU fallback adapter).
# ----------------------------------------------------------------------
# cix-noe-umd 2.0.2 (staged via dpkg-deb -x by 25-cix-proprietary.sh) drops
# both the libnoe binding and the NOE_Engine wrapper into
# /usr/share/cix/pypi. Install both into the venv, but only
# when the venv is 3.11/3.12 — the wheels carry cp311/cp312 .so only, so
# on a 3.13+ venv the import would fail at runtime.
LIBNOE_WHL=$(ls /usr/share/cix/pypi/libnoe-*-py3-none-manylinux2014_aarch64.whl 2>/dev/null | head -1)
NOE_ENGINE_WHL=$(ls /usr/share/cix/pypi/NOE_Engine-*-py3-none-manylinux2014_aarch64.whl 2>/dev/null | head -1)
if [ "$NPU_PY_OK" = "1" ] && [ -n "$LIBNOE_WHL" ]; then
    echo "[47]   installing libnoe (Cix NPU userspace binding) from $(basename "$LIBNOE_WHL")"
    pip_install --quiet "$LIBNOE_WHL" 2>&1 | tail -2
    if [ -n "$NOE_ENGINE_WHL" ]; then
        echo "[47]   installing NOE_Engine from $(basename "$NOE_ENGINE_WHL")"
        pip_install --quiet "$NOE_ENGINE_WHL" 2>&1 | tail -2
    fi
    # Make the C lib (libnoe.so.0.6.0) discoverable for the cp311 extension.
    if [ -d /usr/share/cix/lib ] && ! grep -rqs '/usr/share/cix/lib' /etc/ld.so.conf.d/ 2>/dev/null; then
        echo "/usr/share/cix/lib" > /etc/ld.so.conf.d/cix-noe.conf
        ldconfig 2>/dev/null || true
    fi
elif [ "$NPU_PY_OK" != "1" ]; then
    echo "[47]   skipping libnoe install — venv python is not 3.11/3.12 (NPU adapter disabled)"
else
    echo "[47]   WARN: no libnoe wheel under /usr/share/cix/pypi — is cix-noe-umd 2.0.2 installed?"
fi

# llama-cpp-python — CPU baseline + Vulkan fallback. Use the prebuilt
# CPU wheel index so we don't compile from source on the install host.
echo "[47]   installing llama-cpp-python (CPU baseline)"
pip_install --quiet \
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

# Models are app-layer artifacts, not driver fidelity. If the canonical
# .cix/.gguf models aren't baked into this image, WARN but do NOT fail the
# build: the NPU runtime (libnoe, step 3) is what proves the driver works,
# and models are layered post-flash via `ncz model add` / `ncz install
# mnemos`. (Historical: a missing .cix used to exit 1 here.)
if [ "${#missing_models[@]}" -gt 0 ]; then
    echo "[47]   WARN: model(s) not baked into image: ${missing_models[*]}"
    echo "[47]         layer them post-flash with 'ncz model add'; NPU runtime is installed regardless"
fi

# Stage the tokenizer for the NPU model so the npu-cix adapter runs fully
# offline (no HuggingFace download on first embed). embedkit's tokenizer
# loads from /opt/ncz/models/bge-small-zh-v1.5/.
if [ -d "$MODELS_SRC/bge-small-zh-v1.5" ]; then
    mkdir -p "$MODELS/bge-small-zh-v1.5"
    cp -r "$MODELS_SRC/bge-small-zh-v1.5/." "$MODELS/bge-small-zh-v1.5/"
    echo "[47]   staged bge-small-zh-v1.5 tokenizer -> $MODELS/bge-small-zh-v1.5/"
else
    echo "[47]   WARN: tokenizer $MODELS_SRC/bge-small-zh-v1.5 not baked - npu-cix adapter will fetch it from HF on first use"
fi

# Back-compat symlink: older embedkit/MNEMOS revisions load the upstream
# Compass output name (bge-small-zh_256.cix) instead of the vendored
# bge-small-zh-v1.5_256.cix. Make both names resolve to the same blob.
if [ -f "$MODELS/bge-small-zh-v1.5_256.cix" ] && [ ! -e "$MODELS/bge-small-zh_256.cix" ]; then
    ln -s bge-small-zh-v1.5_256.cix "$MODELS/bge-small-zh_256.cix"
    echo "[47]   compat symlink bge-small-zh_256.cix -> bge-small-zh-v1.5_256.cix"
fi

# README so the operator knows what's in /opt/ncz/models/
cat > "$MODELS/MODELS-README.md" << 'EOF'
# /opt/ncz/models — embedkit model store

Models shipped with this NCZ image:

| File | Format | Adapter | Embed dim | Notes |
|---|---|---|---|---|
| `bge-small-zh-v1.5_256.cix` | Cix Compass NN AOT INT8 | `npu-cix` (Cix Sky1 Zhouyi V3) | 512 | 256-token max |
| `bge-small-zh-v1.5-q8_0.gguf` | llama.cpp Q8 GGUF | `cpu-llamacpp`, `gpu-vulkan` (Mali) | 512 | CPU/Vulkan fallback |
| `bge-small-zh-v1.5/`        | HF tokenizer (BERT WordPiece) | shared by all adapters | -   | offline tokenizer for the .cix/.gguf |

Add more models with:

    ncz model add <huggingface-id-or-path>

The kit's `Engine.auto()` picks among installed models + adapters at
runtime by capability tier (NPU > GPU > CPU) and measured throughput
within tier. No vendor preference.

Embedding is automatic: MNEMOS calls `embedkit.Engine.auto()`,
which detects libnoe + /dev/aipu and selects the `npu-cix` adapter,
loads the `.cix` from this directory, and embeds every memory on
ingest. No manual embedding step and no per-model wiring.

To override:

    embedkit.Engine(adapter="cpu-llamacpp", model="bge-small-zh-v1.5")
EOF

# ----------------------------------------------------------------------
# 5. Wire embedkit into PATH + record provenance for diagnostics.
# ----------------------------------------------------------------------
ln -sf "$VENV/bin/embedkit-bench"  /usr/local/bin/embedkit-bench  2>/dev/null || true
ln -sf "$VENV/bin/embedkit-doctor" /usr/local/bin/embedkit-doctor 2>/dev/null || true

mkdir -p /var/log/cix-install
if [ -n "$UV" ]; then
    "$UV" pip list --python "$VENV/bin/python" 2>/dev/null
else
    "$VENV/bin/pip" list --format=columns 2>/dev/null
fi | grep -iE "^(mnemos-embedkit|noe.engine|llama-cpp-python|libnoe|numpy|transformers)" \
    > /var/log/cix-install/47-embedkit-installed.log || true

# ----------------------------------------------------------------------
# 6. Smoke tests.
#    NPU runtime smoke (import libnoe in the venv) is the SHIP-CRITICAL
#    driver-fidelity gate — fatal when we built a 3.11/3.12 venv and the
#    libnoe wheel was present. embedkit smoke is best-effort (the app layer
#    may be layered post-flash).
# ----------------------------------------------------------------------
if [ "$NPU_PY_OK" = "1" ] && [ -n "$LIBNOE_WHL" ]; then
    echo "[47]   smoke: import libnoe (NPU userspace binding)"
    if "$VENV/bin/python" -c "import libnoe; print('[47]   libnoe import OK:', libnoe.__file__)" 2>&1 \
            | tee /var/log/cix-install/47-libnoe-smoke.log; then
        :
    else
        echo "[47]   ERROR: libnoe smoke failed — NPU adapter would be dark" >&2
        exit 1
    fi
fi

if [ "$EMBEDKIT_OK" = "1" ]; then
    echo "[47]   smoke: embedkit.Engine.list_adapters()"
    "$VENV/bin/python" - 2>&1 << 'PY' | tee /var/log/cix-install/47-embedkit-smoke.log \
        || echo "[47]   WARN: embedkit smoke failed (non-fatal)"
import embedkit
for a in embedkit.Engine.list_adapters():
    print(f"    {a['tier']:3s} {a['name']:18s} {a['available']!s:5s} {a['reason']}")
PY
else
    echo "[47]   embedkit not installed — skipping embedkit smoke (NPU runtime verified above)"
fi

echo "[47] done — $(ls $MODELS 2>/dev/null | wc -l) models, venv at $VENV, embedkit=$EMBEDKIT_OK"
exit 0
