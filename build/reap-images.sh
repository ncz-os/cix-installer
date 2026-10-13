#!/bin/bash
# reap-images.sh -- delete NCZ-OS install images that a newer, gated image supersedes (operator policy 2026-09-29).
#
#   reap-images.sh --arch arm64|amd64 --archive DIR --dir DIR [--dir DIR ...] [--remote HOST:DIR ...]
#                  [--workdir GLOB ...] [--supersede NAME ...] [--apply]
#   reap-images.sh --mark-gated IMAGE [--note TEXT]        record that IMAGE passed its KVM gate
#   reap-images.sh --mark-validated IMAGE [--note TEXT]    record that the operator validated IMAGE on hardware
#
# Default is a DRY RUN that prints exactly what --apply would delete. Only the chosen --arch is ever touched.
#
# Image state lives next to the image in sidecar files: NAME.gated (KVM gate PASS) and NAME.validated (operator
# hardware validation: O6N/MS-R1 flashing is operator-only, this script never writes .validated on its own).
#
# Keep (never deleted):
#   1. the newest GATED image of the arch                   -- must have a copy in --archive, else NOTHING is reaped
#   2. the newest VALIDATED image of the arch               -- the known-good fallback until the newest is validated
#   3. any image newer than the newest gated one            -- not gated or not shipped yet
#   4. any image with no .gated marker, unless named with --supersede (pre-marker images the operator has ruled out)
# Never deleted: the only copy of anything, anything of another architecture.
# Reaped: every copy (all --dir / --remote locations) of the other images of the arch, their sidecars, and workdirs
# (--workdir GLOB, e.g. "$HOME/kvm-install-arm64-*", iso-patch/ dirs) whose name embeds a reaped image's build id.
# Each deletion is logged with name, location and sha256 to --archive/reap.log; survivors are printed.
set -uo pipefail
SSH="${SSH:-ssh}"
ARCH=""; ARCHIVE=""; APPLY=0; MODE=reap
DIRS=(); REMOTES=(); WORKDIRS=(); SUPERSEDE=(); NOTE=""; TARGET=""
while [ $# -gt 0 ]; do
    case "$1" in
        --arch) ARCH="$2"; shift 2 ;;
        --archive) ARCHIVE="$2"; shift 2 ;;
        --dir) DIRS+=("$2"); shift 2 ;;
        --remote) REMOTES+=("$2"); shift 2 ;;
        --workdir) WORKDIRS+=("$2"); shift 2 ;;
        --supersede) SUPERSEDE+=("$2"); shift 2 ;;
        --apply) APPLY=1; shift ;;
        --dry-run) APPLY=0; shift ;;
        --mark-gated) MODE=mark-gated; TARGET="$2"; shift 2 ;;
        --mark-validated) MODE=mark-validated; TARGET="$2"; shift 2 ;;
        --note) NOTE="$2"; shift 2 ;;
        *) echo "reap-images: unknown argument $1" >&2; exit 2 ;;
    esac
done
die() { echo "reap-images: $*" >&2; exit 2; }
sha_of() { sha256sum "$1" | cut -d' ' -f1; }

if [ "$MODE" != reap ]; then
    [ -f "$TARGET" ] || die "no such image: $TARGET"
    ext=gated; [ "$MODE" = mark-validated ] && ext=validated
    printf 'name=%s\nsha256=%s\n%s=%s\nnote=%s\n' "$(basename "$TARGET")" "$(sha_of "$TARGET")" "$ext" "$(date -u +%FT%TZ)" "$NOTE" > "$TARGET.$ext"
    echo "reap-images: recorded $TARGET.$ext"
    exit 0
fi

case "$ARCH" in arm64|amd64) ;; *) die "--arch arm64|amd64 is required" ;; esac
[ -n "$ARCHIVE" ] && [ -d "$ARCHIVE" ] || die "--archive DIR (the image archive directory) is required and must exist"
[ ${#DIRS[@]} -gt 0 ] || [ ${#REMOTES[@]} -gt 0 ] || die "give at least one --dir or --remote"

# ---- inventory: one record per copy: LOC|NAME|HAS_GATED|HAS_VALIDATED|MTIME
declare -a REC=()
list_local() {   # dir
    local d="$1" f
    for f in "$d"/ncz-os-"$ARCH"-*.img; do
        [ -f "$f" ] || continue
        REC+=("$d|$(basename "$f")|$([ -f "$f.gated" ] && echo 1 || echo 0)|$([ -f "$f.validated" ] && echo 1 || echo 0)|$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f")")
    done
}
list_remote() {  # host:dir
    local h="${1%%:*}" d="${1#*:}"
    while IFS='|' read -r n g v m; do
        [ -n "$n" ] && REC+=("$1|$n|$g|$v|$m")
    done < <($SSH "$h" "cd '$d' 2>/dev/null && for f in ncz-os-$ARCH-*.img; do [ -f \"\$f\" ] || continue; printf '%s|%s|%s|%s\n' \"\$f\" \"\$([ -f \"\$f.gated\" ] && echo 1 || echo 0)\" \"\$([ -f \"\$f.validated\" ] && echo 1 || echo 0)\" \"\$(stat -c %Y \"\$f\" 2>/dev/null || stat -f %m \"\$f\")\"; done")
}
for d in "${DIRS[@]}"; do list_local "$d"; done
list_local "$ARCHIVE"
for r in "${REMOTES[@]}"; do list_remote "$r"; done
[ ${#REC[@]} -gt 0 ] || { echo "reap-images: no $ARCH images found; nothing to do"; exit 0; }

# ---- per-name facts (any copy having a marker counts)
declare -A GATED=() VALID=() MT=() COPIES=() ARCHIVED=()
for r in "${REC[@]}"; do
    IFS='|' read -r loc name g v m <<<"$r"
    [ "$g" = 1 ] && GATED[$name]=1
    [ "$v" = 1 ] && VALID[$name]=1
    [ -z "${MT[$name]:-}" ] || [ "$m" -gt "${MT[$name]}" ] && MT[$name]=$m
    COPIES[$name]=$(( ${COPIES[$name]:-0} + 1 ))
    [ "$loc" = "$ARCHIVE" ] && ARCHIVED[$name]=1
done
newest() {   # names on stdin -> newest by mtime
    local best="" n
    while read -r n; do [ -n "$n" ] || continue; if [ -z "$best" ] || [ "${MT[$n]}" -gt "${MT[$best]}" ]; then best=$n; fi; done
    echo "$best"
}
NEWEST_GATED="$(for n in "${!GATED[@]}"; do echo "$n"; done | newest)"
NEWEST_VALID="$(for n in "${!VALID[@]}"; do echo "$n"; done | newest)"
[ -n "$NEWEST_GATED" ] || die "no gated $ARCH image exists (mark one with --mark-gated); refusing to reap anything"
[ "${ARCHIVED[$NEWEST_GATED]:-0}" = 1 ] || die "the newest gated image $NEWEST_GATED has no copy in the archive $ARCHIVE; stage it there first (refusing to reap)"

is_super() { local x; for x in "${SUPERSEDE[@]:-}"; do [ "$x" = "$1" ] && return 0; done; return 1; }
declare -A KEEP=() WHY=()
for n in "${!MT[@]}"; do
    if [ "$n" = "$NEWEST_GATED" ]; then KEEP[$n]=1; WHY[$n]="newest gated"
    elif [ -n "$NEWEST_VALID" ] && [ "$n" = "$NEWEST_VALID" ]; then KEEP[$n]=1; WHY[$n]="newest operator-validated (known-good fallback)"
    elif [ "${MT[$n]}" -gt "${MT[$NEWEST_GATED]}" ]; then KEEP[$n]=1; WHY[$n]="newer than the newest gated image (not gated/shipped yet)"
    elif [ "${GATED[$n]:-0}" != 1 ] && ! is_super "$n"; then KEEP[$n]=1; WHY[$n]="no .gated marker and not named with --supersede"
    fi
done
# never reap the only copy of a name that is not superseded; reaping applies to names, so the rule is implicit:
# a reaped name loses all copies, and only names older than a kept gated image qualify.

echo "reap-images: arch=$ARCH archive=$ARCHIVE mode=$([ $APPLY = 1 ] && echo APPLY || echo DRY-RUN)"
echo "KEEP:"
for n in $(printf '%s\n' "${!KEEP[@]}" | sort); do echo "  $n  (${WHY[$n]}, ${COPIES[$n]} copies)"; done
REAP_NAMES=(); for n in $(printf '%s\n' "${!MT[@]}" | sort); do [ -n "${KEEP[$n]:-}" ] || REAP_NAMES+=("$n"); done
echo "REAP:"
[ ${#REAP_NAMES[@]} -gt 0 ] || echo "  (nothing)"

LOG="$ARCHIVE/reap.log"
del_file() {   # loc file
    local loc="$1" f="$2" sha="-" h d
    case "$loc" in
        *:*) h="${loc%%:*}"; d="${loc#*:}"
             sha=$($SSH "$h" "(sha256sum '$d/$f' 2>/dev/null || shasum -a 256 '$d/$f') | cut -d' ' -f1" 2>/dev/null); : "${sha:=unknown}" ;;
        *)   [ -f "$loc/$f" ] && sha=$(sha_of "$loc/$f") ;;
    esac
    echo "  $([ $APPLY = 1 ] && echo DELETE || echo would delete) $loc/$f  sha256=$sha"
    if [ "$APPLY" = 1 ]; then
        printf '%s reaped %s at %s sha256=%s\n' "$(date -u +%FT%TZ)" "$f" "$loc" "$sha" >> "$LOG"
        case "$loc" in
            *:*) $SSH "$h" "rm -f '$d/$f' '$d/$f.gated' '$d/$f.validated' '$d/$f.sha256' '$d/$f.receipt.json'" ;;
            *)   rm -f "$loc/$f" "$loc/$f.gated" "$loc/$f.validated" "$loc/$f.sha256" "$loc/$f.receipt.json" ;;
        esac
    fi
}
declare -a BUILDIDS=()
for n in "${REAP_NAMES[@]}"; do
    id="${n%.img}"; id="${id##*-}"; BUILDIDS+=("$id")
    for r in "${REC[@]}"; do
        IFS='|' read -r loc name g v m <<<"$r"
        [ "$name" = "$n" ] && del_file "$loc" "$name"
    done
done
# leftovers: gate/work directories whose name embeds a reaped build id (never one that embeds a kept one)
for g in "${WORKDIRS[@]:-}"; do
    [ -n "$g" ] || continue
    for w in $g; do
        [ -d "$w" ] || continue
        b=$(basename "$w"); hit=0; kept=0
        for id in "${BUILDIDS[@]:-}"; do [ -n "$id" ] && case "$b" in *"$id"*) hit=1 ;; esac; done
        for n in "${!KEEP[@]}"; do id="${n%.img}"; id="${id##*-}"; case "$b" in *"$id"*) kept=1 ;; esac; done
        if [ "$hit" = 1 ] && [ "$kept" = 0 ]; then
            echo "  $([ $APPLY = 1 ] && echo DELETE || echo would delete) workdir $w"
            if [ "$APPLY" = 1 ]; then printf '%s reaped workdir %s\n' "$(date -u +%FT%TZ)" "$w" >> "$LOG"; chmod -R u+w "$w" 2>/dev/null; rm -rf "$w"; fi
        fi
    done
done
[ "$APPLY" = 1 ] || echo "DRY RUN: nothing deleted. Re-run with --apply to delete."
echo "SURVIVORS: $(printf '%s ' $(printf '%s\n' "${!KEEP[@]}" | sort))"
