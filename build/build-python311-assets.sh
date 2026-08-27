#!/usr/bin/env bash
# build-python311-assets.sh — populate assets/python311/ for the NPU venv.
#
# WHY THIS EXISTS
# ---------------
# post-install/46-python311.sh lays down a relocatable CPython 3.11 at
# /opt/python3.11 plus the uv toolchain, because the Cix NPU Python binding
# (libnoe, shipped in cix-noe-umd 2.0.2) only contains cpython-311 and
# cpython-312 extension modules — there is no cpython-314 build, and Debian
# forky's system interpreter is 3.14. Without a 3.11 interpreter `import libnoe`
# fails and the NPU is dark from Python even though /dev/aipu and the KMD are
# fine.
#
# 46-python311.sh is offline-first: it looks for a vendored tarball under
# assets/python311/ and only falls back to the network. But nothing ever
# populated that directory — assets/python311/ is a gitignored blob dir with no
# builder — and the chroot has no network, so on 2026-08-02 the O6N install
# logged:
#     [46] WARN: no Python 3.11 tarball available (offline + no network).
#     [46] WARN: uv unavailable (offline + no network)
#     [47]   WARN: no python3.11/3.12 found (system python3 is 3.14);
#     [47]         NPU libnoe binding cannot be imported.
# and the embedkit venv build then failed outright. This script is the missing
# producer. Run it on a build host WITH network before building an ISO.
#
# Both payloads are fetched from their upstream release channels and verified
# by unpacking + executing them on the build host, so a truncated or
# wrong-arch download cannot reach an ISO.
#
# Usage:  build/build-python311-assets.sh [--force]
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$REPO/assets/python311"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

PY_SERIES=3.11
UV_URL=https://github.com/astral-sh/uv/releases/latest/download/uv-aarch64-unknown-linux-gnu.tar.gz
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
    echo "[py311] already vendored: $(basename "$existing") (use --force to refresh)"
else
    echo "[py311] resolving latest python-build-standalone ${PY_SERIES} aarch64 build"
    curl -fsSL "$PBS_LATEST" -o "$WORK/latest.json"
    # latest-release.json carries the release tag plus the asset-url template.
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
        # asking the release itself which 3.11 install_only assets it carries.
        VERSION=$(curl -fsSL "https://api.github.com/repos/astral-sh/python-build-standalone/releases/tags/${TAG}" \
            | grep -oE "cpython-${PY_SERIES}\.[0-9]+\+${TAG}-aarch64-unknown-linux-gnu-install_only\.tar\.gz" \
            | head -1 | sed -E "s/^cpython-(${PY_SERIES}\.[0-9]+)\+.*/\1/")
    fi
    [ -n "$VERSION" ] || { echo "ERROR: could not determine a ${PY_SERIES}.x version in release $TAG" >&2; exit 1; }

    NAME="cpython-${VERSION}+${TAG}-aarch64-unknown-linux-gnu-install_only.tar.gz"
    URL="https://github.com/astral-sh/python-build-standalone/releases/download/${TAG}/${NAME}"
    echo "[py311] fetching $NAME"
    curl -fsSL "$URL" -o "$WORK/$NAME"

    # Verify by unpacking and running it — catches truncation and wrong arch.
    tar -C "$WORK" -xzf "$WORK/$NAME"
    [ -x "$WORK/python/bin/python3.11" ] || { echo "ERROR: $NAME has no bin/python3.11" >&2; exit 1; }
    "$WORK/python/bin/python3.11" -c 'import ctypes,sys; assert sys.version_info[:2]==(3,11)' \
        || { echo "ERROR: vendored interpreter failed its self-check" >&2; exit 1; }

    rm -f "$OUT"/cpython-${PY_SERIES}*-aarch64-unknown-linux-gnu-install_only*.tar.gz
    mv "$WORK/$NAME" "$OUT/$NAME"
    echo "[py311] vendored $NAME ($(du -h "$OUT/$NAME" | cut -f1))"
fi

# --------------------------------------------------------------------- uv ---
if [ -x "$OUT/uv" ] && [ "$FORCE" = 0 ]; then
    echo "[py311] uv already vendored ($("$OUT/uv" --version 2>&1 || echo '?'))"
else
    echo "[py311] fetching uv (aarch64-unknown-linux-gnu)"
    curl -fsSL "$UV_URL" -o "$WORK/uv.tar.gz"
    tar -C "$WORK" -xzf "$WORK/uv.tar.gz"
    UVBIN=$(find "$WORK" -type f -name uv -perm -u+x | head -1)
    [ -n "$UVBIN" ] || { echo "ERROR: no uv binary in $UV_URL" >&2; exit 1; }
    "$UVBIN" --version >/dev/null 2>&1 || { echo "ERROR: vendored uv does not execute on this host" >&2; exit 1; }
    install -m 0755 "$UVBIN" "$OUT/uv"
    echo "[py311] vendored uv ($("$OUT/uv" --version 2>&1))"
fi

echo ""
echo "assets/python311 now contains:"
ls -la "$OUT" | sed 's/^/  /'
echo ""
echo "build/build-iso-di.sh stages this directory automatically; 46-python311.sh"
echo "consumes it offline-first from /cdrom/cixmini/assets/python311."
