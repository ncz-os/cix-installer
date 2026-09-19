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
    cp -f "$latest"/*.deb "$latest/KVER" "$dest/"
    echo "[stage-amd64-kernel] $line <- $(basename "$latest")"
}

case "$WHAT" in
    stable) stage_line amd64-stable amd64-stable- ;;
    edge)   stage_line amd64-edge   amd64-edge-   ;;
    all)    stage_line amd64-stable amd64-stable-; stage_line amd64-edge amd64-edge- ;;
    *) echo "usage: $0 {stable|edge|all}" >&2; exit 2 ;;
esac
