#!/bin/bash
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
# Set from the .deb itself below (once TMPDEB exists). The old default was a
# hardcoded "ncz-singularity-desktop": piping ANY other package in still ran
# includedeb correctly, then resolved the pool path of singularity-desktop and
# published THAT to Buildkite and R2 -- so the requested package never reached
# either backend, and Buildkite returned 409 on the duplicate, aborting the
# script before R2. Measured 2026-08-10 while publishing ncz-npu-embed.
PKG_NAME="${NCZ_PUBLISH_PKG_NAME:-}"

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

# Derive the package name from the artifact, never from a default.
PKG_NAME="${PKG_NAME:-$(dpkg-deb -f "$TMPDEB" Package)}"
[ -n "$PKG_NAME" ] || { echo "FATAL: could not read Package field from the .deb" >&2; exit 1; }

echo "== reprepro includedeb: $(dpkg-deb -f "$TMPDEB" Package)_$(dpkg-deb -f "$TMPDEB" Version) =="
reprepro -b "$REPO" includedeb any "$TMPDEB"

# Resolve the exact pool path reprepro just assigned this package (so we only
# upload the ONE new .deb, not the whole pool).
POOL_REL="$(reprepro -b "$REPO" --list-format '${Filename}\n' list any "$PKG_NAME" | tail -1)"
[ -n "$POOL_REL" ] || { echo "FATAL: could not resolve pool path for $PKG_NAME after includedeb" >&2; exit 1; }

R2_SKIPPED=""

r2_put() {
    local rel="$1" local_path="$2" code
    # This endpoint is a SINGLE-PUT upload with a ~300 MB ceiling: the 378 MB
    # ncz-model-nomic-embed_1.5.0 was rejected with HTTP 413 on 2026-08-10.
    # Say so loudly and record it rather than letting a silent 413 imply the
    # backup exists -- an R2 fallback nobody knows is missing is worse than no
    # fallback. Large objects need a multipart upload, which this script does
    # not implement yet.
    code=$(curl -sS -o /dev/null -w '%{http_code}' -X PUT \
        -H "Authorization: Bearer $R2_TOKEN" \
        -H "Content-Type: application/octet-stream" \
        --data-binary "@$local_path" \
        "https://api.cloudflare.com/client/v4/accounts/$R2_ACCOUNT_ID/r2/buckets/$R2_BUCKET/objects/$rel")
    case "$code" in
        2??) echo "  -> R2 published: $rel" ;;
        413)
            echo "  -> R2 SKIPPED (HTTP 413, too large for single-PUT): $rel" >&2
            echo "     Buildkite (primary) still serves it; the R2 backup does NOT have this object." >&2
            R2_SKIPPED="${R2_SKIPPED}${rel} "
            ;;
        *)   echo "  -> R2 FAILED (HTTP $code): $rel" >&2; return 1 ;;
    esac
}

bk_put() {
    local local_path="$1"
    # A previous comment here claimed Buildkite "will happily accept a re-upload
    # of an already-present (package,version)". MEASURED 2026-08-10: it does
    # NOT -- it returns HTTP 409, and with `curl -f` that aborted the whole
    # script before the R2 publish below, leaving a half-published release.
    #
    # 409 is therefore tolerated, but NOT trusted: a 409 is only accepted after
    # confirming the (name,version) is actually in the registry. Treating a
    # bare 409 as success would report a publish that never happened -- which
    # is exactly what a 378 MB upload did on 2026-08-10, answering 409 while
    # the package was absent from the registry listing.
    local code name version
    name="$(dpkg-deb -f "$local_path" Package)"
    version="$(dpkg-deb -f "$local_path" Version)"
    code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
        -H "Authorization: Bearer $BUILDKITE_TOKEN" \
        -F "file=@$local_path" \
        "https://api.buildkite.com/v2/packages/organizations/$BUILDKITE_ORG/registries/$BUILDKITE_PKG_REGISTRY/packages")
    case "$code" in
        2??) echo "  -> Buildkite Packages published: $(basename "$local_path")" ;;
        409)
            if bk_has "$name" "$version"; then
                echo "  -> Buildkite Packages: already present (409, verified): $name $version"
            else
                echo "  -> Buildkite Packages FAILED: 409 but $name $version is NOT in the registry" >&2
                return 1
            fi
            ;;
        *)   echo "  -> Buildkite Packages FAILED (HTTP $code): $(basename "$local_path")" >&2; return 1 ;;
    esac
}

# Is (name,version) actually served to clients? Check the APT INDEX, not the
# REST packages listing.
#
# MEASURED 2026-08-10: the REST endpoint
# /v2/packages/organizations/<org>/registries/<reg>/packages caps at 50 items
# and does NOT paginate -- ?page=2 and ?page=3 return the SAME 50 rows. Using
# it to verify a publish produced FALSE NEGATIVES: ncz-model-nomic-embed 1.5.0
# and linux-image-cixmini-lts 7.2.0-rc7-sky1-ncz+r210 were both reported
# "not in the registry" while the apt index served them correctly.
#
# The index below is exactly what an apt client resolves against, so it is the
# only honest definition of "published".
bk_has() {
    local name="$1" version="$2"
    # The index is fetched to a file rather than piped into awk.
    #
    # awk used to `exit` as soon as it matched, which closes the pipe under
    # curl's feet: curl then dies with "(23) Failure writing output to
    # destination", and because this script runs with pipefail that non-zero
    # poisons the pipeline -- so a package that IS present reports as absent.
    # The symptom is a false "409 but NOT in the registry", i.e. the check
    # designed to catch a lying 409 could itself lie.
    local idx rc
    idx="$(mktemp)"
    if ! curl -fsSL -m 120 -o "$idx" \
        "https://packages.buildkite.com/$BUILDKITE_ORG/$BUILDKITE_PKG_REGISTRY/any/dists/any/main/binary-arm64/Packages"; then
        rm -f "$idx"
        echo "  -> Buildkite index unreachable; cannot verify $name $version" >&2
        return 1
    fi
    awk -v n="$name" -v v="$version" '
        $1 == "Package:" { pkg = $2 }
        $1 == "Version:" && pkg == n && $2 == v { found = 1 }
        END { exit(found ? 0 : 1) }' "$idx"
    rc=$?
    rm -f "$idx"
    return $rc
}

echo "== publishing to Buildkite Packages (PRIMARY, org=$BUILDKITE_ORG registry=$BUILDKITE_PKG_REGISTRY) =="
# bk_put's exit status USED TO BE DISCARDED here. It returns 1 on a genuine
# failure, but nothing checked it, so the script carried on and printed
# "live on Buildkite Packages (primary)" for a package Buildkite had rejected.
# A publish tool that reports success for work it did not do is worse than no
# tool. Record it and let the final message tell the truth.
BK_OK=1
if ! bk_put "$REPO/$POOL_REL"; then
    BK_OK=0
fi

echo "== publishing to R2 (SECONDARY/backup, bucket=$R2_BUCKET) =="
r2_put "$POOL_REL" "$REPO/$POOL_REL"
for f in dists/any/Release dists/any/InRelease dists/any/Release.gpg \
         dists/any/main/binary-arm64/Packages dists/any/main/binary-arm64/Packages.gz \
         dists/any/main/binary-amd64/Packages dists/any/main/binary-amd64/Packages.gz \
         dists/any/main/source/Sources.gz dists/any/main/source/Release; do
    [ -f "$REPO/$f" ] && r2_put "$f" "$REPO/$f"
done

if [ -n "$R2_SKIPPED" ] && [ "$BK_OK" = 0 ]; then
    echo "== FAILED: $POOL_REL published to NEITHER backend ==" >&2
    echo "   Buildkite rejected it and the R2 backup is incomplete: $R2_SKIPPED" >&2
    exit 3
fi
if [ -n "$R2_SKIPPED" ]; then
    echo "== done WITH GAPS: $POOL_REL live on Buildkite Packages (primary) ONLY ==" >&2
    echo "   not in the R2 backup: $R2_SKIPPED" >&2
    exit 2
fi
if [ "$BK_OK" = 0 ]; then
    echo "== done WITH GAPS: $POOL_REL live on R2 ONLY ==" >&2
    echo "   ${R2_PUBLIC_BASE:-<unset>}/$POOL_REL" >&2
    echo "   Buildkite Packages (PRIMARY) did NOT accept it. apt clients that" >&2
    echo "   resolve via Buildkite will not see this version." >&2
    exit 2
fi
echo "== done: $POOL_REL live on Buildkite Packages (primary) + ${R2_PUBLIC_BASE:-<unset>}/$POOL_REL (backup) =="
