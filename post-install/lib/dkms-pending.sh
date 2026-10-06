#!/bin/sh
# post-install/lib/dkms-pending.sh -- which DKMS kernel-module builds are
# still outstanding on an installed system, and what to tell the user about
# them (docs/GPU-INSTALL-PROGRESS.md, "First boot").
#
# POSIX sh plus `local` (dash, busybox ash and bash all have it, so nothing
# leaks into a caller that sources this) and awk/sed/grep/tr only:
# preseed/late.sh sources it from the d-i environment (busybox ash, no
# dpkg-query) against /target, and the first-boot helper
# (lib/firstboot-gpu.sh) sources it on the installed system.
#
# Evidence this is built on (PEGASUS, r199 amd64, 2026-10-06): the NVIDIA DKMS
# build already runs at install time (54-gpu-accel.sh -> ncz-cuda-setup ->
# apt -> nvidia-kernel-open-dkms postinst -> dkms build). When it FAILS, dpkg
# leaves the package half-configured, so the first-boot `dpkg --configure -a`
# runs the identical build again before the login screen, and it fails again
# the identical way (same driver source, same kernel headers, same compiler).
#
# A package is "pending" when dpkg has unpacked it but not finished
# configuring it (Status: install ok unpacked | half-configured |
# triggers-awaiting | triggers-pending); its postinst will run (and build)
# the next time anything configures packages.
#
# A pending DKMS package is classified:
#   failed  its DKMS make.log for that kernel already holds a compiler
#           "error:" line: a source/API error, which a rebuild from the same
#           inputs reproduces. No point blocking first boot on it.
#   needed  anything else (never attempted, or stopped without a compiler
#           error, e.g. out of memory in the installer): a build that may
#           well succeed.
#
# Text produced here may reach the d-i (newt) screen: ASCII only.

NCZ_DKMS_TREE_REL="${NCZ_DKMS_TREE_REL:-var/lib/dkms}"

# ncz_dkms_pending_pkgs <root> -- one package name per line.
ncz_dkms_pending_pkgs() {
    local _r
    _r="${1:-}"
    [ -r "$_r/var/lib/dpkg/status" ] || return 0
    LC_ALL=C awk '
        /^Package: / { p = $2; next }
        /^Status: / {
            if (p ~ /-dkms$/ && $2 == "install" &&
                ($4 == "unpacked" || $4 == "half-configured" ||
                 $4 == "triggers-awaiting" || $4 == "triggers-pending"))
                print p
            next
        }
        /^$/ { p = "" }
    ' "$_r/var/lib/dpkg/status"
}

# ncz_pkgs_needing_configure <root> -- every package dpkg would configure
# with `dpkg --configure -a` (DKMS or not), one "name:arch" per line (the
# arch keeps Multi-Arch: same packages unambiguous on the dpkg command line).
ncz_pkgs_needing_configure() {
    local _r
    _r="${1:-}"
    [ -r "$_r/var/lib/dpkg/status" ] || return 0
    LC_ALL=C awk '
        /^Package: / { p = $2; a = ""; next }
        /^Architecture: / { a = $2; next }
        /^Status: / { s = $4; d = $2; next }
        /^$/ {
            if (p != "" && d == "install" &&
                (s == "unpacked" || s == "half-configured" ||
                 s == "triggers-awaiting" || s == "triggers-pending"))
                print p (a != "" ? ":" a : "")
            p = ""; s = ""; d = ""; a = ""
        }
        END {
            if (p != "" && d == "install" &&
                (s == "unpacked" || s == "half-configured" ||
                 s == "triggers-awaiting" || s == "triggers-pending"))
                print p (a != "" ? ":" a : "")
        }
    ' "$_r/var/lib/dpkg/status"
}

# ncz_dkms_pkg_module <root> <package> -- "NAME VERSION" from the dh_dkms
# postinst (DKMS_NAME= / DKMS_VERSION=); nothing when it cannot be read.
ncz_dkms_pkg_module() {
    local _r _f _n _v
    _r="${1:-}"; _f="$_r/var/lib/dpkg/info/$2.postinst"
    [ -r "$_f" ] || return 0
    _n=$(sed -n 's/^DKMS_NAME=\([A-Za-z0-9_.+-]*\).*/\1/p' "$_f" | head -n 1)
    _v=$(sed -n 's/^DKMS_VERSION=\([A-Za-z0-9_.+~-]*\).*/\1/p' "$_f" | head -n 1)
    [ -n "$_n" ] && [ -n "$_v" ] && printf '%s %s\n' "$_n" "$_v"
    return 0
}

# ncz_ascii <text> -- gcc's UTF-8 quotes to ', everything else non-printable
# dropped (newt renders non-ASCII as <ERR>).
ncz_ascii() {
    printf '%s' "$1" \
        | LC_ALL=C sed "s/$(printf '\342\200\230')/'/g; s/$(printf '\342\200\231')/'/g" \
        | LC_ALL=C tr '\t' ' ' | LC_ALL=C tr -cd '\040-\176'
}

# ncz_dkms_log_kernel <make.log> -- kernel named in the dkms header line.
ncz_dkms_log_kernel() {
    head -n 1 "$1" 2>/dev/null | sed -n 's/.* for kernel \([^ ]*\).*/\1/p'
}

# ncz_dkms_fail_reason <root> <name> <version> [kernel] -- prints the first
# compiler error of the last build ("os-interface.c:3031: error: ...") and
# returns 0 when that build failed with one (for <kernel>, when given).
ncz_dkms_fail_reason() {
    local _r _log _e _loc _msg
    _r="${1:-}"; _log="$_r/$NCZ_DKMS_TREE_REL/$2/$3/build/make.log"
    [ -r "$_log" ] || return 1
    if [ -n "${4:-}" ]; then
        [ "$(ncz_dkms_log_kernel "$_log")" = "$4" ] || return 1
    fi
    _e=$(LC_ALL=C grep -m1 -E '(^|[[:space:]:])error:' "$_log" 2>/dev/null) || return 1
    [ -n "$_e" ] || return 1
    # keep "<file>:<line>:" in front of "error:", drop the directory and column
    _loc=$(printf '%s\n' "$_e" | LC_ALL=C sed -n 's/^\([^ :]*\):\([0-9][0-9]*\):[0-9]*:* *error:.*/\1:\2/p')
    _msg=$(printf '%s\n' "$_e" | LC_ALL=C sed 's/^.*error:/error:/')
    _loc=${_loc##*/}
    ncz_ascii "${_loc:+$_loc: }$_msg" | cut -c1-150
    printf '\n'
    return 0
}

# ncz_dkms_classify <root> [kernel] -- one line per pending DKMS package:
#   failed|<pkg>|<name>|<version>|<kernel>|<first compiler error>
#   needed|<pkg>|<name>|<version>|-|-
# <kernel> limits "failed" to builds for that kernel (first boot passes
# `uname -r`); without it any recorded compiler error counts.
ncz_dkms_classify() {
    local _r _k _p _nv _n _v _why _lk
    _r="${1:-}"; _k="${2:-}"
    for _p in $(ncz_dkms_pending_pkgs "$_r"); do
        _nv=$(ncz_dkms_pkg_module "$_r" "$_p")
        _n=${_nv%% *}; _v=${_nv#* }
        if [ -n "$_nv" ] && _why=$(ncz_dkms_fail_reason "$_r" "$_n" "$_v" "$_k"); then
            _lk=$(ncz_dkms_log_kernel "$_r/$NCZ_DKMS_TREE_REL/$_n/$_v/build/make.log")
            printf 'failed|%s|%s|%s|%s|%s\n' "$_p" "$_n" "$_v" "${_lk:--}" "$_why"
        else
            printf 'needed|%s|%s|%s|-|-\n' "$_p" "${_n:-$_p}" "${_v:-?}"
        fi
    done
}

# ncz_nvidia_retry_scheduled <root> -- ncz-cuda-setup.timer is enabled and
# not finished, so ncz-cuda-setup owns a failed NVIDIA build: it records the
# compiler error and tries again once the kernel, its config, the driver or
# the local DKMS patches change (identical inputs are not rebuilt).
ncz_nvidia_retry_scheduled() {
    local _r
    _r="${1:-}"
    [ -e "$_r/etc/systemd/system/timers.target.wants/ncz-cuda-setup.timer" ] || return 1
    [ -e "$_r/var/lib/ncz/cuda-setup.done" ] && return 1
    [ -r "$_r/etc/ncz/cuda-selection.conf" ]
}

ncz_is_nvidia_pkg() { case "$1" in nvidia-*|*-nvidia-*) return 0 ;; esac; return 1; }

# ncz_dkms_is_gpu <package> <module>: a display/GPU driver (wording only).
ncz_dkms_is_gpu() {
    case "$1 $2" in *nvidia*|*amdgpu*|*radeon*|*panthor*|*mali*|*gpu*) return 0 ;; esac
    return 1
}

# ncz_dkms_failed_line <root> <package> <module> <version> <reason>: the one
# sentence used at the end of the install AND on first boot for a build that
# failed with a compiler error.
ncz_dkms_failed_line() {
    local _r _then
    _r="${1:-}"
    if ncz_is_nvidia_pkg "$2" && ncz_nvidia_retry_scheduled "$_r"; then
        _then="ncz-cuda-setup retries it automatically once the kernel or the driver changes (status: ncz-cuda-setup status)."
    else
        _then="it is retried when the kernel or driver is updated (or run: sudo dpkg --configure -a)."
    fi
    if ncz_dkms_is_gpu "$2" "$3"; then
        printf '%s\n' "GPU driver build failed for this kernel ($3 $4): $5. The desktop uses the open-source driver for now; $_then"
    else
        printf '%s\n' "Driver build failed for this kernel ($3 $4): $5. The module is unavailable for now; $_then"
    fi
}

# ncz_dkms_noun <classify-lines> <state>: "GPU drivers" when any package in
# <state> is a GPU driver, else "drivers".
ncz_dkms_noun() {
    printf '%s\n' "$1" | while IFS='|' read -r _st _p _n _rest; do
        [ "$_st" = "$2" ] || continue
        ncz_dkms_is_gpu "$_p" "$_n" && { echo gpu; break; }
    done | grep -q gpu && { echo "GPU drivers"; return 0; }
    echo "drivers"
}

# ncz_firstboot_gpu_notice <root> -- the install-end notice, ASCII, one
# paragraph per line; prints nothing when first boot has nothing to build and
# nothing failed. Shown on the last installer screen by preseed/late.sh.
ncz_firstboot_gpu_notice() {
    local _r _cls _needed _st _p _n _v _k _why
    _r="${1:-}"
    _cls=$(ncz_dkms_classify "$_r")
    _needed=$(printf '%s\n' "$_cls" | awk -F'|' '$1 == "needed" { printf "%s%s %s", (n++ ? ", " : ""), $3, $4 }')
    if [ -n "$_needed" ]; then
        printf '%s\n' "First boot will finish setting up your $(ncz_dkms_noun "$_cls" needed) (a DKMS build of $_needed). The login screen may take several minutes to appear. Do not power off."
    fi
    printf '%s\n' "$_cls" | while IFS='|' read -r _st _p _n _v _k _why; do
        [ "$_st" = failed ] || continue
        ncz_dkms_failed_line "$_r" "$_p" "$_n" "$_v" "$_why"
    done
    # NVIDIA driver not even downloaded yet (no network during install): the
    # timer downloads and builds it in the background after boot.
    if [ -z "$_cls" ] && ncz_nvidia_retry_scheduled "$_r"; then
        case "$(cat "$_r/var/lib/ncz/cuda-toolkit.status" 2>/dev/null)" in
            pending:*)
                printf '%s\n' "The NVIDIA driver could not be downloaded during the install. It is downloaded and built in the background after first boot; restart once it has finished (status: ncz-cuda-setup status)." ;;
        esac
    fi
    return 0
}

if [ "${0##*/}" = "dkms-pending.sh" ]; then
    case "${1:-}" in
        pending)  ncz_dkms_pending_pkgs "${2:-}" ;;
        classify) ncz_dkms_classify "${2:-}" "${3:-}" ;;
        notice)   ncz_firstboot_gpu_notice "${2:-}" ;;
        *) echo "usage: dkms-pending.sh pending|classify|notice <root> [kernel]" >&2; exit 2 ;;
    esac
fi
