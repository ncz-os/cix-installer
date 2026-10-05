#!/bin/bash
# test-singularity-deb-deps.sh — assert the ncz-singularity-desktop .deb
# Depends: covers every runtime soname of the /opt/singularity payload.
#
# Why: the previous Depends: was hand-maintained and silently omitted libraries
# the payload links (Item G report 2026-10-05: libnm0, libinput10, libseat1,
# libxcb-*, ...). A clean install then left singularity-desktop with
# unresolvable DT_NEEDED. The list is now generated from the payload
# (build/gen-singularity-deb-depends.sh) and this test guards it.
#
# Checks:
#   1. every soname->package mapping in build/singularity-runtime-deps.tsv has
#      its package covered by the effective Depends: entries (alternatives
#      "pkgA | pkgB" count as covering either);
#   2. with NCZ_SINGULARITY_PAYLOAD=<extracted /opt/singularity tree>, the
#      payload's DT_NEEDED closure is recomputed and every external soname must
#      exist in the map (catches payload drift the map has not seen).
#
# Usage:
#   build/test-singularity-deb-deps.sh
#   NCZ_SINGULARITY_PAYLOAD=/path/to/opt/singularity build/test-singularity-deb-deps.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEB_SCRIPT="${NCZ_SINGULARITY_DEB_SCRIPT:-$ROOT/build/build-singularity-deb.sh}"
DEPS_FILE="$ROOT/build/singularity-deb-depends.txt"
MAP="$ROOT/build/singularity-runtime-deps.tsv"
PAYLOAD="${NCZ_SINGULARITY_PAYLOAD:-}"

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$DEB_SCRIPT" ] || fail "deb recipe not found: $DEB_SCRIPT"

# Effective Depends: entries. The recipe reads the checked-in file; an older
# recipe (or a copy supplied via NCZ_SINGULARITY_DEB_SCRIPT) carries a literal
# Depends: line instead -- support both so this test can be run against a base
# revision to show the regression it guards.
if grep -q 'singularity-deb-depends.txt' "$DEB_SCRIPT" && [ -f "$DEPS_FILE" ]; then
    deps="$(grep -vE '^[[:space:]]*(#|$)' "$DEPS_FILE")"
else
    dep_line="$(sed -n 's/^Depends: //p' "$DEB_SCRIPT" | head -n1)"
    [ -n "$dep_line" ] || fail "no Depends: found in $DEB_SCRIPT"
    deps="$(printf '%s\n' "$dep_line" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
fi

# Bare package name from a Depends token, dropping any "(>= 1.2.3)" constraint
# and surrounding whitespace. Exact matching must not be defeated by a
# versioned entry such as "libfoo1 (>= 1.2.3)".
bare_pkg() {
    printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
        -e 's/(.*//' -e 's/[[:space:]]*$//'
}

# Is $1 one of the Depends alternatives (ignoring version constraints)?
# Flag-based: never `return` from inside a loop, so it cannot be mistaken for a
# subshell return and the exit status is computed once at the end.
have() {
    local want entry tok found=0
    want="$(bare_pkg "$1")"
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        while IFS= read -r tok; do
            if [ "$(bare_pkg "$tok")" = "$want" ]; then
                found=1
                break
            fi
        done < <(printf '%s\n' "$entry" | tr '|' '\n')
        [ "$found" -eq 1 ] && break
    done <<< "$deps"
    [ "$found" -eq 1 ]
}

[ -f "$MAP" ] || fail "soname map missing: $MAP"

# sonames from the map, comments/empties removed once (not per lookup)
map_sonames="$(grep -vE '^[[:space:]]*(#|$)' "$MAP" | cut -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

missing=0
n=0
while IFS=$'\t' read -r so pkg _source; do
    so="$(printf '%s' "$so" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -n "$so" ] || continue
    case "$so" in \#*) continue ;; esac
    [ -n "$pkg" ] || { echo "FAIL: $so has no package in $MAP" >&2; missing=1; continue; }
    if ! have "$pkg"; then
        echo "FAIL: $so -> $pkg is not covered by Depends in $DEB_SCRIPT" >&2
        missing=1
    fi
    n=$((n + 1))
done < "$MAP"
echo "[test] checked $n soname->package mappings against Depends"

# Optional: recompute the payload's DT_NEEDED closure.
if [ -n "$PAYLOAD" ]; then
    [ -d "$PAYLOAD" ] || fail "NCZ_SINGULARITY_PAYLOAD is not a directory: $PAYLOAD"
    command -v readelf >/dev/null 2>&1 || fail "readelf required for payload check"
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/test-sing-deps.XXXXXX")"
    trap 'rm -rf "$tmp"' EXIT
    : > "$tmp/needed"
    : > "$tmp/provided"
    while IFS= read -r -d '' f; do
        if [ "$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n')" = "7f454c46" ]; then
            readelf -d "$f" 2>/dev/null | awk -F'[][]' '/\(SONAME\)/{print $2}' >> "$tmp/provided"
            readelf -d "$f" 2>/dev/null | awk '/\(NEEDED\)/{print $NF}' | tr -d '[]' >> "$tmp/needed"
        fi
    done < <(find "$PAYLOAD" -type f -print0) || true
    sort -u "$tmp/needed" -o "$tmp/needed"
    sort -u "$tmp/provided" -o "$tmp/provided"
    comm -23 "$tmp/needed" "$tmp/provided" > "$tmp/ext"
    m=0
    while IFS= read -r so; do
        [ -n "$so" ] || continue
        if ! printf '%s\n' "$map_sonames" | grep -qxF "$so"; then
            echo "FAIL: payload soname $so is not in $MAP (regenerate the deps)" >&2
            missing=1
        fi
        m=$((m + 1))
    done < "$tmp/ext"
    echo "[test] recomputed $m external sonames from $PAYLOAD"
fi

[ "$missing" -eq 0 ] || fail "dependency coverage gaps"
echo "PASS: every payload runtime soname maps to a Depends entry"
