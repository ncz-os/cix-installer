#!/bin/bash
# test-amd64-freshness-gate.sh -- exercise check_amd64_line() against synthetic
# kernel-staging pool setups. Same testing posture as build/test-arm64-freshness-
# gate.sh: extract the function under test into a sourced shim and drive it from
# script-controlled filesystem fixtures, so the test does not depend on the live
# pool being in any particular state.
#
# REGRESSION (amd64 RC7, 2026-10-12). The r2 revision pin added PKGVERSION so
# the two same-KVER pool dirs (r1 amd64-t2-rc7-20261011 vs r2 amd64-t2-rc7-r2-
# 20261012) resolve unambiguously. But each pool dir ALSO holds a
# linux-image-<kver>-dbg debug build, and a bare
#     find "$newest" -iname 'linux-image-*.deb' | head -1
# is at the mercy of readdir order: it returned the -dbg build in the r2 dir and
# false-FAILed the gate against a correctly staged kernel while the r1 dir
# happened to return the image. check_amd64_line now names the pinned package
# exactly (falling back to the non-dbg image); these cases pin that behaviour.
#
# Run: bash build/test-amd64-freshness-gate.sh
# Exit 0 = all cases pass, exit 1 = at least one failed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SCRIPT_DIR/preflight-freshness-gate.sh"
[ -r "$GATE" ] || { echo "FATAL: cannot read $GATE" >&2; exit 2; }

SHIM="$(mktemp -t amd64-freshness-shim.XXXXXX.sh)"
TMPROOT="$(mktemp -d -t amd64-freshness-root.XXXXXX)"
trap 'rm -rf "$TMPROOT" "$SHIM"' EXIT
awk '
    /^check_amd64_line\(\) \{/ { capture=1; in_body=1; depth=0 }
    capture {
        print
        n_open  = gsub(/\{/, "{")
        n_close = gsub(/\}/, "}")
        depth += n_open - n_close
        if (in_body && depth == 0 && n_close > 0) { capture=0; in_body=0 }
    }
' "$GATE" > "$SHIM"
grep -q '^check_amd64_line() {' "$SHIM" \
    || { echo "EXTRACT FAILED: check_amd64_line() not found in $GATE" >&2; exit 2; }
# The gate's dispatch must call the amd64 arm with the line this test asserts.
grep -q '^ *check_amd64_line amd64-stable$' "$GATE" \
    || { echo "DISPATCH MISMATCH: gate does not call check_amd64_line amd64-stable" >&2; exit 2; }
# shellcheck source=/dev/null
. "$SHIM"
export -f check_amd64_line

PASS=0; FAIL=0

# Build the r1 + r2 same-KVER pool the r2 pin produced. Each dir carries the
# shipping image plus a linux-image-<kver>-dbg build. The -dbg is created LAST
# so that on tmpfs (this host's /tmp, which returns the most-recently-created
# entry first) a bare `find ... 'linux-image-*.deb' | head -1` picks the -dbg --
# the exact live shape that false-FAILed amd64 RC7.  run_case prints that
# `find|head -1` control so the reproduction is visible in the output.
mkpool_r2() {
    local pool="$1"
    rm -rf "$pool"; mkdir -p "$pool"
    local d1="$pool/amd64-t2-rc7-20261011/7.3.0-rc7-t2-ncz"
    local d2="$pool/amd64-t2-rc7-r2-20261012/7.3.0-rc7-t2-ncz"
    mkdir -p "$d1" "$d2"
    printf '7.3.0-rc7-t2-ncz\n' > "$d1/KVER"
    printf '7.3.0-rc7-t2-ncz\n' > "$d2/KVER"
    printf 'r1-img\n' > "$d1/linux-image-7.3.0-rc7-t2-ncz_7.3.0-rc7-1_amd64.deb"
    printf 'r1-hdr\n' > "$d1/linux-headers-7.3.0-rc7-t2-ncz_7.3.0-rc7-1_amd64.deb"
    printf 'r1-dbg\n' > "$d1/linux-image-7.3.0-rc7-t2-ncz-dbg_7.3.0-rc7-1_amd64.deb"   # LAST: tmpfs find|head -1 picks it
    printf 'r2-img\n' > "$d2/linux-image-7.3.0-rc7-t2-ncz_7.3.0-rc7-2_amd64.deb"
    printf 'r2-hdr\n' > "$d2/linux-headers-7.3.0-rc7-t2-ncz_7.3.0-rc7-2_amd64.deb"
    printf 'r2-dbg\n' > "$d2/linux-image-7.3.0-rc7-t2-ncz-dbg_7.3.0-rc7-2_amd64.deb"   # LAST: reproduces the bug shape
}

# stage_local <repo> <image-deb-content> <rev> -- write KVER+PKGVERSION(pinned
# rev 2) and a local image deb (content distinguishes the build).
stage_local() {
    local repo="$1" content="$2" rev="$3"
    mkdir -p "$repo/assets/kernel/amd64-stable"
    printf '7.3.0-rc7-t2-ncz\n' > "$repo/assets/kernel/amd64-stable/KVER"
    printf '7.3.0-rc7-2\n'      > "$repo/assets/kernel/amd64-stable/PKGVERSION"
    printf '%s\n' "$content"    > "$repo/assets/kernel/amd64-stable/linux-image-7.3.0-rc7-t2-ncz_${rev}_amd64.deb"
}

run_case() { # label want_ok want_fail repo setup_cmd
    local label="$1" want_ok="$2" want_fail="$3" repo="$4" setup="$5"
    local out rc got_ok got_fail
    eval "$setup"
    out="$(cd "$repo" && KERNEL_STAGING_DIR="$POOL" FAIL=0 WARN=0 bash -c 'check_amd64_line amd64-stable')"
    rc=$?
    echo "--- $label ---"
    printf '%s\n' "$out" | sed 's/^/    /'
    got_ok=$(printf '%s\n' "$out" | grep -c '^\[3\] OK' || true)
    got_fail=$(printf '%s\n' "$out" | grep -c '^\[3\] FAIL' || true)
    echo "    (find|head -1 on the r2 dir would pick: $(find "$POOL/amd64-t2-rc7-r2-20261012/7.3.0-rc7-t2-ncz" -maxdepth 1 -iname 'linux-image-*.deb' | head -1 | xargs -r basename))"
    if [ "$got_ok" -ge "$want_ok" ] && [ "$got_fail" -eq "$want_fail" ]; then
        echo "  PASS  $label"; PASS=$((PASS+1))
    else
        echo "  FAIL  $label  (want ok>=$want_ok fail==$want_fail, got ok=$got_ok fail=$got_fail rc=$rc)"
        FAIL=$((FAIL+1))
    fi
}

POOL="$TMPROOT/pool"
mkpool_r2 "$POOL"

echo "=== Case 1 (regression): r2 pin + -dbg in the pool, local == pinned r2 image -> OK ==="
run_case "pinned r2 image recognised despite the -dbg build" 1 0 "$TMPROOT/case1" \
    'stage_local "$TMPROOT/case1" r2-img 7.3.0-rc7-2'

echo; echo "=== Case 2: local holds the r1 image while PKGVERSION pins r2 -> FAIL ==="
run_case "local r1 build vs pinned r2 is FAIL" 0 1 "$TMPROOT/case2" \
    'stage_local "$TMPROOT/case2" r1-img 7.3.0-rc7-1'

echo; echo "=== Case 3: local r2 file content differs from the pool's pinned image -> FAIL ==="
run_case "tampered local r2 image is FAIL" 0 1 "$TMPROOT/case3" \
    'stage_local "$TMPROOT/case3" r2-img-TAMPERED 7.3.0-rc7-2'

echo; echo "=== Case 4: pool has no -dbg (image only), local == pinned image -> OK ==="
run_case "pinned image recognised with no -dbg present" 1 0 "$TMPROOT/case4" \
    'rm -f "$POOL/amd64-t2-rc7-r2-20261012/7.3.0-rc7-t2-ncz/linux-image-7.3.0-rc7-t2-ncz-dbg_7.3.0-rc7-2_amd64.deb"; stage_local "$TMPROOT/case4" r2-img 7.3.0-rc7-2'

echo
echo "=== amd64 freshness gate test: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
