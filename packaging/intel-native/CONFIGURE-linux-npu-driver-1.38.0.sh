#!/usr/bin/env bash

# git-lfs caveat: for a filter=lfs path, `git status --porcelain` reports the
# file as modified on every checkout even when the worktree bytes equal HEAD,
# because the clean filter turns the HEAD blob back into a pointer for hashing.
# Compare real content: sha256 of the worktree file vs the blob from git.
_ncz_dirty_paths() {
    local d="$1" f
    git -C "$d" status --porcelain | awk '{print $2}' | while IFS= read -r f; do
        [ -n "$f" ] && [ -f "$d/$f" ] || continue
        if git -C "$d" check-attr filter -- "$f" 2>/dev/null | grep -q lfs; then
            [ "$(sha256sum < "$d/$f" | cut -d" " -f1)" = \
              "$(git -C "$d" cat-file blob "HEAD:$f" 2>/dev/null | sha256sum | cut -d" " -f1)" ] || echo "$f"
        elif ! git -C "$d" diff --quiet -- "$f" 2>/dev/null; then
            echo "$f"
        fi
    done
}

# packaging/intel-native/CONFIGURE-linux-npu-driver-1.38.0.sh
#
# Configure intel/linux-npu-driver 1.38.0 for native amd64 Forky packaging.
# This script DOES modify the CMake cache in $BUILD_DIR (it runs cmake
# configure). It does not build or package. Used by BUILD.sh / AUDIT.sh.
#
# Requires explicit SRC_DIR and BUILD_DIR. SRC_DIR must be a git checkout
# of intel/linux-npu-driver at the exact pinned commit below, with a
# clean working tree.
#
# The public NPU compiler is built from source via upstream ExternalProject
# (see compiler/compiler_source.cmake), which clones the pinned public
# openvinotoolkit/npu_compiler and openvinotoolkit/openvino revisions.
# No vendor binary is fetched.

set -euo pipefail

DRV_VERSION="1.38.0"
DRV_COMMIT="aea583dcd86a4723a8d3bb06ad94b6eb2f80c6f2"
DRV_REPO="https://github.com/intel/linux-npu-driver.git"

: "${SRC_DIR:?SRC_DIR must be set to the linux-npu-driver source checkout}"
: "${BUILD_DIR:?BUILD_DIR must be set to the linux-npu-driver build directory}"

if [ ! -d "$SRC_DIR/.git" ]; then
  echo "[configure-npu-driver] ERROR: $SRC_DIR is not a git checkout" >&2
  exit 1
fi

head_commit="$(git -C "$SRC_DIR" rev-parse HEAD)"
if [ "$head_commit" != "$DRV_COMMIT" ]; then
  echo "[configure-npu-driver] ERROR: HEAD $head_commit != pinned $DRV_COMMIT" >&2
  exit 1
fi

if [ -n "$(_ncz_dirty_paths "$SRC_DIR")" ]; then
  echo "[configure-npu-driver] ERROR: $SRC_DIR has uncommitted changes" >&2
  exit 1
fi

echo "[configure-npu-driver] src=$SRC_DIR build=$BUILD_DIR commit=$DRV_COMMIT"

mkdir -p "$BUILD_DIR"

# Notes on upstream-recognized options (see npu-driver/CMakeLists.txt and
# npu-driver/cmake/packaging/setup.cmake):
#  - STACK_VERSION: upstream project version (default 1.38.0).
#  - BUILD_NUMBER: upstream build number string appended to PROJECT_VERSION
#    in CPACK_PACKAGE_VERSION. We set it to "ncz2" so the resulting Debian
#    version is 1.38.0.ncz2 (~ncz1 packages shipped without Depends and must
#    not be mistaken for the fixed ones).
#  - ENABLE_NPU_COMPILER_BUILD=ON: build the public NPU compiler from source
#    via upstream ExternalProject (compiler/compiler_source.cmake).
#  - ENABLE_VALIDATION_BUILD: upstream default is ON; we keep it ON to
#    preserve validation applications.
#  - ENABLE_NPU_PERFETTO_BUILD: upstream default OFF; left at default.
#  - ENABLE_OPENVINO_PACKAGE: upstream default OFF; left at default.
#  - ENABLE_NPU_ELF_BUILD: upstream default OFF (npu_elf comes from the
#    compiler package); left at default.
#  - ENABLE_TOOLS_BUILD: upstream default OFF; left at default.
#  - CPACK_GENERATOR=DEB and CPACK_DEB_COMPONENT_INSTALL=ON: upstream
#    packaging/setup.cmake selects deb generator on Debian hosts and
#    enumerates components; component install is supported.
#  - CPACK_DEBIAN_PACKAGE_SHLIBDEPS=ON: required for all four components so
#    CPack runs dpkg-shlibdeps and each package declares its shared-library
#    dependencies. npu-debian-metadata.cmake additionally sets the per-component
#    form and the hand-written inter-package relations.
#
# Upstream CPACK_PACKAGE_VERSION is ${PROJECT_VERSION}.${BUILD_NUMBER};
# we do not override it, we only set BUILD_NUMBER.

cmake -G Ninja \
  -S "$SRC_DIR" -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr \
  -DCMAKE_INSTALL_LIBDIR=lib/x86_64-linux-gnu \
  -DSTACK_VERSION="$DRV_VERSION" \
  -DBUILD_NUMBER=ncz2 \
  -DENABLE_NPU_COMPILER_BUILD=ON \
  -DENABLE_VALIDATION_BUILD=ON \
  -DCPACK_GENERATOR=DEB \
  -DCPACK_DEB_COMPONENT_INSTALL=ON \
  -DCPACK_DEBIAN_PACKAGE_SHLIBDEPS=ON
