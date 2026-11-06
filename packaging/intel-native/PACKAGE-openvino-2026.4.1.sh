#!/usr/bin/env bash
# Standalone CPack driver for the pinned Intel OpenVINO native stack.
# Reuses the existing configured build tree; does not recompile C++ unless
# sources changed. Emits only the four selected component packages.
set -euo pipefail

: "${BUILD_DIR:?Set BUILD_DIR to the configured OpenVINO build tree}"
: "${OUT_DIR:?Set OUT_DIR to a fresh package output directory}"
: "${JOBS:?Set JOBS to the parallel build width}"
: "${SOURCE_DATE_EPOCH:?Set SOURCE_DATE_EPOCH to a numeric Unix timestamp}"

case "$SOURCE_DATE_EPOCH" in
  ''|*[!0-9]*) echo 'SOURCE_DATE_EPOCH must be numeric' >&2; exit 1;;
esac
[ "$SOURCE_DATE_EPOCH" -gt 0 ] || { echo 'SOURCE_DATE_EPOCH must be > 0' >&2; exit 1; }

case "$JOBS" in
  ''|*[!0-9]*) echo 'JOBS must be numeric' >&2; exit 1;;
esac
[ "$JOBS" -gt 0 ] || { echo 'JOBS must be > 0' >&2; exit 1; }

[ -d "$BUILD_DIR" ] || { echo "BUILD_DIR not found: $BUILD_DIR" >&2; exit 1; }
[ -f "$BUILD_DIR/CPackConfig.cmake" ] || { echo "CPackConfig.cmake missing in $BUILD_DIR" >&2; exit 1; }

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HELPER="$SCRIPT_DIR/openvino-debian-metadata.cmake"
[ -f "$HELPER" ] || { echo "metadata helper missing: $HELPER" >&2; exit 1; }

export SOURCE_DATE_EPOCH
mkdir -p "$OUT_DIR"
for pkg_path in "$BUILD_DIR" "$OUT_DIR"; do
    pkg_fs=$(findmnt -n -o FSTYPE -T "$pkg_path")
    case "$pkg_fs" in
        ''|tmpfs|ramfs|devtmpfs)
            echo "Package paths must use a known disk-backed filesystem: $pkg_path" >&2
            exit 1 ;;
    esac
done
if compgen -G "$OUT_DIR/*.deb" >/dev/null; then
    echo "OUT_DIR already contains packages; preserve them and use a fresh output directory" >&2
    exit 1
fi

cmake --build "$BUILD_DIR" --parallel "$JOBS"

cd "$BUILD_DIR"
cpack --config CPackConfig.cmake -B "$OUT_DIR" \
  -D "CPACK_COMPONENTS_ALL=core;cpu;gpu;npu" \
  -D "CPACK_PRE_BUILD_SCRIPTS=$HELPER"
