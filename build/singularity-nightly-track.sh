#!/bin/bash
# singularity-nightly-track.sh -- nightly job: report the upstream state of every
# downstream Singularity patch and, when a patch's PR merged AND the patch
# reverse-applies to upstream head, retire it on a bot branch.
#
# Reads `main`. Never pushes to it: retirements land on
# auto/singularity-reconcile-<date> for a human to merge.
#
# Deploy as a systemd user timer (build/systemd/ncz-singularity-patch-reconcile.*).
# Requires: gh authed as perlowja (read-only PR-state queries). Pushes go to each
# of PUSH_REMOTES that exists (ARGONAS file:// bare repo first, then GitLab via the
# stored credential helper). No ARGONAS ssh login is used, so this
# script holds no secret.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${REPO:-$HOME/Projects/cix-installer}"
BRANCH="${BRANCH:-main}"
FETCH_REMOTE="${FETCH_REMOTE:-argonas}"
PUSH_REMOTES="${PUSH_REMOTES:-argonas origin gitlab}"
BOT_BRANCH="auto/singularity-reconcile-$(date -u +%Y%m%d)"

if [ ! -e "$REPO/.git" ]; then
    echo "[nightly] ERROR: $REPO is not a git checkout -- set REPO=<path>" >&2
    exit 1
fi

cd "$REPO"
echo "=== singularity-nightly-track: $(date -u +%Y-%m-%dT%H:%M:%SZ) (tracking $BRANCH) ==="

git fetch --quiet "$FETCH_REMOTE" "+refs/heads/$BRANCH:refs/remotes/$FETCH_REMOTE/$BRANCH"
git checkout --quiet -B "$BOT_BRANCH" "$FETCH_REMOTE/$BRANCH"

# Run the reconciler from THIS script's own checkout, against $REPO's patches, so the
# checkout above never swaps the code that is executing.
python3 "$SELF_DIR/singularity-patch-reconcile.py" --repo-root "$REPO"

if git diff --quiet -- assets/singularity/patches; then
    echo "[nightly] nothing retired, nothing to commit"
    git checkout --quiet --detach "$FETCH_REMOTE/$BRANCH"
    git branch -D --quiet "$BOT_BRANCH" || true
    exit 0
fi

git add assets/singularity/patches
git commit --quiet -m "$(cat <<'EOF'
chore(singularity): retire patches whose upstream PR merged

Nightly build/singularity-patch-reconcile.py run. Each deleted patch had a
MERGED PR and reverse-applied to upstream head; see the diff for which.
EOF
)"

for r in $PUSH_REMOTES; do
    if git remote get-url "$r" >/dev/null 2>&1; then
        git push --quiet "$r" "$BOT_BRANCH" || echo "[nightly] WARN: push to $r failed"
    fi
done

echo "[nightly] retirements committed on $BOT_BRANCH (not merged into $BRANCH)"
