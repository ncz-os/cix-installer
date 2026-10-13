#!/bin/bash
# ncz-singularity-sync.sh — daily sync of singularityos-lab/singularity-desktop
# (+ its submodule set) into our GitLab fork (ncz-os/singularity-desktop),
# validated by a Buildkite arm64 build, with the resulting /opt/singularity
# payload staged (never auto-promoted) to the artifact store.
#
# Design notes (see docs/upstream/singularity/ and cix-installer commit that
# added this file for the full writeup):
#  - Uses a dedicated BARE mirror clone under $WORKDIR, separate from the
#    live build checkout ($HOME/sinty-build/work/singularity-desktop)
#    (that tree may carry local WIP patches and must never be touched by cron).
#  - `upstream-mirror` branch on GitLab is ALWAYS force-updated to the exact
#    upstream commit — it's a robot-owned tracking branch, safe to force.
#  - `master` is updated with `--ff-only` only: if we (or anyone) ever land
#    patch commits directly on GitLab's master ahead of upstream, this push
#    naturally refuses (non-fast-forward) instead of clobbering them. That
#    failure is expected/benign, not an error.
#  - The Buildkite validation build always runs against `upstream-mirror`
#    (the true "does current upstream still build" signal), independent of
#    whether master could be patched.
#  - On a passing build, the artifact is staged to the artifact store with a DATED
#    filename. The file the beta build actually consumes
#    (singularity-opt.tgz) is NEVER overwritten here — promotion is a
#    separate, explicit, human step.
#  - On failure: log only. Never blocks/fails other jobs on this host.
set -uo pipefail

# Captured before anything else runs, so the store staging check below can
# tell "a file from THIS run landed" apart from "some old file is still sitting
# there" -- see the freshness check at step 6 for why this matters.
SYNC_START_EPOCH="$(date +%s)"

# ---- config ------------------------------------------------------------
UPSTREAM_REPO="https://github.com/singularityos-lab/singularity-desktop.git"
WORKDIR="${NCZ_SYNC_WORKDIR:-$HOME/sinty-build/sync/singularity-desktop-mirror.git}"
GITLAB_PROJECT="ncz-os/singularity-desktop"
GITLAB_HOST="gitlab.com"
BUILDKITE_ORG="ncz-os"
BUILDKITE_PIPELINE="singularity-desktop"
# The artifact store target and its password come from $CRED_FILE
# (/etc/ncz/singularity-sync.env): STORE_HOST ([user@]host), STORE_DST (the
# staging directory on it) and STORE_PASS,
# alongside GITLAB_TOKEN and BUILDKITE_TOKEN. It used to be a hardcoded
# literal here, which blocked this script from being committed to git at
# all -- and a script that cannot live in git is a script nobody reviews.
STORE_HOST="${STORE_HOST:-}"; STORE_DST="${STORE_DST:-}"; STORE_PASS="${STORE_PASS:-}"
STATE_DIR="/var/lib/ncz-singularity-sync"
CRED_FILE="/etc/ncz/singularity-sync.env"
LOG_TAG="ncz-singularity-sync"
BUILD_WAIT_MAX_SEC=3600   # give the arm64 native meson build up to 1h
BUILD_POLL_SEC=30

log() { logger -t "$LOG_TAG" -- "$*"; echo "[$LOG_TAG] $*"; }

notify() {
    # Best-effort Telegram notify; silently no-ops if creds absent.
    local msg="$1"
    [ -r "$CRED_FILE" ] || return 0
    # shellcheck disable=SC1090
    . "$CRED_FILE"
    [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ] || return 0
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        --data-urlencode text="[singularity-sync] ${msg}" >/dev/null 2>&1 || true
}

fail() {
    log "FAILED: $*"
    notify "sync FAILED: $*"
    # Failure never blocks anything else on the host — just exit non-zero
    # for this oneshot unit so it shows red in `systemctl status`.
    exit 1
}

[ -r "$CRED_FILE" ] || fail "missing $CRED_FILE (expects GITLAB_TOKEN, BUILDKITE_TOKEN)"
# shellcheck disable=SC1090
. "$CRED_FILE"
[ -n "${GITLAB_TOKEN:-}" ] || fail "GITLAB_TOKEN not set in $CRED_FILE"
[ -n "${BUILDKITE_TOKEN:-}" ] || fail "BUILDKITE_TOKEN not set in $CRED_FILE"
[ -n "${STORE_PASS:-}" ] || fail "STORE_PASS not set in $CRED_FILE"
[ -n "${STORE_HOST:-}" ] && [ -n "${STORE_DST:-}" ] || fail "STORE_HOST / STORE_DST not set in $CRED_FILE"

mkdir -p "$(dirname "$WORKDIR")" "$STATE_DIR"

# ---- 1. fetch upstream --------------------------------------------------
if [ ! -d "$WORKDIR" ]; then
    log "no local mirror yet — cloning $UPSTREAM_REPO"
    git clone --mirror "$UPSTREAM_REPO" "$WORKDIR" || fail "initial mirror clone failed"
fi
cd "$WORKDIR" || fail "cannot cd $WORKDIR"
log "fetching upstream..."
git fetch --prune origin || fail "git fetch origin failed"

UPSTREAM_SHA="$(git rev-parse refs/heads/master 2>/dev/null)"
[ -n "$UPSTREAM_SHA" ] || fail "could not resolve upstream refs/heads/master after fetch"
PREV_SHA="$(cat "$STATE_DIR/last_upstream_sha" 2>/dev/null || true)"
log "upstream master = $UPSTREAM_SHA (previous synced = ${PREV_SHA:-none})"

GITLAB_URL="https://oauth2:${GITLAB_TOKEN}@${GITLAB_HOST}/${GITLAB_PROJECT}.git"

# ---- 2. always force-update the robot-owned tracking branch ------------
log "force-updating GitLab upstream-mirror -> $UPSTREAM_SHA"
git push --force "$GITLAB_URL" "refs/heads/master:refs/heads/upstream-mirror" \
    || fail "push to upstream-mirror failed"
# tags too, best-effort, never fatal
git push "$GITLAB_URL" 'refs/tags/*:refs/tags/*' >/dev/null 2>&1 || true

# ---- 3. best-effort ff-only update of master ----------------------------
# NOTE: git push has no --ff-only option -- that is a merge/pull flag. Passing it
# made git print its usage and exit non-zero on EVERY run, and the else branch
# below then reported that argument error as "likely diverged with local
# patches". The logged "detail" was git's own usage text ("-4, --ipv4 use IPv4
# addresses only"), which is what gave it away. A plain push already refuses a
# non-fast-forward by default, which is exactly the protection that was wanted.
if git push "$GITLAB_URL" "refs/heads/master:refs/heads/master" 2>/tmp/ncz-sync-ffonly.log; then
    log "master fast-forwarded to $UPSTREAM_SHA"
else
    # Distinguish the benign case (a true non-fast-forward: we hold local patches)
    # from a real error, instead of assuming divergence the way the old code did.
    if grep -qE "non-fast-forward|fetch first|rejected" /tmp/ncz-sync-ffonly.log; then
        log "master NOT fast-forwarded (diverged; GitLab master holds commits upstream lacks) — left untouched, this is expected"
    else
        log "WARNING: master push failed for a NON-divergence reason — detail: $(tail -3 /tmp/ncz-sync-ffonly.log | tr '\n' ' ')"
    fi
fi

if [ "$UPSTREAM_SHA" = "$PREV_SHA" ]; then
    log "upstream unchanged since last sync — still running the daily validation build for freshness signal"
fi

# ---- 3b. build a CI-capable mirror branch --------------------------------
#
# upstream-mirror is PURE upstream code, and upstream carries no .buildkite/
# directory -- that is our downstream addition. The pipeline's only step is
# "buildkite-agent pipeline upload", which reads the config out of the checked
# out repo, so a build against upstream-mirror can never configure itself:
#
#   buildkite-agent: fatal: could not find a default pipeline configuration file
#
# Observed on build #59, the first build this script ever managed to trigger.
# Fix: publish upstream-mirror-ci = upstream tree + our .buildkite/ committed
# on top, and validate against that. Still a true "does current upstream build"
# signal -- only the CI recipe is ours, which it has to be.
log "building upstream-mirror-ci (upstream tree + downstream .buildkite/)"
CI_WORK="$(mktemp -d /tmp/ncz-sync-ci.XXXXXX)"
CI_BRANCH="upstream-mirror-ci"
if git clone --quiet --no-checkout "$WORKDIR" "$CI_WORK/repo" 2>/dev/null \
   && git -C "$CI_WORK/repo" checkout --quiet -B "$CI_BRANCH" "$UPSTREAM_SHA" 2>/dev/null; then
    # Take the downstream BUILD TOOLING from OUR fork's master, never from
    # upstream: .buildkite/ (the pipeline), scripts/ (apply-downstream-patches.sh)
    # and patches/ (the vendored series it applies). Overlaying only .buildkite
    # was not enough -- build #62 died with
    #   bash: scripts/apply-downstream-patches.sh: No such file or directory
    # because the pipeline drives that script. Note the patch series failing to
    # apply against newer upstream is a REAL signal, not a flaw in this overlay:
    # it is precisely what a daily upstream build is supposed to detect.
    if git -C "$CI_WORK/repo" fetch --quiet "$GITLAB_URL" "refs/heads/master:refs/remotes/ncz/master" 2>/dev/null \
       && git -C "$CI_WORK/repo" checkout --quiet "refs/remotes/ncz/master" -- .buildkite scripts patches 2>/dev/null; then
        git -C "$CI_WORK/repo" -c user.name="ncz-singularity-sync" \
            -c user.email="nczero@nclawzero.dev" \
            commit --quiet -m "ci: overlay downstream .buildkite on upstream $UPSTREAM_SHA" 2>/dev/null || true
        if git -C "$CI_WORK/repo" push --force --quiet "$GITLAB_URL" "$CI_BRANCH:$CI_BRANCH" 2>/dev/null; then
            BUILD_BRANCH="$CI_BRANCH"
            BUILD_COMMIT="$(git -C "$CI_WORK/repo" rev-parse HEAD)"
            log "upstream-mirror-ci pushed at $BUILD_COMMIT"
        else
            log "WARNING: could not push $CI_BRANCH — falling back to upstream-mirror (build will likely fail on missing pipeline config)"
        fi
    else
        log "WARNING: could not overlay .buildkite from our master — falling back to upstream-mirror"
    fi
else
    log "WARNING: could not prepare $CI_BRANCH worktree — falling back to upstream-mirror"
fi
rm -rf "$CI_WORK"

# ---- 4. trigger a Buildkite validation build ----------------------------
BUILD_BRANCH="${BUILD_BRANCH:-upstream-mirror}"
BUILD_COMMIT="${BUILD_COMMIT:-$UPSTREAM_SHA}"
log "triggering Buildkite build (branch=$BUILD_BRANCH, commit=$BUILD_COMMIT)"
BUILD_JSON="$(curl -sS -H "Authorization: Bearer ${BUILDKITE_TOKEN}" -H "Content-Type: application/json" \
    -X POST "https://api.buildkite.com/v2/organizations/${BUILDKITE_ORG}/pipelines/${BUILDKITE_PIPELINE}/builds" \
    -d "{\"commit\":\"${BUILD_COMMIT}\",\"branch\":\"${BUILD_BRANCH}\",\"message\":\"daily sync $(date -u +%Y-%m-%dT%H:%M:%SZ)\"}")" \
    || fail "buildkite trigger request failed"
BUILD_NUM="$(echo "$BUILD_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("number",""))' 2>/dev/null)"
[ -n "$BUILD_NUM" ] || fail "buildkite trigger did not return a build number: $BUILD_JSON"
log "buildkite build #$BUILD_NUM scheduled: https://buildkite.com/${BUILDKITE_ORG}/${BUILDKITE_PIPELINE}/builds/${BUILD_NUM}"

# ---- 5. poll for completion ---------------------------------------------
ELAPSED=0
STATE="scheduled"
while [ "$ELAPSED" -lt "$BUILD_WAIT_MAX_SEC" ]; do
    sleep "$BUILD_POLL_SEC"
    ELAPSED=$((ELAPSED + BUILD_POLL_SEC))
    STATE="$(curl -sS -H "Authorization: Bearer ${BUILDKITE_TOKEN}" \
        "https://api.buildkite.com/v2/organizations/${BUILDKITE_ORG}/pipelines/${BUILDKITE_PIPELINE}/builds/${BUILD_NUM}" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin).get("state",""))' 2>/dev/null)"
    case "$STATE" in
        passed|failed|canceled|not_run|blocked) break ;;
    esac
done

log "buildkite build #$BUILD_NUM finished with state=$STATE (waited ${ELAPSED}s)"

if [ "$STATE" != "passed" ]; then
    fail "buildkite build #$BUILD_NUM did not pass (state=$STATE) — see https://buildkite.com/${BUILDKITE_ORG}/${BUILDKITE_PIPELINE}/builds/${BUILD_NUM} — NOT staging an artifact, NOT touching the store"
fi

echo "$UPSTREAM_SHA" > "$STATE_DIR/last_upstream_sha"

# ---- 6. stage the artifact to the store (dated, non-destructive) ---------
DATE_TAG="$(date -u +%Y%m%d-%H%M%S)"
STAGE_NAME="singularity-opt-${DATE_TAG}-${UPSTREAM_SHA:0:12}.tgz"
TMP_ART="/tmp/${STAGE_NAME}"

# The PIPELINE now stages the payload to the store itself, straight from the
# arm64 build agent. This script no longer downloads anything, because Buildkite's
# artifact download is unusable from our network: the API 302s to
# buildkiteartifacts.com, which resolves to 0.0.0.0 even on public resolvers
# (1.1.1.1), so curl dies in 2ms with "Could not connect to server". Verified
# on build #65.
#
# What remains here is VERIFICATION: confirm a dated payload actually landed
# for this build, rather than assuming the pipeline's staging step worked.
log "verifying the pipeline staged a NEW payload to the store (not just an old one still sitting there)"
# BUG FOUND 2026-09-14: this used to be `ls -t ... | head -1` -- the single
# most-recently-modified file matching the glob, full stop. If the pipeline's
# own scp step silently failed (it did, for over a week: the new arm64 buildkite
# agent key was never authorized on the store after the arm64 queue moved
# hosts), `ls -t` still happily returned whatever OLD file happened to be
# newest among the leftovers and this script logged "OK: ... payload staged"
# every single run. The build kept reporting success, ncz-singularity-desktop
# went 7+ days without a real rebuild, and nothing here ever said so. `ls -t`
# proves recency relative to OTHER staged files, not relative to THIS run --
# only a comparison against SYNC_START_EPOCH (captured before the build was
# even triggered) proves that.
STAGED_LS="$(SSHPASS="$STORE_PASS" sshpass -e ssh -o PubkeyAuthentication=no \
    -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 \
    "${STORE_HOST}" "ls -t ${STORE_DST}/staged/singularity-opt-*.tgz 2>/dev/null | head -1")" || true
if [ -z "$STAGED_LS" ]; then
    fail "no staged payload found in ${STORE_DST}/staged after a PASSING build #$BUILD_NUM -- the pipeline's staging step did not deliver"
fi
STAGED_MTIME="$(SSHPASS="$STORE_PASS" sshpass -e ssh -o PubkeyAuthentication=no \
    -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 \
    "${STORE_HOST}" "stat -c %Y '$STAGED_LS' 2>/dev/null")" || STAGED_MTIME=0
case "$STAGED_MTIME" in ''|*[!0-9]*) STAGED_MTIME=0 ;; esac
if [ "$STAGED_MTIME" -le "$SYNC_START_EPOCH" ]; then
    fail "newest staged payload $STAGED_LS predates this sync run (mtime=$STAGED_MTIME, run started=$SYNC_START_EPOCH) -- the pipeline's staging step did NOT deliver a new file this time, even though the build passed; check the buildkite job's own 'stage the payload' step and the arm64 agent's SSH trust to the store (this exact failure mode: 2026-09-14, key never re-authorized after the arm64 queue moved hosts)"
fi
STAGED_SIZE="$(SSHPASS="$STORE_PASS" sshpass -e ssh -o PubkeyAuthentication=no \
    -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 \
    "${STORE_HOST}" "stat -c %s '$STAGED_LS' 2>/dev/null")" || STAGED_SIZE=0
case "$STAGED_SIZE" in ''|*[!0-9]*) STAGED_SIZE=0 ;; esac
if [ "$STAGED_SIZE" -lt 1000000 ]; then
    fail "staged payload $STAGED_LS is only ${STAGED_SIZE} bytes -- refusing to call that a good build artifact"
fi
echo "$UPSTREAM_SHA" > "$STATE_DIR/last_upstream_sha"
log "OK: upstream ${UPSTREAM_SHA} builds, payload staged at $STAGED_LS (${STAGED_SIZE} bytes). Promotion to singularity-opt.tgz remains a manual/explicit step."
notify "sync OK — upstream=${UPSTREAM_SHA:0:12}, build #$BUILD_NUM passed, staged $(basename "$STAGED_LS")"
exit 0
