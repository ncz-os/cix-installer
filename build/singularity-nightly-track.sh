#!/bin/bash
# singularity-nightly-track.sh — nightly job: pull cix-installer, retire any
# downstream Singularity patch whose PR merged upstream, commit+push if
# anything changed. Companion to preflight-freshness-gate.sh's check #2
# (which only proves a patch STILL APPLIES, not that it's still NEEDED --
# singularity-patch-reconcile.py's `gh pr view` check is the real signal).
#
# WHY A SEPARATE NIGHTLY JOB, NOT JUST THE PREFLIGHT GATE: the gate runs at
# build time and only WARNS/FAILS on a stale patch -- it never mutates the
# tree. Auto-retiring needs to happen independent of whether a build is
# about to run, so a merged PR's patch doesn't sit there stale for days
# until the next real image build happens to notice.
#
# Deploy as a systemd user timer (same cadence class as the existing
# ncz-singularity-sync job @ 03:15):
#   ~/.config/systemd/user/ncz-singularity-patch-reconcile.service
#   ~/.config/systemd/user/ncz-singularity-patch-reconcile.timer
# `systemctl --user enable --now ncz-singularity-patch-reconcile.timer`
#
# Requires: gh authed (read-only PR-state queries). The ssh command used for
# every git op against the store's origin comes from NCZ_STORE_SSH_COMMAND or
# ~/.config/ncz/store-ssh-command (e.g. a password-auth sshpass wrapper) -- a plain pubkey ssh from inside a systemd user service hit real "Too many
# authentication failures" on 2026-09-21 even though the same pubkey works
# fine from an interactive shell on the same host, because the service has
# no ssh-agent).
set -euo pipefail

REPO="${REPO:-$HOME/Projects/cix-installer}"
BRANCH="${BRANCH:-wip/mkosi-pipeline-2026-09-14}"

if [ ! -d "$REPO/.git" ]; then
    echo "[nightly] ERROR: $REPO is not a git checkout -- set REPO=<path>" >&2
    exit 1
fi

cd "$REPO"
echo "=== singularity-nightly-track: $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

# Pubkey exhaustion against the store's git host (SSH offers too many keys
# before the server's attempt limit) is a real,
# recurring, per-host, session-context-dependent failure -- it hit a plain
# `ssh` here even though the SAME pubkey works fine from an interactive
# shell on this exact host, because systemd user services don't carry an
# ssh-agent. Use the site's store ssh command for every git operation in this
# script, not just the final gitlab push.
. "$(cd "$(dirname "$0")" && pwd)/lib/ncz-site.sh"
STORE_SSH="$(ncz_site_value NCZ_STORE_SSH_COMMAND store-ssh-command)"
export GIT_SSH_COMMAND="${STORE_SSH:-ssh -o BatchMode=yes}"

git fetch origin "$BRANCH" --quiet
git checkout --quiet "$BRANCH"
git reset --hard --quiet "origin/$BRANCH"

python3 build/singularity-patch-reconcile.py

if git diff --quiet -- assets/singularity/patches; then
    echo "[nightly] nothing retired, nothing to commit"
    exit 0
fi

git add assets/singularity/patches
git commit --quiet -m "$(cat <<'EOF'
chore(singularity): auto-retire patches for merged upstream PRs

Nightly build/singularity-patch-reconcile.py run -- see the commit diff
for exactly which PR(s) merged and which patch file(s) this removed.
EOF
)"
git push origin "$BRANCH"

# Same store-first-then-gitlab convention as every other push in this
# repo. Push FROM the bare repo behind origin (ssh://[user@]host/path),
# not from this working copy.
ORIGIN_URL="$(git remote get-url origin)"
case "$ORIGIN_URL" in
    ssh://*)
        _hp="${ORIGIN_URL#ssh://}"; ORIGIN_HOST="${_hp%%/*}"; ORIGIN_PATH="/${_hp#*/}"
        $GIT_SSH_COMMAND "$ORIGIN_HOST" "git -C '$ORIGIN_PATH' push gitlab $BRANCH" \
            || echo "[nightly] WARN: gitlab push failed -- origin has the commit, retry gitlab push by hand" ;;
    *) echo "[nightly] WARN: origin is not an ssh:// bare repo; push $BRANCH to gitlab by hand" ;;
esac

echo "[nightly] retired patch(es) committed and pushed"
