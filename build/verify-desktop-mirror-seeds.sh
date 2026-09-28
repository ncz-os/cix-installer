#!/bin/bash
# Verify every package named in the desktop manifest is present in
# build/desktop-mirror's index.
#
# WHY THIS EXISTS (2026-09-28). The Makefile's desktop-mirror target only
# asked "does the directory exist". A manifest-only change was therefore
# invisible to it: rtkit was added to manifests/desktop.pkgs and
# desktop-amd64.pkgs, `make offline-mirror` reported rc=0 and rebuilt
# nothing, and the desktop mkosi delta then died with
#     E: Package 'rtkit' has no installation candidate
# even though rtkit was present in forky-mirror AND as a .deb in the pool.
# The role deltas install from desktop-mirror (build-role-delta-mkosi.sh
# MIRROR_DIRS), so that is the mirror the desktop manifest must agree with.
#
# This is deliberately NOT verify-offline-mirror-seeds.sh: that one checks
# installer-base + desktop + firmware against ONE mirror, which is right for
# the full forky-mirror and wrong here -- pointed at desktop-mirror it
# reports base packages like vim and tmux missing, which is expected.
#
# LC_ALL=C throughout: sort under a UTF-8 locale collates hyphens and dots
# differently than comm compares them, and package names are full of both.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIRROR=""
LABEL="desktop-mirror"

usage() { echo "usage: $0 --mirror DIR [--label NAME]" >&2; }
while [ $# -gt 0 ]; do
    case "$1" in
        --mirror) MIRROR="${2:-}"; shift 2 ;;
        --label)  LABEL="${2:-}";  shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done
[ -n "$MIRROR" ] || { echo "ERROR: --mirror is required" >&2; usage; exit 2; }
[ -d "$MIRROR" ] || { echo "$LABEL: absent" >&2; exit 1; }

# shellcheck source=../release.conf
. "$ROOT/release.conf"
ARCH="${NCZ_TARGET_ARCH:-$(dpkg --print-architecture 2>/dev/null \
    || uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')}"
SUITE="${NCZ_BASE_CODENAME:-forky}"

PKG_INDEX="$MIRROR/dists/$SUITE/main/binary-$ARCH/Packages"
if [ ! -f "$PKG_INDEX" ]; then
    echo "ERROR: $LABEL missing Packages index: $PKG_INDEX" >&2
    exit 1
fi

MANIFEST="$ROOT/manifests/desktop-$ARCH.pkgs"
[ -f "$MANIFEST" ] || MANIFEST="$ROOT/manifests/desktop.pkgs"
[ -s "$MANIFEST" ] || { echo "ERROR: missing manifest: $MANIFEST" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

sed 's/#.*//' "$MANIFEST" | awk 'NF {print $1}' | LC_ALL=C sort -u > "$TMP/seed"
awk '/^Package: / {print $2}' "$PKG_INDEX"      | LC_ALL=C sort -u > "$TMP/have"
LC_ALL=C comm -23 "$TMP/seed" "$TMP/have" > "$TMP/missing"

if [ -s "$TMP/missing" ]; then
    echo "ERROR: $LABEL is stale -- desktop manifest package(s) absent from the mirror:" >&2
    sed 's/^/  /' "$TMP/missing" >&2
    echo "  (rebuild: move build/desktop-mirror aside and re-run make desktop-mirror)" >&2
    exit 1
fi

echo "verify-desktop-mirror-seeds: PASS ($LABEL satisfies all $(wc -l < "$TMP/seed") desktop seeds)"
