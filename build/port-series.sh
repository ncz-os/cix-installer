#!/bin/bash
# Replay the NCZ Sky1 kernel patch series onto a mainline tag.
#
# Written to make the 7.2-final port a measurement rather than a guess: run it
# against the new tag and it reports exactly which patches still apply.
#
# Two things it gets right that a naive loop does not:
#
#   1. It applies patches in SRC_URI order, NOT filename order. The recipe
#      interleaves a few later fixups earlier in the series.
#   2. It only applies patches the recipe actually wires. patches-7.2/ also
#      holds superseded and experimental patches (21 of 197 as of 2026-08-16)
#      that must NOT be applied.
#
# Validated 2026-08-16 against the currently-shipping base: replaying onto
# v7.2-rc7 applied 176/176 with zero failures, which is the expected result
# since that is the pinned SRCREV.
#
# Usage:
#   port-series.sh <tag> [worktree-dir]
#
# Env overrides (defaults suit the TYDEUS build host):
#   NCZ_KERNEL_CLONE   mainline clone to take the tag from   (~/linux-72)
#   NCZ_RECIPE_DIR     dir holding linux-cix-sky1-ncz_7.2.bb
set -uo pipefail

TAG="${1:?usage: port-series.sh <tag> [worktree]}"
WT="${2:-$HOME/linux-port-$TAG}"
CLONE="${NCZ_KERNEL_CLONE:-$HOME/linux-72}"
SRC="${NCZ_RECIPE_DIR:-$HOME/yocto-docker/yocto6-ncz-tydeus/meta-cix/recipes-kernel/linux-cix-sky1-ncz}"
BB="$SRC/linux-cix-sky1-ncz_7.2.bb"
PDIR="$SRC/linux-cix-sky1-ncz-7.2"

command -v git >/dev/null || { echo "no git in PATH"; exit 1; }
[ -f "$BB" ]   || { echo "recipe not found: $BB (set NCZ_RECIPE_DIR)"; exit 1; }
[ -d "$CLONE" ]|| { echo "clone not found: $CLONE (set NCZ_KERNEL_CLONE)"; exit 1; }

cd "$CLONE" || exit 1
git rev-parse "$TAG^{commit}" >/dev/null 2>&1 || {
    echo "tag $TAG not present in $CLONE -- run: git -C $CLONE fetch --tags origin"; exit 1; }

echo "=== target: $TAG = $(git rev-parse "$TAG^{commit}")"
rm -rf "$WT"
git worktree prune
git worktree add --detach "$WT" "$TAG" >/dev/null 2>&1 || { echo "worktree add failed"; exit 1; }

mapfile -t PATCHES < <(grep -oE 'patches-7\.2/[0-9]+-[^ \\]+\.patch' "$BB")
[ "${#PATCHES[@]}" -gt 0 ] || { echo "no patches parsed from SRC_URI -- check $BB"; exit 1; }
echo "=== series: ${#PATCHES[@]} patches wired in SRC_URI"

cd "$WT" || exit 1
git config user.name "NCZ Port"
git config user.email "jperlow@gmail.com"

ok=0; failed=0
FAILLOG="/tmp/port-series-$TAG.failures"
: > "$FAILLOG"
for p in "${PATCHES[@]}"; do
    f="$PDIR/$p"
    if [ ! -f "$f" ]; then
        echo "MISSING FILE: $p" | tee -a "$FAILLOG"; failed=$((failed+1)); continue
    fi
    if git am -3 --keep-non-patch "$f" >/dev/null 2>&1; then
        ok=$((ok+1))
    else
        git am --abort >/dev/null 2>&1
        echo "FAILED: $p" | tee -a "$FAILLOG"
        failed=$((failed+1))
    fi
done

echo
echo "=== RESULT for $TAG: $ok applied, $failed failed (of ${#PATCHES[@]}) ==="
if [ "$failed" -gt 0 ]; then
    echo "failures listed in $FAILLOG"
    echo "NOTE: a failed patch is not automatically a defect -- upstream may have"
    echo "      taken the change. Check whether the hunk is already present before"
    echo "      re-forward-porting it."
    exit 1
fi
echo "clean replay -- worktree at $WT"
