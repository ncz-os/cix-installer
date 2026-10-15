#!/bin/bash
# stage-screensaver-plugin.sh ARCH [ARCH...] -- copy the pinned Singularity
# screensaver settings plugin deb (ncz-screensavers-plugin) from the store into
# build/ncz-screensavers-out/, verified against
# post-install/lib/ncz-screensavers-plugin.lock. Stages pinned bytes; idempotent (an
# identical destination is left in place).
#
# Run on the build HOST before stage 2 (`make image`), after stage-assets.
# `make ssplugin-stage` runs it for $(ARCH). The stage-2 gate
# (build/check-ssplugin-abi.sh) refuses an image whose staged deb is missing or
# differs from the pin.
#
#   NCZ_SSPLUGIN_SRC_ROOT=DIR   the store's projects root (default: first line of
#                               ~/.config/ncz/projects-dir; build/lib/ncz-site.sh)
#   NCZ_SSPLUGIN_OUT=DIR        destination (default build/ncz-screensavers-out)
#   NCZ_SSPLUGIN_LOCK=FILE      pin file (default post-install/lib/ncz-screensavers-plugin.lock)
#
# Local store is preferred: when a valid local deb exists it is used and the
# network is never touched. When the store is unset, not mounted, or the deb is
# missing, the pinned deb is fetched from the canonical public HTTPS origin
# (packages.buildkite.com/ncz-os/ncz/any) using the locked filename. A corrupt
# local deb is fatal and never falls back to the network. TLS/auth/trust are
# never waived.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../post-install/lib/ncz-ssplugin-install.sh
. "$ROOT/post-install/lib/ncz-ssplugin-install.sh"
ssp_log() { echo "[ssplugin-stage] $*" >&2; }
ssp_err() { echo "[ssplugin-stage] $*" >&2; }

# Canonical public HTTPS origin for the pinned plugin deb. No environment
# override, no credentials, no private hostnames.
SSP_PUBLIC_ORIGIN="https://packages.buildkite.com/ncz-os/ncz/any"

[ "$#" -ge 1 ] || { echo "usage: $0 ARCH [ARCH...]   (ARCH: amd64 | arm64)" >&2; exit 2; }
LOCK="${NCZ_SSPLUGIN_LOCK:-$ROOT/post-install/lib/ncz-screensavers-plugin.lock}"
OUT="${NCZ_SSPLUGIN_OUT:-$ROOT/build/ncz-screensavers-out}"

# Prevalidate every ARCH argument before any download or filesystem work.
for arch in "$@"; do
    case "$arch" in amd64|arm64) ;; *) ssp_err "FATAL: unknown arch '$arch'"; exit 2 ;; esac
done

# Resolve the local store root. It may legitimately be unset or not mounted;
# that is not fatal because the public fallback is authorized.
SRC_ROOT=""
if [ -r "$ROOT/build/lib/ncz-site.sh" ]; then
    # shellcheck source=lib/ncz-site.sh
    . "$ROOT/build/lib/ncz-site.sh"
    SRC_ROOT="$(ncz_site_value NCZ_SSPLUGIN_SRC_ROOT projects-dir)"
fi

# Unique owned temp dir under OUT (Projects caller owns OUT).
mkdir -p "$OUT"
TMPDIR_STAGE="$(mktemp -d "$OUT/.ssplugin-stage.XXXXXX")"
cleanup() { rm -rf "$TMPDIR_STAGE"; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

# Fetch the pinned deb from the canonical public HTTPS origin into $1.
# Uses the locked filename; verifies nothing here (caller verifies).
ssp_fetch_public() {
    local arch="$1" dest="$2" name url
    name="${SSP_PKG}_${SSP_VERSION}_${arch}.deb"
    url="$SSP_PUBLIC_ORIGIN/pool/any/main/n/${SSP_PKG}/${name}"
    ssp_log "fetching $url"
    curl --proto '=https' --proto-redir '=https' --fail --location \
         --connect-timeout 10 --max-time 60 \
         --output "$dest" "$url"
}

rc=0
for arch in "$@"; do
    ssplugin_load_lock "$LOCK" "$arch" || exit 1
    name="${SSP_PKG}_${SSP_VERSION}_${arch}.deb"
    src=""
    local_ok=0
    if [ -n "$SRC_ROOT" ] && [ -d "$SRC_ROOT" ]; then
        cand="$SRC_ROOT/$SSP_STORE_DIR/$name"
        if [ -f "$cand" ]; then
            got="$(ssp_sha256 "$cand")"
            if [ "$got" = "$SSP_SHA256" ]; then
                src="$cand"; local_ok=1
            else
                ssp_err "FATAL: $cand sha256 $got != pinned $SSP_SHA256; refusing to stage (no public fallback for a corrupt local deb)"
                rc=1; continue
            fi
        fi
    fi

    if [ "$local_ok" = 0 ]; then
        # Local store unset, not mounted, or deb missing: authorized public
        # HTTPS fallback. Download into the owned temp dir, then verify.
        fetched="$TMPDIR_STAGE/$name"
        if ! ssp_fetch_public "$arch" "$fetched"; then
            ssp_err "FATAL: public fetch of $name failed; leaving existing staging untouched"
            rc=1; continue
        fi
        got="$(ssp_sha256 "$fetched")"
        if [ "$got" != "$SSP_SHA256" ]; then
            ssp_err "FATAL: fetched $name sha256 $got != pinned $SSP_SHA256; refusing to stage"
            rc=1; continue
        fi
        src="$fetched"
    fi

    # The control fields must say what the file name and the pin say.
    ctl_ok=1
    for kv in "Package=$SSP_PKG" "Version=$SSP_VERSION" "Architecture=$arch" "Maintainer=$SSP_MAINT"; do
        k="${kv%%=*}"; want="${kv#*=}"
        have="$(dpkg-deb -f "$src" "$k" 2>/dev/null || true)"
        if [ "$have" != "$want" ]; then
            ssp_err "FATAL: $src control $k is '$have', expected '$want'"
            ctl_ok=0; break
        fi
    done
    [ "$ctl_ok" = 1 ] || { rc=1; continue; }

    mkdir -p "$OUT"
    dst="$OUT/$name"
    if [ -f "$dst" ] && [ "$(ssp_sha256 "$dst")" = "$SSP_SHA256" ]; then
        ssp_log "identical $dst"
    else
        # Copy into the owned temp dir first, verify, then atomically move into
        # place. The destination is never overwritten before verification.
        copy_tmp="$TMPDIR_STAGE/copy-$name"
        rm -f "$copy_tmp"
        cp "$src" "$copy_tmp"
        got="$(ssp_sha256 "$copy_tmp")"
        if [ "$got" != "$SSP_SHA256" ]; then
            ssp_err "FATAL: copy of $src does not verify (sha256 $got != $SSP_SHA256); leaving existing staging untouched"
            rm -f "$copy_tmp"
            rc=1; continue
        fi
        mv -f "$copy_tmp" "$dst"
        ssp_log "staged $dst <- $src (sha256 $SSP_SHA256)"
    fi
    # Only one plugin deb per arch may sit in the staging dir: a stale one would
    # be ambiguous for every consumer. Remove other plugin debs for THIS arch
    # only (never the engine deb, never the other arch), after the new one is
    # successfully in place.
    for old in "$OUT/${SSP_PKG}_"*"_${arch}.deb"; do
        [ -e "$old" ] || continue
        [ "$(basename "$old")" = "$name" ] && continue
        ssp_log "removing superseded $old"; rm -f "$old"
    done
done
exit "$rc"
