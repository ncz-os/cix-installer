#!/bin/bash
# check-kernel-deb-pin.sh -- refuse Sky1 kernel packages that are not the
# kernel named by the SHIPPING channel pointer (assets/kernel/mainline/KVER).
#
# Why (2026-09-28 incident): staging the r278 7.3.0-rc5 TEST kernel left
# linux-image-cixmini_7.3.0-rc5-sky1-ncz+r278 and friends in build/kernel-debs/.
# build-vendor-mirror.sh publishes every .deb in that directory, and its
# superseded-package cleanup keeps whichever same-named deb it copies LAST,
# so the rc5 set replaced 7.2.8 in the vendor mirror
# (build/forky-vendor-mirror.rc5-stale-20260928-234219 on the arm64 build host still holds
# it). On the target, post-install/10-our-kernel.sh then took the sort -V
# "newest" linux-image-cixmini from the pool. Nothing compared any of this to
# the KVER the build was supposed to ship.
#
# Contract enforced here, for every directory given:
#   * linux-image-cixmini and linux-headers-cixmini: Version must be
#     <KVER>+r<N>, where KVER is the first line of <kver-file>;
#   * at most ONE version of each of the three Sky1 kernel packages
#     (a second version is exactly the ambiguity that let rc5 win);
#   * cixmini-boot's +r<N> revision must equal linux-image-cixmini's
#     (build-kernel-debs.sh builds all three from one BUILD_REV);
#   * when <kver-file> sits in a staged r<N>-<kver>-... directory (the
#     mainline pointer does), the packages' r<N> must not be OLDER than
#     that directory's: a +r258 build of 7.2.8 sorts below the +r277
#     already on boards, and apt silently keeps the old kernel;
#   * linux-image-cixmini must not carry an in-tree VPU driver
#     (kernel/drivers/media/platform/cix/amvx.ko): the VPU ships only as the
#     cix-vpu-driver DKMS module. Revisions listed in KERNEL-POLICY
#     INTREE_ACCEL_GRANDFATHERED_SKY1 only warn.
# A directory with no Sky1 kernel packages passes (amd64 vendor mirrors,
# a pool before the first kernel publish).
#
# Usage: check-kernel-deb-pin.sh <kver-file> <deb-dir> [<deb-dir>...]
# Exit 0 = pinned, 1 = violation, 2 = usage error.
set -euo pipefail
export LC_ALL=C

[ "$#" -ge 2 ] || { echo "usage: $0 <kver-file> <deb-dir> [<deb-dir>...]" >&2; exit 2; }
KVER_FILE="$1"; shift
command -v dpkg-deb >/dev/null 2>&1 || { echo "[kernel-pin] ERROR: dpkg-deb not found" >&2; exit 2; }

KVER=""
if [ -s "$KVER_FILE" ]; then
    KVER="$(head -n1 "$KVER_FILE" | tr -d '[:space:]')"
fi

# Revision floor from the staged directory the KVER file lives in.
PTR_REV=""
_ptr_dir="$(basename "$(readlink -f "$(dirname "$KVER_FILE")" 2>/dev/null || true)")"
case "$_ptr_dir" in
    r[0-9]*-*) PTR_REV="${_ptr_dir%%-*}"; PTR_REV="${PTR_REV#r}" ;;
esac
case "$PTR_REV" in *[!0-9]*) PTR_REV="" ;; esac

# Revisions shipped with an in-tree VPU driver before that became an error.
POLICY_FILE="${KERNEL_POLICY_FILE:-$(cd "$(dirname "$0")/.." && pwd)/assets/kernel/KERNEL-POLICY}"
GRANDFATHERED="$(sed -n 's/^INTREE_ACCEL_GRANDFATHERED_SKY1=//p' "$POLICY_FILE" 2>/dev/null | head -1 || true)"

rc=0
for dir in "$@"; do
    [ -d "$dir" ] || continue
    img_vers=(); hdr_vers=(); boot_vers=()
    dir_rc=0
    while IFS= read -r -d '' deb; do
        pkg="$(dpkg-deb -f "$deb" Package 2>/dev/null || true)"
        ver="$(dpkg-deb -f "$deb" Version 2>/dev/null || true)"
        case "$pkg" in
            linux-image-cixmini)   img_vers+=("$ver") ;;
            linux-headers-cixmini) hdr_vers+=("$ver") ;;
            cixmini-boot)          boot_vers+=("$ver") ;;
            *) continue ;;
        esac
        if [ "$pkg" = cixmini-boot ]; then
            continue
        fi
        if [ "$pkg" = linux-image-cixmini ]; then
            # The VPU driver ships only as the cix-vpu-driver DKMS module; an
            # in-tree amvx.ko with the same name loads whenever the DKMS module
            # is missing. Error, except for grandfathered revisions.
            _amvx="$(dpkg-deb -c "$deb" 2>/dev/null | awk '{print $NF}' \
                | grep -E '/kernel/drivers/media/platform/cix/amvx\.ko(\.xz|\.zst|\.gz)?$' | head -1 || true)"
            if [ -n "$_amvx" ]; then
                _irev="${ver##*+}"
                case ",$GRANDFATHERED," in
                    *",$_irev,"*)
                        echo "[kernel-pin] WARN: $dir: $pkg $ver ships in-tree $_amvx ($_irev is grandfathered)" >&2 ;;
                    *)
                        echo "[kernel-pin] FAIL: $dir: $pkg $ver ships in-tree $_amvx (CONFIG_VIDEO_LINLON set)" >&2
                        echo "             (the VPU driver must ship only as the cix-vpu-driver DKMS module)" >&2
                        dir_rc=1 ;;
                esac
            fi
        fi
        if [ -z "$KVER" ]; then
            echo "[kernel-pin] FAIL: $dir holds $pkg $ver but $KVER_FILE is missing or empty" >&2
            echo "             (cannot prove it is the shipping kernel; refusing to publish it)" >&2
            dir_rc=1
            continue
        fi
        case "$ver" in
            "$KVER"+r[0-9]*)
                _rev="${ver##*+r}"
                if [ -n "$PTR_REV" ] && [ "${_rev%%[!0-9]*}" -lt "$PTR_REV" ] 2>/dev/null; then
                    echo "[kernel-pin] FAIL: $dir: $pkg $ver is older than the staged kernel directory $_ptr_dir" >&2
                    echo "             (apt would keep the newer revision already installed on boards)" >&2
                    dir_rc=1
                fi
                ;;
            *)
                echo "[kernel-pin] FAIL: $dir: $pkg $ver is not the shipping kernel $KVER" >&2
                echo "             (the mainline pointer names $KVER; a test/edge kernel must never be published here)" >&2
                dir_rc=1
                ;;
        esac
    done < <(find "$dir" -maxdepth 1 -type f -name '*.deb' -print0 | sort -z)

    for name in linux-image-cixmini linux-headers-cixmini cixmini-boot; do
        case "$name" in
            linux-image-cixmini)   vers=("${img_vers[@]}") ;;
            linux-headers-cixmini) vers=("${hdr_vers[@]}") ;;
            cixmini-boot)          vers=("${boot_vers[@]}") ;;
        esac
        if [ "${#vers[@]}" -gt 1 ]; then
            echo "[kernel-pin] FAIL: $dir holds ${#vers[@]} versions of $name (${vers[*]}); exactly one may be published" >&2
            dir_rc=1
        fi
    done

    img_one="${img_vers[0]:-}"
    boot_one="${boot_vers[0]:-}"
    if [ -n "$img_one" ] && [ -n "$boot_one" ] && [ "${img_one##*+}" != "${boot_one##*+}" ]; then
        echo "[kernel-pin] FAIL: $dir: cixmini-boot $boot_one and linux-image-cixmini $img_one come from different builds" >&2
        dir_rc=1
    fi
    if [ "$dir_rc" -ne 0 ]; then
        rc=1
    elif [ "$((${#img_vers[@]} + ${#hdr_vers[@]} + ${#boot_vers[@]}))" -gt 0 ]; then
        echo "[kernel-pin] OK: $dir: Sky1 kernel packages match the shipping kernel $KVER (${img_one:-no image})"
    fi
done
exit "$rc"
