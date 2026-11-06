#!/bin/bash
# singularity-patch-drift.sh REPO PATCH_DIR
#
# Report, in queue order, which downstream patches still apply at the pinned
# upstream commit.  Order matters: these patches are a queue, and a later patch
# is written against the tree the earlier ones produce, so testing each patch
# alone against a pristine tree under-reports what really applies.
#
# Prints "OK <patch>" or "FAIL <patch> <first failing file:hunk>", then restores
# the tree so it can be run repeatedly and never leaves the checkout dirty.
#
# Exit 0 always (this is a diagnostic, not a gate); the caller decides.
set -uo pipefail

REPO=${1:?usage: singularity-patch-drift.sh REPO PATCH_DIR}
DIR=${2:?usage: singularity-patch-drift.sh REPO PATCH_DIR}

[ -d "$REPO/.git" ] || { echo "not a git repo: $REPO" >&2; exit 2; }
[ -d "$DIR" ] || { echo "no patch dir: $DIR" >&2; exit 2; }
# resolve before the cd below, so a relative PATCH_DIR still works
DIR=$(cd "$DIR" && pwd)
REPO=$(cd "$REPO" && pwd)

cd "$REPO" || exit 2
git checkout -q -- . 2>/dev/null
git clean -fdq 2>/dev/null

fail=0
total=0
for p in $(ls "$DIR"/*.patch | sort); do
    total=$((total + 1))
    if git apply "$p" 2>/tmp/ncz-drift-err; then
        echo "OK   $(basename "$p")"
    else
        fail=$((fail + 1))
        where=$(grep -oE "patch failed: [^ ]+:[0-9]+" /tmp/ncz-drift-err | head -1 | sed 's/patch failed: //')
        [ -n "$where" ] || where=$(head -1 /tmp/ncz-drift-err | cut -c1-70)
        echo "FAIL $(basename "$p") $where"
    fi
done
rm -f /tmp/ncz-drift-err

git checkout -q -- . 2>/dev/null
git clean -fdq 2>/dev/null
echo "---- $((total - fail)) applied, $fail failed of $total; tree restored"
exit 0
