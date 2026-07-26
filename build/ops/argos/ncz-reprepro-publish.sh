#!/bin/bash
# REFERENCE COPY — the live, authoritative copy of this script runs on ARGOS
# at ~/bin/ncz-reprepro-publish.sh (root of the forced SSH command= in
# jasonperlow's ~/.ssh/authorized_keys for the buildkite-agent@cixmini deploy
# key). It is NOT auto-deployed from this repo — this copy exists so the
# logic isn't stranded off-git (directive: no stranded code); to change the
# live behavior, edit it on ARGOS directly and update this copy to match.
# Depends on ARGOS ~/.config/ncz-r2-publish.env (R2 + Buildkite credentials,
# not present in this repo — provisioned by hand, 600 perms).
#
# ncz-reprepro-publish.sh — restricted-command target for the buildkite-agent
# SSH deploy key (cixmini). Reads a single .deb on stdin, includes it into the
# NCZ-OS reprepro repo (~/ncz-apt-repo, codename "any"), then dual-publishes
# it to BOTH apt-hosting backends:
#   1. Buildkite Packages (org=ncz-os, registry=ncz) — PRIMARY as of
#      2026-07-26 (operator directive: reverses the 2026-07-06 R2 migration
#      now that the org has full OSS/open-source Buildkite privileges —
#      verified empirically same day that anonymous apt-style access
#      (InRelease/Release/Packages + an actual .deb blob) all work with no
#      "Resource limit reached" wall, which is what forced the original
#      move off Buildkite). Published via the Packages API
#      (`POST /v2/packages/organizations/{org}/registries/{registry}/packages`,
#      multipart `file=`) — Buildkite Packages is a managed registry, not a
#      flat-file tree reprepro can write to directly, and it signs releases
#      with ITS OWN auto-generated GPG key (not our `E45A5E1E593D4144`), so
#      clients need `post-install/buildkite-ncz-apt-keyring.asc` to trust it,
#      not the NCZ-OS reprepro keyring.
#   2. Cloudflare R2 bucket `ncz-apt` — SECONDARY/backup (was primary
#      2026-07-06 through 2026-07-25; kept as the fallback source so a
#      Buildkite outage doesn't repeat the original no-fallback install
#      failure that motivated the R2 migration in the first place). Via the
#      Cloudflare R2 object API (bearer-token auth — we hold a Cloudflare
#      API token here, not an S3 access-key/secret pair, so this uses
#      `PUT /accounts/{id}/r2/buckets/{bucket}/objects/{key}`, not the
#      S3-compatible endpoint).
#
# Invoked ONLY via the forced `command=` in ~/.ssh/authorized_keys for the
# buildkite-agent@cixmini deploy key added 2026-07-26 (singularity-desktop
# .deb packaging pipeline). No shell access, no args — everything comes from
# stdin (the .deb) and this script's own config.
set -euo pipefail

REPO=/home/jasonperlow/ncz-apt-repo
ENVFILE=/home/jasonperlow/.config/ncz-r2-publish.env
PKG_NAME="${NCZ_PUBLISH_PKG_NAME:-ncz-singularity-desktop}"

[ -r "$ENVFILE" ] || { echo "FATAL: missing $ENVFILE" >&2; exit 1; }
# shellcheck disable=SC1090
. "$ENVFILE"
: "${R2_ACCOUNT_ID:?}" "${R2_BUCKET:?}" "${R2_TOKEN:?}"
: "${BUILDKITE_TOKEN:?}" "${BUILDKITE_ORG:?}" "${BUILDKITE_PKG_REGISTRY:?}"

# NOTE: NOT /tmp — ARGOS /tmp is a tmpfs that is routinely full (observed
# 31G/31G used 2026-07-26, unrelated batch jobs). Use a scratch dir on the
# real (501G-avail) root filesystem instead.
SCRATCH="/home/jasonperlow/.cache/ncz-publish-tmp"
mkdir -p "$SCRATCH"
export TMPDIR="$SCRATCH"   # dpkg-deb/reprepro/tar all extract via $TMPDIR --
                           # ARGOS system /tmp is a tmpfs observed full
                           # (31G/31G, unrelated batch jobs), so redirect
                           # every tool that defaults to /tmp here instead.
TMPDEB="$(mktemp "$SCRATCH/ncz-publish-XXXXXX.deb")"
trap 'rm -f "$TMPDEB"' EXIT
cat > "$TMPDEB"
[ -s "$TMPDEB" ] || { echo "FATAL: empty stdin — expected a .deb" >&2; exit 1; }
dpkg-deb --info "$TMPDEB" >/dev/null 2>&1 || { echo "FATAL: not a valid .deb" >&2; exit 1; }

echo "== reprepro includedeb: $(dpkg-deb -f "$TMPDEB" Package)_$(dpkg-deb -f "$TMPDEB" Version) =="
reprepro -b "$REPO" includedeb any "$TMPDEB"

# Resolve the exact pool path reprepro just assigned this package (so we only
# upload the ONE new .deb, not the whole pool).
POOL_REL="$(reprepro -b "$REPO" --list-format '${Filename}\n' list any "$PKG_NAME" | tail -1)"
[ -n "$POOL_REL" ] || { echo "FATAL: could not resolve pool path for $PKG_NAME after includedeb" >&2; exit 1; }

r2_put() {
    local rel="$1" local_path="$2"
    curl -sS -f -X PUT \
        -H "Authorization: Bearer $R2_TOKEN" \
        -H "Content-Type: application/octet-stream" \
        --data-binary "@$local_path" \
        "https://api.cloudflare.com/client/v4/accounts/$R2_ACCOUNT_ID/r2/buckets/$R2_BUCKET/objects/$rel" \
        > /dev/null
    echo "  -> R2 published: $rel"
}

bk_put() {
    local local_path="$1"
    # Buildkite Packages will happily accept a re-upload of an
    # already-present (package,version); it just responds with the existing
    # package record rather than erroring — safe to call unconditionally on
    # every publish (including the R2-only history that predates this
    # dual-publish, backfilled separately, see backfill-buildkite-packages.sh).
    curl -sS -f -X POST \
        -H "Authorization: Bearer $BUILDKITE_TOKEN" \
        -F "file=@$local_path" \
        "https://api.buildkite.com/v2/packages/organizations/$BUILDKITE_ORG/registries/$BUILDKITE_PKG_REGISTRY/packages" \
        > /dev/null
    echo "  -> Buildkite Packages published: $(basename "$local_path")"
}

echo "== publishing to Buildkite Packages (PRIMARY, org=$BUILDKITE_ORG registry=$BUILDKITE_PKG_REGISTRY) =="
bk_put "$REPO/$POOL_REL"

echo "== publishing to R2 (SECONDARY/backup, bucket=$R2_BUCKET) =="
r2_put "$POOL_REL" "$REPO/$POOL_REL"
for f in dists/any/Release dists/any/InRelease dists/any/Release.gpg \
         dists/any/main/binary-arm64/Packages dists/any/main/binary-arm64/Packages.gz \
         dists/any/main/binary-amd64/Packages dists/any/main/binary-amd64/Packages.gz \
         dists/any/main/source/Sources.gz dists/any/main/source/Release; do
    [ -f "$REPO/$f" ] && r2_put "$f" "$REPO/$f"
done

echo "== done: $POOL_REL live on Buildkite Packages (primary) + ${R2_PUBLIC_BASE:-<unset>}/$POOL_REL (backup) =="
