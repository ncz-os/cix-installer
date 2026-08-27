#!/bin/bash
# REFERENCE COPY — already run once (2026-07-26, see the sibling
# ncz-reprepro-publish.sh header) against the live copy at
# ARGOS:~/bin/backfill-buildkite-packages.sh. Kept here for the record /
# in case the Buildkite registry ever needs a full re-sync from the reprepro
# pool again (e.g. after a registry reset). Not auto-deployed from this repo.
#
# backfill-buildkite-packages.sh — ONE-TIME script, run on ARGOS.
#
# Buildkite Packages (org=ncz-os, registry=ncz) was the apt-hosting primary
# until 2026-07-06, then abandoned for Cloudflare R2 (auth bug + a
# "Resource limit reached" wall on the plan tier). It was never kept in
# sync after that — every package in it today dates from 2026-06-29 and is
# now stale vs. the current ARGOS reprepro repo (e.g. linux-image-cixmini-edge
# is r98 there, r101 in ~/ncz-apt-repo). Cutting Buildkite back over to
# PRIMARY (2026-07-26 operator directive, full OSS Buildkite privileges now
# granted) without this backfill would mean primary serves OLD kernels on
# day one. This does a one-time full push of every current pool .deb so
# Buildkite starts in sync; ncz-reprepro-publish.sh keeps it in sync for
# every publish going forward.
set -euo pipefail

REPO=/home/jasonperlow/ncz-apt-repo
ENVFILE=/home/jasonperlow/.config/ncz-r2-publish.env
[ -r "$ENVFILE" ] || { echo "FATAL: missing $ENVFILE" >&2; exit 1; }
# shellcheck disable=SC1090
. "$ENVFILE"
: "${BUILDKITE_TOKEN:?}" "${BUILDKITE_ORG:?}" "${BUILDKITE_PKG_REGISTRY:?}"

TOTAL=0
OK=0
FAIL=0
SKIP=0

while IFS= read -r -d '' deb; do
    TOTAL=$((TOTAL + 1))
    name="$(basename "$deb")"
    resp="$(curl -sS -w '\n%{http_code}' -X POST \
        -H "Authorization: Bearer $BUILDKITE_TOKEN" \
        -F "file=@$deb" \
        "https://api.buildkite.com/v2/packages/organizations/$BUILDKITE_ORG/registries/$BUILDKITE_PKG_REGISTRY/packages")"
    code="$(printf '%s' "$resp" | tail -1)"
    body="$(printf '%s' "$resp" | sed '$d')"
    case "$code" in
        200|201)
            OK=$((OK + 1)); echo "OK   $name" ;;
        409)
            SKIP=$((SKIP + 1)); echo "SKIP $name (already present)" ;;
        *)
            FAIL=$((FAIL + 1)); echo "FAIL $name (HTTP $code): $(printf '%s' "$body" | head -c 200)" ;;
    esac
done < <(find "$REPO/pool" -name '*.deb' -print0 | sort -z)

echo ""
echo "== backfill done: $TOTAL total, $OK uploaded, $SKIP already-present, $FAIL failed =="
[ "$FAIL" -eq 0 ] || exit 1
