#!/bin/bash
# test-arm64-freshness-gate.sh -- exercise check_arm64_edge() against
# synthetic symlink + pool setups, mirroring the four cases proven live
# on HYDRA 2026-09-28. Same testing posture as build/test-amd64-kernel-
# classifier.sh: extract the function under test into a sourced shim,
# then drive it from script-controlled filesystem fixtures so the test
# has no dependency on the live pool being in any particular state.
#
# Run: bash build/test-arm64-freshness-gate.sh
# Exit 0 = all cases pass, exit 1 = at least one failed.
#
# Cases (see commit message for verbatim live proof):
#   1. POSITIVE  -- pin -> newest stable r277, prerelease r278 also in
#                   pool => OK with WARN naming r278 (deliberate pin).
#   2. NEGATIVE  -- pin -> r274 (older stable), r277 (newer stable) in
#                   pool => FAIL naming both.
#   3. NEGATIVE  -- symlink dangling => FAIL.
#   4. POSITIVE  -- orphan check flags sky1-<ver>-<date> by name.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SCRIPT_DIR/preflight-freshness-gate.sh"
[ -r "$GATE" ] || { echo "FATAL: cannot read $GATE" >&2; exit 2; }

# Pull just the function definitions out of the gate. We only want
# `is_prerelease()` and `check_arm64_edge()`; everything else (the case
# dispatch, the orphan block, etc.) is irrelevant to the test and could
# interfere with our sourced shim's shell state. Extract line-by-line:
# capture from "<name>() {" to the next "}" at column 0, which is the
# function-body terminator.
SHIM="$(mktemp -t arm64-freshness-shim.XXXXXX.sh)"
trap 'rm -rf "$TMPROOT" "$SHIM"' EXIT
awk '
    function flush() { if (depth == 0 && in_body) { in_body=0; capture=0 } }
    /^is_prerelease\(\) \{/    { capture=1; in_body=1; depth=0 }
    /^check_arm64_edge\(\) \{/ { capture=1; in_body=1; depth=0 }
    capture {
        print
        # Count "{" and "}" inside the body so the next "^}" terminates.
        n_open  = gsub(/\{/, "{")
        n_close = gsub(/\}/, "}")
        depth += n_open - n_close
        if (in_body && depth == 0 && n_close > 0) { capture=0; in_body=0 }
    }
' "$GATE" > "$SHIM"
grep -q '^is_prerelease() {' "$SHIM" \
    || { echo "EXTRACT FAILED: is_prerelease() not found in $GATE" >&2; exit 2; }
grep -q '^check_arm64_edge() {' "$SHIM" \
    || { echo "EXTRACT FAILED: check_arm64_edge() not found in $GATE" >&2; exit 2; }
. "$SHIM"

TMPROOT="$(mktemp -d -t arm64-freshness-root.XXXXXX)"
PASS=0; FAIL=0

mktime() { date -d "$1" +%s 2>/dev/null; }
mksymlink() { ln -sfn "$2" "$1"; }

# Build a synthetic pool of dated dirs whose names classify the way the
# live HYDRA pool does today (one namespace: r<N>-<kver>-sky1-ncz-<date>).
# Caller passes "<dirname>|<iso-date>" specs so we control mtimes and
# therefore which dir is "newest" in each class.
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

# Export functions so they survive into the `bash -c` child. This is the
# simplest portable way to share helpers with the per-case snippets
# below; the snippets are still isolated from PASS/FAIL (those live in
# THIS shell only).
export -f mktime mksymlink mkpool
export -f is_prerelease check_arm64_edge

# Run one test case. Args: label, want_ok, want_warn, want_fail (all
# "minimum number of matching lines in the function's output"), then a
# bash snippet that sets up the fixtures and ends with check_arm64_edge.
# The snippet runs in a subshell so it can't clobber our PASS/FAIL
# counters; we measure pass/fail by grepping the captured output.
run_case() {
    local label="$1" want_ok="$2" want_warn="$3" want_fail="$4"
    shift 4
    local out rc got_ok got_warn got_fail
    KERNEL_STAGING_DIR="$TMPROOT/pool"
    ASSETS="$TMPROOT/assets"
    mkdir -p "$ASSETS/kernel"
    # Export the fixture paths so the bash -c child can see them, and
    # pre-seed FAIL/WARN=0 so a child that doesn't touch them still sees
    # the same baseline.
    export KERNEL_STAGING_DIR ASSETS
    out="$(FAIL=0 WARN=0 bash -c "$1")"
    rc=$?
    echo "--- $label ---"
    printf '%s\n' "$out" | sed 's/^/    /'
    got_fail=$(printf '%s\n' "$out" | grep -c '^\[3\] FAIL' || true)
    got_warn=$(printf '%s\n' "$out" | grep -c '^\[3\] WARN' || true)
    got_ok=$(printf '%s\n'   "$out" | grep -c '^\[3\] OK'   || true)
    if [ "$got_ok"   -ge "$want_ok"   ] \
       && [ "$got_warn" -ge "$want_warn" ] \
       && [ "$got_fail" -ge "$want_fail" ] \
       && [ $rc -eq 0 ]; then
        echo "  PASS  $label"
        PASS=$((PASS+1))
    else
        echo "  FAIL  $label  (want ok>=$want_ok warn>=$want_warn fail>=$want_fail, got ok=$got_ok warn=$got_warn fail=$got_fail rc=$rc)"
        FAIL=$((FAIL+1))
    fi
}

# --- Case 1: POSITIVE -- pin -> r277 (stable), r278 (prerelease) also in pool.
#              pin is the newest stable, so the OK is the primary result and
#              the WARN names r278 as a deliberate-pin note (not a failure).
# The function under test reads `assets/kernel/edge` as a path RELATIVE TO
# CWD (the real gate always runs from $REPO_ROOT, where `assets/` exists).
# We stay at $TMPROOT and just ensure $TMPROOT/assets/kernel/edge is the
# symlink -- that mirrors the gate's CWD-relative lookup without
# requiring a cd.
echo "=== Case 1: POSITIVE -- pin=r277(stable,newest), r278(rc5 prerelease) also in pool ==="
run_case "arm64 OK with WARN on newer opposite-class" 1 1 0 '
    set -e
    mkpool "$KERNEL_STAGING_DIR" \
        "r272-7.2.6-sky1-ncz-20260915|2026-09-15" \
        "r273-7.3.0-rc4-sky1-ncz-20260920|2026-09-20" \
        "r274-7.2.7-sky1-ncz-20260922|2026-09-22" \
        "r277-7.2.8-sky1-ncz-20260927|2026-09-27" \
        "r278-7.3.0-rc5-sky1-ncz-20260927|2026-09-28"
    mksymlink "$ASSETS/kernel/edge" "$KERNEL_STAGING_DIR/r277-7.2.8-sky1-ncz-20260927"
    # Move into a directory whose relative-path "assets/kernel/edge"
    # resolves to the symlink we just made.
    cd "$(dirname "$ASSETS")"
    check_arm64_edge
'

# --- Case 2: NEGATIVE -- pin -> r274 (older stable), r277 (newer stable) exists
#              in same class. Should FAIL naming both.
echo
echo "=== Case 2: NEGATIVE -- pin=r274(stable,older), r277(stable,newer) also in pool ==="
run_case "arm64 FAIL when newer same-class build exists" 0 0 1 '
    set -e
    mkpool "$KERNEL_STAGING_DIR" \
        "r272-7.2.6-sky1-ncz-20260915|2026-09-15" \
        "r273-7.3.0-rc4-sky1-ncz-20260920|2026-09-20" \
        "r274-7.2.7-sky1-ncz-20260922|2026-09-22" \
        "r277-7.2.8-sky1-ncz-20260927|2026-09-27" \
        "r278-7.3.0-rc5-sky1-ncz-20260927|2026-09-28"
    mksymlink "$ASSETS/kernel/edge" "$KERNEL_STAGING_DIR/r274-7.2.7-sky1-ncz-20260922"
    cd "$(dirname "$ASSETS")"
    check_arm64_edge
'

# --- Case 3: NEGATIVE -- symlink is dangling (points at a nonexistent path).
echo
echo "=== Case 3: NEGATIVE -- dangling symlink ==="
run_case "arm64 FAIL on dangling symlink" 0 0 1 '
    set -e
    mkpool "$KERNEL_STAGING_DIR" \
        "r277-7.2.8-sky1-ncz-20260927|2026-09-27"
    mksymlink "$ASSETS/kernel/edge" "/nonexistent/pool/r277-7.2.8-sky1-ncz-20260927"
    cd "$(dirname "$ASSETS")"
    check_arm64_edge
'

# --- Case 4: POSITIVE -- orphan check flags sky1-<ver>-<date>.
#              This one drives the FULL gate (not just check_arm64_edge)
#              because the orphan block isn't in the function under test.
#              We point the gate at a synthetic pool containing BOTH the
#              live-pin dir and the orphan, and assert the orphan line
#              appears in the gate's [3] output.
echo
echo "=== Case 4: POSITIVE -- orphan check flags sky1-<ver>-<date> ==="
SYN_POOL="$TMPROOT/syn-pool"
SYN_ASSETS="$TMPROOT/syn-assets"
mkdir -p "$SYN_ASSETS/kernel"
mkpool "$SYN_POOL" \
    "r277-7.2.8-sky1-ncz-20260927|2026-09-27" \
    "sky1-7.2.8-20260927|2026-09-27"
mksymlink "$SYN_ASSETS/kernel/edge" "$SYN_POOL/r277-7.2.8-sky1-ncz-20260927"
GATE_OUT="$(cd "$SYN_ASSETS" && NCZ_TARGET_ARCH=arm64 \
    KERNEL_STAGING_DIR="$SYN_POOL" bash "$GATE" 2>&1)"
echo "--- orphan check on synthetic pool ---"
printf '%s\n' "$GATE_OUT" | grep -E '^\[3\]|          sky1-|^          r[0-9]+-' | sed 's/^/    /'
if printf '%s\n' "$GATE_OUT" | grep -q 'sky1-7.2.8-20260927'; then
    echo "  PASS  orphan check flags sky1-7.2.8-20260927 by name"
    PASS=$((PASS+1))
else
    echo "  FAIL  orphan check did NOT flag sky1-7.2.8-20260927"
    FAIL=$((FAIL+1))
fi

echo
echo "=== arm64 freshness gate test: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]