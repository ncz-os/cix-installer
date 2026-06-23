#!/bin/bash
# release-ota.sh — build, push, and cosign-sign the NCZ OTA OCI image.
#
# Chain: build/build-ota-image.sh (FROM scratch + squashfs) -> docker push
# (tag + latest) -> resolve the pushed digest -> cosign sign that digest with the
# NCZ OTA image-signing key (build/keys/cosign.key). The matching public key ships
# in assets/keys/ncz-ota-cosign.pub and is verified on-device by ncz-update BEFORE
# the squashfs is mounted (verify-before-mount), in addition to the GPG-signed
# apt Release inside the squashfs.
#
# Requires: docker (logged in to ghcr.io), cosign, build/keys/cosign.key.
# Env: IMG (default ghcr.io/ncz-os/cix-repo), TAG (default 26.6),
#      DOCKER (default "sudo docker"), COSIGN_PASSWORD (default empty).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMG="${IMG:-ghcr.io/ncz-os/cix-repo}"
TAG="${TAG:-26.6}"
DOCKER="${DOCKER:-sudo docker}"
COSIGN_KEY="$REPO/build/keys/cosign.key"
export COSIGN_PASSWORD="${COSIGN_PASSWORD:-}"

command -v cosign >/dev/null || { echo "ERROR: cosign not installed"; exit 1; }
[ -f "$COSIGN_KEY" ] || { echo "ERROR: $COSIGN_KEY missing (run cosign generate-key-pair)"; exit 1; }

echo "== [1/4] build image =="
IMG="$IMG" TAG="$TAG" DOCKER="$DOCKER" bash "$REPO/build/build-ota-image.sh"

echo "== [2/4] push $IMG:$TAG + :latest =="
$DOCKER push "$IMG:$TAG"
$DOCKER push "$IMG:latest"

echo "== [3/4] resolve pushed digest =="
DIGEST="$($DOCKER buildx imagetools inspect "$IMG:$TAG" 2>/dev/null | awk '/^Digest:/{print $2; exit}')"
[ -n "$DIGEST" ] || DIGEST="$($DOCKER inspect --format '{{index .RepoDigests 0}}' "$IMG:$TAG" 2>/dev/null | sed 's/.*@//')"
[ -n "$DIGEST" ] || { echo "ERROR: could not resolve digest"; exit 1; }
REF="$IMG@$DIGEST"
echo "digest: $DIGEST"

echo "== [4/4] cosign sign $REF =="
cosign sign --tlog-upload=false --yes --key "$COSIGN_KEY" "$REF"

echo "$REF" > "$REPO/build/ota-image-digest.txt"
echo ""
echo "released + signed: $REF"
echo "  (recorded in build/ota-image-digest.txt)"
echo "  verify: cosign verify --insecure-ignore-tlog --key assets/keys/ncz-ota-cosign.pub $REF"
