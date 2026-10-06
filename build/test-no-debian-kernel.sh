#!/bin/bash
# test-no-debian-kernel.sh -- exercise build/verify-no-debian-kernel.sh
# against static fixtures (both directions: a clean 7.3 tree/list must pass,
# every Debian-kernel leak must fail) plus the real repository assets.
#
# Usage: build/test-no-debian-kernel.sh
# Exit 0 = all PASS, 1 = one or more FAIL.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
VERIFIER="$HERE/verify-no-debian-kernel.sh"
FIX="$HERE/fixtures/no-debian-kernel"
[ -x "$VERIFIER" ] || { echo "EXTRACT FAILED: $VERIFIER not executable" >&2; exit 2; }
[ -d "$FIX" ] || { echo "EXTRACT FAILED: fixture dir $FIX missing" >&2; exit 2; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0

# run <label> <expect-exit> [args...]
run() {
    local label="$1" expect="$2"; shift 2
    local out rc
    out="$("$VERIFIER" "$@" 2>&1)"; rc=$?
    if [ "$rc" = "$expect" ]; then
        printf '  PASS  %s (exit=%d)\n' "$label" "$rc"; PASS=$((PASS+1))
    else
        printf '  FAIL  %s (expected exit=%d, got=%d)\n' "$label" "$expect" "$rc"
        printf '%s\n' "$out" | sed 's/^/        /'
        FAIL=$((FAIL+1))
    fi
}

# run_grep <label> <expect-exit> <needle> [args...]
run_grep() {
    local label="$1" expect="$2" needle="$3"; shift 3
    local out rc
    out="$("$VERIFIER" "$@" 2>&1)"; rc=$?
    if [ "$rc" = "$expect" ] && printf '%s\n' "$out" | grep -qF -- "$needle"; then
        printf '  PASS  %s (exit=%d)\n' "$label" "$rc"; PASS=$((PASS+1))
    else
        printf '  FAIL  %s (expected exit=%d + %q, got rc=%d)\n' "$label" "$expect" "$needle" "$rc"
        printf '%s\n' "$out" | sed 's/^/        /'
        FAIL=$((FAIL+1))
    fi
}

# mkclean <root> <kver> <refind-fixture>
mkclean() {
    local r="$1" kver="$2" ref="$3"
    mkdir -p "$r/boot/efi/EFI/BOOT" "$r/lib/modules/$kver"
    printf 'vmlinuz placeholder\n' > "$r/boot/vmlinuz-$kver"
    printf 'initrd placeholder\n'  > "$r/boot/initrd.img-$kver"
    printf 'modules placeholder\n' > "$r/lib/modules/$kver/modules.dep"
    cp "$FIX/$ref" "$r/boot/efi/EFI/BOOT/refind.conf"
}

echo "=== Positive: clean 7.3 trees and listings ==="
R="$T/clean-arm64";  mkclean "$R" "7.3.0-rc6-sky1-ncz" "refind-clean-arm64.conf"
run "arm64: clean 7.3 tree, default Mali (Default)" 0 \
    --root "$R" --arch arm64 --expect-kver 7.3.0-rc6-sky1-ncz
R="$T/clean-amd64";  mkclean "$R" "7.3.0-rc6-1-t2-edge-aerfix" "refind-clean-amd64.conf"
run "amd64: clean 7.3 tree, default Stable (Default)" 0 \
    --root "$R" --arch amd64 --expect-kver 7.3.0-rc6-1-t2-edge-aerfix
run "arm64: clean find listing" 0 \
    --listing "$FIX/find-listing-clean-arm64.txt" --arch arm64 --expect-kver 7.3.0-rc6-sky1-ncz
run "amd64: our staged .deb listing passes" 0 \
    --listing "$FIX/find-listing-ours-amd64.txt" --arch amd64 --expect-kver 7.3.0-rc6-1-t2-edge-aerfix

echo "=== Negative: Debian kernel artifacts and packages ==="
run_grep "arm64: listing with vmlinuz-7.1* / modules-7.1*" 1 "Debian 7.1 boot artifact" \
    --listing "$FIX/find-listing-debian.txt" --arch arm64 --expect-kver 7.3.0-rc6-sky1-ncz
run_grep "dpkg listing: Debian metapackage + versioned 7.1" 1 "Debian default kernel metapackage" \
    --listing "$FIX/dpkg-listing-debian.txt" --arch amd64 --expect-kver 7.3.0-rc6-1-t2-edge-aerfix
run_grep "amd64: Debian versioned package in a path" 1 "non-NCZ kernel package" \
    --listing "$FIX/dpkg-listing-debian.txt" --arch amd64 --expect-kver 7.3.0-rc6-1-t2-edge-aerfix

D="$T/dirty-arm64"
mkdir -p "$D/boot/efi/EFI/BOOT" "$D/lib/modules/7.1.4-arm64"
printf 'vmlinuz\n' > "$D/boot/vmlinuz-7.1.4-arm64"
printf 'mod\n'     > "$D/lib/modules/7.1.4-arm64/modules.dep"
cp "$FIX/refind-debian-default.conf" "$D/boot/efi/EFI/BOOT/refind.conf"
run_grep "arm64: tree containing a 7.1 kernel fails" 1 "Debian 7.1 boot artifact" \
    --root "$D" --arch arm64 --expect-kver 7.3.0-rc6-sky1-ncz

echo "=== Negative: wrong default kernel ==="
W="$T/wrong-default";  mkclean "$W" "7.3.0-rc6-sky1-ncz" "refind-debian-default.conf"
run_grep "arm64: default entry is Debian 7.1" 1 "default entry loads a Debian kernel" \
    --root "$W" --arch arm64 --expect-kver 7.3.0-rc6-sky1-ncz
F="$T/foreign-default"; mkclean "$F" "7.3.0-rc6-sky1-ncz" "refind-foreign-default.conf"
run_grep "arm64: default entry is a foreign kernel" 1 "expected vmlinuz-7.3.0-rc6-sky1-ncz" \
    --root "$F" --arch arm64 --expect-kver 7.3.0-rc6-sky1-ncz
M="$T/missing-default"
mkdir -p "$M/boot" "$M/lib/modules/6.1.0-1-arm64"
printf 'x\n' > "$M/boot/vmlinuz-6.1.0-1-arm64"
run_grep "arm64: no vmlinuz-expected present" 1 "bootable kernels are not the expected" \
    --root "$M" --arch arm64 --expect-kver 7.3.0-rc6-sky1-ncz

echo "=== Negative: usage ==="
run "no input" 2 --arch arm64 --expect-kver 7.3.0-rc6-sky1-ncz
run "missing --root dir" 2 --root /nonexistent-xyz --arch arm64 --expect-kver 7.3.0-rc6-sky1-ncz
run "unsupported arch" 2 --listing "$FIX/find-listing-clean-arm64.txt" --arch riscv64

echo "=== Positive: the real repository assets are clean ==="
run "repo: arm64 asset tree carries no Debian kernel" 0 \
    --root "$REPO/assets/kernel" --arch arm64
run "repo: amd64 asset tree carries no Debian kernel" 0 \
    --root "$REPO/assets/kernel" --arch amd64

echo
echo "=== summary: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" = 0 ]
