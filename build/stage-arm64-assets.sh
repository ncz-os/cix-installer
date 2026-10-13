#!/bin/bash
# stage-arm64-assets.sh [--check] -- materialize the pinned arm64 asset groups.
#
# WHY (operator 2026-10-11, r203 failure #3). assets/sky1-firmware/ and
# assets/cix-debs/*.deb are gitignored and were neither pinned nor staged by the
# pipeline, so a truly fresh clone aborted in verify-arm64-inputs at the image
# stage ("one or more required inputs are absent"). They are now pinned as two
# tarballs in manifests/build-inputs.tsv -- fetched by build/stage-build-inputs.sh
# from the build-inputs store -- and this script verifies each tarball
# against its pin and extracts it into assets/.
#
#   build/stage-arm64-assets.sh          # verify + extract (idempotent)
#   build/stage-arm64-assets.sh --check   # verify the pins/bytes, extract nothing
#
# Run on the build host after stage-build-inputs.sh (the pipeline's stage-inputs
# stage does).  Needs sha256sum, zstd and tar.  No-op text (exit 0) on non-arm64.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TSV="${NCZ_BUILD_INPUTS_TSV:-$ROOT/manifests/build-inputs.tsv}"
MODE=fetch
case "${1:-}" in
    --check) MODE=check ;;
    "") : ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "stage-arm64-assets: unknown argument: $1" >&2; exit 2 ;;
esac

# The two pinned archives and the directory each one materializes.
TARBALLS=(assets/sky1-firmware.tar.zst assets/cix-debs.tar.zst)

sha_of() { sha256sum "$1" | awk '{print $1}'; }
fail=0
mkdir -p "$ROOT/assets"   # a fresh clone has it, but never rely on that
for dest in "${TARBALLS[@]}"; do
    pin="$(awk -F'\t' -v d="$dest" '$1=="arm64" && $2==d {print $3; exit}' "$TSV")"
    tarball="$ROOT/$dest"
    if [ -z "$pin" ]; then
        echo "[arm64-assets] FAIL: no arm64 pin for $dest in $TSV" >&2; fail=1; continue
    fi
    if [ ! -f "$tarball" ]; then
        echo "[arm64-assets] FAIL: $dest not staged (run build/stage-build-inputs.sh --arch arm64)" >&2; fail=1; continue
    fi
    got="$(sha_of "$tarball")"
    if [ "$got" != "$pin" ]; then
        echo "[arm64-assets] FAIL: $dest sha256 $got != pin $pin -- refusing to extract" >&2; fail=1; continue
    fi
    if [ "$MODE" = check ]; then
        echo "[arm64-assets] OK $dest (sha256 $pin)"; continue
    fi
    # The archives carry a top-level sky1-firmware/ or cix-debs/ directory, so a
    # straight -C assets/ extraction recreates assets/<dir>/.
    if ! zstd -dc "$tarball" | tar -x -C "$ROOT/assets"; then
        echo "[arm64-assets] FAIL: could not extract $dest" >&2; fail=1; continue
    fi
    case "$dest" in
        *sky1-firmware.tar.zst)
            echo "[arm64-assets] extracted assets/sky1-firmware/ ($(find "$ROOT/assets/sky1-firmware" -type f | wc -l) files)" ;;
        *cix-debs.tar.zst)
            echo "[arm64-assets] extracted assets/cix-debs/ ($(find "$ROOT/assets/cix-debs" -maxdepth 1 -type f -name '*.deb' | wc -l) debs)" ;;
    esac
done

if [ "$fail" != 0 ]; then
    echo "[arm64-assets] FAIL (see lines above)" >&2
    exit 1
fi
echo "[arm64-assets] OK (mode=$MODE)"
