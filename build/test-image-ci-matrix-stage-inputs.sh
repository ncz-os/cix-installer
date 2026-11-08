#!/bin/bash
# test-image-ci-matrix-stage-inputs.sh -- the matrix must stage the gitignored
# build inputs in each fresh clone BEFORE build-image.sh's preflight, or every
# cell dies in host-ready with "build-inputs ... not staged".
set -u
S="$(cd "$(dirname "$0")/.." && pwd)/build/image-ci-matrix.sh"
[ -f "$S" ] || { echo "FAIL: no image-ci-matrix.sh"; exit 1; }
stage=$(grep -n 'bash build/stage-build-inputs.sh --arch "\$a"' "$S" | head -1 | cut -d: -f1)
build=$(grep -n 'bash build/build-image.sh --arch "\$a"' "$S" | head -1 | cut -d: -f1)
if [ -z "$stage" ] || [ -z "$build" ]; then echo "FAIL: stage-inputs or build call missing"; exit 1; fi
if [ "$stage" -lt "$build" ]; then
    echo "PASS: stage-inputs (line $stage) precedes the build (line $build)"
else
    echo "FAIL: stage-inputs (line $stage) is after the build (line $build)"
    exit 1
fi
