#!/bin/bash
# post-install/lib/sky1-kernels.sh -- which installed kernels the Sky1 driver
# hooks (80-npu.sh, 81-vpu.sh) act on.
#
# Sourced, not executed. Defines ncz_sky1_kernel_vers, which prints one line
# per kernel, "<source> <kver>":
#   sidecar  the KVER_NEXT sidecar written by the installer
#            (<meta>/KVER_NEXT); authoritative, always printed first
#   disk     an NCZ Sky1 kernel module tree (<modules-dir>/*-sky1-ncz) that
#            the sidecar does not name, e.g. a kernel package installed by
#            hand after the image was built
# Each kver is printed once, even when /lib is a symlink to /usr/lib and both
# module directories list the same tree.
#
# Every NCZ Sky1 kernel release ends in -sky1-ncz (7.3.0-rc7-sky1-ncz for
# 26.10; build/build-kernel-debs.sh classifies the Sky1 kernel by the same
# suffix), so the disk scan follows the kernel naming instead of a version
# number. The amd64 kernel (-t2-ncz) never matches.
#
# Usage: ncz_sky1_kernel_vers META_DIR [MODULES_DIR...]
#   MODULES_DIR defaults to $NCZ_SKY1_MODULES_DIRS (space-separated; for tests)
#   or /lib/modules /usr/lib/modules.
# Tested by build/test-sky1-kernel-discovery.sh.

ncz_sky1_kernel_vers() {
    local meta="$1" seen=" " k d dir
    shift
    # shellcheck disable=SC2086  # word-split the space-separated list
    [ "$#" -gt 0 ] || set -- ${NCZ_SKY1_MODULES_DIRS:-/lib/modules /usr/lib/modules}
    if [ -f "$meta/KVER_NEXT" ]; then
        k=$(tr -d ' \t\r\n' < "$meta/KVER_NEXT" 2>/dev/null)
        if [ -n "$k" ]; then
            printf 'sidecar %s\n' "$k"
            seen=" $k "
        fi
    fi
    for dir in "$@"; do
        for d in "$dir"/*-sky1-ncz; do
            [ -d "$d" ] || continue
            k="${d##*/}"
            case "$seen" in *" $k "*) continue ;; esac
            seen="$seen$k "
            printf 'disk %s\n' "$k"
        done
    done
}
