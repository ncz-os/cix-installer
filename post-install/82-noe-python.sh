#!/bin/bash
# 82-noe-python.sh — install NOE Python runtime into Python 3.13 uv venv
#
# Background: The Cix NPU Python wheel (libnoe) ships with
# Requires-Python: <3.14 and its .so files are compiled for CPython 3.10-3.13
# only. Ubuntu 26.04 ships Python 3.14, so the wheel cannot be installed
# via the system Python. Solution: install uv + Python 3.13 in a managed
# venv, install libnoe + NOE_Engine there, and point MNEMOS embed at it.
#
# This hook:
#   1. Downloads/installs uv (if not present)
#   2. Downloads Python 3.13 managed by uv
#   3. Creates /opt/ncz/noe-env uv venv with Python 3.13
#   4. Installs libnoe + NOE_Engine wheels from assets/pypi/
#   5. Patches the cix-noe-umd postinst (failed by pip on Python 3.14)
#   6. Writes /etc/nclawzero/embed.env with venv path
#
# Ordering: runs AFTER 25-cix-proprietary.sh (which installs cix-npu-umd
# and cix-noe-umd .debs) and AFTER 80-npu.sh (kernel modules + SSDT).
set -euo pipefail

echo "[82] NOE Python runtime (uv + 3.13 venv)"

ASSETS=/usr/local/lib/cix-installer/assets
NPU_VENV=/opt/ncz/noe-env

# ----------------------------------------------------------------------
# 1. Install uv (Per CLAUDE.md directive: curl | sh, no root needed)
# ----------------------------------------------------------------------
if ! command -v uv >/dev/null 2>&1; then
    echo "[82] installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
    echo "[82] uv installed: $(uv --version 2>/dev/null)"
else
    echo "[82] uv already present: $(uv --version 2>/dev/null)"
fi

# ----------------------------------------------------------------------
# 2. Install Python 3.13 via uv (managed download)
# ----------------------------------------------------------------------
echo "[82] installing Python 3.13 managed by uv..."
uv python install 3.13 2>&1 | tail -3
PY313=$(uv python find 3.13 2>/dev/null)
echo "[82] Python 3.13: $PY313"

# ----------------------------------------------------------------------
# 3. Create NOE venv with Python 3.13
# ----------------------------------------------------------------------
if [ -d "$NPU_VENV" ]; then
    echo "[82] NOE venv already exists at $NPU_VENV"
else
    echo "[82] creating NOE venv at $NPU_VENV..."
    uv venv --python 3.13 "$NPU_VENV"
fi

# ----------------------------------------------------------------------
# 4. Install libnoe + NOE_Engine wheels from assets
# ----------------------------------------------------------------------
if [ -d "$ASSETS/pypi" ]; then
    echo "[82] installing NOE Python wheels from $ASSETS/pypi..."
    WHEELS=$(ls "$ASSETS/pypi/"*.whl 2>/dev/null || true)
    if [ -n "$WHEELS" ]; then
        for whl in $WHEELS; do
            echo "[82]   installing: $(basename $whl)"
            uv pip install --python "$NPU_VENV" "$whl" 2>&1 | tail -2
        done
    else
        echo "[82]   no wheels found in $ASSETS/pypi/"
    fi
else
    echo "[82]   WARN: $ASSETS/pypi/ does not exist — no NOE Python wheels available"
fi

# ----------------------------------------------------------------------
# 5. Patch cix-noe-umd postinst (shebang + pip bypass for Python 3.14)
# ----------------------------------------------------------------------
if dpkg-query -W -f='${Status}' cix-noe-umd 2>/dev/null | grep -q "install ok installed"; then
    echo "[82] cix-noe-umd already configured cleanly"
elif dpkg-query -W -f='${Status}' cix-noe-umd 2>/dev/null | grep -q "installed-failed"; then
    echo "[82] cix-noe-umd in iF state — patching postinst..."
    POSTINST=/var/lib/dpkg/info/cix-noe-umd.postinst
    if [ -f "$POSTINST" ]; then
        # Fix shebang
        sed -i 's|#!/bin/sh|#!/bin/bash|' "$POSTINST"
        # Disable the pip install call (it fails on Python >=3.14)
        # The pip-installed wheel is provided via uv venv instead
        sed -i '/pip install/s/^/# [82] disabled: /' "$POSTINST"
        echo "[82] force-configuring cix-noe-umd..."
        dpkg --configure cix-noe-umd 2>&1 | tail -3
    fi
elif dpkg-query -W -f='${Status}' cix-noe-umd 2>/dev/null | grep -q "not-installed"; then
    echo "[82] cix-noe-umd not installed (25-cix-proprietary skipped it)"
fi

# ----------------------------------------------------------------------
# 6. Install numpy in NOE venv (needed by NOE_Engine)
# ----------------------------------------------------------------------
echo "[82] installing numpy in NOE venv..."
uv pip install --python "$NPU_VENV" numpy 2>&1 | tail -2

# ----------------------------------------------------------------------
# 7. Verify the stack
# ----------------------------------------------------------------------
echo "[82] verifying NOE stack..."
if "$NPU_VENV/bin/python3" -c 'import libnoe; import NOE_Engine; print("libnoe OK, NOE_Engine OK")' 2>&1; then
    echo "[82] NOE Python stack verified"
    NPU_STATE=available
else
    echo "[82] WARN: NOE Python stack import failed"
    echo "[82]   Falling back: embed.env marks NPU as missing; MNEMOS uses GGUF fallback"
    NPU_STATE=missing
fi

# ----------------------------------------------------------------------
# 8. Write /etc/nclawzero/embed.env for MNEMOS auto-detect
# ----------------------------------------------------------------------
install -d -m 0755 /etc/nclawzero

CIX_NOE_VER=$(dpkg-query -W -f='${Version}' cix-noe-umd 2>/dev/null || echo unknown)
CIX_NPU_VER=$(dpkg-query -W -f='${Version}' cix-npu-umd 2>/dev/null || echo unknown)

cat > /etc/nclawzero/embed.env << EOF
# Auto-generated by 82-noe-python.sh
EMBEDKIT_NPU=${NPU_STATE}
EMBEDKIT_NPU_DRIVER_VERSION=${CIX_NPU_VER}
EMBEDKIT_LIBNOE_VERSION=3.1.0
EMBEDKIT_MODELS_DIR=/opt/ncz/models
EMBEDKIT_DEFAULT_MODEL=bge-small-zh-v1.5
EMBEDKIT_DEFAULT_TIER=npu-cix
EMBEDKIT_PYTHON=${NPU_VENV}/bin/python3
EOF
chmod 0644 /etc/nclawzero/embed.env
echo "[82] wrote /etc/nclawzero/embed.env (NPU=$NPU_STATE)"

echo "[82] NOE Python runtime install complete"
