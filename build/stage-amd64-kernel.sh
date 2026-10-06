#!/bin/bash
# stage-amd64-kernel.sh -- pull the single unified amd64 7.3 kernel from the
# shared ARGONAS kernel-staging pool into assets/kernel/amd64-stable/.
#
# Mirrors the arm64 side's stage-kernel.sh in spirit (kernel artifacts are
# gitignored and live in a shared, dated staging area on ARGONAS, per
# ~/.claude/rules/kernel-build-checklist.md's staging convention) but the
# amd64 payload is just a linux-image/linux-headers .deb pair, so this stays
# a plain copy rather than stage-kernel.sh's Image/modules/headers/staleness-
# check ceremony (that machinery is Sky1/Yocto-specific).
#
# POLICY (operator directive 2026-10-05, unified): amd64 ships ONE kernel,
# 7.3, as the DEFAULT and the installer boot kernel (today
# 7.3.0-rc6-3-t2-edge-aer9011, the T2 build with the 9011 Apple T2 Secure Enclave AER quirk; the
# 7.3.0 final build later). The committed assets/kernel/amd64-stable/KVER is
# the pin; a pool build whose KVER disagrees with it is never staged, so a
# different series (7.2.x) or an unpinned build cannot slip in. There is no
# edge channel any more.
#
# Usage: build/stage-amd64-kernel.sh [default|stable|all]  (default: default)
#   default copy the build matching the committed KVER pin into
#           assets/kernel/amd64-stable/ (set AMD64_SRC=<dir> to override)
#   stable  alias for default (historical name)
#   all     alias for default (single-kernel tree)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WHAT="${1:-default}"

# Different hosts mount the same ARGONAS export at different local paths
# (HYDRA/ACHILLES/PROTEUS: /mnt/argonas/datapool/yocto-shared via autofs;
# ULTRA: /mnt/argonas-yocto-shared) -- try both rather than hardcoding one.
for candidate in /mnt/argonas/datapool/yocto-shared /mnt/argonas-yocto-shared /mnt/yocto-shared; do
    [ -d "$candidate/kernel-staging" ] && SHARED="$candidate/kernel-staging" && break
done
[ -n "${SHARED:-}" ] || { echo "ERROR: no ARGONAS yocto-shared/kernel-staging mount found on this host" >&2; exit 1; }

# Prune the previous .deb pair from the line dir before copying the new one.
# Same rationale as before: a fresh kernel version carries new .deb basenames,
# so without pruning the old pair accumulates and a human/verifier can no
# longer tell which one is shipping.
prune_debs() {
    find "$1" -maxdepth 1 -type f \( -name 'linux-image-*_amd64.deb' \
        -o -name 'linux-headers-*_amd64.deb' \) -delete
}

stage_default() {
    # Copy the build that matches the committed pin. The pin is the contract:
    # a pool build whose KVER disagrees with it is never staged.
    local pin_file="$ROOT/assets/kernel/amd64-stable/KVER"
    [ -s "$pin_file" ] || { echo "ERROR: $pin_file missing -- the pinned amd64 7.3 KVER must be committed" >&2; return 1; }
    local wanted d
    wanted=$(tr -d '[:space:]' < "$pin_file")
    [ -n "$wanted" ] || { echo "ERROR: $pin_file is empty" >&2; return 1; }
    case "$wanted" in
        7.3.*|7.3-*) ;;
        *) echo "ERROR: pinned amd64 KVER '$wanted' is not the unified 7.3 series" >&2; return 1 ;;
    esac
    local src=""
    if [ -n "${AMD64_SRC:-}" ]; then
        src="$AMD64_SRC"
    else
        # Search the pool for a directory whose KVER sidecar matches the pin.
        # Covers the multi-variant amd64-t2-* build trees (e.g.
        # amd64-t2-rc6-20261004/7.3.0-rc6-3-t2-edge-aer9011) and the generic
        # amd64-stable-<date> namespace.
        for d in "$SHARED"/amd64-t2-*/*/ "$SHARED"/amd64-stable-*/; do
            [ -d "$d" ] || continue
            [ -s "$d/KVER" ] || continue
            if [ "$(tr -d '[:space:]' < "$d/KVER")" = "$wanted" ]; then
                src="${d%/}"
                break
            fi
        done
    fi
    [ -n "$src" ] && [ -d "$src" ] || {
        echo "ERROR: no staged amd64 build matches pinned KVER '$wanted' under $SHARED" >&2
        echo "       (publish it with build/publish-amd64-kernel.sh <deb-dir>, or set AMD64_SRC)" >&2
        return 1
    }
    if [ ! -s "$src/KVER" ] || [ "$(tr -d '[:space:]' < "$src/KVER")" != "$wanted" ]; then
        echo "ERROR: $src/KVER does not match the pinned amd64 KVER '$wanted' -- refusing to stage" >&2
        return 1
    fi
    local dest="$ROOT/assets/kernel/amd64-stable"
    mkdir -p "$dest"
    prune_debs "$dest"
    cp -f "$src"/*.deb "$src/KVER" "$dest/"
    echo "[stage-amd64-kernel] amd64-stable <- $(basename "$src") (pinned KVER $wanted, pruned to $(ls "$dest"/linux-image-*_amd64.deb 2>/dev/null | wc -l) image + $(ls "$dest"/linux-headers-*_amd64.deb 2>/dev/null | wc -l) headers pair)"
}

case "$WHAT" in
    default|stable|"") stage_default ;;
    all)               stage_default ;;
    edge)              echo "ERROR: the amd64 edge channel was retired (unified 7.3 policy, operator 2026-10-05)" >&2; exit 2 ;;
    *) echo "usage: $0 [default|stable|all]" >&2; exit 2 ;;
esac
