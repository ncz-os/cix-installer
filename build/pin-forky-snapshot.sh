#!/bin/bash
# pin-forky-snapshot.sh — bump release.conf's NCZ_BASE_MIRROR_SNAPSHOT to a
# real, currently-valid snapshot.debian.org timestamp for the active suite.
#
# WHY THIS IS A DELIBERATE COMMAND, NOT AN AUTOMATIC NIGHTLY BUMP: forky
# (testing) moves fast enough that auto-advancing the pin on a timer would
# just reintroduce the exact problem pinning exists to prevent -- every ISO
# built between two auto-bumps would still be reproducible with itself, but
# nobody would have decided "yes, this newer snapshot is what we want to
# ship" the way they decide for a kernel promotion. Bump this by hand when
# you actually want to move forward, same as promoting a new kernel line.
#
# Usage: build/pin-forky-snapshot.sh [--check]
#   (no args)  fetch the newest available snapshot, verify it serves the
#              active suite, rewrite release.conf, print old -> new.
#   --check    print the current pin's age in days and exit 0/1 (1 = older
#              than NCZ_BASE_MIRROR_SNAPSHOT_MAX_AGE_DAYS). No writes.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
# shellcheck source=../release.conf
. release.conf

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

if [ -z "${NCZ_BASE_MIRROR_SNAPSHOT:-}" ]; then
    echo "[pin] release.conf has no NCZ_BASE_MIRROR_SNAPSHOT set -- not pinned, nothing to check/bump" >&2
    exit 1
fi

pin_epoch() {
    # NCZ_BASE_MIRROR_SNAPSHOT is YYYYMMDDTHHMMSSZ. GNU date (-d) is what the
    # fleet's Linux build hosts have; BSD date (-j -f) covers a Mac dev check.
    # (`local a=$1 b=${a}` expands both RHS as command-line args to `local`
    # BEFORE either assignment happens, so `b` can't see `a` -- two statements.)
    local ts="$1"
    local iso="${ts:0:4}-${ts:4:2}-${ts:6:2}T${ts:9:2}:${ts:11:2}:${ts:13:2}Z"
    date -u -d "$iso" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s
}

if [ "$CHECK_ONLY" -eq 1 ]; then
    now_epoch="$(date -u +%s)"
    age_days=$(( (now_epoch - $(pin_epoch "$NCZ_BASE_MIRROR_SNAPSHOT")) / 86400 ))
    max_days="${NCZ_BASE_MIRROR_SNAPSHOT_MAX_AGE_DAYS:-14}"
    echo "[pin] current: $NCZ_BASE_MIRROR_SNAPSHOT (${age_days}d old, max ${max_days}d)"
    [ "$age_days" -le "$max_days" ]
    exit $?
fi

echo "[pin] current pin: $NCZ_BASE_MIRROR_SNAPSHOT"

YEAR="$(date -u +%Y)"
MONTH="$(date -u +%-m)"
NEWEST="$(curl -sf "https://snapshot.debian.org/archive/debian/?year=${YEAR}&month=${MONTH}" \
    | grep -oE '[0-9]{8}T[0-9]{6}Z' | sort -u | tail -1)"
[ -n "$NEWEST" ] || { echo "[pin] ERROR: could not find any snapshot timestamp for ${YEAR}-${MONTH}" >&2; exit 1; }

echo "[pin] newest available: $NEWEST -- verifying it serves suite '$NCZ_BASE_CODENAME'..."
if ! curl -sfI "https://snapshot.debian.org/archive/debian/${NEWEST}/dists/${NCZ_BASE_CODENAME}/Release" \
        -o /dev/null -w '%{http_code}' | grep -qE '^(200|302)$'; then
    echo "[pin] ERROR: $NEWEST does not serve dists/$NCZ_BASE_CODENAME/Release -- refusing to pin a broken snapshot" >&2
    exit 1
fi

if [ "$NEWEST" = "$NCZ_BASE_MIRROR_SNAPSHOT" ]; then
    echo "[pin] already at the newest available snapshot -- nothing to do"
    exit 0
fi

OLD="$NCZ_BASE_MIRROR_SNAPSHOT"
sed -i.bak "s/^NCZ_BASE_MIRROR_SNAPSHOT=\"[^\"]*\"/NCZ_BASE_MIRROR_SNAPSHOT=\"$NEWEST\"/" release.conf
rm -f release.conf.bak
echo "[pin] bumped: $OLD -> $NEWEST -- review, test a build, then commit"
