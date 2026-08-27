#!/bin/bash
# Verify that the profile's explicit seed packages are present in an offline
# mirror. This catches manifest-only changes that local .deb version pinning
# cannot see.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIRROR=""
LABEL=""

usage() {
    echo "usage: $0 --mirror DIR [--label NAME]" >&2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --mirror)
            MIRROR="${2:-}"; shift 2 ;;
        --label)
            LABEL="${2:-}"; shift 2 ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            usage
            exit 2 ;;
    esac
done

[ -n "$MIRROR" ] || { echo "ERROR: --mirror is required" >&2; usage; exit 2; }
[ -d "$MIRROR" ] || { echo "ERROR: mirror not found: $MIRROR" >&2; exit 1; }
LABEL="${LABEL:-$(basename "$MIRROR")}"

# shellcheck source=../release.conf
. "$ROOT/release.conf"
SUITE="${NCZ_BASE_CODENAME:?release.conf did not define NCZ_BASE_CODENAME}"
ARCH="${ARCH:-arm64}"
PKG_INDEX="$MIRROR/dists/$SUITE/main/binary-$ARCH/Packages"
[ -s "$PKG_INDEX" ] || {
    echo "ERROR: $LABEL missing Packages index: $PKG_INDEX" >&2
    exit 1
}

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

{
    for manifest in "$ROOT/manifests/installer-base.pkgs" "$ROOT/manifests/desktop.pkgs"; do
        [ -s "$manifest" ] || { echo "ERROR: missing manifest: $manifest" >&2; exit 1; }
        sed 's/#.*//' "$manifest" | awk 'NF {print $1}'
    done
} | sort -u > "$TMP/seed"

awk '/^Package: / {print $2}' "$PKG_INDEX" | sort -u > "$TMP/have"
comm -23 "$TMP/seed" "$TMP/have" > "$TMP/missing"

if [ -s "$TMP/missing" ]; then
    echo "ERROR: $LABEL is missing explicit manifest package(s):" >&2
    sed 's/^/  /' "$TMP/missing" >&2
    exit 1
fi

echo "verify-offline-mirror-seeds: PASS ($LABEL has $(wc -l < "$TMP/seed") explicit seed packages)"
