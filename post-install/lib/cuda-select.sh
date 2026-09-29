#!/bin/bash
# post-install/lib/cuda-select.sh -- NVIDIA GPU family -> driver branch + CUDA
# toolkit selection for the AMD64 image. SOURCE this file; it only defines
# functions (no side effects), so build/test-amd64-cuda-gates.sh can exercise
# every row with fixtures.
#
# The matrix (decided 2026-09-29, operator: "fall back to older cuda on older
# cards"):
#
#  family        PCI device id     driver                       CUDA toolkit
#  ------------  ----------------  ---------------------------  -------------
#  turing-plus   >= 0x1e00         R615 open kernel modules     13.4
#                (sm_75+)          (cuda-drivers, nvidia-open)  (debian13 repo)
#  maxwell-volta 0x1340 .. 0x1dff  R580 PROPRIETARY module      12.9
#                (sm_50 .. sm_70)  (cuda-drivers-580,           (debian12 repo)
#                                  nvidia-kernel-dkms; the
#                                  open modules are Turing+
#                                  only)
#  kepler-older  < 0x1340          none: NVIDIA and Debian ship no driver
#                                  or CUDA usable on forky      -> nouveau only
#
# Evidence:
#  - CUDA 13 dropped Maxwell/Pascal/Volta offline compilation and library
#    support: CUDA 12.9 release notes ("Maxwell, Pascal, and Volta architectures
#    are now feature-complete ... offline compilation and library support will
#    be removed in the next major CUDA Toolkit version release").
#  - R580 is the last driver branch for Maxwell/Pascal/Volta (NVIDIA statement
#    quoted by Phoronix, "NVIDIA Confirms 580 Linux Driver Is The Last For
#    Maxwell / Pascal / Volta").
#  - NVIDIA's debian13 repo carries drivers >= 590 and toolkits 13.1-13.4 only;
#    the debian12 repo carries 580.x (up to 580.178.04) and toolkits 12.3-12.9.
#  - Debian forky has no nvidia-legacy-* packages (apt-cache on PEGASUS, forky
#    main/contrib/non-free) and NVIDIA publishes no CUDA 11.x for debian12/13,
#    so Kepler and older get nouveau only.
#  - R580 proprietary nvidia.ko 580.178.04 compiles against kernel
#    7.2.8-3-t2-trixie with gcc 16.2 (container build, all 5 modules).
#
# PCI device ids grow with each generation, so a numeric threshold is a
# heuristic (documented, tested at both boundaries); it is not an NVIDIA list.

NCZ_CUDA_TURING_MIN=$((16#1e00))
NCZ_CUDA_MAXWELL_MIN=$((16#1340))

# ncz_cuda_family_of_id HEX4 -> prints turing-plus | maxwell-volta | kepler-older
ncz_cuda_family_of_id() {
    local id="${1,,}"
    case "$id" in
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
        *) echo "unknown"; return 1 ;;
    esac
    local n=$((16#$id))
    if [ "$n" -ge "$NCZ_CUDA_TURING_MIN" ]; then echo turing-plus
    elif [ "$n" -ge "$NCZ_CUDA_MAXWELL_MIN" ]; then echo maxwell-volta
    else echo kepler-older; fi
}

# ncz_cuda_nvidia_ids [FILE] -> prints the 4-hex device id of every NVIDIA
# display-class ([0300]/[0302]/[0380]) controller from `lspci -nn` (or FILE).
ncz_cuda_nvidia_ids() {
    local out
    if [ -n "${1:-}" ]; then out=$(cat "$1" 2>/dev/null) || return 1
    else command -v lspci >/dev/null 2>&1 || return 1; out=$(lspci -nn 2>/dev/null) || return 1; fi
    printf '%s\n' "$out" | grep -E '\[03(00|02|80)\]:' | grep -oiE '\[10de:[0-9a-f]{4}\]' \
        | sed -E 's/^\[10de:([0-9a-fA-F]{4})\]$/\1/' | tr 'A-F' 'a-f'
}

# ncz_cuda_pick_family [FILE] -> prints "<family> <id>" for the machine. The
# OLDEST NVIDIA GPU decides, because one driver branch must serve every card:
# R580 also supports Turing, R615 does not support Pascal. Returns 1 when no
# NVIDIA display controller is present.
ncz_cuda_pick_family() {
    local ids id fam best="" bestid="" rank
    ids=$(ncz_cuda_nvidia_ids "${1:-}") || return 1
    [ -n "$ids" ] || return 1
    for id in $ids; do
        fam=$(ncz_cuda_family_of_id "$id") || continue
        case "$fam" in kepler-older) rank=0 ;; maxwell-volta) rank=1 ;; *) rank=2 ;; esac
        if [ -z "$best" ] || [ "$rank" -lt "$bestrank" ]; then best="$fam"; bestid="$id"; bestrank=$rank; fi
    done
    [ -n "$best" ] || return 1
    echo "$best $bestid"
}

# ncz_cuda_plan FAMILY -> prints KEY=value lines (eval-safe, no spaces in
# values except PKGS/DRIVER_PKGS which are quoted).
ncz_cuda_plan() {
    case "$1" in
        turing-plus)
            cat <<'EOF'
FAMILY=turing-plus
DRIVER_BRANCH=615
DRIVER_PIN='615.*'
KMOD=open
DRIVER_PKGS='cuda-drivers libnvidia-encode1 libnvcuvid1'
TOOLKIT=13-4
TOOLKIT_DIR=/usr/local/cuda-13.4
TOOLKIT_PKGS='cuda-compiler-13-4 cuda-libraries-13-4 cuda-libraries-dev-13-4'
REPO=debian13
KEY_ASSET=cuda-keyring_1.1-1_all.deb
SEQUOIA_RELAX=0
REASON='Turing or newer (sm_75+): R615 open kernel modules + CUDA 13.4'
EOF
            ;;
        maxwell-volta)
            cat <<'EOF'
FAMILY=maxwell-volta
DRIVER_BRANCH=580
DRIVER_PIN='580.*'
KMOD=proprietary
DRIVER_PKGS='cuda-drivers-580'
TOOLKIT=12-9
TOOLKIT_DIR=/usr/local/cuda-12.9
TOOLKIT_PKGS='cuda-compiler-12-9 cuda-libraries-12-9 cuda-libraries-dev-12-9'
REPO=debian12
KEY_ASSET=cuda-archive-keyring-debian12.gpg
SEQUOIA_RELAX=1
REASON='Maxwell/Pascal/Volta (sm_50-sm_70): CUDA 13 dropped them; R580 proprietary module (open modules are Turing+ only) + CUDA 12.9'
EOF
            ;;
        kepler-older)
            cat <<'EOF'
FAMILY=kepler-older
DRIVER_BRANCH=none
DRIVER_PIN=''
KMOD=none
DRIVER_PKGS=''
TOOLKIT=none
TOOLKIT_DIR=''
TOOLKIT_PKGS=''
REPO=none
KEY_ASSET=''
SEQUOIA_RELAX=0
REASON='Kepler or older: no NVIDIA driver or CUDA usable on Debian forky (no nvidia-legacy-* packages, no CUDA 11 for debian12/13); nouveau only'
EOF
            ;;
        *) return 1 ;;
    esac
}

# ncz_cuda_pin_file FAMILY -> apt preferences text keeping the driver family on
# its branch (a Pascal box must never be moved to a branch that drops it).
ncz_cuda_pin_file() {
    local pin
    pin=$(ncz_cuda_plan "$1" | sed -n "s/^DRIVER_PIN='\(.*\)'$/\1/p")
    [ -n "$pin" ] || return 1
    cat <<EOF
# /etc/apt/preferences.d/ncz-nvidia-cuda.pref -- written by NCZ-OS
# (post-install/54-gpu-accel.sh). Family: $1. Keeps the whole NVIDIA driver
# family on branch $pin so a newer NVIDIA branch (or Debian's older in-archive
# nvidia 550.x) never silently replaces it. Point releases inside the branch
# still update. Toolkit packages are versioned by name (cuda-*-N-M), so a new
# toolkit is a different package and is never pulled in by a normal upgrade.
# To move deliberately, edit /etc/ncz/cuda-selection.conf and this file.
Package: cuda-drivers cuda-drivers-* nvidia-* libnvidia-* libcuda1 libcudadebugger1 libnvcuvid1 libnvoptix1 libxnvctrl* libegl-nvidia0 libgles-nvidia* libglx-nvidia0 firmware-nvidia-* xserver-xorg-video-nvidia
Pin: version $pin
Pin-Priority: 1001
EOF
}
