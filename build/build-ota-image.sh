#!/bin/bash
# build-ota-image.sh — wrap cix-repo.squashfs into an OCI image for ghcr.io.
# Build only; push is a separate, explicit step (needs ghcr credentials).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SQUASH="$REPO/build/cix-repo.squashfs"
IMG="${IMG:-ghcr.io/ncz-os/cix-repo}"
TAG="${TAG:-26.6}"

[ -f "$SQUASH" ] || { echo "ERROR: $SQUASH missing — run build-ota-repo.sh first"; exit 1; }

CTX="$REPO/build/.ota-ctx"
rm -rf "$CTX"; mkdir -p "$CTX"
# hardlink (same fs) to avoid duplicating 2.1GB; fall back to copy across fs.
ln "$SQUASH" "$CTX/cix-repo.squashfs" 2>/dev/null || cp "$SQUASH" "$CTX/cix-repo.squashfs"

SHA=$(sha256sum "$SQUASH" | cut -d' ' -f1)
cat > "$CTX/Dockerfile" <<EOF
FROM scratch
LABEL org.opencontainers.image.title="NCZ OTA APT repo"
LABEL org.opencontainers.image.description="nclawzero OTA channel: kernel (lts/edge) + CIX drivers as a loop-mountable squashfs APT repo"
LABEL org.opencontainers.image.source="https://github.com/ncz-os"
LABEL dev.nclawzero.repo.squashfs.sha256="$SHA"
LABEL dev.nclawzero.repo.suite="ncz"
COPY cix-repo.squashfs /cix-repo.squashfs
EOF

DOCKER="${DOCKER:-docker}"
echo "== $DOCKER build $IMG:$TAG (squashfs sha256=$SHA) =="
$DOCKER build -t "$IMG:$TAG" -t "$IMG:latest" "$CTX"
rm -rf "$CTX"
$DOCKER images "$IMG"
echo "done (not pushed)."
