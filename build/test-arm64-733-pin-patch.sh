#!/bin/bash
# test-arm64-733-pin-patch.sh: the arm64 7.3.3 (r298) pin is carried as a
# ready-to-apply patch, docs/patches/arm64-kernel-733-pin.patch, until the O6N
# boot test passes (docs/O6N-TEST-PLAN-7.3.3.md, docs/ARM64-KERNEL-733-PIN.md).
#
# While it is not applied (CURRENT_KVER_arm64 empty):
#   1. the lifecycle gate refuses arm64 on this tree
#   2. the patch applies to this tree
#   3. with the patch applied, the gate accepts arm64 (7.3.3-sky1-ncz,
#      7.3.3-sky1-ncz+r298) and still accepts amd64
# Once the patch is applied this test only reports SKIP; the promotion commit
# deletes the patch and this test.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
P="$ROOT/docs/patches/arm64-kernel-733-pin.patch"
CHK="$ROOT/build/check-kernel-lifecycle.py"
pass=0; fail=0
ok()  { echo "PASS  $1"; pass=$((pass+1)); }
bad() { echo "FAIL  $1"; fail=$((fail+1)); }

cur=$(sed -n 's/^CURRENT_KVER_arm64=//p' "$ROOT/assets/kernel/KERNEL-LIFECYCLE")
if [ -n "$cur" ]; then
    echo "SKIP: arm64 is already promoted ($cur); delete the pin patch and this test"
    exit 0
fi
[ -f "$P" ] && ok "pin patch present" || { bad "pin patch missing: $P"; echo "=== $pass passed, $fail failed"; exit 1; }

python3 -I "$CHK" --root "$ROOT" --arch arm64 >/dev/null 2>&1 \
    && bad "lifecycle gate accepts arm64 before the boot test" \
    || ok "lifecycle gate refuses arm64 while the pin is unapplied"

git -C "$ROOT" apply --check "$P" 2>/dev/null && ok "pin patch applies to this tree" || bad "pin patch does not apply"

T="$(mktemp -d "${TMPDIR:-/tmp}/test-arm64-pin.XXXXXX")"; trap 'rm -rf "$T"' EXIT
files=(assets/kernel/KERNEL-LIFECYCLE assets/kernel-manifest.json assets/kernel/sky1-manifest.json
       manifests/ncz-packages.tsv assets/kernel/amd64-stable/KVER assets/kernel/amd64-stable/PKGVERSION
       assets/kernel/amd64-stable-manifest.json)
inc=()
for f in "${files[@]}"; do
    [ -f "$ROOT/$f" ] || continue
    mkdir -p "$T/$(dirname "$f")"; cp "$ROOT/$f" "$T/$f"; inc+=("--include=$f")
done
if ( cd "$T" && git apply "${inc[@]}" "$P" ); then
    ok "pin patch applies to the lifecycle inputs"
    out=$(python3 -I "$CHK" --root "$T" --arch arm64 2>&1) \
        && ok "with the patch the gate accepts arm64" || bad "gate refuses the patched arm64 pins: $out"
    grep -qx 'CURRENT_KVER_arm64=7.3.3-sky1-ncz' "$T/assets/kernel/KERNEL-LIFECYCLE" \
        && grep -qx 'CURRENT_PKG_arm64=7.3.3-sky1-ncz+r298' "$T/assets/kernel/KERNEL-LIFECYCLE" \
        && ok "patch promotes 7.3.3-sky1-ncz / 7.3.3-sky1-ncz+r298" || bad "patch does not promote r298"
    out=$(python3 -I "$CHK" --root "$T" --arch amd64 2>&1) \
        && ok "with the patch amd64 is still accepted" || bad "patched tree refuses amd64: $out"
else
    bad "pin patch does not apply to the lifecycle inputs"
fi
echo "=== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
