#!/bin/bash
# verify-cuda-mirror.sh -- assert an AMD64 offline mirror carries the NVIDIA
# R615 driver and the CUDA 13.4 toolkit closure that post-install/54 installs.
#
# Checks the mirror's Packages index (and that each named .deb is really in the
# pool) for:
#   cuda-nvcc-13-4 / cuda-compiler-13-4   13.4.*
#   cuda-cudart-dev-13-4, cuda-libraries-13-4
#   nvidia-open, nvidia-kernel-open-dkms, libcuda1   615.*
#   nvidia-detect
# and that the PROPRIETARY nvidia-kernel-dkms is absent (CUDA 13.4 path is the
# open kernel modules only).
#
# usage: verify-cuda-mirror.sh --mirror DIR
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIRROR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --mirror) MIRROR="${2:-}"; shift 2 ;;
        -h|--help) echo "usage: $0 --mirror DIR"; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
    esac
done
[ -n "$MIRROR" ] || { echo "ERROR: --mirror is required" >&2; exit 2; }
[ -d "$MIRROR" ] || { echo "ERROR: mirror not found: $MIRROR" >&2; exit 1; }

# shellcheck source=../release.conf
. "$ROOT/release.conf"
SUITE="${NCZ_BASE_CODENAME:-forky}"
ARCH="${ARCH:-amd64}"
IDX="$MIRROR/dists/$SUITE/main/binary-$ARCH/Packages"
[ -s "$IDX" ] || { echo "ERROR: missing Packages index: $IDX" >&2; exit 1; }

fail=0
# want PACKAGE VERSION-GLOB
want() {
    local pkg="$1" glob="$2" rec ver file
    rec="$(awk -v p="$pkg" 'BEGIN{RS="";FS="\n"} {n="";v="";f=""; for(i=1;i<=NF;i++){if($i~/^Package: /)n=substr($i,10); if($i~/^Version: /)v=substr($i,10); if($i~/^Filename: /)f=substr($i,11)} if(n==p) print v" "f}' "$IDX")"
    if [ -z "$rec" ]; then
        echo "FAIL: $pkg absent from $IDX" >&2; fail=1; return
    fi
    ver="${rec%% *}"; file="${rec#* }"
    # shellcheck disable=SC2254
    case "$ver" in $glob) ;; *) echo "FAIL: $pkg version $ver does not match $glob" >&2; fail=1; return ;; esac
    if [ ! -f "$MIRROR/$file" ]; then
        echo "FAIL: $pkg indexed but $file is not in the pool" >&2; fail=1; return
    fi
    echo "ok   $pkg $ver"
}
want cuda-nvcc-13-4        '13.4.*'
want cuda-compiler-13-4    '13.4.*'
want cuda-cudart-dev-13-4  '13.4.*'
want cuda-libraries-13-4   '13.4.*'
want nvidia-open           '615.*'
want nvidia-kernel-open-dkms '615.*'
want libcuda1              '615.*'
want nvidia-detect         '*'

if awk '/^Package: nvidia-kernel-dkms$/{f=1} END{exit !f}' "$IDX"; then
    echo "FAIL: proprietary nvidia-kernel-dkms is in the mirror (open modules only)" >&2
    fail=1
fi
if [ "$fail" -ne 0 ]; then
    echo "verify-cuda-mirror: FAIL" >&2
    exit 1
fi
echo "verify-cuda-mirror: PASS ($MIRROR)"
