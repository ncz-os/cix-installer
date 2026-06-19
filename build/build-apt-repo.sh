#!/bin/bash
set -e

# This script builds the offline APT repository for NCZ Magnetar 26.6
# It bundles the CIX NPU runtime, MNEMOS integration, and MediaTek firmware

BUILD_DIR="$(dirname "$0")"
REPO_DIR="$BUILD_DIR/apt-repo"

# Export the path to the actual ISO build dir, since this is called alone sometimes
cd "$REPO_DIR"

echo "Building NCZ 26.6 offline APT repository..."

cd "$REPO_DIR"

# Generate Packages list
dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz

# Set up the repo to be hosted on gitlab Pages
mkdir -p "$BUILD_DIR/../public/pool/main"
mkdir -p "$BUILD_DIR/../public/dists/resolute/main/binary-arm64"
cp *.deb "$BUILD_DIR/../public/pool/main/"
cp Packages.gz "$BUILD_DIR/../public/dists/resolute/main/binary-arm64/"

echo "APT repository generated at $REPO_DIR"
