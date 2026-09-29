#!/bin/bash
# singularity-nightly-track.sh -- nightly job: report the upstream state of every
# downstream Singularity patch and, when a patch's PR merged AND the patch
# reverse-applies to upstream head, retire it on a bot branch.
#
# Reads `main`. Never pushes to it: retirements land on
# auto/singularity-reconcile-<date> for a human to merge.
#
# Deploy as a systemd user timer (build/systemd/ncz-singularity-patch-reconcile.*).
# Requires: gh authed as perlowja (read-only PR-state queries), and git remotes
# `argonas` (file:// bare repo on the mounted ARGONAS share) and `origin`
# (GitLab, stored credential helper). No ARGONAS ssh login is used, so this
# script holds no secret.
set -euo pipefail

REPO="${REPO:-$HOME/Projects/cix-installer}"
BRANCH="${BRANCH:-main}"
ARGONAS_REMOTE="${ARGONAS_REMOTE:-argonas}"
BOT_BRANCH="auto/singularity-reconcile-$(date -u +%Y%m%d)"

if [ ! -d "$REPO/.git" ]; then
    echo "[nightly] ERROR: $REPO is not a git checkout -- set REPO=<path>" >&2
    exit 1
fi

cd "$REPO"
echo "=== singularity-nightly-track: $(date -u +%Y-%m-%dT%H:%M:%SZ) (tracking $BRANCH) ==="

git fetch --quiet origin "$BRANCH"
git checkout --quiet -B "$BOT_BRANCH" "origin/$BRANCH"

python3 build/singularity-patch-reconcile.py

if git diff --quiet -- assets/singularity/patches; then
    echo "[nightly] nothing retired, nothing to commit"
    git checkout --quiet --detach "origin/$BRANCH"
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

if git remote get-url "$ARGONAS_REMOTE" >/dev/null 2>&1; then
    git push "$ARGONAS_REMOTE" "$BOT_BRANCH" \
        || echo "[nightly] WARN: $ARGONAS_REMOTE push failed"
else
    echo "[nightly] WARN: no '$ARGONAS_REMOTE' remote in $REPO, skipping ARGONAS push"
fi
git push origin "$BOT_BRANCH" || echo "[nightly] WARN: gitlab push failed"

echo "[nightly] retirements committed on $BOT_BRANCH (not merged into $BRANCH)"
