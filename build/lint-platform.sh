#!/bin/bash
# lint-platform.sh -- structural enforcement of the COMMON / PLATFORM split.
# Design: docs/PLATFORM-SPLIT-DESIGN.md.  Inventory: docs/platform-inventory.tsv.
#
#   build/lint-platform.sh            run every check, exit 1 on any finding
#   make lint-platform                same
#
# Checks (each finding is printed as `LINT-<id>: ...`):
#   FORMAT    inventory rows are well formed (4 columns, valid class/feature)
#   COVER     every tracked file has an inventory row (exact, or a directory
#             prefix row ending in /; longest prefix wins) and no exact row
#             or prefix row is stale
#   HOOKS     every post-install/NN-*.sh has its OWN exact inventory row; the
#             generated hooks.list.<platform> files are current
#             (build/gen-hooks-lists.sh --check); each platform list holds
#             exactly the common+mixed+own-class hooks and only existing files
#   DENY      COMMON hooks contain no platform token from
#             build/platform-deny-patterns.txt (non-comment lines) unless the
#             (hook, pattern id) pair is a reviewed row in
#             docs/platform-deny-exceptions.tsv; stale exceptions also fail
#   GUARD     sky1/amd64 hooks carry the NCZ-PLATFORM-GUARD early-exit block;
#             mixed hooks carry an NCZ-MIXED-HOOK marker naming what is
#             platform-specific (the TODO for the phase C split)
#
# NCZ_LINT_ROOT overrides the repository root (used by the unit tests).
# Needs bash >= 4 (associative arrays); runs on the Linux build hosts.
set -uo pipefail

if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
    echo "lint-platform: bash >= 4 required" >&2
    exit 2
fi

ROOT="${NCZ_LINT_ROOT:-$(git -C "$(dirname "$0")" rev-parse --show-toplevel)}"
INV="$ROOT/docs/platform-inventory.tsv"
DENY="$ROOT/build/platform-deny-patterns.txt"
DENY_EXC="$ROOT/docs/platform-deny-exceptions.tsv"
MAN_DIV="$ROOT/docs/manifest-divergence.tsv"
HOOKDIR="$ROOT/post-install"

FINDINGS=0
fail() { echo "LINT-$1: $2"; FINDINGS=$((FINDINGS + 1)); }

[ -f "$INV" ] || { echo "LINT-FORMAT: missing $INV"; exit 1; }

list_files() {
    if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
       && [ "$(git -C "$ROOT" rev-parse --show-toplevel)" = "$(cd "$ROOT" && pwd -P)" ]; then
        git -C "$ROOT" ls-files --cached --others --exclude-standard
    else
        (cd "$ROOT" && find . -type f -not -path './.git/*' | sed 's#^\./##')
    fi | LC_ALL=C sort
}

# ---------------------------------------------------------------- FORMAT
declare -A CLS FEAT
PREFIXES=()
while IFS=$'\t' read -r p c f r extra; do
    case "$p" in ''|'#'*) continue ;; esac
    if [ -z "$r" ] || [ -n "${extra:-}" ]; then fail FORMAT "row needs exactly 4 tab-separated columns: $p"; continue; fi
    case "$c" in common|sky1|amd64|mixed) ;; *) fail FORMAT "bad class '$c' for $p"; continue ;; esac
    if [ "$f" != "-" ]; then
        IFS=',' read -ra _fs <<< "$f"
        for x in "${_fs[@]}"; do
            case "$x" in t2|nvidia-cuda) ;; *) fail FORMAT "bad feature '$x' for $p" ;; esac
        done
        case "$c" in amd64|mixed|common) ;; *) fail FORMAT "feature on a $c row: $p" ;; esac
    fi
    if [ -n "${CLS[$p]+x}" ]; then fail FORMAT "duplicate row: $p"; continue; fi
    CLS[$p]="$c"; FEAT[$p]="$f"
    case "$p" in */) PREFIXES+=("$p") ;; esac
done < "$INV"

# classify PATH -> sets REPLY_CLASS and REPLY_ROW ("" if uncovered)
classify() {
    local path="$1" best="" pre
    REPLY_CLASS=""; REPLY_ROW=""
    if [ -n "${CLS[$path]+x}" ] && [[ "$path" != */ ]]; then
        REPLY_CLASS="${CLS[$path]}"; REPLY_ROW="$path"; return 0
    fi
    for pre in "${PREFIXES[@]}"; do
        case "$path" in "$pre"*) [ "${#pre}" -gt "${#best}" ] && best="$pre" ;; esac
    done
    if [ -n "$best" ]; then REPLY_CLASS="${CLS[$best]}"; REPLY_ROW="$best"; return 0; fi
    return 1
}

# ----------------------------------------------------------------- COVER
FILES=$(list_files)
declare -A USED
while IFS= read -r f; do
    [ -n "$f" ] || continue
    if classify "$f"; then USED[$REPLY_ROW]=1; else fail COVER "no inventory row for tracked file: $f"; fi
done <<< "$FILES"
for p in "${!CLS[@]}"; do
    [ -n "${USED[$p]+x}" ] && continue
    case "$p" in
        */) fail COVER "stale prefix row (matches no tracked file): $p" ;;
        *)  fail COVER "stale row (file is not tracked): $p" ;;
    esac
done

# ----------------------------------------------------------------- HOOKS
HOOKS=$(cd "$HOOKDIR" 2>/dev/null && ls [0-9][0-9]-*.sh 2>/dev/null | LC_ALL=C sort || true)
for h in $HOOKS; do
    if [ -z "${CLS[post-install/$h]+x}" ]; then
        fail HOOKS "hook $h has no exact inventory row (a directory prefix is not enough for a hook)"
    fi
done
if [ -x "$ROOT/build/gen-hooks-lists.sh" ]; then
    if ! gen_out=$(NCZ_LINT_ROOT="$ROOT" "$ROOT/build/gen-hooks-lists.sh" --check 2>&1); then
        printf '%s\n' "$gen_out" | sed 's/^/LINT-HOOKS: /'
        FINDINGS=$((FINDINGS + 1))
    fi
else
    fail HOOKS "build/gen-hooks-lists.sh is missing or not executable"
fi
for plat in sky1-arm64 amd64; do
    case "$plat" in sky1-arm64) own=sky1 ;; amd64) own=amd64 ;; esac
    lst="$HOOKDIR/hooks.list.$plat"
    if [ ! -f "$lst" ]; then fail HOOKS "missing $lst"; continue; fi
    listed=$(grep -vE '^[[:space:]]*(#|$)' "$lst" | awk '{print $1}')
    for l in $listed; do
        [ -f "$HOOKDIR/$l" ] || fail HOOKS "$plat list names $l which does not exist in post-install/"
    done
    for h in $HOOKS; do
        c="${CLS[post-install/$h]:-}"
        [ -n "$c" ] || continue
        want=0
        case "$c" in common|mixed) want=1 ;; "$own") want=1 ;; esac
        have=0; printf '%s\n' "$listed" | grep -qxF -- "$h" && have=1
        if [ "$want" = 1 ] && [ "$have" = 0 ]; then fail HOOKS "$h ($c) must be on the $plat list but is not"; fi
        if [ "$want" = 0 ] && [ "$have" = 1 ]; then fail HOOKS "$h ($c) must NOT be on the $plat list"; fi
    done
done

# ------------------------------------------------------------------ DENY
declare -A EXC EXC_USED
if [ -f "$DENY_EXC" ]; then
    while IFS=$'\t' read -r h id why; do
        case "$h" in ''|'#'*) continue ;; esac
        [ -n "$why" ] || { fail DENY "exception row needs a reason: $h $id"; continue; }
        EXC["$h|$id"]=1
    done < "$DENY_EXC"
fi
if [ -f "$DENY" ]; then
    for h in $HOOKS; do
        [ "${CLS[post-install/$h]:-}" = common ] || continue
        # non-comment lines, with the installer's own directory name removed
        body=$(grep -vE '^[[:space:]]*#' "$HOOKDIR/$h" | sed -E 's/cix-install(er)?//Ig')
        while IFS=$'\t' read -r id plat re; do
            case "$id" in ''|'#'*) continue ;; esac
            line=$(printf '%s\n' "$body" | grep -iEm1 -- "$re" || true)
            [ -n "$line" ] || continue
            if [ -n "${EXC[$h|$id]+x}" ]; then EXC_USED["$h|$id"]=1; continue; fi
            fail DENY "COMMON hook $h contains a $plat token [$id]: $(printf '%s' "$line" | cut -c1-100)"
        done < "$DENY"
    done
    for k in "${!EXC[@]}"; do
        [ -n "${EXC_USED[$k]+x}" ] || fail DENY "stale exception (no longer matches): ${k/|/ }"
    done
else
    fail DENY "missing $DENY"
fi

# ----------------------------------------------------------------- GUARD
for h in $HOOKS; do
    c="${CLS[post-install/$h]:-}"
    case "$c" in
        sky1|amd64)
            { { grep -q 'NCZ-PLATFORM-GUARD' "$HOOKDIR/$h" && grep -qE '^[[:space:]]*case "\$_ncz_pg_arch" in' "$HOOKDIR/$h"; } \
              || { grep -q 'ARCH GATE (dual-arch parity)' "$HOOKDIR/$h" && grep -qE 'exit 0' "$HOOKDIR/$h"; }; } \
                || fail GUARD "$c hook $h has no NCZ-PLATFORM-GUARD (or release-branch ARCH GATE) early-exit block" ;;
        mixed)
            grep -q 'NCZ-MIXED-HOOK' "$HOOKDIR/$h" \
                || fail GUARD "mixed hook $h has no NCZ-MIXED-HOOK marker" ;;
    esac
done

# Manifest divergence is enforced by build/verify-dual-arch-parity.sh (make parity),
# the single implementation; its allowlist is build/arch-parity-allowlist.tsv.

if [ "$FINDINGS" -gt 0 ]; then
    echo "lint-platform: $FINDINGS finding(s)" >&2
    exit 1
fi

# Phase 2: the component registry is enforcing. Skip when the checker is
# absent (unit tests point NCZ_LINT_ROOT at a fixture that has no registry).
if [ -f "$ROOT/build/components.py" ] && [ -f "$ROOT/manifests/components.tsv" ]; then
    python3 "$ROOT/build/components.py" --root "$ROOT" check --gate \
        || { echo "lint-platform: components.py check --gate failed" >&2; exit 1; }
fi
# Phase 3: the seed files, the NCZ_LOCAL_DEBS block and the parity allowlist
# must still match the registry. A hand-edit that the generator would reject
# fails the lint. Skip when the generator is absent (unit-test fixtures).
if [ -f "$ROOT/build/gen-components-registry.py" ] && [ -f "$ROOT/manifests/components.tsv" ]; then
    python3 "$ROOT/build/gen-components-registry.py" --root "$ROOT" \
        --render-seeds --render-local-debs --render-allowlist --check \
        || { echo "lint-platform: registry generators drifted" >&2; exit 1; }
fi

echo "lint-platform: OK ($(printf '%s\n' "$HOOKS" | grep -c .) hooks, $(printf '%s\n' "$FILES" | grep -c .) files classified)"
