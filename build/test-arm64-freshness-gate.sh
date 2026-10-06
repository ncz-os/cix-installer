#!/bin/bash
# test-arm64-freshness-gate.sh -- exercise check_arm64_channel() against
# synthetic symlink + pool setups. Same testing posture as build/test-amd64-
# kernel-classifier.sh: extract the function under test into a sourced shim,
# then drive it from script-controlled filesystem fixtures so the test has no
# dependency on the live pool being in any particular state.
#
# Unified 7.3 policy (operator 2026-10-05): the Sky1 tree has ONE channel
# pointer, assets/kernel/mainline, which must resolve to the 7.3 kernel
# (rc allowed while KERNEL-POLICY RC_DEFAULT_ALLOWED=1). The former
# test-only edge pointer was retired.
#
# Run: bash build/test-arm64-freshness-gate.sh
# Exit 0 = all cases pass, exit 1 = at least one failed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SCRIPT_DIR/preflight-freshness-gate.sh"
[ -r "$GATE" ] || { echo "FATAL: cannot read $GATE" >&2; exit 2; }

SHIM="$(mktemp -t arm64-freshness-shim.XXXXXX.sh)"
TMPROOT="$(mktemp -d -t arm64-freshness-root.XXXXXX)"
export TMPROOT
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
# The gate's dispatch must call the one pointer with the contract this test
# asserts -- otherwise the unit cases below prove a function nobody calls.
grep -q '^ *check_arm64_channel assets/kernel/mainline unified required$' "$GATE" \
    || { echo "DISPATCH MISMATCH: gate does not check assets/kernel/mainline as unified+required" >&2; exit 2; }
grep -q 'check_arm64_channel assets/kernel/edge' "$GATE" \
    && { echo "DISPATCH MISMATCH: gate still checks the retired assets/kernel/edge pointer" >&2; exit 2; }
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
        : > "$pool/$name/KVER"
        # Stamp the dir AFTER creating KVER: creating a file inside a
        # directory resets its mtime, which made the newest-by-mtime order
        # depend on filesystem timing (it passed on tmpfs by luck and
        # failed on btrfs/ext4 with whole-second ties).
        touch -d "@$date_epoch" "$pool/$name"
    done
}
# A pool holding the retired 7.2.x builds plus the unified 7.3 line (r282,
# r283, r284; r284 newest by mtime).
std_pool() {
    mkpool "$KERNEL_STAGING_DIR" \
        "r272-7.2.6-sky1-ncz-20260915|2026-09-15" \
        "r273-7.3.0-rc4-sky1-ncz-20260920|2026-09-20" \
        "r274-7.2.7-sky1-ncz-20260922|2026-09-22" \
        "r277-7.2.8-sky1-ncz-20260927|2026-09-27" \
        "r281-7.2.9-sky1-ncz-20261003|2026-10-03" \
        "r282-7.3.0-rc6-sky1-ncz-20261004|2026-10-04" \
        "r283-7.3.0-rc6-sky1-ncz-20261006|2026-10-05" \
        "r284-7.3.0-rc6-sky1-ncz-20261006|2026-10-06"
}
one() { check_arm64_channel assets/kernel/mainline unified required; }
export -f mktime mksymlink mkpool std_pool one
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

echo "=== Case 1: POSITIVE -- mainline=r284 (newest 7.3 build) ==="
run_case "mainline on the newest unified 7.3 build" 1 0 0 '
    set -e; std_pool
    mksymlink "$ASSETS/kernel/mainline" "$KERNEL_STAGING_DIR/r284-7.3.0-rc6-sky1-ncz-20261006"
    one'

echo; echo "=== Case 2: NEGATIVE -- mainline points at a retired 7.2.8 build ==="
run_case "mainline pointing at 7.2.x is FAIL" 0 0 1 '
    set -e; std_pool
    mksymlink "$ASSETS/kernel/mainline" "$KERNEL_STAGING_DIR/r277-7.2.8-sky1-ncz-20260927"
    one'

echo; echo "=== Case 3: NEGATIVE -- mainline=r273 rc4 while newer 7.3 r284 exists ==="
run_case "stale unified 7.3 pin is FAIL" 0 0 1 '
    set -e; std_pool
    mksymlink "$ASSETS/kernel/mainline" "$KERNEL_STAGING_DIR/r273-7.3.0-rc4-sky1-ncz-20260920"
    one'

echo; echo "=== Case 3b: NEGATIVE -- mainline=r282 rc6 while newer 7.3 r284 exists ==="
run_case "superseded r282 pin is FAIL" 0 0 1 '
    set -e; std_pool
    mksymlink "$ASSETS/kernel/mainline" "$KERNEL_STAGING_DIR/r282-7.3.0-rc6-sky1-ncz-20261004"
    one'

echo; echo "=== Case 4: NEGATIVE -- mainline dangling ==="
run_case "dangling mainline is FAIL" 0 0 1 '
    set -e; std_pool
    mksymlink "$ASSETS/kernel/mainline" "/nonexistent/pool/r284-7.3.0-rc6-sky1-ncz-20261006"
    one'

echo; echo "=== Case 5: NEGATIVE -- no mainline pointer (required line) ==="
run_case "absent mainline is FAIL" 0 0 1 '
    set -e; std_pool
    one'

echo; echo "=== Case 6: NEGATIVE -- mainline outside the pool ==="
run_case "mainline outside the pool is FAIL" 0 0 1 '
    set -e; std_pool
    mkdir -p "$TMPROOT/outside"
    mksymlink "$ASSETS/kernel/mainline" "$TMPROOT/outside/r284-7.3.0-rc6-sky1-ncz-20261006"
    one'

# --- Case 7: the FULL gate, orphan check + the one pointer. Drives the real
#     script (not the extracted function), so it also proves the dispatch.
echo; echo "=== Case 7: full gate -- orphan flagged, unified channel OK ==="
SYN_POOL="$TMPROOT/syn-pool"
SYN_REPO="$TMPROOT/syn-repo"
mkdir -p "$SYN_REPO/build" "$SYN_REPO/assets/kernel"
cp "$GATE" "$SYN_REPO/build/preflight-freshness-gate.sh"
KERNEL_STAGING_DIR="$SYN_POOL" mkpool "$SYN_POOL" \
    "r281-7.2.9-sky1-ncz-20261003|2026-10-03" \
    "r282-7.3.0-rc6-sky1-ncz-20261004|2026-10-04" \
    "r284-7.3.0-rc6-sky1-ncz-20261006|2026-10-06" \
    "sky1-7.2.9-20261003|2026-10-03"
mksymlink "$SYN_REPO/assets/kernel/mainline" "$SYN_POOL/r284-7.3.0-rc6-sky1-ncz-20261006"
GATE_OUT="$(NCZ_TARGET_ARCH=arm64 bash "$SYN_REPO/build/preflight-freshness-gate.sh" \
    --kernel-staging-dir "$SYN_POOL" 2>&1)"
printf '%s\n' "$GATE_OUT" | grep -E '^\[3\]|          sky1-' | sed 's/^/    /'
if printf '%s\n' "$GATE_OUT" | grep -q 'sky1-7.2.9-20261003' \
   && printf '%s\n' "$GATE_OUT" | grep -q '^\[3\] OK: arm64 mainline -- assets/kernel/mainline -> r284-7.3.0-rc6-sky1-ncz-20261006'; then
    echo "  PASS  full gate: orphan flagged, unified mainline OK"
    PASS=$((PASS+1))
else
    echo "  FAIL  full gate did not report the orphan plus the unified channel OK"
    FAIL=$((FAIL+1))
fi

echo
echo "=== arm64 freshness gate test: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
