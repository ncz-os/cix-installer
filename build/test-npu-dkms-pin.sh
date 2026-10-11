#!/bin/bash
# test-npu-dkms-pin.sh -- the vendor cix-npu-driver-dkms +ncz3 deb (aipu 6.2.0) is a checksum-pinned build input.
#
# r201 arm64 (d90ed961): the SDK tarball is unreachable and the deb was copied by hand from the r200 tree, so a
# clean checkout could not build the image. It now lives in the ARGONAS build-inputs store, pinned in
# manifests/build-inputs.tsv, and is staged by build/stage-build-inputs.sh (make image runs it for every row).
#   1. the tsv pins it for arm64 with a real sha256 + size, and for no other arch
#   2. the store holds a file with exactly that sha256 (SKIP loudly if no store is mounted)
#   3. a clean tree + fixture store: the stager stages it; a tampered store copy is refused
#   4. stage-canonical-assets.sh stages it from the store; verify-arm64-inputs.sh's miss message names the stager
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGER="$ROOT/build/stage-build-inputs.sh"
TSV="$ROOT/manifests/build-inputs.tsv"
N="cix-npu-driver-dkms_6.2.0-cixdeb13-260714+ncz3_arm64.deb"
D="assets/cix-debs/$N"
T="$(mktemp -d "${TMPDIR:-/var/tmp}/npu.XXXXXX")"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

row="$(awk -F'\t' -v d="$D" '$2==d' "$TSV")"
sha="$(printf '%s\n' "$row" | awk -F'\t' 'NR==1{print $3}')"; size="$(printf '%s\n' "$row" | awk -F'\t' 'NR==1{print $4}')"
[ "$(printf '%s\n' "$row" | grep -c .)" = 1 ] && printf '%s\n' "$row" | grep -q '^arm64' && printf '%s' "$sha" | grep -Eq '^[0-9a-f]{64}$' && [ "${size:-0}" -gt 1000 ] \
    && ok "build-inputs.tsv pins the NPU DKMS deb for arm64 (sha256 $sha, $size B)" || bad "no valid single arm64 pin for $D"

STORE=""
for d in "${NCZ_BUILD_INPUTS_DIR:-}" /mnt/argonas/datapool/projects/ncz-os-assets/build-inputs /mnt/datapool/projects/ncz-os-assets/build-inputs /mnt/argonas-projects/ncz-os-assets/build-inputs; do
    [ -n "$d" ] && [ -d "$d" ] && { STORE="$d"; break; }
done
if [ -z "$STORE" ]; then echo "SKIP  store check: no ARGONAS build-inputs store mounted on this host (checks 2 NOT run)"
elif [ -f "$STORE/arm64/$D" ] && [ "$(sha256sum "$STORE/arm64/$D" | awk '{print $1}')" = "$sha" ]; then ok "the store holds the pinned file (sha256 matches)"
else bad "store $STORE/arm64/$D missing or differs from the pin"; fi

mkdir -p "$T/store/arm64/assets/cix-debs" "$T/tree"
head -c 4096 /dev/urandom > "$T/store/arm64/$D"
printf 'arm64\t%s\t%s\t4096\tt\n' "$D" "$(sha256sum "$T/store/arm64/$D" | awk '{print $1}')" > "$T/pins.tsv"
run() { NCZ_BUILD_INPUTS_DIR="$T/store" NCZ_BUILD_INPUTS_TSV="$T/pins.tsv" NCZ_BUILD_INPUTS_TREE="$T/tree" bash "$STAGER" --arch arm64 "$@"; }
run >"$T/o1" 2>&1; rc=$?
[ $rc = 0 ] && cmp -s "$T/store/arm64/$D" "$T/tree/$D" && ok "a clean tree gets the deb from the store" || { bad "stager did not stage the NPU deb (rc=$rc)"; cat "$T/o1"; }
rm -rf "$T/tree"; mkdir "$T/tree"; echo x >> "$T/store/arm64/$D"
run >"$T/o2" 2>&1; rc=$?
[ $rc != 0 ] && [ ! -e "$T/tree/$D" ] && ok "a tampered store copy is refused" || { bad "tampered NPU deb accepted (rc=$rc)"; cat "$T/o2"; }

grep -q 'stage-build-inputs.sh" --arch arm64 --only "assets/cix-debs/\$NPU_DKMS_DEB"' "$ROOT/build/stage-canonical-assets.sh" \
    && ok "stage-canonical-assets.sh stages the NPU deb from the pinned store" || bad "stage-canonical-assets.sh does not consume the pin"
# Since every cix-deb is now a pinned build input (2026-10-11), the miss message
# names the stager generically for every cix-deb prefix (not just the NPU one).
grep -q 'cix-debs.prefix' "$ROOT/build/verify-arm64-inputs.sh" \
    && grep -q 'stage-build-inputs.sh --arch arm64' "$ROOT/build/verify-arm64-inputs.sh" \
    && ok "verify-arm64-inputs.sh names the stager in the cix-debs miss message" || bad "verify-arm64-inputs.sh miss message does not name the stager"
grep -q 'stage-build-inputs.sh --arch \$(ARCH)$' "$ROOT/Makefile" && ok "make image runs the stager for every pinned row" || bad "Makefile image rule does not run the stager"

grep -q 'NPU SDK tarball not needed: all SDK-derived debs are already staged' "$ROOT/build/stage-canonical-assets.sh" \
    && grep -q 'elif \[ ! -f "$SRC_NPU_SDK_TGZ" \]' "$ROOT/build/stage-canonical-assets.sh" \
    && ok "stage-canonical-assets.sh: an unreachable SDK is not counted missing (no PARTIAL) once the SDK-derived debs are staged" || bad "stage-canonical-assets.sh still counts the SDK as missing after staging from the store"

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
