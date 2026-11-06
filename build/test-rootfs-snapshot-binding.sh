#!/bin/bash
# test-rootfs-snapshot-binding.sh — M8: a prebuilt rootfs must carry the snapshot it was built at,
# and stage-build-inputs.sh must refuse a row whose snapshot differs from release.conf's pin.
#
# Both directions are exercised:
#   positive: row snapshot == pin  -> check passes
#   negative: row snapshot != pin  -> check fails and names M8
# Fixtures are a temp tree + temp TSV via the script's own override variables, so nothing real moves.
set -u
cd "$(dirname "$0")/.." || exit 1
TMP=$(mktemp -d "${TMPDIR:-/tmp}/m8-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

PIN=$(grep '^NCZ_BASE_MIRROR_SNAPSHOT=' release.conf | head -1 | cut -d= -f2 | tr -d '"')
[ -n "$PIN" ] || { echo "FAIL: no pin in release.conf"; exit 1; }

mkdir -p "$TMP/tree/assets/mgmt" "$TMP/store/amd64/assets/mgmt"
printf 'fixture-rootfs\n' > "$TMP/tree/assets/mgmt/ncz-mgmt-rootfs.tar.zst"
SHA=$(sha256sum "$TMP/tree/assets/mgmt/ncz-mgmt-rootfs.tar.zst" | cut -d' ' -f1)
SIZE=$(stat -c%s "$TMP/tree/assets/mgmt/ncz-mgmt-rootfs.tar.zst")
cp "$TMP/tree/assets/mgmt/ncz-mgmt-rootfs.tar.zst" "$TMP/store/amd64/assets/mgmt/"

pass=0; fail=0
run_case() { # <label> <snapshot> <expect: pass|fail>
  local label=$1 snap=$2 expect=$3
  printf 'amd64\tassets/mgmt/ncz-mgmt-rootfs.tar.zst\t%s\t%s\tfixture\t%s\n' "$SHA" "$SIZE" "$snap" > "$TMP/tsv"
  : > "$TMP/public.tsv"
  out=$(NCZ_BUILD_INPUTS_TSV="$TMP/tsv" NCZ_BUILD_INPUTS_PUBLIC_TSV="$TMP/public.tsv" \
        NCZ_BUILD_INPUTS_TREE="$TMP/tree" NCZ_BUILD_INPUTS_DIR="$TMP/store" \
        bash build/stage-build-inputs.sh --arch amd64 --check 2>&1); rc=$?
  case "$expect" in
    pass) if [ $rc -eq 0 ]; then pass=$((pass+1)); echo "ok   $label"; else fail=$((fail+1)); echo "FAIL $label (expected pass)"; echo "$out" | tail -2; fi ;;
    fail) if [ $rc -ne 0 ] && echo "$out" | grep -q "M8"; then pass=$((pass+1)); echo "ok   $label"; else fail=$((fail+1)); echo "FAIL $label (expected an M8 refusal)"; echo "$out" | tail -3; fi ;;
  esac
}

run_case "row snapshot equals the pin passes"                "$PIN"            pass
run_case "row at 20261018T082309Z under the pin is refused"  "20261018T082309Z" fail
run_case "row with an empty snapshot column is refused"      ""                fail

printf '\n%d passed, %d failed (pin %s)\n' "$pass" "$fail" "$PIN"
[ "$fail" -eq 0 ]
