#!/bin/bash
# run-hourly.sh -- one scheduled GitHub sync pass (systemd timer or cron).
#
#   1. check-github-sync.sh   state before (report only)
#   2. sync-github-mirror.sh  dry run: fetch, build the copies, plan
#   3. sync-github-mirror.sh  --apply --prune: creates, fast-forwards, and the
#                             rewinds/removals GitLab itself made (lease-pinned,
#                             GitHub values pinned in the backup repository
#                             first). Commits made on GitHub and GitHub-only refs
#                             are never overwritten here (they need a manual
#                             --allow-force / --prune-github-only run), and refs
#                             with a GitHub release are never moved.
#   4. check-github-sync.sh   state after; its exit code is the run's result
#
# Settings come from the NCZ_GHSYNC_* variables (see tools/github-sync/ghsync.py),
# typically from an EnvironmentFile. Logs go to $NCZ_GHSYNC_WORKDIR/logs and are
# kept for 7 days. A second run while one is active exits 0 at once. Extra
# arguments (e.g. --repo NAME, --repos FILE) are passed to every tool call.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
TOOLS="$(cd "$HERE/.." && pwd)"
WD="${NCZ_GHSYNC_WORKDIR:?NCZ_GHSYNC_WORKDIR not set}"
LOGS="$WD/logs"
mkdir -p "$LOGS"
exec 9>"$WD/.run.lock"
flock -n 9 || { echo "run-hourly: another run is active"; exit 0; }

T="$(date -u +%Y%m%dT%H%M%SZ)"
"$TOOLS/check-github-sync.sh" "$@" --report "$LOGS/$T-check-before.tsv" >"$LOGS/$T-check-before.log" 2>&1
"$TOOLS/sync-github-mirror.sh" "$@" --report "$LOGS/$T-plan.json" >"$LOGS/$T-plan.log" 2>&1
plan_rc=$?
if [ "$plan_rc" -eq 2 ]; then
    echo "run-hourly: dry run failed (setup error), nothing applied; see $LOGS/$T-plan.log"
    exit 2
fi
"$TOOLS/sync-github-mirror.sh" "$@" --apply --prune --report "$LOGS/$T-apply.json" \
    >"$LOGS/$T-apply.log" 2>&1
apply_rc=$?
"$TOOLS/check-github-sync.sh" "$@" --report "$LOGS/$T-check-after.tsv" >"$LOGS/$T-check-after.log" 2>&1
check_rc=$?
grep -h "(summary)" "$LOGS/$T-check-after.log" || true
find "$LOGS" -type f -mtime +7 -delete 2>/dev/null || true
echo "run-hourly: $T plan=$plan_rc apply=$apply_rc check=$check_rc"
[ "$apply_rc" -eq 0 ] && [ "$check_rc" -eq 0 ]
