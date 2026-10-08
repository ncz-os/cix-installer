#!/bin/bash
# verify-arm64-inputs.sh — pre-flight check that the Sky1/O6N arm64 build
# inputs are present in assets/. Runs as a build-time gate; emits nothing
# (exit 0) on amd64 or in --verify-firmware-dir mode against a non-arm64
# staging tree. Emits one "MISSING" line per missing class and exits 1 on
# arm64 if any required input is absent.
#
# Rationale (2026-09-28). The arm64 NCZ-OS install image has repeatedly
# shipped with missing accelerator inputs while every gate reported success,
# because the inputs are git-ignored (.gitignore: assets/sky1-firmware/ and
# assets/cix-debs/*.deb) and every consumer degrades to a WARN:
#   - build/build-iso-di.sh ~3338: cp -rL "$ROOT/assets/sky1-firmware" \
#     "$EXTRA/assets/" 2>/dev/null || true
#   - post-install/12-sky1-firmware.sh: missing source dir -> WARN + exit 0
# This gate closes that gap at the build side: it MUST run before the ISO
# assembly picks up a half-empty asset tree, and it MUST be exit-1-loud so
# "make image" / "make iso" fails visibly instead of producing a silently
# broken image.
#
# Run:
#   bash build/verify-arm64-inputs.sh                # check assets/
#   bash build/verify-arm64-inputs.sh --mirror       # also check mirror layout
#   VERIFY_FIRMWARE_DIR=/path bash build/verify-arm64-inputs.sh \
#       --verify-firmware-dir                        # check a different staged dir
#
# Exit codes:
#   0 = OK (or non-arm64 no-op)
#   1 = at least one required input missing (every miss is printed)
#   2 = bad invocation
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ROOT override (test fixture path) or default to the repo root derived from
# the script's own location, NEVER from cwd -- the script may be invoked
# from anywhere (make passes an absolute path, but tests might not).
if [ -n "${VERIFY_ROOT:-}" ]; then
    ROOT="$VERIFY_ROOT"
else
    ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

# --- arg parsing -------------------------------------------------------
CHECK_MIRROR=0
VERIFY_FIRMWARE_DIR="${VERIFY_FIRMWARE_DIR:-}"
while [ $# -gt 0 ]; do
    case "$1" in
        --mirror) CHECK_MIRROR=1 ;;
        --verify-firmware-dir)
            shift
            [ $# -ge 1 ] || { echo "verify-arm64-inputs: --verify-firmware-dir requires a path" >&2; exit 2; }
            VERIFY_FIRMWARE_DIR="$1"
            ;;
        -h|--help)
            sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "verify-arm64-inputs: unknown arg: $1" >&2
            exit 2
            ;;
    esac
    shift
done

# --- arch detection ----------------------------------------------------
# Match the project-wide pattern: env var first, then dpkg --print-architecture,
# then uname -m mapped to dpkg's naming. aarch64 -> arm64 is the only
# transformation we apply (the brief says so explicitly).
NCZ_TARGET_ARCH="${NCZ_TARGET_ARCH:-}"
if [ -z "$NCZ_TARGET_ARCH" ]; then
    NCZ_TARGET_ARCH="$(dpkg --print-architecture 2>/dev/null || true)"
fi
if [ -z "$NCZ_TARGET_ARCH" ]; then
    _raw_arch="$(uname -m 2>/dev/null || true)"
    case "$_raw_arch" in
        aarch64) NCZ_TARGET_ARCH=arm64 ;;
        x86_64)  NCZ_TARGET_ARCH=amd64 ;;
        *)       NCZ_TARGET_ARCH="$_raw_arch" ;;
    esac
fi
case "$NCZ_TARGET_ARCH" in
    arm64)
        : ;;  # fall through to checks below
    *)
        # No-op on amd64 and on any unknown arch. The brief says amd64
        # behaviour must be byte-for-byte unchanged in effect: this script
        # doing nothing IS that.
        echo "verify-arm64-inputs: SKIP (NCZ_TARGET_ARCH=$NCZ_TARGET_ARCH -- arm64 only)"
        exit 0
        ;;
esac

# --- BUILD_VARIANT detection -------------------------------------------
# Mirror 25-cix-proprietary.sh: env first, then /usr/local/lib/cix-installer/
# BUILD_VARIANT (stamped at install-time). At build-time neither is normally
# set, so default to "desktop" (the gate only skips the cix-debs check on
# server/headless, so on a build host we want to ENFORCE the check by default).
BUILD_VARIANT="${BUILD_VARIANT:-${NCZ_BUILD_VARIANT:-}}"
if [ -z "$BUILD_VARIANT" ] && [ -r /usr/local/lib/cix-installer/BUILD_VARIANT ]; then
    BUILD_VARIANT="$(tr -d '[:space:]' < /usr/local/lib/cix-installer/BUILD_VARIANT)"
fi

# --- collect every miss BEFORE exiting --------------------------------
FAIL=0

# Track class-by-class counts so the OK summary line names what it found.
N_FWB=0
N_DEBS=0
N_OTHER_FW=0  # dsp_fw.bin + mali_csffw.bin
N_RESCUE=0
N_MIRROR_DEBS=0
N_MIRROR_INDEX=0

mark_miss() {
    # $1 = class label, $2 = path
    echo "verify-arm64-inputs: MISSING: $1: $2"
    FAIL=1
}

# (a) Sky1 firmware ------------------------------------------------------
# The 16 .fwb codec blobs MUST sit in $FW_DIR as regular non-empty files.
# dsp_fw.bin and arm/mali/arch12.8/mali_csffw.bin follow symlinks (-L), so
# the test rig can stage them as symlinks into a real blob without copying.
FW_DIR="${VERIFY_FIRMWARE_DIR:-$ROOT/assets/sky1-firmware}"
FWB_LIST="
    av1dec.fwb avs2dec.fwb avsdec.fwb h264dec.fwb h264enc.fwb
    hevcdec.fwb hevcenc.fwb jpegdec.fwb jpegenc.fwb mpeg2dec.fwb
    mpeg4dec.fwb vc1dec.fwb vp8dec.fwb vp8enc.fwb vp9dec.fwb vp9enc.fwb
"
for f in $FWB_LIST; do
    p="$FW_DIR/$f"
    if [ -f "$p" ] && [ -s "$p" ]; then
        N_FWB=$((N_FWB + 1))
    else
        mark_miss "sky1-firmware.fwb" "$p"
    fi
done
# dsp_fw.bin (regular file) -- follows symlinks (-L) is fine.
for f in dsp_fw.bin arm/mali/arch12.8/mali_csffw.bin; do
    p="$FW_DIR/$f"
    # -L follows symlinks; -f tests for a regular file after following
    if [ -L "$p" ] || { [ -e "$p" ] && [ ! -d "$p" ]; }; then
        # resolve: if it's a symlink, check that the target exists & non-empty
        if [ -L "$p" ]; then
            tgt="$(readlink -f "$p" 2>/dev/null || true)"
            if [ -n "$tgt" ] && [ -f "$tgt" ] && [ -s "$tgt" ]; then
                N_OTHER_FW=$((N_OTHER_FW + 1))
            else
                mark_miss "sky1-firmware.other" "$p (dangling symlink -> ${tgt:-<empty>})"
            fi
        elif [ -f "$p" ] && [ -s "$p" ]; then
            N_OTHER_FW=$((N_OTHER_FW + 1))
        else
            mark_miss "sky1-firmware.other" "$p (zero-length or not a file)"
        fi
    else
        mark_miss "sky1-firmware.other" "$p"
    fi
done

# (b) CIX proprietary .debs (desktop / non-server only) -----------------
case "$BUILD_VARIANT" in
    server|headless)
        echo "verify-arm64-inputs: cix-debs: SKIP (BUILD_VARIANT=$BUILD_VARIANT)"
        ;;
    *)
        NCZ_CIX_DEB_MIN="${NCZ_CIX_DEB_MIN:-22}"
        DEB_DIR="$ROOT/assets/cix-debs"
        if [ ! -d "$DEB_DIR" ]; then
            mark_miss "cix-debs.dir" "$DEB_DIR"
        else
            # Every file we expect to find, mapped to the .deb filename prefix
            # the validation policy uses. A missing prefix means a category is
            # absent (e.g. no cix-npu-driver-dkms_*.deb means aipu 6.2.0 will
            # never reach the installed target).
            NEED_PREFIXES="
                cix-gpu-umd_
                cix-libglvnd_
                cix-mesa_
                cix-noe-umd_
                cix-npu-driver-dkms_
                cix-vpu-driver-dkms_
                cix-gpu-kmd-dkms_
                panthor-cix-dkms_
                cix-firmware_
            "
            for prefix in $NEED_PREFIXES; do
                if compgen -G "$DEB_DIR/${prefix}*.deb" > /dev/null; then
                    :
                else
                    mark_miss "cix-debs.prefix" "$DEB_DIR/${prefix}*.deb$([ "$prefix" = cix-npu-driver-dkms_ ] && echo " (pinned input: run build/stage-build-inputs.sh --arch arm64)")"
                fi
            done
            # The DKMS debs must carry today's assets/kernel/<drv> source.
            # A stale panthor-cix-dkms deb (pre-7.3 panthor_drv.c) passed the
            # prefix check above and left the r200 O6N without panthor.ko.
            if ! python3 "$SCRIPT_DIR/verify-dkms-deb-sources.py" \
                    --root "$ROOT" --deb-dir "$DEB_DIR" | sed "s/^/verify-arm64-inputs: /"; then
                mark_miss "cix-debs.dkms-source" "$DEB_DIR (stale DKMS deb; see above). Fix: build/stage-canonical-assets.sh, or build/build-dkms-debs.sh <mali|panthor|vpu> (needs dpkg-deb; run in the ncz-imagebuild container on Fedora hosts) and replace the old deb in $DEB_DIR with build/dkms-debs/<name>-dkms_*.deb"
            fi
            N_DEBS=$(find "$DEB_DIR" -maxdepth 1 -type f -name '*.deb' | wc -l | tr -d ' ')
            if [ "$N_DEBS" -lt "$NCZ_CIX_DEB_MIN" ]; then
                mark_miss "cix-debs.count" "$DEB_DIR (have=$N_DEBS, need>=$NCZ_CIX_DEB_MIN)"
            fi
        fi
        ;;
esac

# (c) Rescue rootfs ------------------------------------------------------
# Either the arch-specific or the generic name is acceptable (the build
# already symlinks one to the other, per build-iso-di.sh ~3227-3230).
RESCUE_DIR="$ROOT/assets/rescue"
R1="$RESCUE_DIR/rescue-rootfs-arm64.tar.zst"
R2="$RESCUE_DIR/rescue-rootfs.tar.zst"
if [ -s "$R1" ]; then
    N_RESCUE=$((N_RESCUE + 1))
elif [ -s "$R2" ]; then
    N_RESCUE=$((N_RESCUE + 1))
else
    mark_miss "rescue-rootfs" "$R1 (also checked: $R2)"
fi

# (d) --mirror flag: build/desktop-mirror browser seed ------------------
# Only run when explicitly requested (the build runs offline-mirror itself
# at a later stage; this just makes sure the *seed* debs are present so
# the mirror build has something to index). We look in pool recursively
# (build/desktop-mirror is a generated tree whose exact subdir layout is
# the mirror-build script's choice, not the gate's).
if [ "$CHECK_MIRROR" = 1 ]; then
    MIRROR_ROOT="${BUILD_DIR:-$ROOT/build}/desktop-mirror"
    # The build dir defaults to ROOT/build; honour it if set so the gate
    # works from anywhere the build is invoked.
    for debname in google-chrome-stable chromium-ncz-sky1; do
        if find "$MIRROR_ROOT/pool" -type f -name "${debname}_*_arm64.deb" 2>/dev/null | grep -q .; then
            N_MIRROR_DEBS=$((N_MIRROR_DEBS + 1))
        else
            mark_miss "mirror.deb" "$MIRROR_ROOT/pool (missing: ${debname}_*_arm64.deb)"
        fi
    done
    # Packages index check: if a Packages file exists, both packages must be
    # listed. The brief says "if a Packages file exists" -- we don't require
    # it to exist (an empty mirror is allowed pre-build), but if it does we
    # check it.
    PKG_FILE="$(find "$MIRROR_ROOT" -maxdepth 6 -type f -name Packages 2>/dev/null | head -1 || true)"
    if [ -n "$PKG_FILE" ] && [ -r "$PKG_FILE" ]; then
        for pkg in google-chrome-stable chromium-ncz-sky1; do
            if grep -q "^Package: ${pkg}\$" "$PKG_FILE"; then
                N_MIRROR_INDEX=$((N_MIRROR_INDEX + 1))
            else
                mark_miss "mirror.index" "$PKG_FILE (no entry for Package: ${pkg})"
            fi
        done
    fi
fi

# (e) ncz-screensavers: when manifests/install-extra.pkgs asks for it, the .deb
# must be staged (and, with --mirror, present in the offline mirror) --------
EXTRA_MANIFEST="$ROOT/manifests/install-extra.pkgs"
if [ -s "$EXTRA_MANIFEST" ] && sed 's/#.*//' "$EXTRA_MANIFEST" | awk 'NF {print $1}' | grep -qx ncz-screensavers; then
    if ! ls "$ROOT"/build/ncz-screensavers-out/ncz-screensavers_*_arm64.deb >/dev/null 2>&1; then
        mark_miss "ncz-screensavers.deb" "$ROOT/build/ncz-screensavers-out/ncz-screensavers_*_arm64.deb (install-extra.pkgs requests it)"
    fi
    if [ "$CHECK_MIRROR" = 1 ]; then
        FM="${BUILD_DIR:-$ROOT/build}/forky-mirror"
        if ! find "$FM/pool" -type f -name 'ncz-screensavers_*_arm64.deb' 2>/dev/null | grep -q . ; then
            mark_miss "ncz-screensavers.mirror" "$FM/pool (no ncz-screensavers_*_arm64.deb; re-run stage 0)"
        fi
    fi
    # the Singularity plugin (chooser/settings UI) is a separate package, not
    # published yet; require its deb only when the manifest actually lists it
    if sed 's/#.*//' "$EXTRA_MANIFEST" | awk 'NF {print $1}' | grep -qx ncz-screensavers-plugin; then
        ls "$ROOT"/build/ncz-screensavers-out/ncz-screensavers-plugin_*_arm64.deb >/dev/null 2>&1 || mark_miss "ncz-screensavers-plugin.deb" "$ROOT/build/ncz-screensavers-out/ncz-screensavers-plugin_*_arm64.deb"
        if [ "$CHECK_MIRROR" = 1 ]; then
            find "${BUILD_DIR:-$ROOT/build}/forky-mirror/pool" -type f -name 'ncz-screensavers-plugin_*_arm64.deb' 2>/dev/null | grep -q . || mark_miss "ncz-screensavers-plugin.mirror" "forky-mirror/pool (no ncz-screensavers-plugin_*_arm64.deb; re-run stage 0)"
        fi
    fi
    # the GTK4 reference app is for other distros: never staged, never in the mirror
    if ls "$ROOT"/build/ncz-screensavers-out/ncz-screensavers-gtk4-reference* >/dev/null 2>&1; then
        mark_miss "ncz-screensavers-gtk4-reference" "staged in build/ncz-screensavers-out (it must not be shipped in NCZ-OS)"
    fi
    if [ "$CHECK_MIRROR" = 1 ] && find "${BUILD_DIR:-$ROOT/build}/forky-mirror/pool" -type f -name 'ncz-screensavers-gtk4-reference*' 2>/dev/null | grep -q . ; then
        mark_miss "ncz-screensavers-gtk4-reference.mirror" "forky-mirror/pool carries the GTK4 reference app"
    fi
fi

# (f) overlay MODVERSIONS CRCs vs the pinned kernel -----------------------
# The committed accelerator overlays (assets/kernel/{mali,vpu,npu,panthor}/
# <kver>/*.ko) must carry the symbol CRCs of the kernel that assets/kernel/
# mainline pins (its Module.symvers). Rebuilds keep the KVER and vermagic
# (r282, r283, r284 are all 7.3.0-rc6-sky1-ncz), so only the CRCs tell a stale
# overlay apart; the r282 overlays had 648 mismatches vs r284 and the loader
# refuses them (no GPU/VPU/NPU). A tree without assets/kernel/mainline (test
# fixtures) has no pin to check against and is skipped; a dangling pin fails.
N_OVERLAY_CRC=skip
if [ -e "$ROOT/assets/kernel/mainline" ] || [ -L "$ROOT/assets/kernel/mainline" ]; then
    if python3 "$SCRIPT_DIR/verify-overlay-modversions.py" --root "$ROOT"; then
        N_OVERLAY_CRC=ok
    else
        mark_miss "overlay-modversions" "$ROOT/assets/kernel/{mali,vpu,npu,panthor}/<kver>/*.ko vs the pinned kernel Module.symvers (see build/verify-overlay-modversions.py output above)"
    fi
    # Same kver dirs: each overlay must have been compiled from today's
    # assets/kernel/<drv> source (SOURCE.sha256 from build-accel-overlays.sh).
    if ! python3 "$SCRIPT_DIR/verify-dkms-deb-sources.py" --root "$ROOT" --overlays; then
        mark_miss "overlay-source" "$ROOT/assets/kernel/{mali,vpu,npu,panthor}/<kver>/SOURCE.sha256 vs assets/kernel/<drv> (rebuild with build/build-accel-overlays.sh)"
    fi
fi

# --- summary ------------------------------------------------------------
if [ "$FAIL" -ne 0 ]; then
    cat <<'HINT' >&2

verify-arm64-inputs: one or more required inputs are absent.

  How to restore each missing class:
    - sky1-firmware/    : copy from the canonical set at
                           /mnt/argonas-projects/cix-installer/assets/sky1-firmware
                           on ULTRA, or
                           root@192.168.207.101:/mnt/datapool/projects/cix-installer/assets/sky1-firmware
                           on argonas.
    - cix-debs/         : copy from a checkout that already has them, e.g.
                           ~/Projects/cix-installer-arm64-build-2026-09-25/assets/cix-debs/
                           (the .gitignore excludes both sky1-firmware/ and
                           *.deb under cix-debs/ -- a fresh clone is empty).
    - desktop-mirror/   : run `make offline-mirror` (this repo) to rebuild
                           it from the refreshed vendor mirror + libdrm-debs.
    - overlay-modversions: copy the pinned staging dir's overlays/<dir>/<kver>/
                           *.ko into assets/kernel/<dir>/<kver>/ (or rebuild them
                           with build/build-accel-overlays.sh against its headers).

  Override: set NCZ_CIX_DEB_MIN=0 to build a deliberately GPU-less image
            (NOT recommended for arm64 Sky1 -- boot reaches a black screen).
HINT
    exit 1
fi

# Success summary line, kept compact so callers (Make, CI logs) can grep it.
echo "verify-arm64-inputs: OK (fwb=$N_FWB other_fw=$N_OTHER_FW cix_debs=$N_DEBS rescue=$N_RESCUE mirror_debs=$N_MIRROR_DEBS mirror_index=$N_MIRROR_INDEX overlay_crc=$N_OVERLAY_CRC)"
exit 0
