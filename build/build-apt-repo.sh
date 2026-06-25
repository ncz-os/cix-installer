#!/bin/bash
set -e

# This script builds the offline APT repository for NCZ Magnetar 26.6
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
mkdir -p "$ROOT_DIR/public/dists/resolute/main/binary-arm64"
cp ./*.deb "$ROOT_DIR/public/pool/main/"
cp Packages.gz "$ROOT_DIR/public/dists/resolute/main/binary-arm64/"

echo "APT repository generated at $REPO_DIR"
