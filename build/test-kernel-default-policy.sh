#!/bin/bash
# test-kernel-default-policy.sh -- exercise verify-kernel-default-policy.sh
# against synthetic KVER files matching every code path of the unified 7.3
# kernel policy (operator 2026-10-05).
#
# Why a fixture test (and not just a smoke run on the live tree): the policy
# verifier exists to fail closed on misconfigured staging. Every failure mode
# the verifier can detect (a 7.2.x default, a stale rc allowance, manifest
# drift, a dangling symlink, a surviving edge channel, a retired 7.2.x overlay)
# is a path the live repo only exercises at most once a release; bugs in the
# verifier would silently pass on the live repo.
#
# Usage: test-kernel-default-policy.sh
# Exit 0 = all PASS, 1 = one or more FAIL.
set -uo pipefail

VERIFIER="$(cd "$(dirname "$0")" && pwd)/verify-kernel-default-policy.sh"
[ -x "$VERIFIER" ] || { echo "EXTRACT FAILED: $VERIFIER not executable"; exit 2; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

# Canonical unified policy body.
policy_body() {
    cat <<'POL'
DEFAULT_BASE=7.3
RC_DEFAULT_ALLOWED=1
RC_DEFAULT_EXPIRY_NOTE=replace by 7.3.0 final
RESCUE_SAME_KERNEL=1
RESCUE_AMD64_BLACKLIST_T2=nvidia,nvidia_drm,nvidia_modeset,nvidia_uvm,nouveau,radeon
RESCUE_AMD64_BLACKLIST_GENERIC=amdgpu,radeon,nouveau,nvidia,nvidia_drm,nvidia_modeset,nvidia_uvm
RESCUE_ARM64_BLACKLIST=panthor,panfrost,mali_kbase,memory_group_manager,protected_memory_allocator,amvx,aipu,armchina_npu,cix_vpu,linlon_vpu
EDGE_ENABLED=0
POL
}
pin() { policy_body > "$1/assets/kernel/KERNEL-POLICY"; }

# mkroot <root> <mainline-kver> [manifest-mainline-kver]
mkroot() {
    local root="$1" mainline_kver="$2" manifest_mainline="${3:-}"
    mkdir -p "$root/assets/kernel"
    : > "$root/release.conf"
    echo "NCZ_PRODUCT_NAME=ncz-os" >> "$root/release.conf"
    echo "NCZ_TARGET_ARCH=arm64" >> "$root/release.conf"

    if [ "$mainline_kver" = DANGLING ]; then
        ln -sf "/nonexistent/path/mainline" "$root/assets/kernel/mainline"
    elif [ -n "$mainline_kver" ]; then
        mkdir -p "$root/assets/kernel/mainline"
        printf '%s\n' "$mainline_kver" > "$root/assets/kernel/mainline/KVER"
        printf 'fakecontent\n' > "$root/assets/kernel/mainline/Image-cixmini.bin"
        printf 'fakecontent\n' > "$root/assets/kernel/mainline/modules-cixmini.tgz"
        printf '# config for %s\n' "$mainline_kver" > "$root/assets/kernel/mainline/config-$mainline_kver"
        printf 'fakecontent\n' > "$root/assets/kernel/mainline/headers-cixmini.tar.zst"
    fi

    local mver="${manifest_mainline:-$mainline_kver}"
    if [ -n "$mver" ]; then
        cat > "$root/assets/kernel-manifest.json" <<JSON
{
  "schema": 1,
  "variants": {
    "mainline": {
      "dir": "assets/kernel/mainline",
      "kver": "$mver"
    }
  }
}
JSON
    fi
}

# amd64 root: <root> <stable-kver> [manifest-kver]
mkamd64() {
    local root="$1" kver="$2" mver="${3:-$2}"
    mkdir -p "$root/assets/kernel/amd64-stable"
    : > "$root/release.conf"; echo "NCZ_TARGET_ARCH=amd64" >> "$root/release.conf"
    printf '%s\n' "$kver" > "$root/assets/kernel/amd64-stable/KVER"
    cat > "$root/assets/kernel-manifest.json" <<JSON
{"schema":1,"variants":{"mainline":{"dir":"assets/kernel/amd64-stable","kver":"$mver"}}}
JSON
}

# run <label> <expect_exit> [args...]
run() {
    local label="$1" expect="$2"; shift 2
    local got
    SKIP_RESCUE_CHECK=1 "$VERIFIER" "$@" >/dev/null 2>&1
    got=$?
    if [ "$got" = "$expect" ]; then
        printf '  PASS  %s (exit=%d)\n' "$label" "$got"; PASS=$((PASS+1))
    else
        printf '  FAIL  %s (expected exit=%d, got=%d)\n' "$label" "$expect" "$got"; FAIL=$((FAIL+1))
    fi
}

echo "=== Positive: unified 7.3 ship states ==="
r="$WORK/p1"; mkroot "$r" "7.3.0-rc6-sky1-ncz" "7.3.0-rc6-sky1-ncz"; pin "$r"
run "arm64: 7.3.0-rc6 mainline (rc default allowed)" 0 --root "$r" --arch arm64
r="$WORK/p2"; mkroot "$r" "7.3.0-sky1-ncz" "7.3.0-sky1-ncz"
printf 'DEFAULT_BASE=7.3\nRESCUE_SAME_KERNEL=1\nRESCUE_ARM64_BLACKLIST=panthor\nEDGE_ENABLED=0\n' > "$r/assets/kernel/KERNEL-POLICY"
run "arm64: 7.3.0 final mainline (no rc allowance)" 0 --root "$r" --arch arm64
r="$WORK/p3"; mkamd64 "$r" "7.3.0-rc6-3-t2-edge-aer9011" "7.3.0-rc6-3-t2-edge-aer9011"; pin "$r"
run "amd64: 7.3.0-rc6 default" 0 --root "$r" --arch amd64

echo "=== Negative: retired 7.2.x ==="
r="$WORK/n1"; mkroot "$r" "7.2.9-sky1-ncz" "7.2.9-sky1-ncz"
printf 'DEFAULT_BASE=7.3\nRC_DEFAULT_ALLOWED=1\nRC_DEFAULT_EXPIRY_NOTE=replace by 7.3.0 final\nRESCUE_SAME_KERNEL=1\nRESCUE_ARM64_BLACKLIST=panthor\nEDGE_ENABLED=0\n' > "$r/assets/kernel/KERNEL-POLICY"
run "arm64: 7.2.9 default refused" 1 --root "$r" --arch arm64
r="$WORK/n2"; mkamd64 "$r" "7.2.9-2-t2-trixie" "7.2.9-2-t2-trixie"; pin "$r"
run "amd64: 7.2.9 default refused" 1 --root "$r" --arch amd64
r="$WORK/n2b"; mkamd64 "$r" "7.3.0-rc6-1-t2-edge-aerfix" "7.3.0-rc6-1-t2-edge-aerfix"; pin "$r"
run "amd64: retired ambiguous 'aerfix' (9010 revert) pin refused" 1 --root "$r" --arch amd64
r="$WORK/n2c"; mkamd64 "$r" "7.3.0-rc6-2-t2-edge-aerfix" "7.3.0-rc6-2-t2-edge-aerfix"; pin "$r"
run "amd64: retired ambiguous 'aerfix' (rc6-2) pin refused" 1 --root "$r" --arch amd64

echo "=== Negative: rc allowance rules ==="
r="$WORK/n3"; mkroot "$r" "7.3.0-rc6-sky1-ncz" "7.3.0-rc6-sky1-ncz"
printf 'DEFAULT_BASE=7.3\nRC_DEFAULT_ALLOWED=0\nRESCUE_SAME_KERNEL=1\nRESCUE_ARM64_BLACKLIST=panthor\nEDGE_ENABLED=0\n' > "$r/assets/kernel/KERNEL-POLICY"
run "arm64: rc default without allowance refused" 1 --root "$r" --arch arm64
r="$WORK/n4"; mkroot "$r" "7.3.0-sky1-ncz" "7.3.0-sky1-ncz"
printf 'DEFAULT_BASE=7.3\nRC_DEFAULT_ALLOWED=1\nRC_DEFAULT_EXPIRY_NOTE=replace by 7.3.0 final\nRESCUE_SAME_KERNEL=1\nRESCUE_ARM64_BLACKLIST=panthor\nEDGE_ENABLED=0\n' > "$r/assets/kernel/KERNEL-POLICY"
run "arm64: stale rc allowance (final default) refused" 1 --root "$r" --arch arm64

echo "=== Negative: edge channel / retired assets ==="
r="$WORK/n5"; mkroot "$r" "7.3.0-rc6-sky1-ncz" "7.3.0-rc6-sky1-ncz"
printf 'DEFAULT_BASE=7.3\nRC_DEFAULT_ALLOWED=1\nRC_DEFAULT_EXPIRY_NOTE=replace by 7.3.0 final\nRESCUE_SAME_KERNEL=1\nRESCUE_ARM64_BLACKLIST=panthor\nEDGE_ENABLED=1\n' > "$r/assets/kernel/KERNEL-POLICY"
run "arm64: EDGE_ENABLED=1 refused" 1 --root "$r" --arch arm64
r="$WORK/n6"; mkroot "$r" "7.3.0-rc6-sky1-ncz" "7.3.0-rc6-sky1-ncz"; pin "$r"
mkdir -p "$r/assets/kernel/edge"; printf '7.3.0-rc6-sky1-ncz\n' > "$r/assets/kernel/edge/KVER"
run "arm64: assets/kernel/edge still present refused" 1 --root "$r" --arch arm64
r="$WORK/n7"; mkamd64 "$r" "7.3.0-rc6-3-t2-edge-aer9011" "7.3.0-rc6-3-t2-edge-aer9011"; pin "$r"
mkdir -p "$r/assets/kernel/amd64-edge"; printf '7.3.0-rc6-3-t2-edge-aer9011\n' > "$r/assets/kernel/amd64-edge/KVER"
run "amd64: assets/kernel/amd64-edge still present refused" 1 --root "$r" --arch amd64
r="$WORK/n8"; mkroot "$r" "7.3.0-rc6-sky1-ncz" "7.3.0-rc6-sky1-ncz"; pin "$r"
mkdir -p "$r/assets/kernel/mali/7.2.9-sky1-ncz"; printf 'x\n' > "$r/assets/kernel/mali/7.2.9-sky1-ncz/mali_kbase.ko"
run "arm64: retired 7.2.9 overlay mirror refused" 1 --root "$r" --arch arm64

echo "=== Negative: manifest drift / dangling / missing payload ==="
r="$WORK/n9"; mkroot "$r" "7.3.0-rc6-sky1-ncz" "7.3.0-rc5-sky1-ncz"; pin "$r"
run "arm64: manifest drift refused" 1 --root "$r" --arch arm64
r="$WORK/n10"; mkroot "$r" "DANGLING"
run "arm64: dangling mainline symlink refused" 1 --root "$r" --arch arm64
r="$WORK/n11"; mkroot "$r" "7.3.0-rc6-sky1-ncz" "7.3.0-rc6-sky1-ncz"; pin "$r"
rm -f "$r/assets/kernel/mainline/Image-cixmini.bin"
run "arm64: mainline payload incomplete refused" 1 --root "$r" --arch arm64

echo "=== Negative: missing manifest / misuse ==="
r="$WORK/n12"; mkdir -p "$r/assets/kernel/mainline"; : > "$r/release.conf"; echo "NCZ_TARGET_ARCH=arm64" >> "$r/release.conf"
printf '7.3.0-rc6-sky1-ncz\n' > "$r/assets/kernel/mainline/KVER"
run "arm64: manifest missing refused" 1 --root "$r" --arch arm64
"$VERIFIER" --root /this/path/does/not/exist 2>/dev/null; got=$?
[ "$got" = 2 ] && { printf '  PASS  missing --root (exit=2 misuse)\n'; PASS=$((PASS+1)); } || { printf '  FAIL  missing --root (got=%d)\n' "$got"; FAIL=$((FAIL+1)); }
"$VERIFIER" --root "$WORK/n1" --arch riscv64 2>/dev/null; got=$?
[ "$got" = 2 ] && { printf '  PASS  unsupported --arch (exit=2 misuse)\n'; PASS=$((PASS+1)); } || { printf '  FAIL  unsupported --arch (got=%d)\n' "$got"; FAIL=$((FAIL+1)); }

echo "=== Positive: offline fallback -- local sibling tree matches manifest ==="
r="$WORK/offline-ok"
mkdir -p "$r/assets/kernel/r284-7.3.0-rc6-sky1-ncz-20261006"
printf '7.3.0-rc6-sky1-ncz\n' > "$r/assets/kernel/r284-7.3.0-rc6-sky1-ncz-20261006/KVER"
printf 'fake\n' > "$r/assets/kernel/r284-7.3.0-rc6-sky1-ncz-20261006/Image-cixmini.bin"
printf 'fake\n' > "$r/assets/kernel/r284-7.3.0-rc6-sky1-ncz-20261006/modules-cixmini.tgz"
printf 'cfg\n' > "$r/assets/kernel/r284-7.3.0-rc6-sky1-ncz-20261006/config-7.3.0-rc6-sky1-ncz"
printf 'fake\n' > "$r/assets/kernel/r284-7.3.0-rc6-sky1-ncz-20261006/headers-cixmini.tar.zst"
ln -s "/nonexistent/pool/r284-7.3.0-rc6-sky1-ncz-20261006" "$r/assets/kernel/mainline"
cat > "$r/assets/kernel-manifest.json" <<'JSON'
{"schema":1,"variants":{"mainline":{"dir":"assets/kernel/mainline","kver":"7.3.0-rc6-sky1-ncz"}}}
JSON
: > "$r/release.conf"; echo "NCZ_TARGET_ARCH=arm64" >> "$r/release.conf"
pin "$r"
out=$(SKIP_RESCUE_CHECK=1 "$VERIFIER" --root "$r" --arch arm64 2>&1); got=$?
if [ "$got" = 0 ] && printf '%s' "$out" | grep -q "using it (build farm uses the pool-mounted symlink)"; then
    printf '  PASS  arm64: offline fallback finds local sibling tree\n'; PASS=$((PASS+1))
else
    printf '  FAIL  arm64: offline fallback (exit=%d)\n%s\n' "$got" "$out"; FAIL=$((FAIL+1))
fi

echo "=== Positive: rescue entry preservation + accelerator-blacklist markers (real repo) ==="
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
rescue_check() {
    local out
    out="$("$VERIFIER" --root "$REPO_ROOT" --arch "$1" 2>&1 || true)"
    if printf '%s\n' "$out" | grep -q 'rescue preservation: both arches keep' \
        && ! printf '%s\n' "$out" | grep -q 'FAIL: rescue preservation'; then
        printf '  PASS  %s: real repo preserves the rescue markers\n' "$1"; PASS=$((PASS+1))
    else
        printf '  FAIL  %s: real repo lost its rescue-preservation markers\n' "$1"; FAIL=$((FAIL+1))
    fi
}
rescue_check arm64
rescue_check amd64
# Regression guard: a copy without *-rescue and without the new markers MUST fail.
_regression=$(mktemp -d)
mkdir -p "$_regression/root-fake/assets/kernel/mainline" "$_regression/root-fake/assets/refind"
: > "$_regression/root-fake/release.conf"; echo "NCZ_TARGET_ARCH=arm64" >> "$_regression/root-fake/release.conf"
cp -a "$REPO_ROOT/assets/refind/ncz-refind-refresh.sh" "$_regression/root-fake/assets/refind/ncz-refind-refresh.sh"
cp -a "$REPO_ROOT/assets/refind/ncz-refind-refresh-amd64.sh" "$_regression/root-fake/assets/refind/ncz-refind-refresh-amd64.sh"
perl -pi -e 's/\*-rescue/NO-RESCUE/g; s/NCZ-RESCUE-ACCEL-BEGIN/NCZ-RESCUE-ACCEL-GONE/g' \
    "$_regression/root-fake/assets/refind/ncz-refind-refresh.sh"
printf '7.3.0-rc6-sky1-ncz\n' > "$_regression/root-fake/assets/kernel/mainline/KVER"
printf 'fakecontent\n' > "$_regression/root-fake/assets/kernel/mainline/Image-cixmini.bin"
printf 'fakecontent\n' > "$_regression/root-fake/assets/kernel/mainline/modules-cixmini.tgz"
printf 'fake\n' > "$_regression/root-fake/assets/kernel/mainline/config-7.3.0-rc6-sky1-ncz"
printf 'fake\n' > "$_regression/root-fake/assets/kernel/mainline/headers-cixmini.tar.zst"
cat > "$_regression/root-fake/assets/kernel-manifest.json" <<'JSON'
{"schema":1,"variants":{"mainline":{"dir":"assets/kernel/mainline","kver":"7.3.0-rc6-sky1-ncz"}}}
JSON
if "$VERIFIER" --root "$_regression/root-fake" --arch arm64 >/dev/null 2>&1; then
    printf '  FAIL  arm64: rescue marker deletion not detected\n'; FAIL=$((FAIL+1))
else
    printf '  PASS  arm64: rescue marker deletion detected (exit=1)\n'; PASS=$((PASS+1))
fi
rm -rf "$_regression"

echo
echo "=== summary: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" = 0 ]
