#!/bin/bash
# image-ci-run.sh [--execute] [--state FILE] [--json]
#
# Turn image-ci-poll.py's verdicts into build commands. Dry run by default: it
# prints the exact command, host, bridge env and busy-marker path it would use,
# and starts nothing.
#
# Rules this script enforces, all of them testable:
#   * nothing publishes. The command map is checked at startup for publish hooks
#     (reprepro, --publish, r2/) and the script refuses to run if one appears.
#   * one build per host at a time: if the marker for an action exists, that
#     action is skipped with the reason, never started twice.
#   * the state is only advanced (--update-state) AFTER a launch succeeds, so a
#     failed launch does not swallow the trigger.
#   * a trigger with no mapped action is reported, not guessed.
#
# INVOCATION: run it with stdout going to a file or the journal (cron, a timer, a
# shell redirect). Do NOT wrap it in $( ... ): a background job started inside a
# command substitution is torn down when the substitution finishes, so a build
# launched that way dies immediately and the marker would look stale.
#
# Exit: 0 nothing to do or the plan printed, 1 execution attempted and failed,
#       2 bad invocation.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
POLL="$HERE/image-ci-poll.py"
STATE="${NCZ_IMAGE_CI_STATE:-$HOME/.cache/ncz-image-ci/state.json}"
MARKER_DIR="${NCZ_IMAGE_CI_MARKER_DIR:-$HOME/.config/hive-worker/busy.d}"
RUNS_DIR="${NCZ_IMAGE_CI_RUNS:-$HOME/.cache/ncz-image-ci/runs}"
EXECUTE=0
JSON=0

while [ $# -gt 0 ]; do
    case "$1" in
        --execute) EXECUTE=1 ;;
        --json) JSON=1 ;;
        --state) shift; STATE="${1:?--state needs a path}" ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        *) echo "image-ci-run: unknown argument $1" >&2; exit 2 ;;
    esac
    shift
done

[ -f "$POLL" ] || { echo "image-ci-run: missing $POLL" >&2; exit 2; }
mkdir -p "$RUNS_DIR" "$MARKER_DIR" 2>/dev/null

# --- the command map ------------------------------------------------------------------
# One line per trigger: "<trigger>|<arch-pinned? yes/no>|<command>". Kept as data so the
# publish check and the test can read exactly what would run.
host_arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
case "$host_arch" in x86_64) host_arch=amd64 ;; aarch64) host_arch=arm64 ;; esac

# Overrides exist so the test can prove the runner without building anything.
cmd_for() {
    local trig="$1" var
    var="NCZ_IMAGE_CI_CMD_$(echo "$trig" | tr 'a-z-' 'A-Z_')"
    if [ -n "${!var:-}" ]; then printf '%s' "${!var}"; return; fi
    case "$trig" in
        forky-pin)
            printf '%s' "bash $REPO/build/build-image.sh --arch $host_arch --full --sources pinned --substrate pinned --no-publish" ;;
        kernel-stable|kernel-rc)
            printf '%s' "bash $REPO/build/build-kernel-debs.sh --arch $host_arch" ;;
        singularity)
            printf '%s' "bash $REPO/build/build-singularity.sh" ;;
        ncz-debs)
            printf '%s' "bash $REPO/build/build-image.sh --arch $host_arch --full --sources pinned --substrate pinned --no-publish" ;;
        *)
            printf '%s' "" ;;
    esac
}

# --- the publish guard ---------------------------------------------------------------
for trig in forky-pin kernel-stable kernel-rc singularity ncz-debs; do
    c="$(cmd_for "$trig")"
    # Match publish HOOKS, not the string: every legitimate command carries
    # --no-publish, and a naive *publish* test refused all of them.
    bare="${c//--no-publish/}"
    case "$bare" in
        *publish*|*reprepro*|*r2/*|*--publish*)
            echo "image-ci-run: refusing to start: the command for '$trig' publishes ($c)" >&2
            exit 2 ;;
    esac
done

# --- what the poller says ------------------------------------------------------------
plan="$(python3 "$POLL" --state "$STATE" --json 2>/dev/null)" || {
    echo "image-ci-run: the poller failed; nothing started" >&2; exit 1; }

rows="$(printf '%s' "$plan" | python3 -c '
import json,sys
d=json.load(sys.stdin)
for r in d["rows"]:
    print("%s\t%s\t%s" % (r["trigger"], r["verdict"], r["value"].replace("\t"," ")))
')"

if [ "$JSON" = 1 ]; then
    printf '%s' "$plan"
    exit 0
fi

echo "image-ci run ($([ "$EXECUTE" = 1 ] && echo execute || echo dry-run)) host=$host_arch"
echo "state: $STATE"
echo

did=0; skipped=0; failed=0
while IFS=$'\t' read -r trig verdict value; do
    [ -n "$trig" ] || continue
    case "$verdict" in
        *"WOULD TRIGGER"*) ;;
        *) continue ;;
    esac
    cmd="$(cmd_for "$trig")"
    if [ -z "$cmd" ]; then
        printf '%-14s %-28s no mapped action -- reported, not guessed\n' "$trig" "$value"
        skipped=$((skipped + 1)); continue
    fi
    marker="$MARKER_DIR/ncz-image-ci-$trig"
    if [ -e "$marker" ]; then
        mpid="$(tr -dc '0-9' < "$marker" 2>/dev/null)"
        if [ -n "$mpid" ] && kill -0 "$mpid" 2>/dev/null; then
            printf '%-14s %-28s SKIP: a build already holds %s (pid %s alive)\n' \
                "$trig" "$value" "$(basename "$marker")" "$mpid"
            skipped=$((skipped + 1)); continue
        fi
        # A marker whose pid is gone would block this trigger forever. Clear it and say so.
        printf '%-14s %-28s clearing a stale marker (pid %s is not running)\n' \
            "$trig" "$value" "${mpid:-empty}"
        rm -f "$marker"
    fi
    if [ "$EXECUTE" != 1 ]; then
        printf '%-14s %-28s WOULD RUN: %s\n' "$trig" "$value" "$cmd"
        printf '%-14s %-28s            marker %s, run dir %s\n' "" "" "$marker" "$RUNS_DIR"
        did=$((did + 1)); continue
    fi
    # Reserve the marker atomically before launching: checking for the file and then
    # creating it is a race two runners can both win. `set -C` gives O_EXCL.
    # Reserve with our own pid, never an empty file: an empty marker reads as
    # "stale" to another runner, which would then clear a live reservation.
    if ! ( set -C; printf '%s\n' "$$" > "$marker" ) 2>/dev/null; then
        printf '%-14s %-28s SKIP: another runner reserved %s first\n' \
            "$trig" "$value" "$(basename "$marker")"
        skipped=$((skipped + 1)); continue
    fi
    # launch, record, then advance the state
    log="$RUNS_DIR/$trig-$(date -u +%Y%m%dT%H%M%SZ).log"
    # `nohup setsid cmd &` gives a pid that MAY be a wrapper which exits while the
    # build keeps running -- setsid forks when it is already a process-group leader,
    # and then the recorded pid is dead immediately, so the marker looks stale and
    # the next run would start a second build. Background the SUBSHELL instead: it
    # waits for the build, so its pid is alive exactly as long as the build is.
    ( export NCZ_IMAGE_CI_LAUNCHED_BY=image-ci-run
      setsid bash -c "$cmd" > "$log" 2>&1 ) &
    bpid=$!
    printf '%s\n' "$bpid" > "$marker"
    pid="$bpid"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        printf '%-14s %-28s started pid=%s log=%s\n' "$trig" "$value" "$pid" "$log"
        printf '{"trigger":"%s","pid":%s,"value":"%s","command":"%s","log":"%s","started_at":"%s"}\n' \
            "$trig" "$pid" "${value//\"/}" "${cmd//\"/}" "$log" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$RUNS_DIR/launched.jsonl"
        did=$((did + 1))
    else
        rm -f "$marker"
        printf '%-14s %-28s FAILED to start; see %s\n' "$trig" "$value" "$log"
        failed=$((failed + 1))
    fi
done <<< "$rows"

if [ "$did" = 0 ] && [ "$skipped" = 0 ]; then
    echo "nothing to do: no trigger moved"
fi
echo
echo "summary: would-run/started=$did skipped=$skipped failed=$failed"

if [ "$EXECUTE" = 1 ] && [ "$did" -gt 0 ] && [ "$failed" = 0 ]; then
    python3 "$POLL" --state "$STATE" --update-state >/dev/null 2>&1 && echo "state advanced: $STATE"
fi
[ "$failed" = 0 ] || exit 1
exit 0
