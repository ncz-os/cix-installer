#!/bin/bash
# pin-forky-snapshot.sh — bump release.conf's NCZ_BASE_MIRROR_SNAPSHOT to a
# real, currently-valid snapshot.debian.org timestamp for the active suite.
#
# WHY THIS IS A DELIBERATE COMMAND, NOT AN AUTOMATIC NIGHTLY BUMP: forky
# (testing) moves fast enough that auto-advancing the pin on a timer would
# just reintroduce the exact problem pinning exists to prevent -- every image
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
    # Linux build hosts have; BSD date (-j -f) covers a Mac dev check.
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
    # preseed.cfg carries the same snapshot as a SEPARATE hardcoded string, in
    # a different file, with no templating step between them. Checking the age
    # of the pin while the preseed quietly points somewhere else is not a check.
    build/check-preseed-mirror-sync.sh || exit 1

    # AGE IS NOT EXPIRY. The pin 20260920T203924Z was 7 days old -- well
    # inside the 14-day budget, so this check returned 0 -- while its Release
    # file had ALREADY been invalid for nearly five hours, and both arches
    # failed their builds on it that night (see 699183f). forky is testing;
    # its Release carries a Valid-Until far shorter than the age budget, so
    # the age test can never catch this on its own. Ask the archive.
    rel_url="https://snapshot.debian.org/archive/debian/${NCZ_BASE_MIRROR_SNAPSHOT}/dists/${NCZ_BASE_CODENAME}/Release"
    valid_until="$(curl -sfL --max-time 60 "$rel_url" \
        | sed -n 's/^Valid-Until: *//p' | head -1)"
    if [ -z "$valid_until" ]; then
        # A guard that passes when it could not verify is the bug being fixed
        # here, so an unreachable or malformed Release is a FAILURE, not a
        # shrug. If snapshot.debian.org is genuinely down, re-run the check.
        echo "[pin] ERROR: could not read Valid-Until from $rel_url -- refusing to report the pin healthy without checking it" >&2
        exit 1
    fi
    vu_epoch="$(date -u -d "$valid_until" +%s 2>/dev/null \
        || date -u -j -f '%a, %d %b %Y %H:%M:%S %Z' "$valid_until" +%s 2>/dev/null)"
    if [ -z "$vu_epoch" ]; then
        echo "[pin] ERROR: could not parse Valid-Until '$valid_until'" >&2
        exit 1
    fi
    # Warn before it bites: a pin that dies mid-build costs a whole rebuild.
    grace_h="${NCZ_BASE_MIRROR_SNAPSHOT_EXPIRY_GRACE_HOURS:-24}"
    left_h=$(( (vu_epoch - now_epoch) / 3600 ))
    if [ "$left_h" -lt 0 ]; then
        echo "[pin] EXPIRED: Release Valid-Until $valid_until passed $(( -left_h ))h ago -- run build/pin-forky-snapshot.sh" >&2
        exit 1
    fi
    echo "[pin] Release valid for a further ${left_h}h (warn under ${grace_h}h)"
    if [ "$left_h" -lt "$grace_h" ]; then
        echo "[pin] EXPIRING: under ${grace_h}h of validity left -- re-pin before starting a build" >&2
        exit 1
    fi

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
        -o /dev/null -w '%{http_code}' | grep >/dev/null -E '^(200|302)$'; then
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
echo "[pin] bumped: $OLD -> $NEWEST"
# Carry the bump into preseed.cfg's hardcoded mirror block in the same breath.
# Leaving that to a human is how the two drifted apart in the first place.
build/check-preseed-mirror-sync.sh --fix
build/check-preseed-mirror-sync.sh
echo "[pin] release.conf + preseed.cfg both at $NEWEST -- review, test a build, then commit"
