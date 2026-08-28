#!/usr/bin/env bash
# build-images.sh -- build BOTH NCZ-OS build containers, on any build host.
#
# Both hosts run podman (TYDEUS gained it 2026-08-28; ULTRA already had it), so
# one script works everywhere. Previously TYDEUS used docker and ULTRA used
# podman, and each host built only the image for its own half of the pipeline
# from a file that existed nowhere else -- which is how they drifted.
#
# ROOTFUL vs ROOTLESS MATTERS. Rootless podman cannot mknod, which blocks
# rootfs extraction during an ISO build. Pass --rootful to build/run the images
# under `sudo podman` on a host whose ISO builds need device nodes.
#
#   ./build-images.sh              # build both images, rootless
#   ./build-images.sh --rootful    # build both under sudo podman
#   ./build-images.sh --only yocto # build just one
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

build() { # <tag> <containerfile>
    echo "[build-images] $1  <-  $2  (engine: ${ENGINE[*]})"
    "${ENGINE[@]}" build \
        --build-arg BUILD_UID="$(id -u)" \
        --build-arg BUILD_GID="$(id -g)" \
        -t "$1" -f "$HERE/$2" "$HERE"
}

[ "$ONLY" = "isobuild" ] || build ncz-yocto-y6:trixie   Containerfile.yocto
[ "$ONLY" = "yocto" ]    || build ncz-isobuild:trixie   Containerfile.isobuild

echo "[build-images] done on $(hostname)"
"${ENGINE[@]}" images --format '  {{.Repository}}:{{.Tag}}  {{.ID}}' | grep -E 'ncz-(yocto|isobuild)' || true
