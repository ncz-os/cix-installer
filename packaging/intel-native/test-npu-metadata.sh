#!/usr/bin/env bash
# Offline test for npu-debian-metadata.cmake using only temp files.
# Mirrors test-openvino-metadata.sh conventions.
#
# NOTE: this fixture deliberately does NOT set CPACK_DEBIAN_<COMP>_PACKAGE_NAME.
# Upstream deb.cmake never sets it either; CPack composes the component package
# name itself as "${CPACK_PACKAGE_NAME}-${component}". An earlier revision of
# this file set those variables, which made the tests pass against a state the
# real build never produces.
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

VER="1.38.0.ncz2"
DEB_VER="${VER}~deb12u1"
SDE=1700000000

pkg_for() {
  case "$1" in
    driver-compiler-npu) echo "intel-driver-compiler-npu";;
    fw-npu)              echo "intel-fw-npu";;
    level-zero-npu)      echo "intel-level-zero-npu";;
    validation-npu)      echo "intel-validation-npu";;
    *) echo "UNKNOWN" ;;
  esac
}

# Build the fixture stage tree: four component directories with the files that
# the upstream CPack DEB generator would have staged (empty lib/doc dirs are
# enough for this metadata overlay — it only reads/writes metadata files).
make_stage() {
  rm -rf "$STAGE"
  for comp in driver-compiler-npu fw-npu level-zero-npu validation-npu; do
    d="$STAGE/$comp/usr/share/doc/$(pkg_for "$comp")"
    mkdir -p "$d"
    # sentinel file to verify we don't clobber existing staged content
    printf 'UPSTREAM-SENTINEL-%s\n' "$comp" > "$d/UPSTREAM-SENTINEL"
  done
}

write_driver() {
  local out="$1"
  local ver="$VER"
  local deb_ver="$DEB_VER"
  cat > "$out" <<EOF
set(CPACK_GENERATOR "DEB")
set(CPACK_TEMPORARY_DIRECTORY "$STAGE")
set(CPACK_COMPONENTS_ALL "driver-compiler-npu;fw-npu;level-zero-npu;validation-npu")
set(CPACK_PACKAGE_NAME "intel")
set(CPACK_PACKAGE_VERSION "$ver")
set(CPACK_DEBIAN_PACKAGE_VERSION "$deb_ver")
# fw-npu ships a postinst; the overlay must preserve it, not replace it.
set(CPACK_DEBIAN_FW-NPU_PACKAGE_CONTROL_EXTRA "/upstream/fw-postinst")
include("$HELPER")
message(STATUS "T-CTRL-DRIVER-COMPILER-NPU=\${CPACK_DEBIAN_DRIVER-COMPILER-NPU_PACKAGE_CONTROL_EXTRA}")
message(STATUS "T-CTRL-FW-NPU=\${CPACK_DEBIAN_FW-NPU_PACKAGE_CONTROL_EXTRA}")
message(STATUS "T-CTRL-LEVEL-ZERO-NPU=\${CPACK_DEBIAN_LEVEL-ZERO-NPU_PACKAGE_CONTROL_EXTRA}")
message(STATUS "T-CTRL-VALIDATION-NPU=\${CPACK_DEBIAN_VALIDATION-NPU_PACKAGE_CONTROL_EXTRA}")
message(STATUS "T-SHLIBDEPS-DRIVER-COMPILER-NPU=\${CPACK_DEBIAN_DRIVER-COMPILER-NPU_PACKAGE_SHLIBDEPS}")
message(STATUS "T-SHLIBDEPS-FW-NPU=\${CPACK_DEBIAN_FW-NPU_PACKAGE_SHLIBDEPS}")
message(STATUS "T-SHLIBDEPS-LEVEL-ZERO-NPU=\${CPACK_DEBIAN_LEVEL-ZERO-NPU_PACKAGE_SHLIBDEPS}")
message(STATUS "T-SHLIBDEPS-VALIDATION-NPU=\${CPACK_DEBIAN_VALIDATION-NPU_PACKAGE_SHLIBDEPS}")
message(STATUS "T-DEPENDS-DRIVER-COMPILER-NPU=\${CPACK_DEBIAN_DRIVER-COMPILER-NPU_PACKAGE_DEPENDS}")
message(STATUS "T-DEPENDS-FW-NPU=\${CPACK_DEBIAN_FW-NPU_PACKAGE_DEPENDS}")
message(STATUS "T-DEPENDS-LEVEL-ZERO-NPU=\${CPACK_DEBIAN_LEVEL-ZERO-NPU_PACKAGE_DEPENDS}")
message(STATUS "T-DEPENDS-VALIDATION-NPU=\${CPACK_DEBIAN_VALIDATION-NPU_PACKAGE_DEPENDS}")
EOF
}

run_positive() {
  make_stage
  write_driver "$CMAKEDIR/positive.cmake"
  local out
  out=$(SOURCE_DATE_EPOCH=$SDE cmake -P "$CMAKEDIR/positive.cmake" 2>&1) || {
    echo "positive run failed:" >&2; echo "$out" >&2; exit 1; }

  ctrl_of() { printf '%s\n' "$out" | sed -n "s/^-- T-CTRL-$1=//p"; }

  # All four packages must have copyright and changelog.gz in the DATA tree
  for comp in driver-compiler-npu fw-npu level-zero-npu validation-npu; do
    d="$STAGE/$comp/usr/share/doc/$(pkg_for "$comp")"
    [ -f "$d/copyright" ] || { echo "missing copyright: $d" >&2; exit 1; }
    [ -f "$d/changelog.gz" ] || { echo "missing changelog.gz: $d" >&2; exit 1; }
    zcat "$d/changelog.gz" | grep -q "($VER~deb12u1)" || {
      echo "bad version in changelog.gz: $d" >&2; exit 1; }
    zcat "$d/changelog.gz" | grep -q "^ -- " || {
      echo "missing -- trailer in changelog.gz: $d" >&2; exit 1; }
    # trailer date must be RFC 2822; an ISO 8601 stamp makes lintian report
    # syntax-error-in-debian-changelog "badly formatted trailer line".
    zcat "$d/changelog.gz" | grep -qE \
      '^ -- .+ <[^>]+>  [A-Z][a-z][a-z], [0-9][0-9] [A-Z][a-z][a-z] [0-9][0-9][0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9] \+0000$' || {
      echo "changelog trailer is not RFC 2822: $d" >&2; exit 1; }
    grep -qE "^Maintainer: .+ <[^@]+@[^@]+>" "$d/copyright" || {
      echo "missing/invalid Maintainer in copyright: $d" >&2; exit 1; }
    grep -q "UPSTREAM-SENTINEL-$comp" "$d/UPSTREAM-SENTINEL" || {
      echo "upstream sentinel mutated: $d" >&2; exit 1; }
  done

  # triggers/shlibs are CONTROL members now, staged OUTSIDE the data tree.
  for comp in driver-compiler-npu fw-npu level-zero-npu validation-npu; do
    [ ! -e "$STAGE/$comp/triggers" ] || {
      echo "triggers leaked into data tree: $STAGE/$comp/triggers" >&2; exit 1; }
    [ ! -e "$STAGE/$comp/shlibs" ] || {
      echo "shlibs leaked into data tree: $STAGE/$comp/shlibs" >&2; exit 1; }
  done

  # ldconfig triggers: exactly one line, driver-compiler-npu and level-zero-npu only
  for comp in driver-compiler-npu level-zero-npu; do
    t="$STAGE/ncz-npu-meta/$comp/triggers"
    [ -f "$t" ] || { echo "missing triggers: $t" >&2; exit 1; }
    expected="activate-noawait ldconfig"
    actual=$(cat "$t")
    [ "$actual" = "$expected" ] || {
      echo "wrong triggers content: $t (got '$actual')" >&2; exit 1; }
    [ "$(wc -l < "$t")" = "1" ] || { echo "triggers not one line: $t" >&2; exit 1; }
  done
  for comp in fw-npu validation-npu; do
    [ ! -f "$STAGE/ncz-npu-meta/$comp/triggers" ] || {
      echo "unexpected triggers: $STAGE/ncz-npu-meta/$comp/triggers" >&2; exit 1; }
  done

  # shlibs: level-zero-npu only
  shlibs="$STAGE/ncz-npu-meta/level-zero-npu/shlibs"
  [ -f "$shlibs" ] || { echo "missing shlibs: $shlibs" >&2; exit 1; }
  grep -q "^libze_intel_npu " "$shlibs" || {
    echo "bad shlibs content: $shlibs" >&2; exit 1; }
  for comp in driver-compiler-npu fw-npu validation-npu; do
    [ ! -f "$STAGE/ncz-npu-meta/$comp/shlibs" ] || {
      echo "unexpected shlibs: $STAGE/ncz-npu-meta/$comp/shlibs" >&2; exit 1; }
  done

  # The overlay must DECLARE those files on the right components
  printf '%s\n' "$out" | grep -q "ncz-npu-meta/driver-compiler-npu/triggers" || {
    echo "driver-compiler-npu triggers not declared" >&2; exit 1; }
  printf '%s\n' "$out" | grep -q "ncz-npu-meta/level-zero-npu/triggers" || {
    echo "level-zero-npu triggers not declared" >&2; exit 1; }
  printf '%s\n' "$out" | grep -q "ncz-npu-meta/level-zero-npu/shlibs" || {
    echo "level-zero-npu shlibs not declared" >&2; exit 1; }
  [ -z "$(ctrl_of VALIDATION-NPU)" ] || {
    echo "validation-npu should declare no control extra" >&2; exit 1; }

  # fw-npu's upstream postinst must be preserved alongside any overlay additions
  printf '%s\n' "$(ctrl_of FW-NPU)" | grep -q "/upstream/fw-postinst" || {
    echo "fw-npu upstream postinst was dropped" >&2; exit 1; }

  # dpkg-shlibdeps must stay enabled for every component; when CPackDeb sees
  # the flag off it emits a package with no Depends at all and no warning.
  for comp in DRIVER-COMPILER-NPU FW-NPU LEVEL-ZERO-NPU VALIDATION-NPU; do
    v=$(printf '%s\n' "$out" | sed -n "s/^-- T-SHLIBDEPS-$comp=//p")
    [ "$v" = "ON" ] || { echo "shlibdeps not ON for $comp (got '$v')" >&2; exit 1; }
  done

  # Upstream Intel inter-package relations, pinned to the package version.
  lvl_depends=$(printf '%s\n' "$out" | sed -n 's/^-- T-DEPENDS-LEVEL-ZERO-NPU=//p')
  case "$lvl_depends" in
    *"intel-fw-npu (= ${DEB_VER})"*) ;;
    *) echo "level-zero-npu missing intel-fw-npu (= ${DEB_VER}): '$lvl_depends'" >&2; exit 1;;
  esac
  case "$lvl_depends" in
    *"intel-driver-compiler-npu (= ${DEB_VER})"*) ;;
    *) echo "level-zero-npu missing intel-driver-compiler-npu (= ${DEB_VER}): '$lvl_depends'" >&2; exit 1;;
  esac

  val_depends=$(printf '%s\n' "$out" | sed -n 's/^-- T-DEPENDS-VALIDATION-NPU=//p')
  case "$val_depends" in
    *"intel-level-zero-npu (= ${DEB_VER})"*) ;;
    *) echo "validation-npu missing intel-level-zero-npu (= ${DEB_VER}): '$val_depends'" >&2; exit 1;;
  esac

  # driver-compiler-npu and fw-npu carry no NCZ-internal relation.
  for comp in DRIVER-COMPILER-NPU FW-NPU; do
    v=$(printf '%s\n' "$out" | sed -n "s/^-- T-DEPENDS-$comp=//p")
    [ -z "$v" ] || { echo "unexpected $comp Depends: '$v'" >&2; exit 1; }
  done

  echo 'positive: ok'
}

expect_fail() {
  local label="$1"
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

# stale revision: the ~ncz1 packages are exactly the ones that shipped without
# Depends, so the overlay must refuse them instead of silently reproducing the
# broken packages.
make_stage
sed 's/set(CPACK_PACKAGE_VERSION .*/set(CPACK_PACKAGE_VERSION "1.38.0.ncz1")/' \
  "$CMAKEDIR/positive.cmake" > "$CMAKEDIR/negative.cmake"
expect_fail stale-revision

# wrong package name: CPack derives <CPACK_PACKAGE_NAME>-<component>, so a
# different vendor prefix must be rejected.
make_stage
sed 's/set(CPACK_PACKAGE_NAME "intel")/set(CPACK_PACKAGE_NAME "acme")/' \
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
