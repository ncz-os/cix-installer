#!/usr/bin/env bash
# Semantic identity gate for desktop.squashfs: it is REBUILT FRESH FROM
# HEAD every time by design (build_singularity_payload(), see this file's
# header comment) -- its bytes are not reproducible/stable across builds,
# so a fixed size+sha256 SBOM entry is the wrong tool. sbom/expected-assets-
# amd64.txt's own 2026-09-18 comment already flagged this tension without
# resolving it; the practical effect was a manual hash-bump chore every
# single build, and on 2026-09-21 a stale hash silently aborted a full
# rebuild's own internal preflight check right after the squashfs stage
# completed (companion incident to MNEMOS mem_1789997635556_0497ae).
#
# Real check: does desktop.squashfs actually contain the CURRENTLY STAGED
# ncz-singularity-desktop .deb version -- content identity, not byte
# identity. This is the same philosophy as verify-squashfs-kernel-identity.sh
# for base.squashfs's kernel, applied to desktop.squashfs's payload.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SQUASHFS="${1:-$REPO/assets/squashfs/desktop.squashfs}"

[ -f "$SQUASHFS" ] || { echo "verify-desktop-squashfs-identity: ERROR: $SQUASHFS not found" >&2; exit 2; }

DEB="$(find "$REPO/assets/cix-debs" -maxdepth 1 -name 'ncz-singularity-desktop_*.deb' | sort -V | tail -1)"
[ -n "$DEB" ] || { echo "verify-desktop-squashfs-identity: ERROR: no staged ncz-singularity-desktop .deb in assets/cix-debs" >&2; exit 2; }

staged_version="$(dpkg-deb -f "$DEB" Version)"
[ -n "$staged_version" ] || { echo "verify-desktop-squashfs-identity: ERROR: could not read Version from $DEB" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
unsquashfs -f -d "$WORK" "$SQUASHFS" var/lib/dpkg/status >/dev/null 2>&1 || true

embedded_version="$(awk '/^Package: ncz-singularity-desktop$/{p=1; next} p && /^Version: /{print substr($0,10); exit} p && /^$/{exit}' "$WORK/var/lib/dpkg/status" 2>/dev/null)"

if [ -z "$embedded_version" ]; then
    echo "verify-desktop-squashfs-identity: FAIL: no ncz-singularity-desktop package found embedded in $(basename "$SQUASHFS")" >&2
    exit 1
fi

if [ "$embedded_version" != "$staged_version" ]; then
    echo "verify-desktop-squashfs-identity: FAIL: staged $DEB is version $staged_version but $(basename "$SQUASHFS") embeds $embedded_version -- squashfs predates the staged .deb" >&2
    exit 1
fi

echo "verify-desktop-squashfs-identity: PASS ($(basename "$SQUASHFS") embeds ncz-singularity-desktop $embedded_version, matching staged $DEB)"
