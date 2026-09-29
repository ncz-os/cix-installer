#!/bin/bash
# Watch upstream for new kernel tags and start the mechanical forward-port.
#
# Two lines are maintained concurrently and they are different KINDS of port:
#
#   stable  (v7.2.x)   maintenance. Small upstream deltas; we expect nearly the
#                      whole series to still apply, so ANY failure is a genuine
#                      upstream conflict that must be read, not a routine chore.
#   rc      (v7.3-rcN) development. Breakage is normal and forward-porting is
#                      the actual work.
#
# This script does the MECHANICAL half only: fetch tags, detect what is new,
# replay the series, and — when patches fail — hand the failures to Codex to
# draft forward-ports in an isolated worktree.
#
# It deliberately does NOT touch the shipping series, does not commit to
# meta-cix, and does not push. A machine may propose a forward-port; a human
# decides whether it ships. The output is a branch plus a report.
#
# Usage:
#   kernel-port-watch.sh              # check both lines, act on new tags
#   kernel-port-watch.sh --line stable|rc
#   kernel-port-watch.sh --tag v7.2.3 # force one tag, ignore the state file
#   kernel-port-watch.sh --dry-run    # report what is new, port nothing
#   kernel-port-watch.sh --no-codex   # replay only, skip the Codex stage
set -uo pipefail

CLONE="${NCZ_KERNEL_CLONE:-$HOME/linux-72}"
INSTALLER="${NCZ_INSTALLER_DIR:-$HOME/isobuild/cix-installer}"
RECIPE_DIR="${NCZ_RECIPE_DIR:-$HOME/yocto-work/meta-cix/recipes-kernel/linux-cix-sky1-ncz}"
STATE="${NCZ_PORT_STATE:-$HOME/.ncz-port-watch.state}"
OUTDIR="${NCZ_PORT_OUTDIR:-$HOME/port-reports}"
CODEX_MODEL="${NCZ_CODEX_MODEL:-gpt-5.5}"
MAINLINE_URL="https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git"
STABLE_URL="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git"

LINE_FILTER=""; FORCE_TAG=""; DRY=0; USE_CODEX=1
while [ $# -gt 0 ]; do
    case "$1" in
        --line)     LINE_FILTER="$2"; shift 2 ;;
        --tag)      FORCE_TAG="$2";   shift 2 ;;
        --dry-run)  DRY=1;            shift ;;
        --no-codex) USE_CODEX=0;      shift ;;
        -h|--help)  sed -n '2,25p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { echo "FATAL: $*" >&2; exit 1; }

[ -d "$CLONE/.git" ]   || die "no kernel clone at $CLONE (set NCZ_KERNEL_CLONE)"
[ -d "$RECIPE_DIR" ]   || die "no recipe dir at $RECIPE_DIR (set NCZ_RECIPE_DIR)"
[ -x "$INSTALLER/build/port-series.sh" ] || die "port-series.sh not found under $INSTALLER"
mkdir -p "$OUTDIR"
touch "$STATE"

# --- remotes -----------------------------------------------------------------
# Stable tags (v7.2.3) live in linux-stable, NOT in torvalds. Both remotes are
# required; a clone of torvalds alone will silently never see a stable release.
git -C "$CLONE" remote get-url stable >/dev/null 2>&1 || {
    log "adding linux-stable remote"
    git -C "$CLONE" remote add stable "$STABLE_URL"
}
git -C "$CLONE" remote get-url origin >/dev/null 2>&1 || \
    git -C "$CLONE" remote add origin "$MAINLINE_URL"

log "fetching tags (origin, stable)"
git -C "$CLONE" fetch --tags --quiet origin  || log "WARN: origin fetch failed"
git -C "$CLONE" fetch --tags --quiet stable  || log "WARN: stable fetch failed"

# --- what is the current base? -----------------------------------------------
# Read it from the recipe rather than assuming, so a recipe bump moves the
# watcher with it instead of leaving it watching a stale series.
BB="$(ls "$RECIPE_DIR"/linux-cix-sky1-ncz_7.2.bb 2>/dev/null | head -1)"
[ -f "$BB" ] || die "recipe not found in $RECIPE_DIR"
BASE_SRCREV="$(grep -oE '^SRCREV_kernel[[:space:]]*=[[:space:]]*"[0-9a-f]{40}"' "$BB" | grep -oE '[0-9a-f]{40}' | head -1)"
BASE_TAG="$(git -C "$CLONE" describe --tags --exact-match "$BASE_SRCREV" 2>/dev/null || echo unknown)"
log "recipe base: SRCREV=${BASE_SRCREV:0:12} tag=$BASE_TAG"

# --- candidate tags ----------------------------------------------------------
# stable: v7.2.N for N>=1, ordered by version
# rc:     v7.3-rcN and any later vX.Y-rcN
stable_tags() { git -C "$CLONE" tag -l 'v7.2.*' | grep -E '^v7\.2\.[0-9]+$' | sort -V; }
rc_tags()     { git -C "$CLONE" tag -l 'v7.3-rc*' 'v7.4-rc*' | grep -E '^v[0-9]+\.[0-9]+-rc[0-9]+$' | sort -V; }

seen() { grep -qxF "$1" "$STATE"; }
mark() { grep -qxF "$1" "$STATE" || echo "$1" >> "$STATE"; }

# --- the port itself ---------------------------------------------------------
port_one() {
    local tag="$1" line="$2"
    local stamp; stamp="$(date -u +%Y%m%d-%H%M%S)"
    local wt="$HOME/linux-port-$tag"
    local report="$OUTDIR/port-$tag-$stamp.md"
    local faillog="/tmp/port-series-$tag.failures"

    log "=== porting $line tag $tag"
    local out rc
    out="$(NCZ_KERNEL_CLONE="$CLONE" NCZ_RECIPE_DIR="$RECIPE_DIR" \
           "$INSTALLER/build/port-series.sh" "$tag" "$wt" 2>&1)"; rc=$?

    local applied failed total
    applied="$(sed -n 's/.*RESULT for .*: \([0-9]*\) applied.*/\1/p' <<<"$out" | tail -1)"
    failed="$(sed -n  's/.*RESULT for .*: [0-9]* applied, \([0-9]*\) failed.*/\1/p' <<<"$out" | tail -1)"
    total="$(sed -n   's/.*RESULT for .*(of \([0-9]*\)).*/\1/p' <<<"$out" | tail -1)"
    : "${applied:=0}" "${failed:=?}" "${total:=?}"

    {
        echo "# Kernel port replay — $tag ($line)"
        echo
        echo "- generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "- base in recipe: $BASE_TAG (${BASE_SRCREV:0:12})"
        echo "- target: $tag = $(git -C "$CLONE" rev-parse "$tag^{commit}" 2>/dev/null)"
        echo "- result: **$applied applied, $failed failed** of $total wired"
        echo "- worktree: \`$wt\`"
        echo
        if [ "$line" = stable ] && [ "${failed:-0}" != 0 ]; then
            echo "> Stable line. A failure here is an upstream conflict on a point"
            echo "> release, not routine churn — read it before forward-porting."
            echo
        fi
        if [ -s "$faillog" ]; then
            echo "## Failed patches"; echo; echo '```'; cat "$faillog"; echo '```'; echo
        fi
        echo "## Replay output"; echo; echo '```'; echo "$out"; echo '```'
    } > "$report"

    log "result: $applied applied, $failed failed (of $total) -> $report"

    if [ "$USE_CODEX" = 1 ] && [ -s "$faillog" ]; then
        codex_stage "$tag" "$line" "$wt" "$faillog" "$report"
    fi

    # Only mark a tag seen once it has been through the whole pipeline, so a
    # crash mid-run retries the tag next time instead of skipping it forever.
    mark "$tag"
    return 0
}

codex_stage() {
    local tag="$1" line="$2" wt="$3" faillog="$4" report="$5"
    command -v codex >/dev/null || { log "codex not in PATH — skipping draft stage"; return 0; }

    local nfail; nfail="$(grep -c . "$faillog")"
    log "dispatching codex for $nfail failed patch(es) on $tag"

    local brief="/tmp/codex-port-$tag.txt"
    cat > "$brief" <<BRIEF
Forward-port a Yocto kernel patch series onto a new upstream tag.

Repository worktree: $wt   (already checked out at upstream tag $tag)
Patch series lives in: $RECIPE_DIR/linux-cix-sky1-ncz-7.2/patches-7.2/
Line: $line ($([ "$line" = stable ] && echo "point release — expect small deltas; a conflict here is a real upstream change" || echo "development rc — breakage is expected"))

These patches from our series FAILED to apply with 'git am -3' onto $tag:

$(cat "$faillog")

For EACH failed patch, in order:
  1. Read the patch and identify the upstream file and hunks it targets.
  2. Check whether upstream has ALREADY taken the change at $tag. If the hunk
     is present, the patch is OBSOLETE — say so explicitly and propose dropping
     it from SRC_URI. Do NOT re-apply a change upstream already has.
  3. Otherwise rewrite the patch against the code as it now exists at $tag,
     preserving the original intent and commit message, and apply it in the
     worktree so the following patches can build on it.
  4. If a patch cannot be resolved mechanically because the upstream design
     changed, STOP on that patch and explain what changed and what the options
     are. Do not invent a fix you cannot justify from the code in front of you.

Rules:
  - Work ONLY inside $wt. Do not modify $RECIPE_DIR, do not touch the shipping
    series, do not commit to meta-cix, and do not push anything anywhere.
  - Write each resulting patch to $wt/ported-patches/ using the original
    filename, so a human can diff old vs new.
  - Quote the exact upstream lines you relied on for each decision. An
    unsupported claim that a patch is obsolete is worse than leaving it failing.

Finish with a summary table: patch | verdict (ported / obsolete / blocked) | why.
BRIEF

    mkdir -p "$wt/ported-patches"
    local clog="$OUTDIR/codex-$tag.log"
    if (cd "$wt" && codex exec --skip-git-repo-check -m "$CODEX_MODEL" \
            --sandbox workspace-write "$(cat "$brief")" </dev/null) > "$clog" 2>&1; then
        log "codex finished -> $clog"
    else
        log "codex exited non-zero -> $clog"
    fi

    {
        echo
        echo "## Codex forward-port draft"
        echo
        echo "Model: $CODEX_MODEL. Log: \`$clog\`"
        echo "Drafts (NOT applied to the shipping series): \`$wt/ported-patches/\`"
        echo
        echo '```'
        tail -80 "$clog" 2>/dev/null
        echo '```'
    } >> "$report"
}

# --- main --------------------------------------------------------------------
NEW=0
run_line() {
    local line="$1"; shift
    local t
    for t in $("${line}_tags"); do
        [ -n "$FORCE_TAG" ] && [ "$t" != "$FORCE_TAG" ] && continue
        if [ -z "$FORCE_TAG" ] && seen "$t"; then continue; fi
        NEW=$((NEW+1))
        if [ "$DRY" = 1 ]; then log "NEW ($line): $t"; continue; fi
        port_one "$t" "$line"
    done
}

case "$LINE_FILTER" in
    stable) run_line stable ;;
    rc)     run_line rc ;;
    "")     run_line stable; run_line rc ;;
    *) die "unknown line: $LINE_FILTER (want stable|rc)" ;;
esac

[ "$NEW" = 0 ] && log "no new tags on $([ -n "$LINE_FILTER" ] && echo "$LINE_FILTER" || echo "either line")"
log "done. reports in $OUTDIR"
