#!/bin/bash
# stage-substrate.sh -- materialize the pinned Debian testing netinst substrate
# into downloads/ from the substrate cache, sha256-verified against
# manifests/base.pin.
#
# WHY. The image build runs `make image` inside the ncz-imagebuild container,
# which mounts only the clone (/work/cix-installer) -- NOT the host
# SUBSTRATE_CACHE_DIRS -- so `make download` cannot reach the cache from inside
# it.  The pipeline therefore pre-stages the pinned ISO into the host's
# downloads/ (build-image.sh "Container helper", r202 workaround #4).  A fresh
# clone has an empty downloads/, so with --substrate pinned the
# 01 refresh-substrate stage verified the pin and returned WITHOUT restoring the
# ISO, and 07 image failed 12 s in with
#   [download] SUBSTRATE ROTATED ... pinned ISO not found in <cache dirs>
# (r203 / amd64 RC5 finding A).  This script closes that gap permanently: the
# pinned substrate is always restored here, sha256-checked, and never floated.
#
# The pin is SINGLE-SOURCED from manifests/base.pin (substrate sha256 per arch).
# The ISO is looked up in the substrate cache as <name>-<yyyymmdd>-<sha8>.iso
# (NCZ_SUBSTRATE_CACHE_DIRS or ~/.config/ncz/substrate-cache-dir; space-separated).
#
# USAGE
#   build/stage-substrate.sh --arch amd64|arm64           # stage into downloads/
#   build/stage-substrate.sh --arch amd64 --check         # verify only (no copy)
# Exit: 0 staged/verified; 1 missing/mismatched (fails closed); 2 usage.
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"

ARCH=""; MODE=stage
while [ $# -gt 0 ]; do
    case "$1" in
        --arch) ARCH="${2:-}"; shift 2 ;;
        --check) MODE=check; shift ;;
        -h|--help) sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "stage-substrate: unknown argument: $1" >&2; exit 2 ;;
    esac
done
case "$ARCH" in
    amd64|arm64) ;;
    "") ARCH="${NCZ_TARGET_ARCH:-}"
        [ -n "$ARCH" ] || { echo "stage-substrate: --arch amd64|arm64 required" >&2; exit 2; } ;;
    *) echo "stage-substrate: bad --arch $ARCH" >&2; exit 2 ;;
esac

PIN="$ROOT/manifests/base.pin"
[ -f "$PIN" ] || { echo "stage-substrate: FAIL: missing $PIN" >&2; exit 1; }
WANT="$(awk -F'\t' -v a="$ARCH" '$1==a{print $2; exit}' "$PIN")"
printf '%s' "$WANT" | grep -Eq '^[0-9a-f]{64}$' \
    || { echo "stage-substrate: FAIL: no sha256 substrate pin for '$ARCH' in $PIN" >&2; exit 1; }
SHORT="${WANT:0:8}"
ISO_NAME="${NCZ_SUBSTRATE_ISO_NAME:-debian-testing-$ARCH-netinst.iso}"
DEST="$ROOT/downloads/$ISO_NAME"
sha_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

# already staged and correct?
if [ -f "$DEST" ] && [ "$(sha_of "$DEST")" = "$WANT" ]; then
    echo "[substrate] already staged: downloads/$ISO_NAME ($WANT)"
    exit 0
fi
if [ "$MODE" = check ]; then
    echo "stage-substrate: FAIL: downloads/$ISO_NAME missing or sha256 != pin $WANT" >&2
    exit 1
fi

# Substrate cache directories (space-separated): NCZ_SUBSTRATE_CACHE_DIRS or
# ~/.config/ncz/substrate-cache-dir (same lookup as build/lib/ncz-site.sh,
# inlined because tests run a copy of this script outside the repo).
_site_value() {
    local v="${!1:-}" f
    if [ -z "$v" ]; then
        f="${XDG_CONFIG_HOME:-${HOME:-}/.config}/ncz/$2"
        if [ -r "$f" ]; then IFS= read -r v < "$f" || true; fi
    fi
    printf '%s' "$v"
}
CACHE_DIRS="$(_site_value NCZ_SUBSTRATE_CACHE_DIRS substrate-cache-dir)"
found=""
for d in $CACHE_DIRS; do
    [ -d "$d" ] || continue
    for f in "$d"/*-"$SHORT".iso "$d"/"$ISO_NAME"; do
        [ -f "$f" ] || continue
        if [ "$(sha_of "$f")" = "$WANT" ]; then found="$f"; break 2; fi
        echo "[substrate] WARNING: $f does not match the pin (sha256 $(sha_of "$f")); ignoring" >&2
    done
done
if [ -z "$found" ]; then
    {
        echo "stage-substrate: FAIL: the pinned substrate ($SHORT, $WANT) was not found in:"
        for d in $CACHE_DIRS; do echo "  $d"; done
        [ -n "$CACHE_DIRS" ] || echo "  (none configured: set NCZ_SUBSTRATE_CACHE_DIRS or ~/.config/ncz/substrate-cache-dir)"
        echo "Upstream republishes the netinst filename weekly; the pinned ISO is cached in"
        echo "the substrate cache as <name>-<yyyymmdd>-$SHORT.iso. Restore it into one of the cache dirs"
        echo "(or set NCZ_SUBSTRATE_CACHE_DIRS), or adopt a new substrate deliberately: build"
        echo "an image on it, run the KVM gate, then update manifests/base.pin. This script"
        echo "never floats to whatever Debian serves today."
    } >&2
    exit 1
fi

mkdir -p "$ROOT/downloads"
cp -f "$found" "$DEST.tmp" && mv -f "$DEST.tmp" "$DEST"
got="$(sha_of "$DEST")"
[ "$got" = "$WANT" ] || { echo "stage-substrate: FAIL: copy verifies as $got != $WANT" >&2; rm -f "$DEST"; exit 1; }
echo "[substrate] staged downloads/$ISO_NAME from $found ($WANT)"
exit 0
