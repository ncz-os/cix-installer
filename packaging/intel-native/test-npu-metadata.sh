#!/usr/bin/env bash
# Offline test for npu-debian-metadata.cmake using only temp files.
# Mirrors test-openvino-metadata.sh conventions.
set -euo pipefail

: "${TMPDIR:?Set TMPDIR to a writable temp directory}"
[ -d "$TMPDIR" ] || { echo "TMPDIR not a directory: $TMPDIR" >&2; exit 1; }

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HELPER="$SCRIPT_DIR/npu-debian-metadata.cmake"
[ -f "$HELPER" ] || { echo "helper missing: $HELPER" >&2; exit 1; }

WORK=$(mktemp -d "$TMPDIR/npu-metadata-test.XXXXXX")
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

STAGE="$WORK/stage"
CMAKEDIR="$WORK/cmake"
mkdir -p "$CMAKEDIR"

VER="1.38.0.ncz1"
SDE=1700000000

# Build the fixture stage tree: four component directories with the files that
# the upstream CPack DEB generator would have staged (empty lib/doc dirs are
# enough for this metadata overlay — it only reads/writes metadata files).
make_stage() {
  rm -rf "$STAGE"
  for comp in driver-compiler-npu fw-npu level-zero-npu validation-npu; do
    case "$comp" in
      driver-compiler-npu) pkg="intel-driver-compiler-npu";;
      fw-npu)              pkg="intel-fw-npu";;
      level-zero-npu)      pkg="intel-level-zero-npu";;
      validation-npu)      pkg="intel-validation-npu";;
    esac
    d="$STAGE/$comp/usr/share/doc/$pkg"
    mkdir -p "$d"
    # sentinel file to verify we don't clobber existing staged content
    printf 'UPSTREAM-SENTINEL-%s\n' "$comp" > "$d/UPSTREAM-SENTINEL"
  done
}

write_driver() {
  local out="$1"
  local ver="$VER"
  local deb_ver="${ver}~deb12u1"
  cat > "$out" <<EOF
set(CPACK_GENERATOR "DEB")
set(CPACK_TEMPORARY_DIRECTORY "$STAGE")
set(CPACK_COMPONENTS_ALL "driver-compiler-npu;fw-npu;level-zero-npu;validation-npu")
set(CPACK_PACKAGE_VERSION "$ver")
set(CPACK_DEBIAN_PACKAGE_VERSION "$deb_ver")
set(CPACK_DEBIAN_DRIVER-COMPILER-NPU_PACKAGE_NAME "intel-driver-compiler-npu")
set(CPACK_DEBIAN_FW-NPU_PACKAGE_NAME "intel-fw-npu")
set(CPACK_DEBIAN_LEVEL-ZERO-NPU_PACKAGE_NAME "intel-level-zero-npu")
set(CPACK_DEBIAN_VALIDATION-NPU_PACKAGE_NAME "intel-validation-npu")
include("$HELPER")
EOF
}

run_positive() {
  make_stage
  write_driver "$CMAKEDIR/positive.cmake"
  SOURCE_DATE_EPOCH=$SDE cmake -P "$CMAKEDIR/positive.cmake" >/dev/null 2>&1

  # All four packages must have copyright and changelog.gz
  for comp in driver-compiler-npu fw-npu level-zero-npu validation-npu; do
    case "$comp" in
      driver-compiler-npu) pkg="intel-driver-compiler-npu";;
      fw-npu)              pkg="intel-fw-npu";;
      level-zero-npu)      pkg="intel-level-zero-npu";;
      validation-npu)      pkg="intel-validation-npu";;
    esac
    d="$STAGE/$comp/usr/share/doc/$pkg"
    [ -f "$d/copyright" ] || { echo "missing copyright: $d" >&2; exit 1; }
    [ -f "$d/changelog.gz" ] || { echo "missing changelog.gz: $d" >&2; exit 1; }
    # changelog.gz must contain the correct version
    zcat "$d/changelog.gz" | grep -q "($VER~deb12u1)" || {
      echo "bad version in changelog.gz: $d" >&2; exit 1; }
    # changelog.gz must have a -- trailer line
    zcat "$d/changelog.gz" | grep -q "^ -- " || {
      echo "missing -- trailer in changelog.gz: $d" >&2; exit 1; }
    # copyright must have a Maintainer line with RFC-822 address
    grep -qE "^Maintainer: .+ <[^@]+@[^@]+>" "$d/copyright" || {
      echo "missing/invalid Maintainer in copyright: $d" >&2; exit 1; }
    # upstream sentinel must be preserved
    grep -q "UPSTREAM-SENTINEL-$comp" "$d/UPSTREAM-SENTINEL" || {
      echo "upstream sentinel mutated: $d" >&2; exit 1; }
  done

  # ldconfig triggers: exactly one line, for driver-compiler-npu and level-zero-npu only
  for comp in driver-compiler-npu level-zero-npu; do
    t="$STAGE/$comp/triggers"
    [ -f "$t" ] || { echo "missing triggers: $t" >&2; exit 1; }
    expected="interest ldconfig /usr/lib/x86_64-linux-gnu"
    actual=$(cat "$t")
    [ "$actual" = "$expected" ] || {
      echo "wrong triggers content: $t (got '$actual')" >&2; exit 1; }
    # must be exactly one line
    [ "$(wc -l < "$t")" = "1" ] || { echo "triggers not one line: $t" >&2; exit 1; }
  done

  # fw-npu and validation-npu must NOT have a triggers file
  for comp in fw-npu validation-npu; do
    [ ! -f "$STAGE/$comp/triggers" ] || {
      echo "unexpected triggers file: $STAGE/$comp/triggers" >&2; exit 1; }
  done

  # shlibs: level-zero-npu only
  shlibs="$STAGE/level-zero-npu/shlibs"
  [ -f "$shlibs" ] || { echo "missing shlibs: $shlibs" >&2; exit 1; }
  grep -q "^libze_intel_npu " "$shlibs" || {
    echo "bad shlibs content: $shlibs" >&2; exit 1; }
  for comp in driver-compiler-npu fw-npu validation-npu; do
    [ ! -f "$STAGE/$comp/shlibs" ] || {
      echo "unexpected shlibs file: $STAGE/$comp/shlibs" >&2; exit 1; }
  done

  echo 'positive: ok'
}

expect_fail() {
  local label="$1"; shift
  if SOURCE_DATE_EPOCH="${SDE:-}" cmake -P "$CMAKEDIR/negative.cmake" >/dev/null 2>&1; then
    echo "negative '$label' unexpectedly succeeded" >&2; exit 1
  fi
  echo "negative '$label': ok"
}

run_positive

# --- negative tests ---

# wrong generator
make_stage
sed 's/set(CPACK_GENERATOR "DEB")/set(CPACK_GENERATOR "TGZ")/' \
  "$CMAKEDIR/positive.cmake" > "$CMAKEDIR/negative.cmake"
expect_fail wrong-generator

# wrong components (extra)
make_stage
sed 's/set(CPACK_COMPONENTS_ALL .*/set(CPACK_COMPONENTS_ALL "driver-compiler-npu;fw-npu;level-zero-npu;validation-npu;extra")/' \
  "$CMAKEDIR/positive.cmake" > "$CMAKEDIR/negative.cmake"
expect_fail unexpected-component

# wrong components (missing)
make_stage
sed 's/set(CPACK_COMPONENTS_ALL .*/set(CPACK_COMPONENTS_ALL "driver-compiler-npu;fw-npu;level-zero-npu")/' \
  "$CMAKEDIR/positive.cmake" > "$CMAKEDIR/negative.cmake"
expect_fail missing-component

# non-numeric SOURCE_DATE_EPOCH
make_stage
write_driver "$CMAKEDIR/negative.cmake"
if SOURCE_DATE_EPOCH="not-a-number" cmake -P "$CMAKEDIR/negative.cmake" >/dev/null 2>&1; then
  echo "negative 'non-numeric-SDE' unexpectedly succeeded" >&2; exit 1
fi
echo "negative 'non-numeric-SDE': ok"

# missing SOURCE_DATE_EPOCH
make_stage
write_driver "$CMAKEDIR/negative.cmake"
if cmake -P "$CMAKEDIR/negative.cmake" >/dev/null 2>&1; then
  echo "negative 'missing-SDE' unexpectedly succeeded" >&2; exit 1
fi
echo "negative 'missing-SDE': ok"

# wrong version
make_stage
sed 's/set(CPACK_PACKAGE_VERSION .*/set(CPACK_PACKAGE_VERSION "9.9.9")/' \
  "$CMAKEDIR/positive.cmake" > "$CMAKEDIR/negative.cmake"
expect_fail wrong-version

# wrong package name
make_stage
sed 's/set(CPACK_DEBIAN_LEVEL-ZERO-NPU_PACKAGE_NAME .*/set(CPACK_DEBIAN_LEVEL-ZERO-NPU_PACKAGE_NAME "other-pkg")/' \
  "$CMAKEDIR/positive.cmake" > "$CMAKEDIR/negative.cmake"
expect_fail unexpected-package-name

# missing stage
rm -rf "$STAGE"
write_driver "$CMAKEDIR/negative.cmake"
expect_fail missing-stage

# --- PACKAGE script refusal test ---
# The package driver must refuse to run when OUT_DIR already contains packages.
mkdir -p "$WORK/build" "$WORK/out"
: > "$WORK/build/CPackConfig.cmake"
printf 'prior artifact sentinel\n' > "$WORK/out/prior.deb"
if BUILD_DIR="$WORK/build" OUT_DIR="$WORK/out" JOBS=1 SOURCE_DATE_EPOCH=$SDE \
    bash "$SCRIPT_DIR/PACKAGE-linux-npu-driver-1.38.0.sh" > "$WORK/refusal.log" 2>&1; then
  echo 'nonempty output directory unexpectedly accepted' >&2; exit 1
fi
grep -q 'OUT_DIR already contains packages' "$WORK/refusal.log"
grep -qx 'prior artifact sentinel' "$WORK/out/prior.deb"
echo 'negative prior-output: ok'

echo 'all npu metadata tests passed'
