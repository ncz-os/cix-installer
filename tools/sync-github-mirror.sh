#!/bin/bash
# sync-github-mirror.sh -- update the GitHub copies of the GitLab projects.
#
# GitLab is canonical. Each GitHub repository gets a deterministic filtered copy
# of the GitLab branches and tags (see tools/github-sync/ghsync.py for what the
# filter does and which site settings it reads). Without --apply nothing is
# pushed: the run fetches, builds the copy and prints the planned ref changes.
#
#   tools/sync-github-mirror.sh [--repo NAME]... [--report plan.json]
#   tools/sync-github-mirror.sh --apply [--allow-force] [--prune] [--repo NAME]...
#
# Non-fast-forward updates are only applied with --allow-force, always pinned
# with --force-with-lease to the GitHub sha seen in the plan, and only after the
# GitHub refs were bundled to the backup directory. Refs that carry a GitHub
# release are never moved or deleted (they show as BLOCKED in the plan).
set -euo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
command -v git-filter-repo >/dev/null 2>&1 || { echo "sync-github-mirror: git-filter-repo not on PATH" >&2; exit 2; }
exec python3 "$HERE/github-sync/ghsync.py" sync "$@"
