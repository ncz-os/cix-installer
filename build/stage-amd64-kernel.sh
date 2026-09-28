#!/bin/bash
# stage-amd64-kernel.sh -- pull the latest built amd64 kernel line(s) from the
# shared ARGONAS kernel-staging pool into assets/kernel/amd64-{stable,edge}/.
#
# Mirrors the arm64 side's stage-kernel.sh in spirit (kernel artifacts are
# gitignored and live in a shared, dated staging area on ARGONAS, per
# ~/.claude/rules/kernel-build-checklist.md's staging convention) but the
# amd64 payload is just a linux-image/linux-headers .deb pair per line, so
# this stays a plain copy rather than stage-kernel.sh's Image/modules/
# headers/staleness-check ceremony (that machinery is Sky1/Yocto-specific).
#
# Usage: build/stage-amd64-kernel.sh [stable|edge|all]  (default: all)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WHAT="${1:-all}"

# Different hosts mount the same ARGONAS export at different local paths
# (HYDRA/ACHILLES/PROTEUS: /mnt/argonas/datapool/yocto-shared via autofs;
# ULTRA: /mnt/argonas-yocto-shared) -- try both rather than hardcoding one.
for candidate in /mnt/argonas/datapool/yocto-shared /mnt/argonas-yocto-shared /mnt/yocto-shared; do
    [ -d "$candidate/kernel-staging" ] && SHARED="$candidate/kernel-staging" && break
done
[ -n "${SHARED:-}" ] || { echo "ERROR: no ARGONAS yocto-shared/kernel-staging mount found on this host" >&2; exit 1; }

stage_line() {  # <line-name e.g. amd64-stable> <staging-dir-prefix e.g. amd64-stable->
    local line="$1" prefix="$2"
    local latest
    latest=$(ls -dt "$SHARED"/${prefix}* 2>/dev/null | head -1)
    [ -n "$latest" ] || { echo "ERROR: no staged build found for $line (looked for $SHARED/${prefix}*)" >&2; return 1; }
    local dest="$ROOT/assets/kernel/$line"
    mkdir -p "$dest"
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
    find "$dest" -maxdepth 1 -type f \( -name 'linux-image-*_amd64.deb' \
        -o -name 'linux-headers-*_amd64.deb' \) -delete
    cp -f "$latest"/*.deb "$latest/KVER" "$dest/"
    echo "[stage-amd64-kernel] $line <- $(basename "$latest") (pruned to $(ls "$dest"/linux-image-*_amd64.deb 2>/dev/null | wc -l) image + $(ls "$dest"/linux-headers-*_amd64.deb 2>/dev/null | wc -l) headers pair)"
}

case "$WHAT" in
    stable) stage_line amd64-stable amd64-stable- ;;
    edge)   stage_line amd64-edge   amd64-edge-   ;;
    all)    stage_line amd64-stable amd64-stable-; stage_line amd64-edge amd64-edge- ;;
    *) echo "usage: $0 {stable|edge|all}" >&2; exit 2 ;;
esac
