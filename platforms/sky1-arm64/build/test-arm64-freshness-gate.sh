#!/bin/bash
# test-arm64-freshness-gate.sh -- exercise check_arm64_channel() against
# synthetic symlink + pool setups. Same testing posture as build/test-amd64-
# kernel-classifier.sh: extract the function under test into a sourced shim,
# then drive it from script-controlled filesystem fixtures so the test has no
# dependency on the live pool being in any particular state.
#
# Since 2026-09-29 the Sky1 tree has TWO channel pointers, mirroring amd64:
#   assets/kernel/mainline -- shipping 7.2.x, stable class, required
#   assets/kernel/edge     -- test-only 7.3.x, prerelease class, optional
# The gate runs check_arm64_channel once per pointer, exactly as the cases
# below do.
#
# Run: bash build/test-arm64-freshness-gate.sh
# Exit 0 = all cases pass, exit 1 = at least one failed.
#
# FAIL counts are asserted EXACTLY (a positive case with a stray FAIL is a
# test failure); OK/WARN counts are minimums.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SCRIPT_DIR/preflight-freshness-gate.sh"
[ -r "$GATE" ] || { echo "FATAL: cannot read $GATE" >&2; exit 2; }

SHIM="$(mktemp -t arm64-freshness-shim.XXXXXX.sh)"
TMPROOT="$(mktemp -d -t arm64-freshness-root.XXXXXX)"
trap 'rm -rf "$TMPROOT" "$SHIM"' EXIT
awk '
    /^is_prerelease\(\) \{/        { capture=1; in_body=1; depth=0 }
    /^check_arm64_channel\(\) \{/  { capture=1; in_body=1; depth=0 }
    capture {
        print
        n_open  = gsub(/\{/, "{")
        n_close = gsub(/\}/, "}")
        depth += n_open - n_close
        if (in_body && depth == 0 && n_close > 0) { capture=0; in_body=0 }
    }
' "$GATE" > "$SHIM"
grep -q '^is_prerelease() {' "$SHIM" \
    || { echo "EXTRACT FAILED: is_prerelease() not found in $GATE" >&2; exit 2; }
grep -q '^check_arm64_channel() {' "$SHIM" \
    || { echo "EXTRACT FAILED: check_arm64_channel() not found in $GATE" >&2; exit 2; }
# The gate's dispatch must call both pointers with the contract this test
# asserts -- otherwise the unit cases below prove a function nobody calls.
grep -q '^ *check_arm64_channel assets/kernel/mainline stable required$' "$GATE" \
    || { echo "DISPATCH MISMATCH: gate does not check assets/kernel/mainline as stable+required" >&2; exit 2; }
grep -q '^ *check_arm64_channel assets/kernel/edge prerelease optional$' "$GATE" \
    || { echo "DISPATCH MISMATCH: gate does not check assets/kernel/edge as prerelease+optional" >&2; exit 2; }
# shellcheck source=/dev/null
. "$SHIM"

PASS=0; FAIL=0

mktime() { date -d "$1" +%s 2>/dev/null; }
mksymlink() { ln -sfn "$2" "$1"; }
mkpool() {
    local pool="$1"; shift
    rm -rf "$pool"; mkdir -p "$pool"
    local spec name date_epoch
    for spec in "$@"; do
        name="${spec%%|*}"
        date_epoch="$(mktime "${spec##*|}")"
        mkdir -p "$pool/$name"
        touch -d "@$date_epoch" "$pool/$name"
        : > "$pool/$name/KVER"
    done
}
# The live pool on 2026-09-29, by name and date.
std_pool() {
    mkpool "$KERNEL_STAGING_DIR" \
        "r272-7.2.6-sky1-ncz-20260915|2026-09-15" \
        "r273-7.3.0-rc4-sky1-ncz-20260920|2026-09-20" \
        "r274-7.2.7-sky1-ncz-20260922|2026-09-22" \
        "r277-7.2.8-sky1-ncz-20260927|2026-09-27" \
        "r278-7.3.0-rc5-sky1-ncz-20260927|2026-09-28"
}
both() {
    check_arm64_channel assets/kernel/mainline stable required
    check_arm64_channel assets/kernel/edge prerelease optional
}
export -f mktime mksymlink mkpool std_pool both
export -f is_prerelease check_arm64_channel

run_case() {   # label want_ok want_warn want_fail(exact) snippet
    local label="$1" want_ok="$2" want_warn="$3" want_fail="$4"
    shift 4
    local out rc got_ok got_warn got_fail
    KERNEL_STAGING_DIR="$TMPROOT/pool"
    ASSETS="$TMPROOT/case-$PASS-$FAIL/assets"
    rm -rf "$ASSETS"; mkdir -p "$ASSETS/kernel"
    export KERNEL_STAGING_DIR ASSETS
    out="$(cd "$(dirname "$ASSETS")" && FAIL=0 WARN=0 bash -c "$1")"
    rc=$?
    echo "--- $label ---"
    printf '%s\n' "$out" | sed 's/^/    /'
    got_fail=$(printf '%s\n' "$out" | grep -c '^\[3\] FAIL' || true)
    got_warn=$(printf '%s\n' "$out" | grep -c '^\[3\] WARN' || true)
    got_ok=$(printf '%s\n'   "$out" | grep -c '^\[3\] OK'   || true)
    if [ "$got_ok" -ge "$want_ok" ] && [ "$got_warn" -ge "$want_warn" ] \
       && [ "$got_fail" -eq "$want_fail" ] && [ $rc -eq 0 ]; then
        echo "  PASS  $label"; PASS=$((PASS+1))
    else
        echo "  FAIL  $label  (want ok>=$want_ok warn>=$want_warn fail==$want_fail, got ok=$got_ok warn=$got_warn fail=$got_fail rc=$rc)"
        FAIL=$((FAIL+1))
    fi
}

echo "=== Case 1: POSITIVE -- mainline=r277 (newest stable), edge=r278 (newest rc) ==="
run_case "both channels on their newest same-class build" 2 0 0 '
    set -e; std_pool
    mksymlink "$ASSETS/kernel/mainline" "$KERNEL_STAGING_DIR/r277-7.2.8-sky1-ncz-20260927"
    mksymlink "$ASSETS/kernel/edge"     "$KERNEL_STAGING_DIR/r278-7.3.0-rc5-sky1-ncz-20260927"
    both'

echo; echo "=== Case 2: NEGATIVE (the 2026-09-28 incident) -- mainline=r278 rc5 ==="
run_case "mainline pointing at a prerelease is FAIL" 0 0 1 '
    set -e; std_pool
    mksymlink "$ASSETS/kernel/mainline" "$KERNEL_STAGING_DIR/r278-7.3.0-rc5-sky1-ncz-20260927"
    mksymlink "$ASSETS/kernel/edge"     "$KERNEL_STAGING_DIR/r278-7.3.0-rc5-sky1-ncz-20260927"
    both'

echo; echo "=== Case 3: NEGATIVE -- edge=r277 7.2.8 (a release kernel under edge) ==="
run_case "edge pointing at a release kernel is FAIL" 1 0 1 '
    set -e; std_pool
    mksymlink "$ASSETS/kernel/mainline" "$KERNEL_STAGING_DIR/r277-7.2.8-sky1-ncz-20260927"
    mksymlink "$ASSETS/kernel/edge"     "$KERNEL_STAGING_DIR/r277-7.2.8-sky1-ncz-20260927"
    both'

echo; echo "=== Case 4: NEGATIVE -- mainline=r274 while newer stable r277 exists ==="
run_case "stale same-class mainline pin is FAIL" 1 0 1 '
    set -e; std_pool
    mksymlink "$ASSETS/kernel/mainline" "$KERNEL_STAGING_DIR/r274-7.2.7-sky1-ncz-20260922"
    mksymlink "$ASSETS/kernel/edge"     "$KERNEL_STAGING_DIR/r278-7.3.0-rc5-sky1-ncz-20260927"
    both'

echo; echo "=== Case 5: NEGATIVE -- edge=r273 rc4 while newer rc r278 exists ==="
run_case "stale same-class edge pin is FAIL" 1 0 1 '
    set -e; std_pool
    mksymlink "$ASSETS/kernel/mainline" "$KERNEL_STAGING_DIR/r277-7.2.8-sky1-ncz-20260927"
    mksymlink "$ASSETS/kernel/edge"     "$KERNEL_STAGING_DIR/r273-7.3.0-rc4-sky1-ncz-20260920"
    both'

echo; echo "=== Case 6: POSITIVE -- no edge pointer at all (optional line) ==="
run_case "absent edge is WARN, not FAIL" 1 1 0 '
    set -e; std_pool
    mksymlink "$ASSETS/kernel/mainline" "$KERNEL_STAGING_DIR/r277-7.2.8-sky1-ncz-20260927"
    both'

echo; echo "=== Case 7: NEGATIVE -- no mainline pointer (required line) ==="
run_case "absent mainline is FAIL" 1 0 1 '
    set -e; std_pool
    mksymlink "$ASSETS/kernel/edge" "$KERNEL_STAGING_DIR/r278-7.3.0-rc5-sky1-ncz-20260927"
    both'

echo; echo "=== Case 8: NEGATIVE -- mainline dangling ==="
run_case "dangling mainline is FAIL" 1 0 1 '
    set -e; std_pool
    mksymlink "$ASSETS/kernel/mainline" "/nonexistent/pool/r277-7.2.8-sky1-ncz-20260927"
    mksymlink "$ASSETS/kernel/edge"     "$KERNEL_STAGING_DIR/r278-7.3.0-rc5-sky1-ncz-20260927"
    both'

# --- Case 9: the FULL gate, orphan check + both pointers. Drives the real
#     script (not the extracted function), so it also proves the dispatch.
#     The gate cd's to its OWN repo root and probes the real pool mounts,
#     so it runs from a synthetic repo copy with --kernel-staging-dir;
#     otherwise it would silently check the live checkout and live pool.
echo; echo "=== Case 9: full gate -- orphan flagged, both channels OK ==="
SYN_POOL="$TMPROOT/syn-pool"
SYN_REPO="$TMPROOT/syn-repo"
mkdir -p "$SYN_REPO/build" "$SYN_REPO/assets/kernel"
cp "$GATE" "$SYN_REPO/build/preflight-freshness-gate.sh"
KERNEL_STAGING_DIR="$SYN_POOL" mkpool "$SYN_POOL" \
    "r277-7.2.8-sky1-ncz-20260927|2026-09-27" \
    "r278-7.3.0-rc5-sky1-ncz-20260927|2026-09-28" \
    "sky1-7.2.8-20260927|2026-09-27"
mksymlink "$SYN_REPO/assets/kernel/mainline" "$SYN_POOL/r277-7.2.8-sky1-ncz-20260927"
mksymlink "$SYN_REPO/assets/kernel/edge"     "$SYN_POOL/r278-7.3.0-rc5-sky1-ncz-20260927"
GATE_OUT="$(NCZ_TARGET_ARCH=arm64 bash "$SYN_REPO/build/preflight-freshness-gate.sh" \
    --kernel-staging-dir "$SYN_POOL" 2>&1)"
printf '%s\n' "$GATE_OUT" | grep -E '^\[3\]|          sky1-' | sed 's/^/    /'
if printf '%s\n' "$GATE_OUT" | grep -q 'sky1-7.2.8-20260927' \
   && printf '%s\n' "$GATE_OUT" | grep -q '^\[3\] OK: arm64 mainline -- assets/kernel/mainline -> r277-7.2.8-sky1-ncz-20260927' \
   && printf '%s\n' "$GATE_OUT" | grep -q '^\[3\] OK: arm64 edge -- assets/kernel/edge -> r278-7.3.0-rc5-sky1-ncz-20260927'; then
    echo "  PASS  full gate: orphan flagged, mainline and edge OK"
    PASS=$((PASS+1))
else
    echo "  FAIL  full gate did not report the orphan plus both channel OKs"
    FAIL=$((FAIL+1))
fi

echo
echo "=== arm64 freshness gate test: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
