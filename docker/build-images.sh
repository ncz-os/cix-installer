#!/usr/bin/env bash
# build-images.sh -- build BOTH NCZ-OS build containers, on any build host:
# the Yocto kernel container (docker/Containerfile.yocto) and the raw GPT
# image-build container (build/containers/Containerfile.ncz-imagebuild).
#
# Both arm64 build hosts run podman (since 2026-08-28), so
# one script works everywhere. Previously one used docker and the other used
# podman, and each host built only the image for its own half of the pipeline
# from a file that existed nowhere else -- which is how they drifted.
#
# ROOTFUL vs ROOTLESS MATTERS. Rootless podman cannot mknod, which blocks
# rootfs extraction during an image build. Pass --rootful to build/run the
# images under `sudo podman` on a host whose image builds need device nodes.
#
#   ./build-images.sh              # build both images, rootless
#   ./build-images.sh --rootful    # build both under sudo podman
#   ./build-images.sh --only yocto # build just one (yocto | imagebuild)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
ENGINE=(podman)
ONLY=""
while [ $# -gt 0 ]; do
    case "$1" in
        --rootful) ENGINE=(sudo podman); shift ;;
        --only)    ONLY="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

command -v podman >/dev/null || { echo "podman not installed on $(hostname)" >&2; exit 1; }

case "$ONLY" in ""|yocto|imagebuild) ;; *) echo "--only takes yocto or imagebuild" >&2; exit 1 ;; esac

build() { # <tag> <containerfile path> <context dir>
    echo "[build-images] $1  <-  $2  (engine: ${ENGINE[*]})"
    "${ENGINE[@]}" build \
        --build-arg BUILD_UID="$(id -u)" \
        --build-arg BUILD_GID="$(id -g)" \
        -t "$1" -f "$2" "$3"
}

[ "$ONLY" = "imagebuild" ] || build ncz-yocto-y6:trixie    "$HERE/Containerfile.yocto" "$HERE"
[ "$ONLY" = "yocto" ]      || build ncz-imagebuild:trixie  "$REPO/build/containers/Containerfile.ncz-imagebuild" "$REPO/build/containers"

echo "[build-images] done on $(hostname)"
"${ENGINE[@]}" images --format '  {{.Repository}}:{{.Tag}}  {{.ID}}' | grep -E 'ncz-(yocto|imagebuild)' || true
