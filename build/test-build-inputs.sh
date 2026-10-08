#!/bin/bash
# test-build-inputs.sh -- build/stage-build-inputs.sh and the inputs hooks 25/38 depend on (r201).
#
#  * the pinned store round-trips: publish -> fetch into an empty tree -> check
#  * a store file whose sha256 differs from the pin is REFUSED (nothing staged)
#  * a missing input fails loudly and names the file
#  * manifests/build-inputs.tsv pins the hook-38 recovery rootfs for BOTH arches,
#    every pin is a real sha256, and the Makefile/squashfs builder call the stager
#  * the packages the optional hooks apt-get install are seeded in the offline
#    mirrors (their absence was the rc=100 behind the 13/20/25/38 WARNs)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGER="$ROOT/build/stage-build-inputs.sh"
T="$(mktemp -d "${TMPDIR:-/var/tmp}/bi.XXXXXX")"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

# --- synthetic store/tree/manifest ------------------------------------------------------------
mkdir -p "$T/src/assets/mgmt" "$T/src/assets/python311" "$T/store"
head -c 4096 /dev/urandom > "$T/src/assets/mgmt/ncz-mgmt-rootfs.tar.zst"
head -c 2048 /dev/urandom > "$T/src/assets/python311/uv"
printf '# test pins\namd64\tassets/mgmt/ncz-mgmt-rootfs.tar.zst\t-\t0\tmgmt\namd64\tassets/python311/uv\t-\t0\tuv\narm64\tassets/mgmt/ncz-mgmt-rootfs.tar.zst\t-\t0\tmgmt arm64\n' > "$T/pins.tsv"
run() { NCZ_BUILD_INPUTS_DIR="$T/store" NCZ_BUILD_INPUTS_TSV="$T/pins.tsv" NCZ_BUILD_INPUTS_TREE="$1" bash "$STAGER" "${@:2}"; }

# 1. publish writes the store and rewrites the pins
run "$T/src" --arch amd64 --publish >"$T/o1" 2>&1; rc=$?
sha=$(sha256sum "$T/src/assets/python311/uv" | awk '{print $1}')
if [ $rc = 0 ] && [ -f "$T/store/amd64/assets/mgmt/ncz-mgmt-rootfs.tar.zst" ] && grep -q "$sha" "$T/pins.tsv" \
   && grep -q '^arm64' "$T/pins.tsv" && grep -q '^# test pins' "$T/pins.tsv"; then ok "publish copies to the store and rewrites pins (other arch + comments kept)"
else bad "publish (rc=$rc)"; cat "$T/o1"; fi

# 2. fetch into an empty tree stages both files byte-identically
mkdir -p "$T/dst"
run "$T/dst" --arch amd64 >"$T/o2" 2>&1; rc=$?
if [ $rc = 0 ] && cmp -s "$T/src/assets/mgmt/ncz-mgmt-rootfs.tar.zst" "$T/dst/assets/mgmt/ncz-mgmt-rootfs.tar.zst" \
   && cmp -s "$T/src/assets/python311/uv" "$T/dst/assets/python311/uv" && [ -x "$T/dst/assets/python311/uv" ]; then ok "fetch stages pinned inputs into an empty tree"
else bad "fetch (rc=$rc)"; cat "$T/o2"; fi

# 3. second run is a no-op that still passes, and --check passes
run "$T/dst" --arch amd64 >"$T/o3" 2>&1; rc=$?; run "$T/dst" --arch amd64 --check >"$T/o3b" 2>&1; rc2=$?
if [ $rc = 0 ] && [ $rc2 = 0 ] && grep -q '2 already staged, 0 copied' "$T/o3"; then ok "re-run and --check are clean"; else bad "idempotence (rc=$rc/$rc2)"; cat "$T/o3"; fi

# 4. a tampered store file is refused and nothing is staged
mkdir -p "$T/dst2"
echo tampered >> "$T/store/amd64/assets/mgmt/ncz-mgmt-rootfs.tar.zst"
run "$T/dst2" --arch amd64 >"$T/o4" 2>&1; rc=$?
if [ $rc != 0 ] && grep -q 'wrong sha256' "$T/o4" && [ ! -e "$T/dst2/assets/mgmt/ncz-mgmt-rootfs.tar.zst" ]; then ok "checksum mismatch in the store is refused"
else bad "tampered store file accepted (rc=$rc)"; cat "$T/o4"; fi

# 5. a locally staged file that differs from the pin fails --check
echo x >> "$T/dst/assets/python311/uv"
run "$T/dst" --arch amd64 --check >"$T/o5" 2>&1; rc=$?
if [ $rc != 0 ] && grep -q 'assets/python311/uv sha256 differs' "$T/o5"; then ok "--check flags a locally modified input"; else bad "--check missed a modified input (rc=$rc)"; cat "$T/o5"; fi

# 6. a missing input names itself; an arch with no rows fails
mkdir -p "$T/dst3"; rm -rf "$T/store/arm64"
run "$T/dst3" --arch arm64 >"$T/o6" 2>&1; rc=$?
if [ $rc != 0 ] && grep -q 'MISSING/BAD: assets/mgmt/ncz-mgmt-rootfs.tar.zst not in the store' "$T/o6"; then ok "missing input fails loudly, naming the file"; else bad "missing input (rc=$rc)"; cat "$T/o6"; fi
# 7. no store mounted but everything already staged still passes; unstaged fails
NCZ_BUILD_INPUTS_DIR=/nonexistent/x NCZ_BUILD_INPUTS_TSV="$T/pins.tsv" NCZ_BUILD_INPUTS_TREE="$T/src" bash "$STAGER" --arch amd64 >"$T/o7" 2>&1; rc=$?
if [ $rc = 0 ]; then ok "no store mounted is fine when the tree is already staged"; else bad "already-staged tree rejected without a store (rc=$rc)"; cat "$T/o7"; fi

# --- the real manifest ---------------------------------------------------------------------------
REAL="$ROOT/manifests/build-inputs.tsv"
for a in amd64 arm64; do
    if awk -F'\t' -v a="$a" '$1==a && $2=="assets/mgmt/ncz-mgmt-rootfs.tar.zst" && $3 ~ /^[0-9a-f]{64}$/ && $4+0 > 1000000 {f=1} END{exit !f}' "$REAL"; then
        ok "build-inputs.tsv pins the recovery rootfs for $a (sha256, >1MB)"
    else bad "build-inputs.tsv has no real pin for the $a recovery rootfs"; fi
done
badpins=$(awk -F'\t' '!/^[[:space:]]*(#|$)/ && $3 !~ /^[0-9a-f]{64}$/ {print $1" "$2}' "$REAL")
[ -z "$badpins" ] && ok "every pin in build-inputs.tsv is a sha256" || { bad "unpinned rows: $badpins"; }
grep -q 'stage-build-inputs.sh' "$ROOT/Makefile" && grep -q 'stage-build-inputs.sh' "$ROOT/build/build-squashfs-layers.sh" \
    && ok "Makefile and build-squashfs-layers.sh call the stager" || bad "stager not wired into the build"

# --- hook apt packages are seeded (rc=100 root causes) ---------------------------------------
seeded() { grep -qx "$2" "$ROOT/manifests/$1"; }
for p in systemd-container systemd-coredump; do
    seeded desktop.pkgs "$p" && seeded desktop-amd64.pkgs "$p" && ok "$p seeded for both arches" || bad "$p missing from a desktop seed"
done
seeded desktop.pkgs python3-numpy && ok "python3-numpy seeded for arm64 (25-cix-proprietary NOE_Engine)" || bad "python3-numpy not seeded for arm64"

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
