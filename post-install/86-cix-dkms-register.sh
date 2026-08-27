#!/bin/bash
# 86-cix-dkms-register.sh — register the NPU and VPU DKMS sources.
#
# Operator directive: all CIX accelerator drivers ship out-of-tree via DKMS, so
# a kernel upgrade rebuilds them instead of silently leaving stale, vermagic-
# locked modules behind. The GPU drivers already do this in their own scripts
# (82-mali-gpu.sh needs the SCMI rate-limit patch applied to its source, and
# 83-panthor-gpu.sh has its own staging rules), so this script covers the two
# that need nothing beyond stage-and-register: NPU (aipu) and VPU (amvx).
#
# Prerequisite: 79-dkms-prep.sh. The shipped kernel headers are a Yocto
# build-host artifact and cannot compile anything until it repairs them --
# foreign fixdep/modpost, and a missing localversion that would otherwise stamp
# every module with the wrong vermagic.
#
# Registration is worth doing even when the build cannot run right now: `dkms
# add` alone means the next kernel upgrade autoinstalls the driver. Until then
# the in-tree module or the prebuilt overlay carries the boot, so nothing here
# is allowed to be fatal.
set -uo pipefail

INSTALLER_META=/usr/local/lib/cix-installer

KVER_NEXT=""
[ -f "$INSTALLER_META/KVER_NEXT" ] && KVER_NEXT=$(tr -d ' \t\r\n' < "$INSTALLER_META/KVER_NEXT")
[ -n "$KVER_NEXT" ] || KVER_NEXT=$(uname -r)

register() {
    local label="$1" asset="$2" pkg="$3" ver="$4"
    local src_dir="$INSTALLER_META/assets/kernel/$asset"
    local conf="$src_dir/dkms.conf"
    local tree="$src_dir/src"

    if [ ! -d "$tree" ] || [ ! -f "$conf" ]; then
        echo "[86] $label: no DKMS source at $tree — skipping"
        return 0
    fi

    # THE dkms.conf IS THE SINGLE SOURCE OF TRUTH FOR THE VERSION.
    #
    # A caller-supplied version that disagrees with PACKAGE_VERSION does not
    # fail loudly -- it fails in a way that looks like a missing kernel header.
    # MEASURED on O6N 2026-08-18: this function was called as
    #
    #     register "VPU" vpu cix-vpu-driver 1.0.2
    #
    # while assets/kernel/vpu/dkms.conf declared PACKAGE_VERSION="1.0.2-ncz1".
    # `dkms add -v 1.0.2` therefore staged the source at
    # /var/lib/dkms/cix-vpu-driver/1.0.2/build, but MAKE[0] interpolates
    # ${PACKAGE_VERSION} into its own -M path, so the compile ran against
    # /var/lib/dkms/cix-vpu-driver/1.0.2-ncz1/build and died with:
    #
    #     Makefile:199: *** specified external module directory
    #     "/var/lib/dkms/cix-vpu-driver/1.0.2-ncz1/build" does not exist.  Stop.
    #
    # The result was `cix-vpu-driver/1.0.2: added` and nothing else, so the
    # board silently fell back to the OLDER IN-TREE amvx while cixmini -- whose
    # dkms.conf still said plain "1.0.2" -- correctly ran the DKMS module from
    # updates/dkms/amvx.ko.xz. Two boards, two different VPU drivers, no error
    # anywhere. Take the version from the conf so the two can never diverge.
    local conf_ver
    conf_ver=$(sed -n 's/^[[:space:]]*PACKAGE_VERSION="\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' "$conf" | head -1)
    if [ -n "$conf_ver" ] && [ "$conf_ver" != "$ver" ]; then
        echo "[86] $label: dkms.conf declares PACKAGE_VERSION=$conf_ver (hook said $ver) — using $conf_ver"
        ver="$conf_ver"
    fi

    local dst="/usr/src/${pkg}-${ver}"

    rm -rf "$dst"
    mkdir -p "$dst"
    if ! cp -a "$tree/." "$dst/"; then
        echo "[86] $label: WARNING: could not stage source to $dst"
        return 0
    fi
    cp -a "$conf" "$dst/dkms.conf"
    echo "[86] $label: staged $dst"

    command -v dkms >/dev/null 2>&1 || {
        echo "[86] $label: dkms absent — source staged only (see 79-dkms-prep.sh)"
        return 0
    }

    dkms add -m "$pkg" -v "$ver" >/dev/null 2>&1 \
        && echo "[86] $label: dkms add ${pkg}/${ver}" \
        || echo "[86] $label: dkms add skipped (already registered?)"

    # Only attempt a build if the headers are actually there. If they are not,
    # AUTOINSTALL picks this up on the next kernel upgrade.
    if [ -f "/lib/modules/$KVER_NEXT/build/Makefile" ]; then
        if dkms build -m "$pkg" -v "$ver" -k "$KVER_NEXT" >/dev/null 2>&1 \
           && dkms install -m "$pkg" -v "$ver" -k "$KVER_NEXT" --force >/dev/null 2>&1; then
            echo "[86] $label: dkms built+installed for $KVER_NEXT (-> updates/dkms/)"
        else
            # SHOW THE ACTUAL ERROR. "deferred" is indistinguishable from
            # "failed", and the autoinstall it promises only ever runs on a
            # LATER kernel upgrade -- which for a freshly flashed board never
            # comes. The VPU version-mismatch bug above survived precisely
            # because this branch printed a reassuring message and discarded
            # the one line that identified the fault.
            echo "[86] $label: WARNING: dkms build FAILED for ${pkg}/${ver} on $KVER_NEXT"
            local _log="/var/lib/dkms/$pkg/$ver/build/make.log"
            [ -f "$_log" ] || _log=$(ls -1t /var/lib/dkms/"$pkg"/*/build/make.log 2>/dev/null | head -1)
            if [ -n "${_log:-}" ] && [ -f "$_log" ]; then
                grep -iE '\*\*\*|error|no such file|does not exist' "$_log" \
                    | head -5 | sed "s/^/[86]     /"
            fi
            echo "[86]     (in-tree module, if any, carries the boot instead — this is a REAL defect, not a deferral)"
        fi
    else
        echo "[86] $label: no kernel headers for $KVER_NEXT — will autoinstall on kernel upgrade"
    fi
}

# NPU: the REAL 26Q2-SDK driver (aipu/6.2.0) ships self-contained via the
# cix-npu-driver-dkms .deb, which stages /usr/src/aipu-6.2.0 (its own proper
# dkms.conf, no hand-transcription needed) and carries a standard postinst
# that calls /usr/lib/dkms/common.postinst. That SHOULD self-register, but
# measured 2026-08-17 (O6N, real hardware): the .deb reports fully configured
# (dpkg ii) yet `dkms status` never shows aipu/6.2.0 registered at all --
# most likely dkms add/build silently no-ops for the target KVER when it
# runs inside the chroot during image assembly, before a matching
# /lib/modules/ tree exists to build against. Register+build+install it
# explicitly here as a second, idempotent guarantee -- the whole point of
# this script per the header above ("worth doing even when the build cannot
# run right now").
#
# The OLD cix-npu-kmd/1.0 registration (hand-transcribed dkms.conf, HARD-CODES
# COMPASS_DRV_BTENVAR_KMD_VERSION=5.11.0 on the make command line regardless
# of actual source content) is REMOVED here, not just superseded: measured
# 2026-08-17 on O6N, its aipu.ko was the one that actually got built+loaded
# (self-identifying as "AIPU KMD (v5.11.0)" in dmesg) while aipu/6.2.0 sat
# unregistered -- and 5.11.0 is the same driver generation
# docs/DRIVER_FIDELITY_72.md documents as failing (either cleanly, as
# measured on O6N -- noe_init_context: Failed to initialize adapter,
# query capability [fail] -- or with a kernel panic, as measured 2026-08-04
# against a different 5.11.0 source tree). Leaving cix-npu-kmd/1.0 registered
# alongside aipu/6.2.0 risks exactly this outcome again on a future kernel
# bump if build/install ordering ever favors the stale package. There is no
# known-good reason to keep it: aipu-6.2.0 is a complete replacement, not an
# addition.
# ORDER MATTERS: remove cix-npu-kmd/1.0 FIRST, before registering
# aipu/6.2.0. Both packages install to the same destination filename
# (updates/dkms/aipu.ko.xz) -- measured 2026-08-17 doing it the other way
# round on O6N: installing aipu/6.2.0 then removing cix-npu-kmd/1.0 deleted
# the just-installed aipu/6.2.0 file, because dkms remove deletes whatever
# currently occupies that path under the belief it is cix-npu-kmd/1.0s own
# output. Whichever package is (re)installed LAST wins the file; it must be
# aipu/6.2.0.
if command -v dkms >/dev/null 2>&1 && dkms status 2>/dev/null | grep -q '^cix-npu-kmd/1.0'; then
    echo "[86] NPU: removing stale cix-npu-kmd/1.0 (superseded by aipu/6.2.0) BEFORE registering the replacement"
    dkms remove -m cix-npu-kmd -v 1.0 --all >/dev/null 2>&1         && echo "[86] NPU: cix-npu-kmd/1.0 removed"         || echo "[86] NPU: cix-npu-kmd/1.0 removal skipped (not fully registered?)"
fi
rm -rf /usr/src/cix-npu-kmd-1.0

if [ ! -d /usr/src/aipu-6.2.0 ]; then
    NPU_DKMS_DEB=$(ls "$INSTALLER_META"/assets/cix-debs/cix-npu-driver-dkms_*.deb 2>/dev/null | head -1)
    if [ -n "$NPU_DKMS_DEB" ]; then
        echo "[86] NPU: /usr/src/aipu-6.2.0 absent; extracting source from $(basename "$NPU_DKMS_DEB")"
        dpkg-deb -x "$NPU_DKMS_DEB" / 2>/dev/null \
            && echo "[86] NPU: staged aipu/6.2.0 source from bundled DKMS deb" \
            || echo "[86] NPU: WARNING: could not extract source from bundled DKMS deb"
    fi
fi

if [ -d /usr/src/aipu-6.2.0 ] && [ -f /usr/src/aipu-6.2.0/dkms.conf ]; then
    echo "[86] NPU: registering aipu/6.2.0 explicitly (postinst self-registration cannot be relied on inside the build chroot)"
    dkms add -m aipu -v 6.2.0 >/dev/null 2>&1         && echo "[86] NPU: dkms add aipu/6.2.0"         || echo "[86] NPU: dkms add aipu/6.2.0 skipped (already registered?)"
    if [ -f "/lib/modules/$KVER_NEXT/build/Makefile" ]; then
        if dkms build -m aipu -v 6.2.0 -k "$KVER_NEXT" >/dev/null 2>&1            && dkms install -m aipu -v 6.2.0 -k "$KVER_NEXT" --force >/dev/null 2>&1; then
            echo "[86] NPU: dkms built+installed aipu/6.2.0 for $KVER_NEXT (-> updates/dkms/)"
        else
            echo "[86] NPU: WARNING: aipu/6.2.0 dkms build FAILED for $KVER_NEXT"
            _log="/var/lib/dkms/aipu/6.2.0/build/make.log"
            if [ -f "$_log" ]; then
                grep -iE '\*\*\*|error|no such file|does not exist' "$_log" \
                    | head -5 | sed "s/^/[86]     /"
            fi
            echo "[86]     (this install must not ship without updates/dkms/aipu.ko*)"
        fi
    else
        echo "[86] NPU: no kernel headers for $KVER_NEXT — aipu/6.2.0 will autoinstall on kernel upgrade"
    fi
else
    echo "[86] NPU: /usr/src/aipu-6.2.0 not staged (cix-npu-driver-dkms not installed?) — skipping"
fi

register "VPU" vpu cix-vpu-driver 1.0.2

if command -v dkms >/dev/null 2>&1; then
    echo "[86] dkms status:"
    dkms status 2>/dev/null | sed 's/^/[86]   /'
fi

exit 0
