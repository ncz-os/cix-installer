#!/bin/bash
# Verify that the staged amd64 kernel assets on disk match the kernel
# assets embedded inside assets/squashfs/base.squashfs.
#
# WHY THIS EXISTS (2026-09-28).
#   The amd64 installer hook 10-amd64-kernel.sh installs the kernels from
#   /usr/local/lib/cix-installer/assets/kernel/amd64-{stable,edge}/ --
#   which is baked INTO base.squashfs by build/build-squashfs-layers.sh's
#   build_base() at the moment base is built. Once baked, the embed is
#   frozen: re-running `build/build-squashfs-layers.sh all` then re-stages
#   the .debs on the build disk but reuses the existing base.squashfs
#   verbatim, so the IMAGE keeps shipping the OLD .debs while the build
#   host now has the NEW .debs. The install hook installs whatever's in
#   the image (the OLD .debs), but a side-car KVER file it consults may
#   have come from a different point in time and the two can disagree.
#
#   Confirmed live 2026-09-28 on the amd64 image ncz-os-amd64-20260928-
#   c291de2.img: commit c291de2 advanced both lines (7.2.7->7.2.8 and
#   7.3.0-rc4-xhcifix->7.3.0-rc5), the rc5 .debs were staged onto the
#   build host, but base.squashfs was reused from 2026-09-26, so the
#   install gate saw the OLD rc4-xhcifix kernel installed (rc4 was
#   embedded) and the side-car KVER pointing at rc5 -- a check that
#   disagrees with what is actually on disk is worse than no check.
#
#   Same defect class as the desktop-mirror staleness gap closed in
#   3fc79c3: a layer cached on inputs that exclude what changed. Mirror
#   that fix's shape: a verifier that compares the layer's contents
#   against the inputs it should have been rebuilt from, and a Makefile
#   target that rebuilds the layer (rotating the stale one aside under
#   base.squashfs.stale-<ts>, the same convention already used here)
#   when the verifier fails.
#
#   This is a BASE-layer check, NOT a check of the .deb basenames that
#   dpkg actually installs on the target. The hook (post-install/
#   10-amd64-kernel.sh) consumes the basenames INSIDE base.squashfs at
#   install time, so the base.squashfs content is the relevant cache
#   key. Matching base.squashfs against the source tree is therefore
#   the right invariant; if it ever stops being right, the symptom is a
#   failed install gate, not a successful one.
#
#   LC_ALL=C throughout: sort under a UTF-8 locale collates hyphens and
#   dots differently than comm compares them, and package filenames are
#   full of both. Same reason verify-desktop-mirror-seeds.sh uses it.
#
# Exit codes:
#   0  layer is consistent with the staged source (PASS)
#   1  layer is STALE (lists each divergence; build target rebuilds)
#   2  misuse (bad args / missing inputs / unsquashfs absent)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAYER=""
LABEL="base-kernel-assets"

usage(){ echo "usage: $0 [--layer PATH] [--label NAME]" >&2; }
while [ $# -gt 0 ]; do
    case "$1" in
        --layer) LAYER="${2:-}"; shift 2 ;;
        --label) LABEL="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done

# Defaults so the verifier is callable from `all` without flags.
LAYER="${LAYER:-$ROOT/assets/squashfs/base.squashfs}"

command -v unsquashfs >/dev/null || { echo "verify-base-kernel-assets: ERROR: unsquashfs not on PATH" >&2; exit 2; }
[ -f "$LAYER" ] || { echo "$LABEL: layer absent ($LAYER)" >&2; exit 1; }

SRC_BASE="$ROOT/assets/kernel"
EMBED_BASE="usr/local/lib/cix-installer/assets/kernel"

# The single amd64 kernel line the install hook reads. arm64 has its own
# asset layout (assets/kernel/mainline/, KVER_NEXT, etc.) and a different
# hook (10-our-kernel.sh) -- out of scope for this verifier.
#
# Bug 2 fix (2026-09-28, arm64 host). The verifier used to RUN on every
# host that built a base.squashfs, including ULTRA (arm64/Sky1).
# On an arm64 host assets/kernel/amd64-stable/ holds only a KVER stub --
# there is no Image-cixmini.bin, no .deb pairs, nothing this verifier
# knows how to compare -- so the per-line pair sanity check reported
# empty channels and exited 1:
#     ERROR: base.squashfs: amd64-stable holds 0 image(s) and 0 headers(s) (must be exactly 1 of each)
# On ULTRA's 2026-09-28 arm64 build run the verifier aborted
# base.squashfs reuse even though the kernel input it would have
# checked (amd64 lines) was not relevant to that image at all. Gate the
# verifier the same way post-install/10-our-kernel.sh and
# post-install/10-amd64-kernel.sh already gate themselves: env var
# first, then the late.sh-stamped BUILD_ARCH sidecar, then
# dpkg --print-architecture as a last-resort fallback. On arm64 it
# skips cleanly; on amd64 it runs the existing comparison as before.
#
# Policy update (operator directive 2026-10-05): amd64 ships the 7.2.x
# stable line as the default plus the pinned 7.3.0-rc6 AER-revert edge line
# (7.3.0-rc6-1-t2-edge-aerfix). LINES now covers amd64-stable and, when that
# channel is present, amd64-edge; the embed filter matches both.
ARCH="${NCZ_TARGET_ARCH:-}"
if [ -z "$ARCH" ] && [ -r "$ROOT/build/iso-staging-di/ncz-payload/BUILD_ARCH" ]; then
    ARCH=$(tr -d '[:space:]' < "$ROOT/build/iso-staging-di/ncz-payload/BUILD_ARCH")
fi
ARCH="${ARCH:-$(dpkg --print-architecture 2>/dev/null || true)}"
if [ "$ARCH" != "amd64" ]; then
    echo "verify-base-kernel-assets: skipped (NCZ_TARGET_ARCH=$ARCH -- amd64-only verifier; arm64/Sky1 uses assets/kernel/mainline + 10-our-kernel.sh, not the amd64 .deb-pair layout this verifier compares against)"
    exit 0
fi
LINES=(amd64-stable)
[ -d "$ROOT/assets/kernel/amd64-edge" ] && LINES+=(amd64-edge)

EMBED_LIST="$(mktemp "${TMPDIR:-/tmp}/ncz-vbka-embed.XXXXXX")"
SRC_LIST="$(mktemp "${TMPDIR:-/tmp}/ncz-vbka-src.XXXXXX")"
trap 'rm -f "$EMBED_LIST" "$SRC_LIST"' EXIT

# unsquashfs -l lists every path inside the layer without extraction
# (no /tmp write, no sudo). Lines start with "squashfs-root/" (a
# synthetic prefix unsquashfs adds; not part of the archive) -- strip
# it before matching, then filter to FILES (not directory entries)
# under the amd64-stable channel, and pull just the basenames. The
# on-disk path inside the layer is a build detail; only the filenames
# matter because that is what dpkg -i receives at install time. KVER
# sidecars under amd64-stable are also matched -- the staging script
# keeps one KVER per line, so that file IS part of the embed contract
# (10-amd64-kernel.sh historically read it; the filename derivation in
# the rewritten hook no longer depends on it, but a future hook or
# operator inspection might).
EMBED_LINES_RE='amd64-(stable|edge)'
unsquashfs -l "$LAYER" 2>/dev/null \
    | sed -e 's#^squashfs-root/##' \
    | awk -v eb="$EMBED_BASE" -v lre="$EMBED_LINES_RE" '
          BEGIN { re = "^(" lre ")/[^/]+$" }
          index($0, eb "/") == 1 {
              sub("^" eb "/", "", $0)
              if ($0 ~ re) {
                  sub(".*/", "", $0)
                  print
              }
          }
      ' \
    | LC_ALL=C sort -u > "$EMBED_LIST"

# Source: basenames under assets/kernel/<line>/, all lines together,
# because the layer embeds them all together. Includes the KVER
# sidecar -- it is part of the embed contract (10-amd64-kernel.sh
# historically read it; the rewritten hook derives its expected kver
# from the .deb filename now, but the sidecar is still committed and
# still gets baked in, so it must remain consistent with the source).
# Policy update (2026-10-05): amd64-stable and the pinned amd64-edge
# channel are both scanned when amd64-edge is present in the tree.
: > "$SRC_LIST"
for line in "${LINES[@]}"; do
    d="$SRC_BASE/$line"
    [ -d "$d" ] || { echo "verify-base-kernel-assets: ERROR: source dir absent: $d" >&2; exit 2; }
    [ -f "$d/KVER" ] && echo "KVER" >> "$SRC_LIST"
    find "$d" -maxdepth 1 -type f -name 'linux-image-*_amd64.deb'   -printf '%f\n' >> "$SRC_LIST"
    find "$d" -maxdepth 1 -type f -name 'linux-headers-*_amd64.deb' -printf '%f\n' >> "$SRC_LIST"
done
LC_ALL=C sort -u "$SRC_LIST" -o "$SRC_LIST"

DIVERGE=0
MISSING_IN_LAYER="$(LC_ALL=C comm -23 "$SRC_LIST" "$EMBED_LIST")"
EXTRA_IN_LAYER="$(LC_ALL=C   comm -13 "$SRC_LIST" "$EMBED_LIST")"

if [ -n "$MISSING_IN_LAYER" ]; then
    echo "ERROR: $LABEL is stale -- staged kernel asset(s) absent from $LAYER:" >&2
    sed 's/^/  + /' <<<"$MISSING_IN_LAYER" >&2
    DIVERGE=1
fi
if [ -n "$EXTRA_IN_LAYER" ]; then
    echo "ERROR: $LABEL is stale -- $LAYER still embeds kernel asset(s) that are no longer staged on disk:" >&2
    sed 's/^/  - /' <<<"$EXTRA_IN_LAYER" >&2
    DIVERGE=1
fi

# Per-line pair sanity: each line must carry exactly one image + one
# headers. stage-amd64-kernel.sh now prunes to one pair; this is the
# cheap gate that catches a regression of that behavior before it
# reaches the install hook.
PAIR_BAD=0
for line in "${LINES[@]}"; do
    d="$SRC_BASE/$line"
    nimg=$(find "$d" -maxdepth 1 -type f -name 'linux-image-*_amd64.deb'   | wc -l | tr -d ' ')
    nhdr=$(find "$d" -maxdepth 1 -type f -name 'linux-headers-*_amd64.deb' | wc -l | tr -d ' ')
    if [ "$nimg" -ne 1 ] || [ "$nhdr" -ne 1 ]; then
        echo "ERROR: $LABEL: $line holds $nimg image(s) and $nhdr headers(s) (must be exactly 1 of each)" >&2
        ls -1 "$d"/linux-image-*_amd64.deb "$d"/linux-headers-*_amd64.deb 2>/dev/null | sed 's/^/    /' >&2
        PAIR_BAD=1
    fi
done

if [ "$DIVERGE" -ne 0 ] || [ "$PAIR_BAD" -ne 0 ]; then
    echo "  (rebuild: remove $LAYER and re-run build/build-squashfs-layers.sh base)" >&2
    exit 1
fi

echo "verify-base-kernel-assets: PASS ($LABEL embeds the exact $(wc -l < "$SRC_LIST") staged amd64 kernel asset(s); 1 image + 1 headers per line)"