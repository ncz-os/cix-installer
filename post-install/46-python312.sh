#!/bin/bash
# 46-python312.sh — lay down a relocatable CPython 3.12 at /opt/python3.12.
#
# This is the SIBLING of 46-python311.sh — same offline-first mechanism
# (python-build-standalone install_only tarball under assets/, network
# fallback to the latest 3.12 aarch64-unknown-linux-gnu release), parallel
# provisioner pattern, no logic shared with 46-python311.sh. See that file's
# header for the broader WHY (Debian Forky ships 3.13/3.14/3.15 only, so no
# apt python3.11 / python3.12 exists there). 47-embedkit.sh's interpreter
# selection ALREADY lists /opt/python3.11 first, then command -v python3.11,
# then command -v python3.12 (see the `for cand in ...` loop near the top),
# so this hook is consumed the moment it lays down /opt/python3.12 — no
# edits to 47-embedkit.sh needed.
#
# WHY 3.12 IS NEEDED, IN ADDITION TO 3.11
# ----------------------------------------
# 1. Build-time (must exist at compile time on the build host):
#    subprojects/singularity-gestures/scripts/bootstrap-runtime.sh (an
#    unconditional prerequisite of `make compile`, which the
#    Singularity Desktop build pulls in) hardcodes /usr/bin/python3.12 to
#    pull a cp312 MediaPipe wheel and extract libmediapipe.so. The build
#    container gets /usr/bin/python3.12 via build-singularity-podman.sh
#    after fetching the same python-build-standalone tarball this hook
#    stages (see the BUILD-CONTAINER step in that script).
#
# 2. Runtime (the shipped system): libnoe-2.0.0 ships cpython-311 AND
#    cpython-312 .so, not just cp311 — 47-embedkit.sh can build a venv on
#    EITHER. Provisioning 3.12 as part of the post-install flow lets
#    `command -v python3.12` resolve on the installed system, so the
#    existing 3.12 fallback in 47-embedkit.sh becomes real rather than a
#    silent no-op.
#
# uv is NOT re-provisioned here. 46-python311.sh installs it at
# /usr/local/bin/uv (idempotent; checks `command -v uv` first); uv is
# install-once, not per-interpreter. This hook simply omits ensure_uv.
#
# RUNS INSIDE CHROOT (Phase 2, non-blocking). All paths target the
# installed system root (no /target/ prefix). Same idempotency contract
# as 46-python311.sh.
set -uo pipefail

PREFIX=/opt/python3.12
PYBIN="$PREFIX/bin/python3.12"

ASSETS=/usr/local/lib/cix-installer/assets/python312
if [ ! -d "$ASSETS" ] && [ -d /cdrom/cixmini/assets/python312 ]; then
    ASSETS=/cdrom/cixmini/assets/python312
fi

echo "[46] provisioning relocatable CPython 3.12 → $PREFIX"

# Idempotent: already laid down and importable?
if [ -x "$PYBIN" ] && "$PYBIN" -c 'import ctypes,sys; assert sys.version_info[:2]==(3,12)' 2>/dev/null; then
    echo "[46] $PYBIN already present ($("$PYBIN" --version 2>&1)); nothing to do"
    exit 0
fi

WORK=$(mktemp -d)
TARBALL=""

# 1. Offline: a vendored install_only tarball under assets/python312/.
if [ -d "$ASSETS" ]; then
    TARBALL=$(find "$ASSETS" -maxdepth 1 -type f \
        -name 'cpython-3.12*-aarch64-unknown-linux-gnu-install_only*.tar.gz' 2>/dev/null \
        | sort | tail -1)
    [ -n "$TARBALL" ] && echo "[46] using vendored interpreter: $(basename "$TARBALL")"
fi

# 2. Network fallback: resolve the latest 3.12 aarch64 build.
#
# We resolve the actual CPython 3.12.x version from the GitHub release
# payload rather than hardcoding it the way 46-python311.sh does (which
# would silently 404 once astral bumps the source version past the
# hardcoded literal). This costs one extra GET per install on first boot
# but always succeeds against the live release.
if [ -z "$TARBALL" ]; then
    echo "[46] no vendored tarball; attempting network fetch (python-build-standalone)"
    META=https://raw.githubusercontent.com/astral-sh/python-build-standalone/latest-release/latest-release.json
    URL=""
    if command -v curl >/dev/null 2>&1; then
        TAG=$(curl -fsSL "$META" 2>/dev/null \
            | grep -oE '"tag"[[:space:]]*:[[:space:]]*"[0-9]+"' | grep -oE '[0-9]+' | head -1)
        if [ -n "$TAG" ]; then
            # Resolve the actual 3.12.x version by listing release assets via
            # the GitHub API, then construct the install_only tarball URL.
            # Falls through to a known-good literal (3.12.14) if the listing
            # is unreachable.
            CPVER=$(curl -fsSL --max-time 20 \
                "https://api.github.com/repos/astral-sh/python-build-standalone/releases/tags/${TAG}" 2>/dev/null \
                | grep -oE '"name"[[:space:]]*:[[:space:]]*"cpython-3\.12\.[0-9]+\+'"${TAG}"'-aarch64-unknown-linux-gnu-install_only\.tar\.gz"' \
                | grep -oE 'cpython-3\.12\.[0-9]+' | head -1)
            [ -z "$CPVER" ] && CPVER=cpython-3.12.14
            URL="https://github.com/astral-sh/python-build-standalone/releases/download/${TAG}/${CPVER}+${TAG}-aarch64-unknown-linux-gnu-install_only.tar.gz"
        fi
    fi
    if [ -n "$URL" ] && curl -fsSL -o "$WORK/py312.tar.gz" "$URL" 2>/dev/null; then
        TARBALL="$WORK/py312.tar.gz"
        echo "[46] fetched $URL"
    fi
fi

if [ -z "$TARBALL" ] || [ ! -f "$TARBALL" ]; then
    echo "[46] WARN: no Python 3.12 tarball available (offline + no network)."
    echo "[46]       gesture-bootstrap on the BUILD HOST will fail; shipped-system"
    echo "[46]       runtime will fall back to /opt/python3.11 via 47-embedkit.sh."
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

# python-build-standalone ships bin/python3.12; ensure the expected name.
[ -x "$PREFIX/bin/python3.12" ] || ln -sf python3 "$PREFIX/bin/python3.12" 2>/dev/null || true

if "$PYBIN" -c 'import ctypes,sys; assert sys.version_info[:2]==(3,12)' 2>/dev/null; then
    echo "[46] OK: $("$PYBIN" --version 2>&1) at $PYBIN"
else
    echo "[46] WARN: $PYBIN did not verify; shipped system may not be able to consume this interpreter"
fi

exit 0