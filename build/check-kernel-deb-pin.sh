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
#     already on boards, and apt silently keeps the old kernel.
#   * with --manifest (docs/BUILD-STABILITY.md M7): every Sky1 kernel
#     package's full Version (the +rNNN packaging revision, not just KVER)
#     and sha256 must equal the deb assets/kernel-manifest.json pins, and
#     the set must be complete.  KVER alone let r292 debs pass under an
#     r293 manifest (2026-10-29) and fail only at provenance, stage 50.
# A directory with no Sky1 kernel packages passes (amd64 vendor mirrors,
# a pool before the first kernel publish), but a --manifest that is missing,
# malformed or pins no kernel deb fails every invocation.
#
# Usage: check-kernel-deb-pin.sh [--manifest <kernel-manifest.json>]
#                                <kver-file> <deb-dir> [<deb-dir>...]
# Exit 0 = pinned, 1 = violation, 2 = usage error.
set -euo pipefail
export LC_ALL=C

USAGE="usage: $0 [--manifest <kernel-manifest.json>] <kver-file> <deb-dir> [<deb-dir>...]"
MANIFEST=""
if [ "${1:-}" = "--manifest" ]; then
    [ -n "${2:-}" ] || { echo "$USAGE" >&2; exit 2; }
    MANIFEST="$2"; shift 2
fi
[ "$#" -ge 2 ] || { echo "$USAGE" >&2; exit 2; }
KVER_FILE="$1"; shift
command -v dpkg-deb >/dev/null 2>&1 || { echo "[kernel-pin] ERROR: dpkg-deb not found" >&2; exit 2; }

# Pinned "<package> <version> <sha256>" rows from the manifest.  A manifest
# that is missing, unparseable or pins no kernel deb is fatal before any
# directory is looked at: with nothing pinned, a directory holding no Sky1
# deb (amd64 mirror, empty pool) would otherwise pass and hide a broken pin
# file until the first arm64 publish (review 2026-11-01).
PINNED=""
if [ -n "$MANIFEST" ]; then
    PINNED="$(python3 -I -c '
import json, re, sys
from urllib.parse import unquote
for d in json.load(open(sys.argv[1], encoding="utf-8"))["kernel_debs"]:
    m = re.match(r"^([^_]+)_([^_]+)_([^_]+)\.deb$", d["file"].rsplit("/", 1)[-1])
    if not m or not re.fullmatch(r"[0-9a-f]{64}", d.get("sha256", "")):
        sys.exit("bad kernel_debs entry: %r" % (d,))
    print(m.group(1), unquote(m.group(2)), d["sha256"])
' "$MANIFEST" 2>&1)" || {
        echo "[kernel-pin] FAIL: $MANIFEST is unreadable or malformed: $PINNED" >&2
        exit 1
    }
    if [ -z "$PINNED" ]; then
        echo "[kernel-pin] FAIL: $MANIFEST pins no kernel_debs" >&2
        exit 1
    fi
fi

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

rc=0
for dir in "$@"; do
    [ -d "$dir" ] || continue
    img_vers=(); hdr_vers=(); boot_vers=(); seen_pkgs=" "
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
        if [ -n "$MANIFEST" ]; then
            seen_pkgs="$seen_pkgs$pkg "
            want="$(awk -v p="$pkg" '$1 == p { print $2 " " $3 }' <<<"$PINNED")"
            if [ -z "$want" ]; then
                echo "[kernel-pin] FAIL: $dir: $pkg $ver is not pinned by $MANIFEST" >&2
                dir_rc=1
            elif [ "$ver" != "${want%% *}" ]; then
                echo "[kernel-pin] FAIL: $dir: $pkg $ver is not the pinned revision ${want%% *} ($MANIFEST)" >&2
                echo "             (same KVER, different packaging revision: refusing to publish it)" >&2
                dir_rc=1
            else
                have_sha="$(sha256sum "$deb" | awk '{print $1}')"
                if [ "$have_sha" != "${want#* }" ]; then
                    echo "[kernel-pin] FAIL: $dir: $pkg $ver sha256 $have_sha != pinned ${want#* } ($MANIFEST)" >&2
                    dir_rc=1
                fi
            fi
        fi
        if [ "$pkg" = cixmini-boot ]; then
            continue
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
    if [ -n "$MANIFEST" ] && [ "$seen_pkgs" != " " ]; then
        while read -r mp mv _; do
            [ -n "$mp" ] || continue
            case "$seen_pkgs" in *" $mp "*) ;; *)
                echo "[kernel-pin] FAIL: $dir: incomplete Sky1 kernel set: $mp $mv (pinned by $MANIFEST) is missing" >&2
                dir_rc=1 ;;
            esac
        done <<<"$PINNED"
    fi
    if [ "$dir_rc" -ne 0 ]; then
        rc=1
    elif [ "$((${#img_vers[@]} + ${#hdr_vers[@]} + ${#boot_vers[@]}))" -gt 0 ]; then
        echo "[kernel-pin] OK: $dir: Sky1 kernel packages match the shipping kernel $KVER (${img_one:-no image})${MANIFEST:+; Version and sha256 match $MANIFEST}"
    fi
done
exit "$rc"
