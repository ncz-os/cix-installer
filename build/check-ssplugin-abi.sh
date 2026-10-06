#!/bin/bash
# check-ssplugin-abi.sh --arch ARCH [--plugin-deb F] [--payload-deb F]
#
# Stage-2 gate for the Singularity screensaver settings plugin
# (ncz-screensavers-plugin), run by `make image` before the image is written:
#
#  1. staged: exactly one ncz-screensavers-plugin deb for ARCH in
#     build/ncz-screensavers-out/, and its sha256 is the one pinned in
#     post-install/lib/ncz-screensavers-plugin.lock (stage it with
#     build/stage-screensaver-plugin.sh ARCH on the build host);
#  2. ABI: the Singularity payload the image installs -- the newest
#     assets/cix-debs/ncz-singularity-desktop_*_ARCH.deb, which stage 1 rebuilt
#     and baked into the desktop layer, and which 20-desktop.sh installs -- is
#     the payload the plugin was linked against: same version, or a
#     byte-identical libsingularity (the only Singularity library the plugin
#     links). Otherwise FAIL with the rebuild instructions. The installer applies
#     the same rule (post-install/lib/ncz-ssplugin-install.sh) and refuses to
#     install a mismatched plugin, so this gate only moves the failure from the
#     install gate to the build.
#
# Exit: 0 pass, 1 fail, 2 bad invocation.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../post-install/lib/ncz-ssplugin-install.sh
. "$ROOT/post-install/lib/ncz-ssplugin-install.sh"
ssp_log() { echo "[ssplugin-abi] $*"; }
ssp_err() { echo "[ssplugin-abi] $*" >&2; }

ARCH=""; PLUGIN_DEB=""; PAYLOAD_DEB=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --arch) ARCH="${2:-}"; shift 2 ;;
        --plugin-deb) PLUGIN_DEB="${2:-}"; shift 2 ;;
        --payload-deb) PAYLOAD_DEB="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) ssp_err "unknown argument $1"; exit 2 ;;
    esac
done
case "$ARCH" in amd64|arm64) ;; *) ssp_err "--arch amd64|arm64 required"; exit 2 ;; esac
LOCK="${NCZ_SSPLUGIN_LOCK:-$ROOT/post-install/lib/ncz-screensavers-plugin.lock}"
OUT="${NCZ_SSPLUGIN_OUT:-$ROOT/build/ncz-screensavers-out}"
CIX_DEBS="${NCZ_SSPLUGIN_CIX_DEBS:-$ROOT/assets/cix-debs}"
ssplugin_load_lock "$LOCK" "$ARCH" || exit 1

# 1. the staged plugin deb ---------------------------------------------------------
if [ -z "$PLUGIN_DEB" ]; then
    shopt -s nullglob
    staged=("$OUT/${SSP_PKG}_"*"_${ARCH}.deb")
    shopt -u nullglob
    if [ "${#staged[@]}" -ne 1 ]; then
        ssp_err "FATAL: expected exactly one ${SSP_PKG}_*_${ARCH}.deb in $OUT, found ${#staged[@]}"
        ssp_err "       run on the build host: build/stage-screensaver-plugin.sh $ARCH   (or: make ssplugin-stage)"
        exit 1
    fi
    PLUGIN_DEB="${staged[0]}"
fi
[ -s "$PLUGIN_DEB" ] || { ssp_err "FATAL: plugin deb $PLUGIN_DEB missing"; exit 1; }
got="$(ssp_sha256 "$PLUGIN_DEB")"
if [ "$got" != "$SSP_SHA256" ]; then
    ssp_err "FATAL: $PLUGIN_DEB sha256 $got != pinned $SSP_SHA256 ($LOCK); re-run build/stage-screensaver-plugin.sh $ARCH"
    exit 1
fi
[ "$(basename "$PLUGIN_DEB")" = "${SSP_PKG}_${SSP_VERSION}_${ARCH}.deb" ] || {
    ssp_err "FATAL: $PLUGIN_DEB is not named ${SSP_PKG}_${SSP_VERSION}_${ARCH}.deb (the installer looks for that name)"; exit 1; }
ssp_log "staged plugin OK: $(basename "$PLUGIN_DEB") sha256 $got"

# 2. the payload the image installs ---------------------------------------------------
if [ -z "$PAYLOAD_DEB" ]; then
    PAYLOAD_DEB="$(ls -1 "$CIX_DEBS"/ncz-singularity-desktop_*_"$ARCH".deb 2>/dev/null | sort -V | tail -1)"
fi
if [ -z "$PAYLOAD_DEB" ] || [ ! -s "$PAYLOAD_DEB" ]; then
    ssp_err "FATAL: no Singularity payload deb ncz-singularity-desktop_*_$ARCH.deb in $CIX_DEBS (stage 1 builds it); cannot check the plugin ABI"
    exit 1
fi
pver="$(dpkg-deb -f "$PAYLOAD_DEB" Version 2>/dev/null || true)"
[ -n "$pver" ] || { ssp_err "FATAL: cannot read the Version of $PAYLOAD_DEB"; exit 1; }
work="$(mktemp -d "${TMPDIR:-/var/tmp}/ssplugin-abi.XXXXXX")"
trap 'rm -rf "$work"' EXIT
# Extract only the libsingularity entries (the soname link and its target).
rel=".${SSP_ABI_LIB}"
if ! dpkg-deb --fsys-tarfile "$PAYLOAD_DEB" | tar -x -C "$work" --wildcards "${rel}*" 2>/dev/null; then
    ssp_err "FATAL: $PAYLOAD_DEB does not contain $SSP_ABI_LIB"
    exit 1
fi
lib="$work$SSP_ABI_LIB"
if [ -L "$lib" ]; then lib="$(dirname "$lib")/$(readlink "$lib")"; fi
libsha=""; [ -f "$lib" ] && libsha="$(ssp_sha256 "$lib")"
[ -n "$libsha" ] || { ssp_err "FATAL: $SSP_ABI_LIB in $PAYLOAD_DEB does not resolve to a file"; exit 1; }
if verdict="$(ssplugin_abi_verdict "$pver" "$libsha")"; then
    ssp_log "ABI OK ($verdict): payload $pver, libsingularity $libsha; plugin built against $SSP_PAYLOAD"
    exit 0
fi
ssp_err "FATAL: ABI MISMATCH between the plugin and the image's Singularity payload ($(basename "$PAYLOAD_DEB"), libsingularity $libsha)"
ssplugin_rebuild_help "$ARCH" "$pver"
exit 1
