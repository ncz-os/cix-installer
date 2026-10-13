#!/bin/bash
# stage-screensaver-plugin.sh ARCH [ARCH...] -- copy the pinned Singularity
# screensaver settings plugin deb (ncz-screensavers-plugin) from the store into
# build/ncz-screensavers-out/, verified against
# post-install/lib/ncz-screensavers-plugin.lock. Copies only; never touches the
# network; idempotent (an identical destination is left in place).
#
# Run on the build HOST (it needs the store's NFS mount) before stage 2
# (`make image`), after stage-assets. `make ssplugin-stage` runs it for $(ARCH).
# The stage-2 gate (build/check-ssplugin-abi.sh) refuses an image whose staged
# deb is missing or differs from the pin.
#
#   NCZ_SSPLUGIN_SRC_ROOT=DIR   the store's projects root (default: first line of
#                               ~/.config/ncz/projects-dir; build/lib/ncz-site.sh)
#   NCZ_SSPLUGIN_OUT=DIR        destination (default build/ncz-screensavers-out)
#   NCZ_SSPLUGIN_LOCK=FILE      pin file (default post-install/lib/ncz-screensavers-plugin.lock)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../post-install/lib/ncz-ssplugin-install.sh
. "$ROOT/post-install/lib/ncz-ssplugin-install.sh"
ssp_log() { echo "[ssplugin-stage] $*"; }
ssp_err() { echo "[ssplugin-stage] $*" >&2; }

[ "$#" -ge 1 ] || { echo "usage: $0 ARCH [ARCH...]   (ARCH: amd64 | arm64)" >&2; exit 2; }
LOCK="${NCZ_SSPLUGIN_LOCK:-$ROOT/post-install/lib/ncz-screensavers-plugin.lock}"
OUT="${NCZ_SSPLUGIN_OUT:-$ROOT/build/ncz-screensavers-out}"

. "$ROOT/build/lib/ncz-site.sh"
SRC_ROOT="$(ncz_site_value NCZ_SSPLUGIN_SRC_ROOT projects-dir)"
[ -n "$SRC_ROOT" ] && [ -d "$SRC_ROOT" ] || {
    ssp_err "FATAL: the store's projects root is not configured or not mounted ('${SRC_ROOT:-<unset>}'); set NCZ_SSPLUGIN_SRC_ROOT or ~/.config/ncz/projects-dir"
    exit 1
}

rc=0
for arch in "$@"; do
    case "$arch" in amd64|arm64) ;; *) ssp_err "FATAL: unknown arch '$arch'"; exit 2 ;; esac
    ssplugin_load_lock "$LOCK" "$arch" || exit 1
    name="${SSP_PKG}_${SSP_VERSION}_${arch}.deb"
    src="$SRC_ROOT/$SSP_ARGONAS_DIR/$name"
    if [ ! -s "$src" ]; then ssp_err "FATAL: $src missing (pin: $LOCK)"; rc=1; continue; fi
    got="$(ssp_sha256 "$src")"
    if [ "$got" != "$SSP_SHA256" ]; then
        ssp_err "FATAL: $src sha256 $got != pinned $SSP_SHA256; refusing to stage"; rc=1; continue
    fi
    # The control fields must say what the file name and the pin say.
    for kv in "Package=$SSP_PKG" "Version=$SSP_VERSION" "Architecture=$arch" "Maintainer=$SSP_MAINT"; do
        k="${kv%%=*}"; want="${kv#*=}"
        have="$(dpkg-deb -f "$src" "$k" 2>/dev/null || true)"
        if [ "$have" != "$want" ]; then ssp_err "FATAL: $src control $k is '$have', expected '$want'"; rc=1; continue 2; fi
    done
    mkdir -p "$OUT"
    # Only one plugin deb per arch may sit in the staging dir: a stale one would
    # be ambiguous for every consumer. Remove other plugin debs for THIS arch
    # only (never the engine deb, never the other arch).
    for old in "$OUT/${SSP_PKG}_"*"_${arch}.deb"; do
        [ -e "$old" ] || continue
        [ "$(basename "$old")" = "$name" ] && continue
        ssp_log "removing superseded $old"; rm -f "$old"
    done
    dst="$OUT/$name"
    if [ -f "$dst" ] && [ "$(ssp_sha256 "$dst")" = "$SSP_SHA256" ]; then
        ssp_log "identical $dst"
    else
        cp "$src" "$dst.tmp.$$" && mv -f "$dst.tmp.$$" "$dst"
        [ "$(ssp_sha256 "$dst")" = "$SSP_SHA256" ] || { rm -f "$dst"; ssp_err "FATAL: copy of $src does not verify"; rc=1; continue; }
        ssp_log "staged $dst <- $src (sha256 $SSP_SHA256)"
    fi
done
exit "$rc"
