#!/bin/bash
# stage-amd64-kernel.sh -- pull the amd64 STABLE kernel line and (when
# requested) the pinned EDGE kernel line from the shared ARGONAS
# kernel-staging pool into assets/kernel/amd64-{stable,edge}/.
#
# Mirrors the arm64 side's stage-kernel.sh in spirit (kernel artifacts are
# gitignored and live in a shared, dated staging area on ARGONAS, per
# ~/.claude/rules/kernel-build-checklist.md's staging convention) but the
# amd64 payload is just a linux-image/linux-headers .deb pair, so this stays
# a plain copy rather than stage-kernel.sh's Image/modules/headers/staleness-
# check ceremony (that machinery is Sky1/Yocto-specific).
#
# POLICY (operator directive 2026-10-05): amd64 ships the 7.2.x stable line
# as the DEFAULT (pinned 7.2.9) plus, as a separate non-default rEFInd
# entry, exactly one pinned EDGE kernel: the 7.3.0-rc6 T2 build carrying the
# AER ANFE revert (7.3.0-rc6-1-t2-edge-aerfix). The edge KVER is read from
# the committed assets/kernel/amd64-edge/KVER pin; any other -rc build is
# refused. This supersedes the 2026-09-30 "amd64 ships no edge" rule.
#
# Usage: build/stage-amd64-kernel.sh [stable|edge|all]  (default: stable)
#   stable  copy the newest amd64-stable-* build into assets/kernel/amd64-stable/
#   edge    copy the build matching the committed edge KVER pin into
#           assets/kernel/amd64-edge/ (set AMD64_EDGE_SRC=<dir> to override)
#   all     do both
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WHAT="${1:-stable}"

# Different hosts mount the same ARGONAS export at different local paths
# (HYDRA/ACHILLES/PROTEUS: /mnt/argonas/datapool/yocto-shared via autofs;
# ULTRA: /mnt/argonas-yocto-shared) -- try both rather than hardcoding one.
for candidate in /mnt/argonas/datapool/yocto-shared /mnt/argonas-yocto-shared /mnt/yocto-shared; do
    [ -d "$candidate/kernel-staging" ] && SHARED="$candidate/kernel-staging" && break
done
[ -n "${SHARED:-}" ] || { echo "ERROR: no ARGONAS yocto-shared/kernel-staging mount found on this host" >&2; exit 1; }

# Prune the previous .deb pair from a line dir before copying the new one.
# cp -f overwrites files BY NAME, but a fresh kernel line (new version
# string) carries .deb basenames that the previous run did not have on
# disk -- so on any kernel bump the old .deb(s) silently accumulate
# alongside the new ones and the install hook's `find ... | sort -V |
# tail -1` would still resolve cleanly (sort -V picks the highest), but
# *humans* reading the dir see two lines and rightly wonder which one is
# shipping. More importantly: a future hook that does anything other
# than `sort -V | tail -1` (e.g. a dpkg -i of all of them, an `ls`
# listing, a verifier counting files) sees the previous version and the
# disagreement with KVER is the failure mode that broke the 2026-09-28
# image. Wipe the dest's previous .debs first; KVER is overwritten
# below anyway. We do NOT delete the dest itself -- other entries may
# be added there by hand (asset-curation scripts, recovery flows).
prune_debs() {
    find "$1" -maxdepth 1 -type f \( -name 'linux-image-*_amd64.deb' \
        -o -name 'linux-headers-*_amd64.deb' \) -delete
}

stage_line() {  # <line-name e.g. amd64-stable> <staging-dir-prefix e.g. amd64-stable->
    local line="$1" prefix="$2"
    local latest
    latest=$(ls -dt "$SHARED"/${prefix}* 2>/dev/null | head -1)
    [ -n "$latest" ] || { echo "ERROR: no staged build found for $line (looked for $SHARED/${prefix}*)" >&2; return 1; }
    local dest="$ROOT/assets/kernel/$line"
    mkdir -p "$dest"
    prune_debs "$dest"
    cp -f "$latest"/*.deb "$latest/KVER" "$dest/"
    echo "[stage-amd64-kernel] $line <- $(basename "$latest") (pruned to $(ls "$dest"/linux-image-*_amd64.deb 2>/dev/null | wc -l) image + $(ls "$dest"/linux-headers-*_amd64.deb 2>/dev/null | wc -l) headers pair)"
}

stage_edge() {
    # Copy the edge build that matches the committed pin. The pin is the
    # contract: a pool build whose KVER disagrees with it is never staged,
    # so an unpinned -rc cannot slip in through a newer-by-mtime glob.
    local pin_file="$ROOT/assets/kernel/amd64-edge/KVER"
    [ -s "$pin_file" ] || { echo "ERROR: $pin_file missing -- the pinned amd64 edge KVER must be committed" >&2; return 1; }
    local wanted src="" d
    wanted=$(tr -d '[:space:]' < "$pin_file")
    [ -n "$wanted" ] || { echo "ERROR: $pin_file is empty" >&2; return 1; }
    if [ -n "${AMD64_EDGE_SRC:-}" ]; then
        src="$AMD64_EDGE_SRC"
    else
        # Search the pool for a directory whose KVER sidecar matches the
        # pin. Covers the published amd64-edge-<kver>-<date> namespace and
        # the multi-variant amd64-t2-* build trees (e.g.
        # amd64-t2-rc6-20261004/7.3.0-rc6-1-t2-edge-aerfix).
        for d in "$SHARED"/amd64-edge-* "$SHARED"/amd64-t2-*/*/; do
            [ -d "$d" ] || continue
            [ -s "$d/KVER" ] || continue
            if [ "$(tr -d '[:space:]' < "$d/KVER")" = "$wanted" ]; then
                src="${d%/}"
                break
            fi
        done
    fi
    [ -n "$src" ] && [ -d "$src" ] || {
        echo "ERROR: no staged amd64 edge build matches pinned KVER '$wanted' under $SHARED" >&2
        echo "       (publish it with build/publish-amd64-kernel.sh edge <deb-dir>, or set AMD64_EDGE_SRC)" >&2
        return 1
    }
    # The pin is a hard contract even for an explicit AMD64_EDGE_SRC: a
    # source tree whose KVER disagrees with the committed pin is refused.
    if [ ! -s "$src/KVER" ] || [ "$(tr -d '[:space:]' < "$src/KVER")" != "$wanted" ]; then
        echo "ERROR: $src/KVER does not match the pinned amd64 edge KVER '$wanted' -- refusing to stage" >&2
        return 1
    fi
    local dest="$ROOT/assets/kernel/amd64-edge"
    mkdir -p "$dest"
    prune_debs "$dest"
    cp -f "$src"/*.deb "$src/KVER" "$dest/"
    echo "[stage-amd64-kernel] amd64-edge <- $(basename "$src") (pinned KVER $wanted, pruned to $(ls "$dest"/linux-image-*_amd64.deb 2>/dev/null | wc -l) image + $(ls "$dest"/linux-headers-*_amd64.deb 2>/dev/null | wc -l) headers pair)"
}

case "$WHAT" in
    stable|"") stage_line amd64-stable amd64-stable- ;;
    edge)      stage_edge ;;
    all)       stage_line amd64-stable amd64-stable- && stage_edge ;;
    *) echo "usage: $0 [stable|edge|all]" >&2; exit 2 ;;
esac
