#!/bin/bash
# 46-python311.sh — lay down a relocatable CPython 3.11 at /opt/python3.11
# AND the uv toolchain at /usr/local/bin/uv, for the NPU embedding venv(s).
# 47-embedkit.sh builds `uv venv --python /opt/python3.11/...`.
#
# WHY THIS EXISTS
# ---------------
# r104 (Ubuntu Resolute) ships Python 3.14 as the system interpreter.
# The Cix NPU userspace binding shipped in cix-noe-umd 2.0.2 is
#   libnoe-2.0.0-py3-none-manylinux2014_aarch64.whl
# whose archive — despite the "py3-none" tag — contains ONLY compiled
# extensions for CPython 3.11 and 3.12:
#   libnoe/libnoe.cpython-311-aarch64-linux-gnu.so
#   libnoe/libnoe.cpython-312-aarch64-linux-gnu.so
# There is no cpython-314 variant, so `import libnoe` fails in any venv
# built from the system 3.14 interpreter. That silently disables the NPU
# from Python (the C lib libnoe.so.0.6.0 + /dev/aipu + KMD are all fine).
#
# Validated 2026-06-17 on .66 (7.0.12-cix-sky1-next, armchina_npu KMD):
# a Python 3.11 venv + cix-noe-umd 2.0.2 (libnoe 2.0.0 wheel) runs
# all-MiniLM minilm_128.cix at ~56 emb/s real-tokenized (vs CPU 13.3,
# Mali/panvk 8.8). UMD 1.1.1 (libnoe 0.5.0) and 3.1.2 do NOT work with
# the in-tree KMD — 2.0.2 is the one matched to our v0-compat module.
#
# This hook provides the 3.11 interpreter; 47-embedkit.sh consumes it.
#
# TEMPORARY / REMOVABLE: this is a deliberate stopgap. CIX has Python 3.14
# support pending in a future UMD release. Once libnoe ships a cpython-314
# (or abi3/stable-ABI) wheel, delete this hook and the venv-interpreter
# selection in 47-embedkit.sh and run the embedder on the system Python.
# See docs/POST-CIX-NPU-EMBEDDINGS-DRAFT.md "We know this is messy".
#
# Apt has no python3.11 on Resolute, so we vendor a relocatable
# python-build-standalone (Astral) install_only tarball. Offline-first;
# network fallback resolves the latest 3.11 aarch64-unknown-linux-gnu
# build via latest-release.json.
#
# RUNS INSIDE CHROOT (Phase 2, non-blocking). All paths target the
# installed system root (no /target/ prefix).
set -uo pipefail

PREFIX=/opt/python3.11
PYBIN="$PREFIX/bin/python3.11"

ASSETS=/usr/local/lib/cix-installer/assets/python311
if [ ! -d "$ASSETS" ] && [ -d /cdrom/cixmini/assets/python311 ]; then
    ASSETS=/cdrom/cixmini/assets/python311
fi

echo "[46] provisioning relocatable CPython 3.11 → $PREFIX"

# Idempotent: already laid down and importable?
if [ -x "$PYBIN" ] && "$PYBIN" -c 'import ctypes,sys; assert sys.version_info[:2]==(3,11)' 2>/dev/null; then
    echo "[46] $PYBIN already present ($("$PYBIN" --version 2>&1)); nothing to do"
    exit 0
fi

WORK=$(mktemp -d)
TARBALL=""

# 1. Offline: a vendored install_only tarball under assets/python311/.
if [ -d "$ASSETS" ]; then
    TARBALL=$(find "$ASSETS" -maxdepth 1 -type f \
        -name 'cpython-3.11*-aarch64-unknown-linux-gnu-install_only*.tar.gz' 2>/dev/null \
        | sort | tail -1)
    [ -n "$TARBALL" ] && echo "[46] using vendored interpreter: $(basename "$TARBALL")"
fi

# 2. Network fallback: resolve the latest 3.11 aarch64 build.
if [ -z "$TARBALL" ]; then
    echo "[46] no vendored tarball; attempting network fetch (python-build-standalone)"
    META=https://raw.githubusercontent.com/astral-sh/python-build-standalone/latest-release/latest-release.json
    URL=""
    if command -v curl >/dev/null 2>&1; then
        TAG=$(curl -fsSL "$META" 2>/dev/null \
            | grep -oE '"tag"[[:space:]]*:[[:space:]]*"[0-9]+"' | grep -oE '[0-9]+' | head -1)
        if [ -n "$TAG" ]; then
            URL="https://github.com/astral-sh/python-build-standalone/releases/download/${TAG}/cpython-3.11.15+${TAG}-aarch64-unknown-linux-gnu-install_only.tar.gz"
        fi
    fi
    if [ -n "$URL" ] && curl -fsSL -o "$WORK/py311.tar.gz" "$URL" 2>/dev/null; then
        TARBALL="$WORK/py311.tar.gz"
        echo "[46] fetched $URL"
    fi
fi

if [ -z "$TARBALL" ] || [ ! -f "$TARBALL" ]; then
    echo "[46] WARN: no Python 3.11 tarball available (offline + no network)."
    echo "[46]       NPU-from-Python will be unavailable; embedkit falls back to CPU/GPU."
    rm -rf "$WORK"
    exit 0
fi

# Extract: install_only archives unpack to a top-level python/ dir.
tar -C "$WORK" -xzf "$TARBALL" 2>/dev/null || {
    echo "[46] WARN: failed to extract $TARBALL"; rm -rf "$WORK"; exit 0; }

if [ ! -d "$WORK/python" ]; then
    echo "[46] WARN: unexpected tarball layout (no python/ dir)"; rm -rf "$WORK"; exit 0
fi

rm -rf "$PREFIX"
mkdir -p "$(dirname "$PREFIX")"
mv "$WORK/python" "$PREFIX"
rm -rf "$WORK"

# python-build-standalone ships bin/python3.11; ensure the expected name.
[ -x "$PREFIX/bin/python3.11" ] || ln -sf python3 "$PREFIX/bin/python3.11" 2>/dev/null || true

if "$PYBIN" -c 'import ctypes,sys; assert sys.version_info[:2]==(3,11)' 2>/dev/null; then
    echo "[46] OK: $("$PYBIN" --version 2>&1) at $PYBIN"
else
    echo "[46] WARN: $PYBIN did not verify; NPU-from-Python may be unavailable"
fi

# ----------------------------------------------------------------------
# uv toolchain — used by 47-embedkit.sh to build the venv and install
# wheels. Offline-first (vendored static binary), network fallback to the
# official install script.
# ----------------------------------------------------------------------
ensure_uv() {
    if command -v uv >/dev/null 2>&1; then
        echo "[46] uv already on PATH: $(command -v uv) ($(uv --version 2>&1))"; return 0
    fi
    # Vendored static binary: assets/python311/uv (aarch64).
    if [ -d "$ASSETS" ]; then
        local v
        v=$(find "$ASSETS" -maxdepth 1 -type f -name 'uv' 2>/dev/null | head -1)
        if [ -n "$v" ]; then
            install -D -m 0755 "$v" /usr/local/bin/uv && {
                echo "[46] installed vendored uv → /usr/local/bin/uv ($(/usr/local/bin/uv --version 2>&1))"; return 0; }
        fi
        # Or a vendored install tarball (uv-aarch64-unknown-linux-gnu.tar.gz).
        local t
        t=$(find "$ASSETS" -maxdepth 1 -type f -name 'uv-*aarch64*linux*.tar.gz' 2>/dev/null | head -1)
        if [ -n "$t" ]; then
            local d; d=$(mktemp -d)
            if tar -C "$d" -xzf "$t" 2>/dev/null; then
                local b; b=$(find "$d" -type f -name uv | head -1)
                [ -n "$b" ] && install -D -m 0755 "$b" /usr/local/bin/uv && {
                    rm -rf "$d"; echo "[46] installed uv from tarball → /usr/local/bin/uv"; return 0; }
            fi
            rm -rf "$d"
        fi
    fi
    # Network fallback.
    if command -v curl >/dev/null 2>&1; then
        echo "[46] fetching uv via official installer"
        if curl -LsSf https://astral.sh/uv/install.sh 2>/dev/null \
            | env UV_INSTALL_DIR=/usr/local/bin INSTALLER_NO_MODIFY_PATH=1 sh >/dev/null 2>&1 \
            && [ -x /usr/local/bin/uv ]; then
            echo "[46] installed uv → /usr/local/bin/uv ($(/usr/local/bin/uv --version 2>&1))"; return 0
        fi
    fi
    echo "[46] WARN: uv unavailable (offline + no network); 47-embedkit.sh will use stdlib venv"
    return 1
}
ensure_uv || true

exit 0
