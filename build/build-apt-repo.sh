#!/bin/bash
set -e

# Never hardcode the base suite. release.conf is the single source of truth --
# a hardcoded "resolute" here is how a Forky tree ends up building a Ubuntu
# mirror and silently combining the two.
_RC="${ROOT:-$(cd "$(dirname "$0")/.." && pwd)}/release.conf"
if [ -r "$_RC" ]; then . "$_RC"; else
  echo "ERROR: $_RC not readable -- refusing to guess the base distro" >&2; exit 1
fi
: "${NCZ_BASE_CODENAME:?release.conf did not define NCZ_BASE_CODENAME}"


# This script builds the offline APT repository for NCZ Server 26.6
# It bundles the CIX NPU runtime, MNEMOS integration, and MediaTek firmware

# Resolve to absolute paths so the script is correct whether invoked from the
# repo root, from build/, or standalone (the old relative double-cd cd'd into
# apt-repo twice and aborted, leaving Packages.gz stale after a .deb rebuild).
BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$BUILD_DIR/apt-repo"
ROOT_DIR="$(dirname "$BUILD_DIR")"

cd "$REPO_DIR"

echo "Building NCZ 26.6 offline APT repository..."

# Generate Packages list
dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz

# Set up the repo to be hosted on gitlab Pages
mkdir -p "$ROOT_DIR/public/pool/main"
mkdir -p "$ROOT_DIR/public/dists/$NCZ_BASE_CODENAME/main/binary-arm64"
cp ./*.deb "$ROOT_DIR/public/pool/main/"
cp Packages.gz "$ROOT_DIR/public/dists/$NCZ_BASE_CODENAME/main/binary-arm64/"

echo "APT repository generated at $REPO_DIR"
