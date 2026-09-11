#!/usr/bin/env bash
# build-python312-assets.sh — populate assets/python312/ for the gesture
# runtime (build-time) AND the shipped-system 47-embedkit.sh fallback (run-time).
#
# WHY THIS EXISTS
# ---------------
# post-install/46-python312.sh lays down a relocatable CPython 3.12 at
# /opt/python3.12, mirroring 46-python311.sh. Two consumers, distinct
# purposes:
#
#   1. BUILD TIME on the Singularity Desktop build host:
#      subprojects/singularity-gestures/scripts/bootstrap-runtime.sh (a
#      precondition of `make compile`) hardcodes /usr/bin/python3.12 to
#      pull a cp312 MediaPipe wheel and extract libmediapipe.so. The build
#      container is provisioned with /usr/bin/python3.12 inside
#      build/build-singularity-podman.sh.
#
#   2. SHIPPED SYSTEM at install time:
#      47-embedkit.sh's interpreter-selection list already tries
#      `command -v python3.12` as a fallback for the NPU venv (the libnoe
#      wheel ships cp311 AND cp312 extensions). Provisioning 3.12 at install
#      time makes that fallback real rather than a silent no-op.
#
# This script is the producer for assets/python312/ — without it,
# 46-python312.sh has no vendored tarball and would fall through to network
# at install time, which the d-i chroot doesn't have.
#
# Usage:  build/build-python312-assets.sh [--force]
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$REPO/assets/python312"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

PY_SERIES=3.12
PBS_LATEST=https://raw.githubusercontent.com/astral-sh/python-build-standalone/latest-release/latest-release.json

for t in curl tar python3; do
    command -v "$t" >/dev/null 2>&1 || { echo "ERROR: missing tool: $t" >&2; exit 1; }
done

mkdir -p "$OUT"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------- CPython ---
existing=$(find "$OUT" -maxdepth 1 -type f \
    -name "cpython-${PY_SERIES}*-aarch64-unknown-linux-gnu-install_only*.tar.gz" | sort | tail -1)
if [ -n "$existing" ] && [ "$FORCE" = 0 ]; then
    echo "[py312] already vendored: $(basename "$existing") (use --force to refresh)"
else
    echo "[py312] resolving latest python-build-standalone ${PY_SERIES} aarch64 build"
    curl -fsSL "$PBS_LATEST" -o "$WORK/latest.json"
    read -r TAG VERSION < <(python3 - "$WORK/latest.json" "$PY_SERIES" <<'PY'
import json, sys
meta = json.load(open(sys.argv[1]))
series = sys.argv[2]
tag = str(meta.get("tag") or meta.get("release") or "").strip()
version = ""
for key in ("python_versions", "versions"):
    for v in meta.get(key) or []:
        if str(v).startswith(series + "."):
            version = str(v)
if not tag:
    sys.exit("could not read release tag from latest-release.json")
print(tag, version)
PY
)
    if [ -z "$VERSION" ]; then
        # latest-release.json does not always enumerate versions; fall back to
        # asking the release itself which 3.12 install_only assets it carries.
        VERSION=$(curl -fsSL "https://api.github.com/repos/astral-sh/python-build-standalone/releases/tags/${TAG}" \
            | grep -oE "cpython-${PY_SERIES}\.[0-9]+\+${TAG}-aarch64-unknown-linux-gnu-install_only\.tar\.gz" \
            | head -1 | sed -E "s/^cpython-(${PY_SERIES}\.[0-9]+)\+.*/\1/")
    fi
    [ -n "$VERSION" ] || { echo "ERROR: could not determine a ${PY_SERIES}.x version in release $TAG" >&2; exit 1; }

    NAME="cpython-${VERSION}+${TAG}-aarch64-unknown-linux-gnu-install_only.tar.gz"
    URL="https://github.com/astral-sh/python-build-standalone/releases/download/${TAG}/${NAME}"
    echo "[py312] fetching $NAME"
    curl -fsSL "$URL" -o "$WORK/$NAME"

    # Verify by unpacking and running it — catches truncation and wrong arch.
    tar -C "$WORK" -xzf "$WORK/$NAME"
    [ -x "$WORK/python/bin/python3.12" ] || { echo "ERROR: $NAME has no bin/python3.12" >&2; exit 1; }
    "$WORK/python/bin/python3.12" -c 'import ctypes,sys; assert sys.version_info[:2]==(3,12)' \
        || { echo "ERROR: vendored interpreter failed its self-check" >&2; exit 1; }

    rm -f "$OUT"/cpython-${PY_SERIES}*-aarch64-unknown-linux-gnu-install_only*.tar.gz
    mv "$WORK/$NAME" "$OUT/$NAME"
    echo "[py312] vendored $NAME ($(du -h "$OUT/$NAME" | cut -f1))"
fi

echo ""
echo "assets/python312 now contains:"
ls -la "$OUT" | sed 's/^/  /'
echo ""
echo "build/build-iso-di.sh stages this directory automatically; 46-python312.sh"
echo "consumes it offline-first from /cdrom/cixmini/assets/python312. The same"
echo "tarball is also fetched (and extracted to /opt/python3.12 + symlinked to"
echo "/usr/bin/python3.12) by build/build-singularity-podman.sh so the gesture"
echo "bootstrap-runtime.sh inside the build container has the literal interpreter"
echo "path it hardcodes."