#!/bin/bash
# test-kernel-default-policy.sh -- exercise verify-kernel-default-policy.sh
# against synthetic KVER files matching every code path.
#
# Why a fixture test (and not just a smoke run on the live tree): the
# policy verifier exists to fail closed on misconfigured staging. Every
# failure mode the verifier can detect (rc on mainline, edge==mainline,
# missing manifest, dangling symlink, missing required file, amd64-edge
# present, etc.) is a path the live repo only exercises at most once a
# release; bugs in the verifier would silently pass on the live repo.
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

# Helper: synthesise a minimal ROOT tree with the given mainline/edge KVERs.
#   mkroot <root> <mainline-kver> [edge-kver] [manifest-mainline-kver]
# When <root>/assets/kernel/mainline is a real directory, the files in it
# are the requested KVER's filename. Symlinks to a non-existent path can
# be exercised by passing mainline-kver=DANGLING.
mkroot() {
    local root="$1" mainline_kver="$2" edge_kver="${3:-}" manifest_mainline="${4:-}"
    mkdir -p "$root/assets/kernel" 2>/dev/null || true
    # release.conf is a regular FILE. The verifier reads NCZ_TARGET_ARCH
    # from it; the test supplies it to pin ARCH for the run.
    : > "$root/release.conf"
    echo "NCZ_PRODUCT_NAME=ncz-os" >> "$root/release.conf"
    echo "NCZ_TARGET_ARCH=arm64" >> "$root/release.conf"

    if [ "$mainline_kver" = DANGLING ]; then
        ln -sf "/nonexistent/path/mainline" "$root/assets/kernel/mainline"
    elif [ -n "$mainline_kver" ]; then
        mkdir -p "$root/assets/kernel/mainline"
        printf '%s\n' "$mainline_kver" > "$root/assets/kernel/mainline/KVER"
        # Required payload files. 'fakecontent' instead of `: >` so -s sees
        # non-zero size; :> creates 0-byte files which the verifier (rightly)
        # treats as missing/empty.
        printf 'fakecontent\n' > "$root/assets/kernel/mainline/Image-cixmini.bin"
        printf 'fakecontent\n' > "$root/assets/kernel/mainline/modules-cixmini.tgz"
        printf '# config for %s\n' "$mainline_kver" > "$root/assets/kernel/mainline/config-$mainline_kver"
        printf 'fakecontent\n' > "$root/assets/kernel/mainline/headers-cixmini.tar.zst"
    fi

    case "$edge_kver" in
        "") ;;
        DANGLING) ln -sf "/nonexistent/path/edge" "$root/assets/kernel/edge" ;;
        *)
            mkdir -p "$root/assets/kernel/edge"
            printf '%s\n' "$edge_kver" > "$root/assets/kernel/edge/KVER"
            printf 'fakecontent\n' > "$root/assets/kernel/edge/Image-cixmini.bin"
            printf 'fakecontent\n' > "$root/assets/kernel/edge/modules-cixmini.tgz"
            printf '# config for %s\n' "$edge_kver" > "$root/assets/kernel/edge/config-$edge_kver"
            printf 'fakecontent\n' > "$root/assets/kernel/edge/headers-cixmini.tar.zst"
            ;;
    esac

    # Manifest with the requested mainline kver.
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

# run <label> <expect_exit> [args...]
run() {
    local label="$1" expect="$2"; shift 2
    local got
    # Fixture tests build a synthetic asset tree without the rEFInd refresh
    # scripts on purpose; the rescue-preservation check is exercised against
    # the real repo only (see test_rescue_preservation below).
    SKIP_RESCUE_CHECK=1 "$VERIFIER" "$@" >/dev/null 2>&1
    got=$?
    if [ "$got" = "$expect" ]; then
        printf '  PASS  %s (exit=%d)\n' "$label" "$got"
        PASS=$((PASS+1))
    else
        printf '  FAIL  %s (expected exit=%d, got=%d)\n' "$label" "$expect" "$got"
        FAIL=$((FAIL+1))
    fi
}

echo "=== Positive: shipping configuration ==="
# arm64 ship state: mainline=KVER+release, edge=KVER+rc, manifest agrees.
r="$WORK/p1" ; mkroot "$r" "7.2.8-sky1-ncz" "7.3.0-rc5-sky1-ncz" "7.2.8-sky1-ncz"
run "arm64: 7.2.8 mainline + 7.3-rc5 edge (ship state)" 0 --root "$r" --arch arm64
# amd64 ship state: stable=7.2.8, NO edge channel.
r="$WORK/p2"
mkdir -p "$r/assets/kernel/amd64-stable"
: > "$r/release.conf"
echo "NCZ_TARGET_ARCH=amd64" >> "$r/release.conf"
printf '7.2.8-1-t2-trixie\n' > "$r/assets/kernel/amd64-stable/KVER"
cat > "$r/assets/kernel-manifest.json" <<'JSON'
{"schema":1,"variants":{"mainline":{"dir":"assets/kernel/amd64-stable","kver":"7.2.8-1-t2-trixie"}}}
JSON
# mkroot's arm64-only `assets/kernel/mainline` will be missing -> the
# verifier should NOT use it (amd64 reads amd64-stable). The manifest
# mainline.kver is still what the verifier cross-checks against; the
# mainline payload check is arm64-only via the per-arch branch below.
run "amd64: 7.2.8 stable only" 0 --root "$r" --arch amd64

echo "=== Positive: minimal arm64 (no edge) ==="
r="$WORK/p3" ; mkroot "$r" "7.2.8-sky1-ncz" "" "7.2.8-sky1-ncz"
run "arm64: 7.2.8 mainline, no edge channel" 0 --root "$r" --arch arm64

echo "=== Negative: 7.3-rc5 as DEFAULT (the .66 incident) ==="
r="$WORK/n1" ; mkroot "$r" "7.3.0-rc5-sky1-ncz" "7.3.0-rc5-sky1-ncz" "7.3.0-rc5-sky1-ncz"
run "arm64: mainline is -rc (rejected)" 1 --root "$r" --arch arm64

echo "=== Negative: edge KVER == mainline KVER (copy-paste symlink error) ==="
r="$WORK/n2" ; mkroot "$r" "7.2.8-sky1-ncz" "7.2.8-sky1-ncz" "7.2.8-sky1-ncz"
run "arm64: edge KVER equals mainline KVER" 1 --root "$r" --arch arm64

echo "=== Negative: edge is a release version (warn-only, still passes) ==="
r="$WORK/n3" ; mkroot "$r" "7.2.8-sky1-ncz" "7.2.7-sky1-ncz" "7.2.8-sky1-ncz"
# Expect exit 0 (warn only). Capture stderr to verify WARN present.
out=$(SKIP_RESCUE_CHECK=1 "$VERIFIER" --root "$r" --arch arm64 2>&1)
got=$?
case "$got" in
    0) if printf '%s' "$out" | grep -q 'WARN: edge KVER.*release version'; then
            printf '  PASS  arm64: edge as release (warn-only)\n'; PASS=$((PASS+1))
        else
            printf '  FAIL  arm64: edge as release -- expected WARN, got none\n'; FAIL=$((FAIL+1))
        fi ;;
    *) printf '  FAIL  arm64: edge as release (expected exit=0, got=%d)\n' "$got"; FAIL=$((FAIL+1)) ;;
esac

echo "=== Negative: missing mainline KVER file ==="
r="$WORK/n4"
mkdir -p "$r/assets/kernel/mainline" 2>/dev/null || true
: > "$r/release.conf"
echo "NCZ_TARGET_ARCH=arm64" >> "$r/release.conf"
cat > "$r/assets/kernel-manifest.json" <<'JSON'
{"schema":1,"variants":{"mainline":{"dir":"assets/kernel/mainline","kver":"7.2.8-sky1-ncz"}}}
JSON
run "arm64: empty mainline/KVER" 1 --root "$r" --arch arm64

echo "=== Negative: missing manifest ==="
r="$WORK/n5"
mkdir -p "$r/assets/kernel/mainline" 2>/dev/null || true
: > "$r/release.conf"
echo "NCZ_TARGET_ARCH=arm64" >> "$r/release.conf"
printf '7.2.8-sky1-ncz\n' > "$r/assets/kernel/mainline/KVER"
: > "$r/assets/kernel/mainline/Image-cixmini.bin"
: > "$r/assets/kernel/mainline/modules-cixmini.tgz"
: > "$r/assets/kernel/mainline/config-7.2.8-sky1-ncz"
: > "$r/assets/kernel/mainline/headers-cixmini.tar.zst"
run "arm64: manifest missing" 1 --root "$r" --arch arm64

echo "=== Negative: manifest drift (mainline 7.2.7 vs KVER 7.2.8) ==="
r="$WORK/n6" ; mkroot "$r" "7.2.8-sky1-ncz" "" "7.2.7-sky1-ncz"
run "arm64: manifest drift" 1 --root "$r" --arch arm64

echo "=== Negative: dangling symlink ==="
r="$WORK/n7" ; mkroot "$r" "DANGLING"
run "arm64: dangling mainline symlink" 1 --root "$r" --arch arm64

echo "=== Negative: amd64 ships edge (policy violation) ==="
r="$WORK/n8" ; mkroot "$r" "7.2.8-1-t2-trixie"
# Now add an amd64-edge KVER (mkroot only does mainline/edge for arm64)
mkdir -p "$r/assets/kernel/amd64-edge"
printf '7.3.0-rc5-1-t2-trixie\n' > "$r/assets/kernel/amd64-edge/KVER"
run "amd64: amd64-edge exists" 1 --root "$r" --arch amd64

echo "=== Negative: amd64 stable is rc (policy violation) ==="
r="$WORK/n9"
mkdir -p "$r/assets/kernel"
: > "$r/release.conf"
echo "NCZ_TARGET_ARCH=amd64" >> "$r/release.conf"
mkdir -p "$r/assets/kernel/amd64-stable"
printf '7.3.0-rc5-1-t2-trixie\n' > "$r/assets/kernel/amd64-stable/KVER"
cat > "$r/assets/kernel-manifest.json" <<'JSON'
{"schema":1,"variants":{"mainline":{"dir":"assets/kernel/amd64-stable","kver":"7.3.0-rc5-1-t2-trixie"}}}
JSON
run "amd64: stable KVER is -rc" 1 --root "$r" --arch amd64

echo "=== Negative: amd64 classifier hook still classifies rc as edge (regression) ==="
# Builds an amd64 tree that satisfies the kernel payload checks but the
# classifier hook has been rolled back to the pre-directive shape
# (rc5 promoted to edge). The verifier refuses this so the regression
# can't ship.
r="$WORK/n9b"
mkdir -p "$r/assets/kernel"
: > "$r/release.conf"
echo "NCZ_TARGET_ARCH=amd64" >> "$r/release.conf"
mkdir -p "$r/assets/kernel/amd64-stable"
printf '7.2.8-1-t2-trixie\n' > "$r/assets/kernel/amd64-stable/KVER"
cat > "$r/assets/kernel-manifest.json" <<'JSON'
{"schema":1,"variants":{"mainline":{"dir":"assets/kernel/amd64-stable","kver":"7.2.8-1-t2-trixie"}}}
JSON
# Classifier hook WITHOUT the directive marker (old shape, asserts rc -> edge)
mkdir -p "$r/assets/refind"
cat > "$r/assets/refind/zz1-ncz-refind-refresh-amd64" <<'SHIM'
classify() {
    case "$1" in
        *-t2-trixie*) if is_prerelease "$1"; then echo edge; else echo stable; fi ;;
    esac
}
SHIM
run "amd64: classifier hook rolled back (no directive marker)" 1 --root "$r" --arch amd64

echo "=== Negative: amd64 refresh script doesn't refuse KVER_EDGE (regression) ==="
# Same shape but the refresh script is the pre-directive version
# (writes an edge entry when KVER_EDGE is set).
r="$WORK/n9c"
mkdir -p "$r/assets/kernel"
: > "$r/release.conf"
echo "NCZ_TARGET_ARCH=amd64" >> "$r/release.conf"
mkdir -p "$r/assets/kernel/amd64-stable"
printf '7.2.8-1-t2-trixie\n' > "$r/assets/kernel/amd64-stable/KVER"
cat > "$r/assets/kernel-manifest.json" <<'JSON'
{"schema":1,"variants":{"mainline":{"dir":"assets/kernel/amd64-stable","kver":"7.2.8-1-t2-trixie"}}}
JSON
mkdir -p "$r/assets/refind"
cat > "$r/assets/refind/zz1-ncz-refind-refresh-amd64" <<'SHIM'
classify() { return; }
SHIM
# Pre-directive refresh script -- no KVER_EDGE refuse-to-write block.
cat > "$r/assets/refind/ncz-refind-refresh-amd64.sh" <<'SHIM'
#!/bin/bash
echo "KVER_STABLE=$KVER_STABLE KVER_EDGE=$KVER_EDGE"
SHIM
run "amd64: refresh script rolled back (no KVER_EDGE refuse)" 1 --root "$r" --arch amd64

echo "=== Positive: amd64 runtime pipeline honours the directive ==="
r="$WORK/p9"
mkdir -p "$r/assets/kernel"
: > "$r/release.conf"
echo "NCZ_TARGET_ARCH=amd64" >> "$r/release.conf"
mkdir -p "$r/assets/kernel/amd64-stable"
printf '7.2.8-1-t2-trixie\n' > "$r/assets/kernel/amd64-stable/KVER"
cat > "$r/assets/kernel-manifest.json" <<'JSON'
{"schema":1,"variants":{"mainline":{"dir":"assets/kernel/amd64-stable","kver":"7.2.8-1-t2-trixie"}}}
JSON
mkdir -p "$r/assets/refind"
cat > "$r/assets/refind/zz1-ncz-refind-refresh-amd64" <<'SHIM'
# amd64 never ships edge (directive 2026-09-30)
classify() { return; }
SHIM
cat > "$r/assets/refind/ncz-refind-refresh-amd64.sh" <<'SHIM'
#!/bin/bash
# KVER_EDGE ignored -- amd64 has no validated 7.3 kernel (operator directive 2026-09-30)
echo "ok"
SHIM
run "amd64: runtime pipeline honours directive" 0 --root "$r" --arch amd64

echo "=== Negative: mainline missing required payload file (Image) ==="
r="$WORK/n10" ; mkroot "$r" "7.2.8-sky1-ncz" "" "7.2.8-sky1-ncz"
# Wipe Image-cixmini.bin
rm -f "$r/assets/kernel/mainline/Image-cixmini.bin"
run "arm64: mainline payload incomplete (Image missing)" 1 --root "$r" --arch arm64

echo "=== Negative: ARCH unset and not inferable ==="
r="$WORK/n11"
mkdir -p "$r"  # bare minimum: no release.conf, no /etc, no dpkg
# `which dpkg` is intentionally not disabled here -- on a build host the
# verifier WILL infer ARCH from dpkg, and on this host ARCH=amd64. The
# bare-repo case is "no kernel manifest, no mainline payload", which is
# a policy failure (exit 1), not a usage error. Document both possibilities.
"$VERIFIER" --root "$r" 2>/dev/null
got=$?
case "$got" in
    1|2)
        if [ "$got" = 2 ] && [ ! -s "$r/release.conf" ] && ! command -v dpkg >/dev/null 2>&1; then
            printf '  PASS  bare repo with no ARCH inferable (exit=2 misuse)\n'; PASS=$((PASS+1))
        elif [ "$got" = 1 ]; then
            printf '  PASS  bare repo with inferred ARCH (exit=1 policy fail)\n'; PASS=$((PASS+1))
        else
            printf '  FAIL  bare repo (exit=%d -- neither expected variant)\n' "$got"; FAIL=$((FAIL+1))
        fi
        ;;
    *) printf '  FAIL  bare repo (expected exit=1 or 2, got=%d)\n' "$got"; FAIL=$((FAIL+1)) ;;
esac

echo "=== Negative: --root not a directory (misuse) ==="
"$VERIFIER" --root /this/path/does/not/exist 2>/dev/null
got=$?
case "$got" in
    2) printf '  PASS  missing --root (exit=2 misuse)\n'; PASS=$((PASS+1)) ;;
    *) printf '  FAIL  missing --root (expected exit=2, got=%d)\n' "$got"; FAIL=$((FAIL+1)) ;;
esac

echo "=== Negative: unsupported --arch value ==="
r="$WORK/p2"
"$VERIFIER" --root "$r" --arch riscv64 2>/dev/null
got=$?
case "$got" in
    2) printf '  PASS  unsupported --arch (exit=2 misuse)\n'; PASS=$((PASS+1)) ;;
    *) printf '  FAIL  unsupported --arch (expected exit=2, got=%d)\n' "$got"; FAIL=$((FAIL+1)) ;;
esac

echo "=== Positive: offline fallback -- local sibling tree matches manifest ==="
# Symlinks at assets/kernel/{mainline,edge} are DANGLING (point to a path
# that does not exist on this build host, e.g. because the kernel-staging
# pool is not NFS-mounted). The verifier must fall back to the matching
# tree vendored in assets/kernel/r*/ and PASS with WARNs.
r="$WORK/offline-ok"
mkdir -p "$r/assets/kernel/r277-7.2.8-sky1-ncz-20260927"
printf '7.2.8-sky1-ncz\n' > "$r/assets/kernel/r277-7.2.8-sky1-ncz-20260927/KVER"
printf 'fake\n' > "$r/assets/kernel/r277-7.2.8-sky1-ncz-20260927/Image-cixmini.bin"
printf 'fake\n' > "$r/assets/kernel/r277-7.2.8-sky1-ncz-20260927/modules-cixmini.tgz"
printf 'cfg\n' > "$r/assets/kernel/r277-7.2.8-sky1-ncz-20260927/config-7.2.8-sky1-ncz"
printf 'fake\n' > "$r/assets/kernel/r277-7.2.8-sky1-ncz-20260927/headers-cixmini.tar.zst"
mkdir -p "$r/assets/kernel/r273-7.3.0-rc4-sky1-ncz-20260920"
printf '7.3.0-rc4-sky1-ncz\n' > "$r/assets/kernel/r273-7.3.0-rc4-sky1-ncz-20260920/KVER"
printf 'fake\n' > "$r/assets/kernel/r273-7.3.0-rc4-sky1-ncz-20260920/Image-cixmini.bin"
printf 'fake\n' > "$r/assets/kernel/r273-7.3.0-rc4-sky1-ncz-20260920/modules-cixmini.tgz"
printf 'cfg\n' > "$r/assets/kernel/r273-7.3.0-rc4-sky1-ncz-20260920/config-7.3.0-rc4-sky1-ncz"
printf 'fake\n' > "$r/assets/kernel/r273-7.3.0-rc4-sky1-ncz-20260920/headers-7.3.0-rc4-sky1-ncz.tar.zst"
# Dangling symlinks (the committed state when the staging pool is unmounted)
ln -s "/nonexistent/pool/r277-7.2.8-sky1-ncz-20260927" "$r/assets/kernel/mainline"
ln -s "/nonexistent/pool/r273-7.3.0-rc4-sky1-ncz-20260920" "$r/assets/kernel/edge"
cat > "$r/assets/kernel-manifest.json" <<'JSON'
{"schema":1,"variants":{"mainline":{"dir":"assets/kernel/mainline","kver":"7.2.8-sky1-ncz"}}}
JSON
: > "$r/release.conf"
echo "NCZ_TARGET_ARCH=arm64" >> "$r/release.conf"
out=$(SKIP_RESCUE_CHECK=1 "$VERIFIER" --root "$r" --arch arm64 2>&1); got=$?
case "$got" in
    0)
        if echo "$out" | grep -q "using it (build farm uses the pool-mounted symlink)"; then
            printf '  PASS  arm64: offline fallback finds local sibling tree (exit=0)\n'; PASS=$((PASS+1))
        else
            printf '  FAIL  arm64: offline fallback passed but did not log the fallback WARN\n'; FAIL=$((FAIL+1))
        fi
        ;;
    *) printf '  FAIL  arm64: offline fallback (expected exit=0, got=%d)\n%s\n' "$got" "$out"; FAIL=$((FAIL+1)) ;;
esac

echo "=== Negative: offline fallback -- no sibling matches the manifest ==="
# Symlinks are dangling AND no local r*/ tree matches the manifest's
# variants.mainline.kver. Verifier must FAIL with the canonical message.
r="$WORK/offline-miss"
mkdir -p "$r/assets/kernel/r999-7.1.0-sky1-ncz-20260101"
printf '7.1.0-sky1-ncz\n' > "$r/assets/kernel/r999-7.1.0-sky1-ncz-20260101/KVER"
printf 'fake\n' > "$r/assets/kernel/r999-7.1.0-sky1-ncz-20260101/Image-cixmini.bin"
printf 'fake\n' > "$r/assets/kernel/r999-7.1.0-sky1-ncz-20260101/modules-cixmini.tgz"
printf 'cfg\n' > "$r/assets/kernel/r999-7.1.0-sky1-ncz-20260101/config-7.1.0-sky1-ncz"
printf 'fake\n' > "$r/assets/kernel/r999-7.1.0-sky1-ncz-20260101/headers-cixmini.tar.zst"
ln -s "/nonexistent/pool/r277-7.2.8-sky1-ncz-20260927" "$r/assets/kernel/mainline"
cat > "$r/assets/kernel-manifest.json" <<'JSON'
{"schema":1,"variants":{"mainline":{"dir":"assets/kernel/mainline","kver":"7.2.8-sky1-ncz"}}}
JSON
: > "$r/release.conf"
echo "NCZ_TARGET_ARCH=arm64" >> "$r/release.conf"
out=$(SKIP_RESCUE_CHECK=1 "$VERIFIER" --root "$r" --arch arm64 2>&1); got=$?
case "$got" in
    1)
        if echo "$out" | grep -q "Mount the kernel-staging pool or repoint the symlink"; then
            printf '  PASS  arm64: dangling symlink, no matching sibling (exit=1, canonical message)\n'; PASS=$((PASS+1))
        else
            printf '  FAIL  arm64: dangling symlink, no sibling -- wrong error message\n%s\n' "$out"; FAIL=$((FAIL+1))
        fi
        ;;
    *) printf '  FAIL  arm64: dangling symlink, no sibling (expected exit=1, got=%d)\n%s\n' "$got" "$out"; FAIL=$((FAIL+1)) ;;
esac

echo "=== Positive: payload filename variant -- per-KVER headers ==="
# The edge tree uses headers-<kver>.tar.zst (newer convention) rather than
# headers-cixmini.tar.zst (legacy). Verifier must accept either name.
r="$WORK/p10" ; mkroot "$r" "7.2.8-sky1-ncz" "7.3.0-rc5-sky1-ncz" "7.2.8-sky1-ncz"
mv "$r/assets/kernel/edge/headers-cixmini.tar.zst" "$r/assets/kernel/edge/headers-7.3.0-rc5-sky1-ncz.tar.zst"
run "arm64: edge payload with per-KVER headers filename" 0 --root "$r" --arch arm64

echo
echo "=== Positive: rescue entry preservation (real repo, no SKIP) ==="
# The rescue-preservation check runs against the REAL rEFInd refresh
# scripts (it deliberately skips synthetic fixtures because they don't
# carry these scripts). Run the verifier without SKIP_RESCUE_CHECK
# against the repo root and assert it passes for both arches; then
# prove the check catches a deleted rescue-marker by running against
# a temporary copy with the *-rescue sparing stripped out.
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if "$VERIFIER" --root "$REPO_ROOT" --arch arm64 >/dev/null 2>&1; then
    printf '  PASS  arm64: real repo preserves rescue markers (exit=0)\n'; PASS=$((PASS+1))
else
    printf '  FAIL  arm64: real repo lost its rescue-preservation markers\n'; FAIL=$((FAIL+1))
fi
if "$VERIFIER" --root "$REPO_ROOT" --arch amd64 >/dev/null 2>&1; then
    printf '  PASS  amd64: real repo preserves rescue markers (exit=0)\n'; PASS=$((PASS+1))
else
    printf '  FAIL  amd64: real repo lost its rescue-preservation markers\n'; FAIL=$((FAIL+1))
fi
# Regression guard: a copy of the refresh script with the *-rescue
# sparing stripped out MUST be flagged.
_regression=$(mktemp -d)
cp -a "$REPO_ROOT/assets/refind/ncz-refind-refresh.sh" "$_regression/ncz-refind-refresh.sh"
cp -a "$REPO_ROOT/assets/refind/ncz-refind-refresh-amd64.sh" "$_regression/ncz-refind-refresh-amd64.sh"
sed -i 's|\*-rescue|NO-RESCUE|g' "$_regression/ncz-refind-refresh.sh"
mkdir -p "$_regression/root-fake/assets/kernel/mainline"
: > "$_regression/root-fake/release.conf"
echo "NCZ_TARGET_ARCH=arm64" >> "$_regression/root-fake/release.conf"
mkdir -p "$_regression/root-fake/assets/refind"
cp "$_regression/ncz-refind-refresh.sh" "$_regression/root-fake/assets/refind/ncz-refind-refresh.sh"
cp "$_regression/ncz-refind-refresh-amd64.sh" "$_regression/root-fake/assets/refind/ncz-refind-refresh-amd64.sh"
printf '7.2.8-sky1-ncz\n' > "$_regression/root-fake/assets/kernel/mainline/KVER"
printf 'fakecontent\n' > "$_regression/root-fake/assets/kernel/mainline/Image-cixmini.bin"
printf 'fakecontent\n' > "$_regression/root-fake/assets/kernel/mainline/modules-cixmini.tgz"
printf 'fake\n' > "$_regression/root-fake/assets/kernel/mainline/config-7.2.8-sky1-ncz"
printf 'fake\n' > "$_regression/root-fake/assets/kernel/mainline/headers-cixmini.tar.zst"
cat > "$_regression/root-fake/assets/kernel-manifest.json" <<JSON
{"schema":1,"variants":{"mainline":{"dir":"assets/kernel/mainline","kver":"7.2.8-sky1-ncz"}}}
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