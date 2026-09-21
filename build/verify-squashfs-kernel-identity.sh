#!/usr/bin/env bash
# Semantic staleness gate for base.squashfs: the SBOM manifest
# (sbom/expected-assets*.txt) only ever checked a fixed size+sha256 for
# base.squashfs -- an opaque byte-identity check with no idea what kernel
# is actually inside. That entry's expected hash was pinned once (2026-09-15)
# and never bumped, so it silently "passed" for days against a base.squashfs
# that itself never got rebuilt after a kernel promotion (2026-09-21
# incident, MNEMOS mem_1789997635556_0497ae) -- both a stale AND a fresh
# base.squashfs pass the opaque check as long as neither side changes.
#
# This checks something the hash check cannot: does base.squashfs actually
# contain every kernel this build currently has staged, by name, not by
# whole-file hash. Run this in ADDITION to verify-assets.sh, not instead of
# it -- they catch different classes of drift.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SQUASHFS="${1:-$REPO/assets/squashfs/base.squashfs}"
NCZ_TARGET_ARCH="${NCZ_TARGET_ARCH:-$(dpkg --print-architecture 2>/dev/null || true)}"
FAILED=0

[ -f "$SQUASHFS" ] || { echo "verify-squashfs-kernel-identity: ERROR: $SQUASHFS not found" >&2; exit 2; }

# Only the kernel dirs each arch's post-install hook actually consumes --
# assets/kernel/ also holds the OTHER arch's dirs plus historical dated
# snapshots (r264-*, r272-*, test-*) that no install hook reads. Checking
# those unconditionally is a false-positive staleness report, not a real
# gap (found live testing this script: 5 spurious FAILs from arm64/history
# dirs on an amd64 build).
case "$NCZ_TARGET_ARCH" in
    amd64|x86_64) KDIRS="amd64-stable amd64-edge" ;;
    arm64|aarch64) KDIRS="edge edge-experimental" ;;
    *) echo "verify-squashfs-kernel-identity: ERROR: unknown NCZ_TARGET_ARCH=" >&2; exit 2 ;;
esac

LISTING="$(unsquashfs -l "$SQUASHFS" 2>/dev/null)"

for d in $KDIRS; do
    kv="$REPO/assets/kernel/$d/KVER"
    [ -s "$kv" ] || { echo "WARN: $d has no staged KVER, skipping" >&2; continue; }
    kver="$(tr -d '[:space:]' < "$kv")"
    label="$d"
    if [[ "$LISTING" == *"vmlinuz-${kver}"$'
'* || "$LISTING" == *"vmlinuz-${kver}" ]]; then
        echo "OK: $label staged kernel $kver is embedded in $(basename "$SQUASHFS")"
    else
        echo "STALE: $label staged kernel $kver ($kv) is NOT embedded in $(basename "$SQUASHFS") -- base layer predates this kernel promotion" >&2
        FAILED=1
    fi
done

if [ "$FAILED" -ne 0 ]; then
    echo "verify-squashfs-kernel-identity: FAIL" >&2
    exit 1
fi

echo "verify-squashfs-kernel-identity: PASS"
