#!/usr/bin/env bash
# packaging/intel-native/CONFIGURE-openvino-2026.4.1.sh
#
# Configure OpenVINO 2026.4.1 for native amd64 Forky packaging.
# This script DOES modify the CMake cache in $BUILD_DIR (it runs cmake
# configure). It does not build or package. Used by BUILD.sh / AUDIT.sh.
#
# Requires explicit SRC_DIR and BUILD_DIR. SRC_DIR must be a git checkout
# of openvinotoolkit/openvino at the exact pinned commit below, with a
# clean working tree.

set -euo pipefail

OV_VERSION="2026.4.1"
OV_COMMIT="e213a14725769a6a2bf86fc86650aa78a9c05d3e"
OV_REPO="https://github.com/openvinotoolkit/openvino.git"

: "${SRC_DIR:?SRC_DIR must be set to the OpenVINO source checkout}"
: "${BUILD_DIR:?BUILD_DIR must be set to the OpenVINO build directory}"

if [ ! -d "$SRC_DIR/.git" ]; then
  echo "[configure-openvino] ERROR: $SRC_DIR is not a git checkout" >&2
  exit 1
fi

head_commit="$(git -C "$SRC_DIR" rev-parse HEAD)"
if [ "$head_commit" != "$OV_COMMIT" ]; then
  echo "[configure-openvino] ERROR: HEAD $head_commit != pinned $OV_COMMIT" >&2
  exit 1
fi

if [ -n "$(git -C "$SRC_DIR" status --porcelain)" ]; then
  echo "[configure-openvino] ERROR: $SRC_DIR has uncommitted changes" >&2
  exit 1
fi

echo "[configure-openvino] src=$SRC_DIR build=$BUILD_DIR commit=$OV_COMMIT"

mkdir -p "$BUILD_DIR"

# Notes on upstream-recognized options (see openvino/cmake/features.cmake,
# openvino/cmake/packaging/debian.cmake):
#  - ENABLE_INTEL_CPU / ENABLE_INTEL_GPU / ENABLE_INTEL_NPU: plugin toggles.
#  - ENABLE_OV_ONNX_FRONTEND: ONNX frontend toggle (upstream name).
#  - ENABLE_INTEL_NPU_INTERNAL: required for NPU plugin internal components
#    (defaults to BUILD_SHARED_LIBS).
#  - ENABLE_SYSTEM_TBB: use system TBB when CPACK_GENERATOR=DEB.
#  - CPACK_DEBIAN_PACKAGE_RELEASE: appended to CPACK_PACKAGE_VERSION by
#    upstream debian.cmake to form the full Debian version.
#  - CPACK_DEBIAN_PACKAGE_SHLIBDEPS: upstream debian.cmake already sets
#    SHLIBDEPS_PRIVATE_DIRS for NPU; enabling shlibdeps is supported.
#
# Upstream OpenVINO_VERSION is derived from the source tree; we do not
# override it. The Debian release suffix is set via
# CPACK_DEBIAN_PACKAGE_RELEASE so the resulting package version is
# 1:<upstream CPACK_PACKAGE_VERSION>-ncz1. Epoch 1 preserves an ordinary
# upgrade from Intel vendor builds whose fourth numeric component is higher.
# Upstream debian.cmake applies the same epoch to exact internal dependencies.

cmake -G Ninja \
  -S "$SRC_DIR" -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr \
  -DCMAKE_INSTALL_LIBDIR=lib/x86_64-linux-gnu \
  -DENABLE_INTEL_CPU=ON \
  -DENABLE_INTEL_GPU=ON \
  -DENABLE_INTEL_NPU=ON \
  -DENABLE_INTEL_NPU_INTERNAL=ON \
  -DENABLE_OV_ONNX_FRONTEND=ON \
  -DENABLE_PYTHON=OFF \
  -DENABLE_TESTS=OFF \
  -DENABLE_SAMPLES=OFF \
  -DENABLE_DOCS=OFF \
  -DENABLE_WHEEL=OFF \
  -DTHREADING=TBB \
  -DENABLE_SYSTEM_TBB=ON \
  -DCPACK_GENERATOR=DEB \
  -DCPACK_DEB_COMPONENT_INSTALL=ON \
  -DCPACK_DEBIAN_PACKAGE_SHLIBDEPS=ON \
  -DCPACK_DEBIAN_PACKAGE_RELEASE=ncz1 \
  -DCPACK_DEBIAN_PACKAGE_EPOCH=1
