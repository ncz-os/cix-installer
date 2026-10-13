#!/bin/bash
# verify-cuda-assets.sh -- static gate for the AMD64 dynamic NVIDIA/CUDA design.
#
#  1. The repo keys are staged: assets/nvidia/cuda-keyring_1.1-1_all.deb (debian13
#     repo, Turing+) and assets/nvidia/cuda-archive-keyring-debian12.gpg (debian12
#     repo, Maxwell..Volta).
#  2. ncz-cuda-setup and its systemd units are staged and well-formed (network-online
#     ordering, SuccessExitStatus=75, idempotence condition, timer).
#  3. NO driver or CUDA packages are seeded in any manifest (Debian's own
#     firmware-nvidia-* blobs for nouveau are allowed): the design decision
#     is that CUDA is downloaded at install time, not baked into the image.
#  4. With --mirror DIR: the built offline mirror index carries no NVIDIA driver or
#     CUDA package (cuda-*, nvidia-*, libnvidia-*, libcu*-N-M, libnpp-*, ...).
#  5. Every toolkit family ships the -dev pieces (cuda-libraries-dev-*).
#
# usage: verify-cuda-assets.sh [--mirror DIR]
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIRROR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --mirror) MIRROR="${2:-}"; shift 2 ;;
        --root)   ROOT="${2:-}"; shift 2 ;;   # test hook
        -h|--help) echo "usage: $0 [--mirror DIR]"; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
    esac
done
fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }
A="$ROOT/assets/nvidia"

[ -s "$A/cuda-keyring_1.1-1_all.deb" ] || bad "missing $A/cuda-keyring_1.1-1_all.deb"
[ -s "$A/cuda-archive-keyring-debian12.gpg" ] || bad "missing $A/cuda-archive-keyring-debian12.gpg"
[ -x "$A/ncz-cuda-setup" ] || bad "$A/ncz-cuda-setup missing or not executable"
[ -x "$A/ncz-cuda-setup" ] && { bash -n "$A/ncz-cuda-setup" 2>/dev/null || bad "ncz-cuda-setup has a syntax error"; }
U="$A/ncz-cuda-setup.service"; T="$A/ncz-cuda-setup.timer"
[ -f "$U" ] || bad "missing $U"
[ -f "$T" ] || bad "missing $T"
if [ -f "$U" ]; then
    grep -q '^After=.*network-online.target' "$U" || bad "service is not ordered After=network-online.target"
    grep -q '^SuccessExitStatus=75' "$U" || bad "service lacks SuccessExitStatus=75 (EX_TEMPFAIL must not be a failure)"
    grep -q '^ConditionPathExists=!/var/lib/ncz/cuda-setup.done' "$U" || bad "service is not idempotent (no stamp condition)"
    grep -q '^Type=oneshot' "$U" || bad "service is not Type=oneshot"
    grep -q '^WantedBy=' "$U" && bad "service must not be WantedBy anything (it must not join the boot transaction)"
fi
if [ -f "$T" ]; then
    grep -q '^OnBootSec=' "$T" || bad "timer lacks OnBootSec"
    grep -q '^WantedBy=timers.target' "$T" || bad "timer is not WantedBy=timers.target"
fi

# 3. manifests must not seed NVIDIA/CUDA packages
PATTERN='^(cuda|nvidia|libnvidia|libcuda|libcu[a-z]*-(dev-)?[0-9]|libnpp|libnvjitlink|libnvfatbin|libnvjpeg|libnvvm|libnvptx|xserver-xorg-video-nvidia|nsight)'
for m in "$ROOT"/manifests/*.pkgs; do
    [ -f "$m" ] || continue
    if sed 's/#.*//' "$m" | awk 'NF{print $1}' | grep -E "$PATTERN" >/dev/null; then
        bad "$(basename "$m") seeds NVIDIA/CUDA packages: $(sed 's/#.*//' "$m" | awk 'NF{print $1}' | grep -E "$PATTERN" | tr '\n' ' ')"
    fi
done

# 5. -dev pieces in every toolkit plan
if [ -r "$ROOT/post-install/lib/cuda-select.sh" ]; then
    # shellcheck disable=SC1091
    . "$ROOT/post-install/lib/cuda-select.sh"
    for fam in turing-plus maxwell-volta; do
        ncz_cuda_plan "$fam" | grep -q "^TOOLKIT_PKGS='.*cuda-libraries-dev-" || bad "$fam toolkit plan lacks cuda-libraries-dev (headers)"
    done
else
    bad "missing post-install/lib/cuda-select.sh"
fi

# 4. built mirror
if [ -n "$MIRROR" ]; then
    [ -d "$MIRROR" ] || bad "mirror not found: $MIRROR"
    IDX=$(ls "$MIRROR"/dists/*/main/binary-amd64/Packages 2>/dev/null | head -n1)
    if [ -z "$IDX" ]; then bad "no Packages index under $MIRROR"; else
        hits=$(awk '/^Package: /{print $2}' "$IDX" | grep -E "$PATTERN" | tr '\n' ' ')
        [ -z "$hits" ] || bad "offline mirror contains NVIDIA/CUDA packages (must be downloaded at install time): $hits"
    fi
fi

if [ "$fail" -ne 0 ]; then echo "verify-cuda-assets: FAIL" >&2; exit 1; fi
echo "verify-cuda-assets: PASS"
