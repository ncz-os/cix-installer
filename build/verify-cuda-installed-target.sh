#!/bin/bash
# verify-cuda-installed-target.sh -- installed-target gate for the AMD64 CUDA
# 13.4 toolkit (post-install/54-gpu-accel.sh).
#
# post-install/54 records its outcome in <root>/var/lib/ncz/cuda-toolkit.status
# as  installed:<version> | skipped:<reason> | failed:<reason>.  This gate
# turns that record into a pass/fail so a silent failure cannot hide:
#
#   --expect installed   (an NVIDIA Turing+ build): status must be installed:*,
#                        nvcc must be executable under usr/local/cuda-13.4,
#                        the /etc/profile.d and apt-pin files must exist, and
#                        dpkg must list cuda-nvcc-13-4 as installed.
#   --expect skipped     (non-NVIDIA / pre-Turing hardware): status must be a
#                        deliberate skipped:<reason>; nvcc must NOT exist.
#   --expect auto        derive the expectation from the status itself, but
#                        a failed:* status is always an error.
#
# usage: verify-cuda-installed-target.sh --root DIR [--expect installed|skipped|auto]
set -uo pipefail
TARGET=""; EXPECT=auto
while [ $# -gt 0 ]; do
    case "$1" in
        --root)   TARGET="${2:-}"; shift 2 ;;
        --expect) EXPECT="${2:-}"; shift 2 ;;
        -h|--help) echo "usage: $0 --root DIR [--expect installed|skipped|auto]"; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
    esac
done
[ -n "$TARGET" ] && [ -d "$TARGET" ] || { echo "ERROR: --root DIR required" >&2; exit 2; }
case "$EXPECT" in installed|skipped|auto) ;; *) echo "ERROR: bad --expect: $EXPECT" >&2; exit 2 ;; esac

STATUS_FILE="$TARGET/var/lib/ncz/cuda-toolkit.status"
if [ ! -s "$STATUS_FILE" ]; then
    echo "FAIL: $STATUS_FILE missing -- 54-gpu-accel.sh did not record a CUDA outcome" >&2
    exit 1
fi
STATUS="$(head -n1 "$STATUS_FILE" | tr -d '\r')"
KIND="${STATUS%%:*}"
NVCC="$TARGET/usr/local/cuda-13.4/bin/nvcc"
fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }

case "$KIND" in
    failed) bad "54-gpu-accel.sh recorded a CUDA failure: $STATUS" ;;
    installed|skipped) ;;
    *) bad "unrecognized CUDA status '$STATUS'" ;;
esac
[ "$EXPECT" = auto ] && [ "$KIND" != failed ] && EXPECT="$KIND"

case "$EXPECT" in
    installed)
        [ "$KIND" = installed ] || bad "expected an installed CUDA toolkit, status is '$STATUS'"
        [ -x "$NVCC" ] || bad "nvcc not executable: $NVCC"
        [ -f "$TARGET/etc/profile.d/ncz-cuda.sh" ] || bad "missing /etc/profile.d/ncz-cuda.sh"
        [ -f "$TARGET/etc/apt/preferences.d/ncz-nvidia-cuda.pref" ] || bad "missing R615 apt pin ncz-nvidia-cuda.pref"
        if [ -f "$TARGET/var/lib/dpkg/status" ]; then
            awk 'BEGIN{RS="";FS="\n"} /(^|\n)Package: cuda-nvcc-13-4\n/ && /Status: install ok installed/ {f=1} END{exit !f}' \
                "$TARGET/var/lib/dpkg/status" || bad "dpkg does not list cuda-nvcc-13-4 as installed"
        else
            bad "no dpkg status database under $TARGET"
        fi
        ;;
    skipped)
        [ "$KIND" = skipped ] || bad "expected a deliberate CUDA skip, status is '$STATUS'"
        [ ! -e "$NVCC" ] || bad "status says skipped but nvcc exists: $NVCC"
        [ -n "${STATUS#skipped:}" ] || bad "skip recorded without a reason"
        ;;
esac

if [ "$fail" -ne 0 ]; then
    echo "verify-cuda-installed-target: FAIL ($STATUS)" >&2
    exit 1
fi
echo "verify-cuda-installed-target: PASS ($STATUS)"
