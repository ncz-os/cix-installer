#!/bin/bash
# verify-cuda-installed-target.sh -- installed-target gate for the AMD64
# NVIDIA driver + CUDA toolkit (post-install/54-gpu-accel.sh + ncz-cuda-setup).
#
# 54 and ncz-cuda-setup record their outcome in
# <root>/var/lib/ncz/cuda-toolkit.status as
#   installed:<version> | pending:<why> | skipped:<why> | failed:<why>
# This gate turns that record into pass/fail so a silent failure cannot hide.
#
#   --expect installed   NVIDIA hardware, network was up: status installed:*,
#                        the toolkit's nvcc (path from etc/ncz/cuda-selection.conf)
#                        executable, /etc/profile.d/ncz-cuda.sh, the apt pin, the
#                        stamp file, and dpkg listing cuda-nvcc-<toolkit>.
#   --expect pending     NVIDIA hardware, install deferred: status pending:*,
#                        selection conf present, ncz-cuda-setup + its .service and
#                        .timer installed, the timer ENABLED (symlink under
#                        timers.target.wants), the pin present, NO stamp, NO nvcc.
#   --expect skipped     no NVIDIA / unsupported / deselected: status skipped:<why>,
#                        no nvcc, and no toolkit packages recorded as installed.
#   --expect auto        derive the expectation from the status; failed:* is
#                        always an error.
#
# usage: verify-cuda-installed-target.sh --root DIR [--expect installed|pending|skipped|auto]
set -uo pipefail
TARGET=""; EXPECT=auto
while [ $# -gt 0 ]; do
    case "$1" in
        --root)   TARGET="${2:-}"; shift 2 ;;
        --expect) EXPECT="${2:-}"; shift 2 ;;
        -h|--help) echo "usage: $0 --root DIR [--expect installed|pending|skipped|auto]"; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
    esac
done
[ -n "$TARGET" ] && [ -d "$TARGET" ] || { echo "ERROR: --root DIR required" >&2; exit 2; }
case "$EXPECT" in installed|pending|skipped|auto) ;; *) echo "ERROR: bad --expect: $EXPECT" >&2; exit 2 ;; esac

STATUS_FILE="$TARGET/var/lib/ncz/cuda-toolkit.status"
CONF="$TARGET/etc/ncz/cuda-selection.conf"
if [ ! -s "$STATUS_FILE" ]; then
    echo "FAIL: $STATUS_FILE missing -- 54-gpu-accel.sh did not record a CUDA outcome" >&2
    exit 1
fi
STATUS="$(head -n1 "$STATUS_FILE" | tr -d '\r')"
KIND="${STATUS%%:*}"
conf() { sed -n "s/^$1=//p" "$CONF" 2>/dev/null | head -n1 | sed -e "s/^'//" -e "s/'\$//"; }
# ncz-cuda-setup records what it resolved and installed (INSTALLED_*); older selections name it directly
TDIR="$(conf INSTALLED_TOOLKIT_DIR)"; TDIR="${TDIR:-$(conf TOOLKIT_DIR)}"
TVER="$(conf INSTALLED_TOOLKIT)"; TVER="${TVER:-$(conf TOOLKIT)}"
NVCC="$TARGET${TDIR:-/usr/local/cuda-none}/bin/nvcc"
fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }

case "$KIND" in
    failed) bad "recorded a CUDA failure: $STATUS" ;;
    installed|pending|skipped) ;;
    *) bad "unrecognized CUDA status '$STATUS'" ;;
esac
[ "$EXPECT" = auto ] && [ "$KIND" != failed ] && EXPECT="$KIND"

need_conf() {
    [ -s "$CONF" ] || { bad "missing $CONF (the GPU family/driver/toolkit decision)"; return 1; }
    for k in GPU_PCI_ID FAMILY DRIVER_BRANCH TOOLKIT; do
        [ -n "$(conf $k)" ] || bad "$CONF lacks $k"
    done
    [ -n "$(conf TOOLKIT_SERIES)$(conf TOOLKIT_DIR)" ] || bad "$CONF lacks TOOLKIT_SERIES (or a legacy TOOLKIT_DIR)"
}
dpkg_has() {
    [ -f "$TARGET/var/lib/dpkg/status" ] || return 1
    awk -v p="$1" 'BEGIN{RS="";FS="\n"} { n=""; ok=0; for(i=1;i<=NF;i++){ if($i=="Package: " p) n=p; if($i=="Status: install ok installed") ok=1 } if(n==p && ok) f=1 } END{exit !f}' "$TARGET/var/lib/dpkg/status"
}

case "$EXPECT" in
    installed)
        [ "$KIND" = installed ] || bad "expected an installed CUDA toolkit, status is '$STATUS'"
        need_conf
        [ -x "$NVCC" ] || bad "nvcc not executable: $NVCC"
        [ -f "$TARGET/etc/profile.d/ncz-cuda.sh" ] || bad "missing /etc/profile.d/ncz-cuda.sh"
        [ -f "$TARGET/etc/apt/preferences.d/ncz-nvidia-cuda.pref" ] || bad "missing driver-branch apt pin"
        [ -f "$TARGET/var/lib/ncz/cuda-setup.done" ] || bad "no cuda-setup.done stamp"
        [ -n "$(conf TOOLKIT_SERIES)" ] && [ -z "$(conf INSTALLED_TOOLKIT)" ] && bad "$CONF has no INSTALLED_TOOLKIT: ncz-cuda-setup did not record what it installed"
        [ -n "$TVER" ] || bad "$CONF has no TOOLKIT: cannot verify the toolkit packages"
        if [ -n "$TVER" ]; then
            dpkg_has "cuda-nvcc-$TVER" || bad "dpkg does not list cuda-nvcc-$TVER as installed"
            dpkg_has "cuda-libraries-dev-$TVER" || bad "dpkg does not list cuda-libraries-dev-$TVER (headers) as installed"
        fi
        if [ "$(conf FAMILY)" = turing-plus ]; then
            dpkg_has nvidia-egl-icd || bad "dpkg does not list nvidia-egl-icd (PRIME EGL vendor) as installed"
            dpkg_has libegl-nvidia0 || bad "dpkg does not list libegl-nvidia0 (NVIDIA EGL library) as installed"
            dpkg_has libnvidia-egl-wayland1 || bad "dpkg does not list libnvidia-egl-wayland1 (Wayland EGL platform) as installed"
            dpkg_has libnvidia-egl-gbm1 || bad "dpkg does not list libnvidia-egl-gbm1 (GBM EGL platform) as installed"
        fi
        ;;
    pending)
        [ "$KIND" = pending ] || bad "expected a deferred CUDA install, status is '$STATUS'"
        need_conf
        [ -x "$TARGET/usr/local/sbin/ncz-cuda-setup" ] || bad "ncz-cuda-setup not installed/executable"
        [ -f "$TARGET/etc/systemd/system/ncz-cuda-setup.service" ] || bad "missing ncz-cuda-setup.service"
        [ -f "$TARGET/etc/systemd/system/ncz-cuda-setup.timer" ] || bad "missing ncz-cuda-setup.timer"
        [ -L "$TARGET/etc/systemd/system/timers.target.wants/ncz-cuda-setup.timer" ] || bad "ncz-cuda-setup.timer is not enabled (no timers.target.wants symlink)"
        [ -f "$TARGET/etc/apt/preferences.d/ncz-nvidia-cuda.pref" ] || bad "missing driver-branch apt pin"
        [ ! -e "$TARGET/var/lib/ncz/cuda-setup.done" ] || bad "stamp exists but status is pending"
        [ ! -e "$NVCC" ] || bad "status pending but nvcc exists: $NVCC"
        ;;
    skipped)
        [ "$KIND" = skipped ] || bad "expected a deliberate CUDA skip, status is '$STATUS'"
        _why="${STATUS#skipped:}"; _why="$(printf '%s' "$_why" | tr -d ' \t')"
        [ -n "$_why" ] || bad "skip recorded without a reason"
        [ ! -e "$NVCC" ] || bad "status says skipped but nvcc exists: $NVCC"
        # any installed cuda-nvcc-* package contradicts a skip (not a fixed list: toolkits change)
        if [ -f "$TARGET/var/lib/dpkg/status" ]; then
            for pkg in $(awk 'BEGIN{RS="";FS="\n"} { n=""; ok=0; for(i=1;i<=NF;i++){ if($i ~ /^Package: cuda-nvcc-/) n=substr($i,10); if($i=="Status: install ok installed") ok=1 } if(n!="" && ok) print n }' "$TARGET/var/lib/dpkg/status"); do
                bad "status says skipped but $pkg is installed"
            done
        fi
        ;;
esac

if [ "$fail" -ne 0 ]; then
    echo "verify-cuda-installed-target: FAIL ($STATUS)" >&2
    exit 1
fi
echo "verify-cuda-installed-target: PASS ($STATUS)"
