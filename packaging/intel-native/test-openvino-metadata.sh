#!/usr/bin/env bash
# Offline test for openvino-debian-metadata.cmake using only temp files.
set -euo pipefail

: "${TMPDIR:?Set TMPDIR to a writable temp directory}"
[ -d "$TMPDIR" ] || { echo "TMPDIR not a directory: $TMPDIR" >&2; exit 1; }

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HELPER="$SCRIPT_DIR/openvino-debian-metadata.cmake"
[ -f "$HELPER" ] || { echo "helper missing: $HELPER" >&2; exit 1; }

WORK=$(mktemp -d "$TMPDIR/openvino-metadata-test.XXXXXX")
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

STAGE="$WORK/stage"
CMAKEDIR="$WORK/cmake"
mkdir -p "$CMAKEDIR"

ABI=2026.4.1
VER=2026.4.1.1
REL=ncz1
EPOCH=1
SDE=1700000000

make_stage() {
  rm -rf "$STAGE"
  for comp in core cpu gpu npu; do
    case "$comp" in
      core) pkg="libopenvino-$ABI";;
      cpu)  pkg="libopenvino-intel-cpu-plugin-$ABI";;
      gpu)  pkg="libopenvino-intel-gpu-plugin-$ABI";;
      npu)  pkg="libopenvino-intel-npu-plugin-$ABI";;
    esac
    d="$STAGE/$comp/usr/share/doc/$pkg"
    mkdir -p "$d"
    printf 'UPSTREAM-COPYRIGHT-SENTINEL-%s\n' "$comp" > "$d/copyright"
    printf 'UPSTREAM-CHANGELOG-SENTINEL-%s\n' "$comp" | gzip -n -9 > "$d/changelog.gz"
  done
}

write_driver() {
  local out="$1"
  cat > "$out" <<EOF
set(CPACK_GENERATOR "DEB")
set(CPACK_TEMPORARY_DIRECTORY "$STAGE")
set(CPACK_COMPONENTS_ALL "core;cpu;gpu;npu")
set(CPACK_PACKAGE_VERSION "$VER")
set(CPACK_DEBIAN_PACKAGE_RELEASE "$REL")
set(CPACK_DEBIAN_PACKAGE_EPOCH "$EPOCH")
set(CPACK_DEBIAN_CORE_PACKAGE_NAME "libopenvino-$ABI")
set(CPACK_DEBIAN_CPU_PACKAGE_NAME "libopenvino-intel-cpu-plugin-$ABI")
set(CPACK_DEBIAN_GPU_PACKAGE_NAME "libopenvino-intel-gpu-plugin-$ABI")
set(CPACK_DEBIAN_NPU_PACKAGE_NAME "libopenvino-intel-npu-plugin-$ABI")
include("$HELPER")
EOF
}

run_positive() {
  make_stage
  write_driver "$CMAKEDIR/positive.cmake"
  SOURCE_DATE_EPOCH=$SDE cmake -P "$CMAKEDIR/positive.cmake" >/dev/null
  for comp in core cpu gpu npu; do
    case "$comp" in
      core) pkg="libopenvino-$ABI";;
      cpu)  pkg="libopenvino-intel-cpu-plugin-$ABI";;
      gpu)  pkg="libopenvino-intel-gpu-plugin-$ABI";;
      npu)  pkg="libopenvino-intel-npu-plugin-$ABI";;
    esac
    d="$STAGE/$comp/usr/share/doc/$pkg"
    [ -f "$d/changelog.Debian.gz" ] || { echo "missing changelog.Debian.gz: $d" >&2; exit 1; }
    zcat "$d/changelog.Debian.gz" | grep -q "($EPOCH:$VER-$REL)" || { echo "bad version in $d" >&2; exit 1; }
    zcat "$d/changelog.Debian.gz" | grep -q 'Jason Perlow <jperlow@gmail.com>' || { echo "bad maintainer in $d" >&2; exit 1; }
    grep -q "UPSTREAM-COPYRIGHT-SENTINEL-$comp" "$d/copyright" || { echo "copyright mutated: $d" >&2; exit 1; }
    zcat "$d/changelog.gz" | grep -q "UPSTREAM-CHANGELOG-SENTINEL-$comp" || { echo "upstream changelog mutated: $d" >&2; exit 1; }
  done
  echo 'positive: ok'
}

expect_fail() {
  local label="$1"; shift
  if SOURCE_DATE_EPOCH=$SDE cmake -P "$CMAKEDIR/negative.cmake" >/dev/null 2>&1; then
    echo "negative '$label' unexpectedly succeeded" >&2; exit 1
  fi
  echo "negative '$label': ok"
}

run_positive

# negative: missing stage
rm -rf "$STAGE"
write_driver "$CMAKEDIR/negative.cmake"
expect_fail missing-stage

# negative: missing copyright
make_stage
rm -f "$STAGE/core/usr/share/doc/libopenvino-$ABI/copyright"
write_driver "$CMAKEDIR/negative.cmake"
expect_fail missing-copyright

# negative: epoch 0
make_stage
sed 's/^set(CPACK_DEBIAN_PACKAGE_EPOCH .*/set(CPACK_DEBIAN_PACKAGE_EPOCH "0")/' \
  "$CMAKEDIR/positive.cmake" > "$CMAKEDIR/negative.cmake"
expect_fail epoch-zero

# negative: unexpected component
make_stage
sed 's/^set(CPACK_COMPONENTS_ALL .*/set(CPACK_COMPONENTS_ALL "core;cpu;gpu;npu;extra")/' \
  "$CMAKEDIR/positive.cmake" > "$CMAKEDIR/negative.cmake"
expect_fail unexpected-component

# Reject a lookalike package name even when it contains the expected ABI.
make_stage
sed 's/"libopenvino-intel-gpu-plugin-2026.4.1"/"other-2026x4y1"/' \
  "$CMAKEDIR/positive.cmake" > "$CMAKEDIR/negative.cmake"
expect_fail unexpected-package-name

# The package driver must preserve prior artifacts and refuse before building.
mkdir -p "$WORK/build" "$WORK/out"
: > "$WORK/build/CPackConfig.cmake"
printf 'prior artifact sentinel\n' > "$WORK/out/prior.deb"
if BUILD_DIR="$WORK/build" OUT_DIR="$WORK/out" JOBS=1 SOURCE_DATE_EPOCH=$SDE \
    bash "$SCRIPT_DIR/PACKAGE-openvino-2026.4.1.sh" > "$WORK/refusal.log" 2>&1; then
  echo 'nonempty output directory unexpectedly accepted' >&2; exit 1
fi
grep -q 'OUT_DIR already contains packages' "$WORK/refusal.log"
grep -qx 'prior artifact sentinel' "$WORK/out/prior.deb"
echo 'negative prior-output: ok'

echo 'all metadata tests passed'
