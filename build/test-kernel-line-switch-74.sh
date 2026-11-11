#!/bin/bash
# test-kernel-line-switch-74.sh -- the operator 2026-11-09 22:20Z line-switch
# contract ("move away from 7.3 and go directly to 7.4, on both architectures")
# for the guards that positively list the 7.3 series:
#
#   1. post-install/10-amd64-kernel.sh   image-build kernel install hook
#   2. build/publish-amd64-kernel.sh     shared-pool publish gate
#   3. post-install/10-our-kernel.sh     arm64 target defence-in-depth
#
# Each guard's `case` block is extracted VERBATIM from the shipped script and
# executed against sample KVERs (same posture as test-kernel-purity-guards.sh):
# 7.3.* / 7.4.* accepted while DEFAULT_BASE=7.3,7.4; 7.2.x and anything else
# stays refused. The boot classifier (assets/refind/zz1-ncz-refind-refresh-amd64)
# is covered by test-amd64-kernel-classifier.sh; the arm64 channel-pointer
# class by test-arm64-freshness-gate.sh.
#
# Usage: build/test-kernel-line-switch-74.sh
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
HOOK_A="$REPO/post-install/10-amd64-kernel.sh"
PUBLISH="$REPO/build/publish-amd64-kernel.sh"
HOOK_B="$REPO/post-install/10-our-kernel.sh"
for f in "$HOOK_A" "$PUBLISH" "$HOOK_B"; do
    [ -r "$f" ] || { echo "EXTRACT FAILED: cannot read $f"; exit 2; }
done

PASS=0; FAIL=0

extract_case() { # extract_case <file> <anchor-regex> -> prints case..esac block
    local f="$1" anchor="$2" n start
    n=$(grep -n "$anchor" "$f" | head -1 | cut -d: -f1)
    [ -n "$n" ] || return 1
    start=$(head -n "$n" "$f" | grep -n '[[:space:]]*case "' | tail -1 | cut -d: -f1)
    [ -n "$start" ] || return 1
    awk -v s="$start" 'NR>=s {print} NR>=s && /esac/ {exit}' "$f"
}

try_kver() { # try_kver <block-file> <var> <value> -> echoes accept|reject
    local blk="$1" var="$2" val="$3" rc
    # `return 1` (hook A) and `exit 1` (publish, hook B) both surface as a
    # non-zero here; an accepting arm falls off the end of the sourced block.
    rc=$( ( set +e; export "$var=$val"; . "$blk" >/dev/null 2>&1; echo $? ) 2>/dev/null )
    case "$rc" in 0) echo accept ;; *) echo reject ;; esac
}

run_guard() { # run_guard <label> <block-file> <var> <accept...> -- <reject...>
    local label="$1" blk="$2" var="$3"; shift 3
    local v got want
    local mode=accept
    for v in "$@"; do
        if [ "$v" = "--" ]; then mode=reject; continue; fi
        got=$(try_kver "$blk" "$var" "$v")
        want=$mode
        if [ "$got" = "$want" ]; then
            echo "  PASS  $label: $v -> $got"; PASS=$((PASS+1))
        else
            echo "  FAIL  $label: $v -> $got (want $want)"; FAIL=$((FAIL+1))
        fi
    done
}

A_BLK="$(mktemp -t line-switch-a.XXXX.sh)"; P_BLK="$(mktemp -t line-switch-p.XXXX.sh)"
B_BLK="$(mktemp -t line-switch-b.XXXX.sh)"
trap 'rm -f "$A_BLK" "$P_BLK" "$B_BLK"' EXIT

extract_case "$HOOK_A" "Refusing to install" > "$A_BLK" \
    || { echo "EXTRACT FAILED: 10-amd64-kernel.sh guard case"; exit 2; }
# "is not the unified 7.3" matches both the pre-switch and post-switch message wording.
extract_case "$PUBLISH" "is not the unified 7.3" > "$P_BLK" \
    || { echo "EXTRACT FAILED: publish-amd64-kernel.sh guard case"; exit 2; }
extract_case "$HOOK_B" "is not the unified 7.3" > "$B_BLK" \
    || { echo "EXTRACT FAILED: 10-our-kernel.sh guard case"; exit 2; }

echo "=== 10-amd64-kernel.sh install hook ==="
run_guard "hook-amd64" "$A_BLK" kver \
    7.3.3-t2-ncz 7.3.0-rc7-t2-ncz 7.4.0-rc2-t2-ncz 7.4.0-t2-ncz \
    -- 7.2.9-2-t2-ncz 6.1.0-13-amd64 7.5.0-t2-ncz ""

echo "=== publish-amd64-kernel.sh pool publish gate ==="
run_guard "publish" "$P_BLK" KVER \
    7.3.3-t2-ncz 7.3.0-rc7-t2-ncz 7.4.0-rc2-t2-ncz \
    -- 7.2.9-2-t2-ncz 6.1.0-13-amd64 7.5.0-t2-ncz

echo "=== 10-our-kernel.sh arm64 target guard ==="
run_guard "hook-arm64" "$B_BLK" KVER_NEXT \
    7.3.3-sky1-ncz 7.3.0-rc7-sky1-ncz 7.4.0-rc2-sky1-ncz 7.4.0-sky1-ncz \
    -- 7.2.8-sky1-ncz 7.1.2-arm64 7.5.0-sky1-ncz

echo
echo "=== kernel line-switch 7.4 guard test: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
