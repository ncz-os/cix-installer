#!/bin/bash
# stage-to-argonas.sh -- copy a GATED build artifact to the ARGONAS images
# store, with sha256 verification.  Called by build/build-image.sh's archive
# stage AFTER the KVM and provenance gates have PASSed this run.
#
# This is NOT ship-image.sh: it does not tag, it does not reap, it does not
# touch a live repo/R2/Buildkite, and it deletes nothing.  Retention (only the
# last operator-validated image per arch + the in-flight candidate) is enforced
# by the operator/runbook, not here.  See docs/IMAGE-RELEASE-RUNBOOK.md.
#
#   build/stage-to-argonas.sh <arch> <image> <run-dir> [archive-dir]
#
# Copies: <image>, <image>.receipt.json (if present), <image>.sha256 (created),
# and the run's build-image.log if a run dir is given.  Fails closed on any
# sha mismatch or missing image.
set -euo pipefail

ARCH="${1:?usage: stage-to-argonas.sh <arch> <image> <run-dir> [archive-dir]}"
IMG="${2:?image path required}"
RUN_DIR="${3:-}"
ARCHIVE="${4:-}"

sha_of() { sha256sum "$1" | awk '{print $1}'; }

[ -f "$IMG" ] || { echo "[stage] FAIL: image not found: $IMG" >&2; exit 1; }
case "$IMG" in
    *.img) ;;
    *) echo "[stage] FAIL: expected a .img artifact, got: $IMG" >&2; exit 1 ;;
esac

if [ -z "$ARCHIVE" ]; then
    for d in "${NCZ_IMAGE_ARCHIVE:-}" \
             /mnt/argonas/datapool/projects/ncz-os-assets/images \
             /mnt/argonas-projects/ncz-os-assets/images \
             /mnt/argonas/projects/ncz-os-assets/images; do
        [ -n "$d" ] || continue
        [ -d "$d" ] && { ARCHIVE="$d"; break; }
    done
fi
[ -n "$ARCHIVE" ] || { echo "[stage] FAIL: no reachable ARGONAS images dir (set NCZ_IMAGE_ARCHIVE)" >&2; exit 1; }
[ -d "$ARCHIVE" ] || { echo "[stage] FAIL: $ARCHIVE is not a directory" >&2; exit 1; }

BASE="$(basename "$IMG")"
DEST="$ARCHIVE/$BASE"
IMG_SHA="$(sha_of "$IMG")"

# Refuse to overwrite a DIFFERENT file of the same name.
if [ -f "$DEST" ] && [ "$(sha_of "$DEST")" != "$IMG_SHA" ]; then
    echo "[stage] FAIL: $DEST exists with a different sha256; refusing to clobber" >&2
    exit 1
fi

echo "[stage] $IMG_SHA  $BASE" > "$RUN_DIR/$BASE.sha256" 2>/dev/null || true
tmp="$ARCHIVE/.$BASE.part.$$"
cp -f "$IMG" "$tmp" 2>/dev/null || { echo "[stage] FAIL: cannot write to $ARCHIVE" >&2; exit 1; }
[ "$(sha_of "$tmp")" = "$IMG_SHA" ] || { rm -f "$tmp"; echo "[stage] FAIL: copy corrupted in transit" >&2; exit 1; }
mv -f "$tmp" "$DEST"

SIDE=0
for s in "$IMG.receipt.json" "$RUN_DIR/$BASE.sha256"; do
    [ -f "$s" ] || continue
    cp -f "$s" "$ARCHIVE/$(basename "$s")" && SIDE=$((SIDE + 1))
done
echo "$IMG_SHA  $BASE" > "$ARCHIVE/$BASE.sha256"

# Verify the archived copy round-trips.
[ "$(sha_of "$DEST")" = "$IMG_SHA" ] || { echo "[stage] FAIL: archived copy sha mismatch" >&2; exit 1; }
echo "[stage] archived $DEST (sha256 verified, $((SIDE + 1)) sidecar(s))"
echo "[stage] retention: keep only the last operator-validated image per arch + this candidate; reap is operator-only"
echo "[stage] df $ARCHIVE: $(df -Ph "$ARCHIVE" | awk 'NR==2{print $2" total, "$4" free"}')"
