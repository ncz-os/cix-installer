#!/bin/bash
# singularity-patch-drift.sh [--gate] REPO PATCH_DIR
#
# Report, in queue order, which downstream patches still apply at the pinned
# upstream commit.  Order matters: these patches are a queue, and a later patch
# is written against the tree the earlier ones produce, so testing each patch
# alone against a pristine tree under-reports what really applies.
#
# Prints "OK <patch>" or "FAIL <patch> <first failing file:hunk>", then restores
# the tree so it can be run repeatedly and never leaves the checkout dirty.
#
# Exit 0 always as a diagnostic; with --gate it exits 1 when any patch fails, so a CI
# stage can use the same ordered queue as a gate. The ordering and the restore are the
# same either way - --gate changes the exit code, not what is measured.
set -uo pipefail

GATE=0
if [ "${1:-}" = --gate ]; then GATE=1; shift; fi
REPO=${1:?usage: singularity-patch-drift.sh [--gate] REPO PATCH_DIR}
DIR=${2:?usage: singularity-patch-drift.sh [--gate] REPO PATCH_DIR}

[ -d "$REPO/.git" ] || { echo "not a git repo: $REPO" >&2; exit 2; }
[ -d "$DIR" ] || { echo "no patch dir: $DIR" >&2; exit 2; }
# resolve before the cd below, so a relative PATCH_DIR still works
DIR=$(cd "$DIR" && pwd)
REPO=$(cd "$REPO" && pwd)

cd "$REPO" || exit 2

# This tool restores the tree with `git checkout -- .` and `git clean -fdq`, so pointing it
# at a working tree with real work in it silently deletes that work. Since it is now a CI
# gate, a wrong path is one typo away - so a dirty tree is refused instead of cleaned.
if [ "${NCZ_DRIFT_ALLOW_DIRTY:-0}" != 1 ]; then
    dirty="$(git status --porcelain 2>/dev/null)"
    if [ -n "$dirty" ]; then
        echo "FATAL: $REPO has uncommitted changes; this tool restores the tree and would destroy them" >&2
        printf '%s\n' "$dirty" | head -5 >&2
        echo "       commit or stash them, or set NCZ_DRIFT_ALLOW_DIRTY=1 if the tree is disposable" >&2
        exit 2
    fi
fi
git checkout -q -- . 2>/dev/null
git clean -fdq 2>/dev/null

ERR="$(mktemp "${TMPDIR:-/tmp}/ncz-drift-err.XXXXXX")" || exit 2
trap 'rm -f "$ERR"' EXIT
fail=0
total=0
for p in $(ls "$DIR"/*.patch | sort); do
    total=$((total + 1))
    if git apply "$p" 2>"$ERR"; then
        echo "OK   $(basename "$p")"
    else
        fail=$((fail + 1))
        where=$(grep -oE "patch failed: [^ ]+:[0-9]+" "$ERR" | head -1 | sed 's/patch failed: //')
        [ -n "$where" ] || where=$(head -1 "$ERR" | cut -c1-70)
        echo "FAIL $(basename "$p") $where"
    fi
done

git checkout -q -- . 2>/dev/null
git clean -fdq 2>/dev/null
echo "---- $((total - fail)) applied, $fail failed of $total; tree restored"
if [ "$GATE" = 1 ] && [ "$fail" -ne 0 ]; then exit 1; fi
exit 0
