#!/bin/bash
# stage-amd64-kernel.sh -- pull the single unified amd64 7.3 kernel from the
# shared kernel-staging pool into assets/kernel/amd64-stable/.
#
# Mirrors the arm64 side's stage-kernel.sh in spirit (kernel artifacts are
# gitignored and live in a shared, dated staging area on the artifact store,
# per the project's kernel staging convention) but the
# amd64 payload is just a linux-image/linux-headers .deb pair, so this stays
# a plain copy rather than stage-kernel.sh's Image/modules/headers/staleness-
# check ceremony (that machinery is Sky1/Yocto-specific).
#
# POLICY (operator directive 2026-10-05, unified): amd64 ships ONE kernel,
# 7.3, as the DEFAULT and the installer boot kernel (today
# 7.3.0-rc7-t2-ncz, the T2 build with the SEP ANFE quirk 9011 + Wunner
# 79c168e2aa95 which is in v7.3-rc7; the 7.3.0 final build later). The
# committed assets/kernel/amd64-stable/KVER is the pin; a pool build whose
# KVER disagrees with it is never staged, so a different series (7.2.x) or
# an unpinned build cannot slip in. There is no edge channel any more.
#
# Usage: build/stage-amd64-kernel.sh [default|stable|all]  (default: default)
#   default copy the build matching the committed KVER pin into
#           assets/kernel/amd64-stable/ (set AMD64_SRC=<dir> to override)
#   stable  alias for default (historical name)
#   all     alias for default (single-kernel tree)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WHAT="${1:-default}"

# Different hosts mount the shared Yocto export at different local paths, so the
# root comes from NCZ_YOCTO_SHARED_DIR or ~/.config/ncz/yocto-shared-dir
# (build/lib/ncz-site.sh) rather than a hardcoded mount point.
. "$ROOT/build/lib/ncz-site.sh"
_ysd="$(ncz_site_value NCZ_YOCTO_SHARED_DIR yocto-shared-dir)"
[ -n "$_ysd" ] && [ -d "$_ysd/kernel-staging" ] && SHARED="$_ysd/kernel-staging"
[ -n "${SHARED:-}" ] || { echo "ERROR: kernel-staging pool not found: set NCZ_YOCTO_SHARED_DIR (or ~/.config/ncz/yocto-shared-dir) to the shared Yocto export root" >&2; exit 1; }

# The staging dir ships EXACTLY ONE kernel: the pinned linux-image +
# linux-headers .deb PAIR.  Two independent gates enforce that:
#   * forky-provenance.py's one-kernel audit (KERNEL_ARTIFACT_RE matches
#     linux-image*/linux-headers*) requires every kernel artifact present in
#     the finished image to be a row in manifests/ncz-packages.tsv, which
#     authorises only the pair; and
#   * post-install/10-amd64-kernel.sh requires exactly one linux-image-*.deb
#     and one linux-headers-*.deb in this dir.
# A `make deb-pkg` pool build ALSO emits linux-image-<KVER>-dbg (debug
# symbols, ~1.1 GiB) and linux-libc-dev; neither is a shipping artifact and
# neither is in the ledger.  A wholesale `cp "$src"/*.deb` (the old shape)
# leaked both into base.squashfs and failed the provenance gate on rc7
# (the rc6-4 pool happened to carry only the pair, so the bug was latent).
# Prune every .deb, then stage the pair by name.
prune_debs() {
    find "$1" -maxdepth 1 -type f -name '*.deb' -delete
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
    # Optional package-REVISION pin: assets/kernel/amd64-stable/PKGVERSION.
    # The KVER is deliberately stable across the r1/r2 rebuilds of the same
    # 7.3.0-rc7-t2-ncz kernel, so a KVER-only pool search is ambiguous once
    # two same-KVER staging dirs exist (amd64-t2-rc7-20261011 r1 vs
    # amd64-t2-rc7-r2-20261012 r2). When PKGVERSION is present, only a pool
    # dir holding linux-image-<KVER>_<PKGVERSION>_amd64.deb is eligible.
    local pkgver=""
    if [ -s "$ROOT/assets/kernel/amd64-stable/PKGVERSION" ]; then
        pkgver=$(tr -d '[:space:]' < "$ROOT/assets/kernel/amd64-stable/PKGVERSION")
    fi
    if [ -n "${AMD64_SRC:-}" ]; then
        src="$AMD64_SRC"
    else
        # Search the pool for a directory whose KVER sidecar matches the pin.
        # Covers the multi-variant amd64-t2-* build trees (e.g.
        # amd64-t2-rc7-r2-20261012/7.3.0-rc7-t2-ncz) and the generic
        # amd64-stable-<date> namespace. With PKGVERSION set, a dir must also
        # carry the pinned package revision.
        for d in "$SHARED"/amd64-t2-*/*/ "$SHARED"/amd64-stable-*/; do
            [ -d "$d" ] || continue
            [ -s "$d/KVER" ] || continue
            [ "$(tr -d '[:space:]' < "$d/KVER")" = "$wanted" ] || continue
            if [ -n "$pkgver" ] && [ ! -f "$d/linux-image-${wanted}_${pkgver}_amd64.deb" ]; then
                continue
            fi
            src="${d%/}"
            break
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
    # Name the pinned pair explicitly.  `linux-image-${wanted}_*.deb` cannot
    # match `linux-image-${wanted}-dbg_*.deb` (the suffix starts with '-', not
    # '_'), so the -dbg build can never be selected here.  Fail closed if the
    # pool does not hold exactly one of each.
    local imgs hdrs
    if [ -n "$pkgver" ]; then
        imgs=("$src"/linux-image-"$wanted"_"$pkgver"_amd64.deb)
        hdrs=("$src"/linux-headers-"$wanted"_"$pkgver"_amd64.deb)
    else
        imgs=("$src"/linux-image-"$wanted"_*.deb)
        hdrs=("$src"/linux-headers-"$wanted"_*.deb)
    fi
    if [ ! -f "${imgs[0]}" ] || [ "${#imgs[@]}" -ne 1 ] \
       || [ ! -f "${hdrs[0]}" ] || [ "${#hdrs[@]}" -ne 1 ]; then
        echo "ERROR: $src must hold exactly one linux-image-${wanted}_*.deb and one linux-headers-${wanted}_*.deb (found ${#imgs[@]} image / ${#hdrs[@]} headers) -- refusing to stage" >&2
        return 1
    fi
    local dest="$ROOT/assets/kernel/amd64-stable"
    mkdir -p "$dest"
    prune_debs "$dest"
    cp -f "${imgs[0]}" "${hdrs[0]}" "$src/KVER" "$dest/"
    echo "[stage-amd64-kernel] amd64-stable <- $(basename "$src") (pinned KVER $wanted, staged exactly $(ls "$dest"/*.deb 2>/dev/null | wc -l) debs: the image+headers pair)"
}

case "$WHAT" in
    default|stable|"") stage_default ;;
    all)               stage_default ;;
    edge)              echo "ERROR: the amd64 edge channel was retired (unified 7.3 policy, operator 2026-10-05)" >&2; exit 2 ;;
    *) echo "usage: $0 [default|stable|all]" >&2; exit 2 ;;
esac
