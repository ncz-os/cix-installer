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
    local dst="/usr/src/${pkg}-${ver}"

    if [ ! -d "$tree" ] || [ ! -f "$conf" ]; then
        echo "[86] $label: no DKMS source at $tree — skipping"
        return 0
    fi

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
            echo "[86] $label: dkms build deferred — will autoinstall on kernel upgrade"
        fi
    else
        echo "[86] $label: no kernel headers for $KVER_NEXT — will autoinstall on kernel upgrade"
    fi
}

register "NPU" npu cix-npu-kmd    1.0
register "VPU" vpu cix-vpu-driver 1.0.2

if command -v dkms >/dev/null 2>&1; then
    echo "[86] dkms status:"
    dkms status 2>/dev/null | sed 's/^/[86]   /'
fi

exit 0
