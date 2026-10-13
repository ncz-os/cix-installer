#!/bin/bash
# 26-gpu-default-mali.sh — make the CIX proprietary mali stack the default GPU
# stack (hardware GLES + EGL + OpenCL) for the 26.7 "Maximilian" MALI release.
#
# INVERTS the old 26-gpu-default-open.sh. That hook DEMOTED the CIX GPU userspace
# to open Mesa/llvmpipe because the mali_kbase kernel driver was NOT present (the
# image then ran the in-tree panthor driver, and the CIX libGLX driver-check
# `abort()`s Xorg without /dev/mali0). 26.7 SHIPS mali_kbase as a DKMS/overlay
# module (see 82-mali-gpu.sh) with the boot cmdline blacklisting panthor, so
# /dev/mali0 IS present at runtime → the CIX driver-check PASSES → the CIX GL
# stack comes up hardware-accelerated (metal-confirmed 2026-07-23 on O6N:
# "glamor X acceleration enabled on Mali-G720-Immortalis", eglinfo GLES renderer
# = Mali-G720, no greeter wedge). Without this, GL falls back to llvmpipe
# (software) — the very thing 26.7 must not ship.
#
# So: re-ENABLE the CIX GL ld-paths that -open disabled, AND the CIX Vulkan
# ICD. (CORRECTED 2026-07-27: an earlier version of this hook kept Vulkan
# disabled on the assumption "libmali exposes no Vulkan" — that was WRONG,
# disproven on real O6N hardware: `VK_DRIVER_FILES=/etc/vulkan/icd.d/mali.json
# vulkaninfo` enumerates a real device, apiVersion 1.3.296, driverID
# DRIVER_ID_ARM_PROPRIETARY, deviceName "Mali-G720-Immortalis". The WSI
# implicit layer's status is NOT re-verified by that test and stays disabled
# pending its own check.)
#
# The enable is a config change only — it does NOT need /dev/mali0 at install
# time (we are in a chroot). The CIX driver-check runs at RUNTIME (first boot /
# greeter start), by which point mali_kbase has loaded. RUNS INSIDE CHROOT via
# run-all.sh, after 25-cix-* (which installs these files).
# ARCH GATE (dual-arch parity): Sky1-only hook. run-all.sh runs every hook on every architecture, so
# log and no-op anywhere else (build/lint-hook-arch-gates.sh enforces this).
_ncz_a="${NCZ_TARGET_ARCH:-$(tr -d '[:space:]' < /usr/local/lib/cix-installer/BUILD_ARCH 2>/dev/null)}"
[ -n "$_ncz_a" ] || _ncz_a="$(dpkg --print-architecture 2>/dev/null || true)"
if [ "$_ncz_a" != arm64 ]; then echo "[26] Sky1-only hook; target architecture is '${_ncz_a:-unknown}' -- skipping"; exit 0; fi
unset _ncz_a
set -uo pipefail

enable_file() {  # base label   (base.disabled -> base)
    local base="$1" label="$2"
    if [ -e "$base.disabled" ]; then
        mv "$base.disabled" "$base"
        echo "[26] enabled CIX $label: $(basename "$base")"
    elif [ -e "$base" ]; then
        echo "[26] CIX $label already enabled"
    else
        echo "[26] CIX $label absent ($base) — nothing to enable"
    fi
}

# --- GLES/GL + OpenCL: dynamic-linker search paths (the CIX mali stack) -----
enable_file /etc/ld.so.conf.d/00-cixgpu-pro.conf    "OpenCL/libmali (ld path)"

# 01-cixgpu-compat is DELIBERATELY LEFT DISABLED as of 2026-09-04.
#
# It puts /opt/cixgpu-compat on the system loader path, and that directory is a
# COMPLETE SECOND GL STACK: cix-libglvnd 1.7.0 (libGL, libGLESv2, libGLESv1_CM,
# libGLX, libGLdispatch) plus cix-mesa 24.0.4 (libEGL_mesa, libEGL.so.1,
# libglapi, dri/). The system now ships glvnd 1.7.0 with Mesa 26.1.6, so
# enabling it made libEGL.so.1 resolve to the 24.0.4 copy for EVERY process
# while GTK 4.22.4 is built against 26.
#
# That combination does not work. Measured on MS-R1 2026-09-04:
#   GTK clients      -> "Could not initialize EGL display", GskCairoRenderer
#                       (software). On the Panthor boot: "renderer is llvmpipe".
#   CIX vendor forced-> free(): invalid pointer, core dump
# which is the same heap corruption ncz-gpu-env's panthor branch already
# documents for the mirror case. Operator-visible symptom was "MS-R1 is jerky"
# and "Chromium is not accelerating" -- both were software rendering.
#
# This hook's header records that enabling it was metal-confirmed working on
# 2026-07-23 ("glamor X acceleration enabled on Mali-G720-Immortalis"). That was
# true then; the system Mesa/GTK upgrade since is what turned it into a
# regression. So this is not a revert of a wrong decision, it is a forward fix.
#
# Nothing is lost: libEGL_cix.so.1 links against libc ONLY -- it is a
# self-contained glvnd vendor shim that dlopens libmali -- and it lives in
# 00-cixgpu-pro, which stays enabled. Verified with a direct EGL probe under the
# single-Mesa loader:
#     GBM     : OK  EGL 1.5  vendor=ARM  Valhall-"r53p0-00eac0"  OpenGL_ES
#     Wayland : eglInitialize FAILED (0x3001)   <- blob is GBM-only, by design
# Compositor came up on Mali with 0 restarts and the operator confirmed video
# playback accelerating.
#
# If you re-enable this, you are putting Mesa 24 back in front of Mesa 26.
disable_file() {  # base label   (base -> base.disabled)
    local base="$1" label="$2"
    if [ -e "$base" ]; then
        mv "$base" "$base.disabled"
        echo "[26] disabled CIX $label: $(basename "$base") (Mesa 24 must not shadow system Mesa)"
    else
        echo "[26] CIX $label already disabled"
    fi
}
disable_file /etc/ld.so.conf.d/01-cixgpu-compat.conf "GL/GLX/GLES glvnd compat (ld path)"
ldconfig 2>/dev/null || true

# --- Vulkan: ENABLE the ICD (real device, hardware-validated 2026-07-27).
#     WSI implicit layer stays disabled — unverified, and it's not needed for
#     ICD discovery (VK_DRIVER_FILES in ncz-gpu-env handles that explicitly).
enable_file /etc/vulkan/icd.d/mali.json "Vulkan ICD"
if [ -e /etc/vulkan/implicit_layer.d/VkLayer_window_system_integration.json ]; then
    mv /etc/vulkan/implicit_layer.d/VkLayer_window_system_integration.json \
       /etc/vulkan/implicit_layer.d/VkLayer_window_system_integration.json.disabled
    echo "[26] kept CIX Vulkan WSI implicit layer DISABLED (unverified)"
fi

# --- Report the winners the loaders will resolve at runtime ----------------
echo "[26] libGLX.so.0    -> $(ldconfig -p 2>/dev/null | awk '/libGLX.so.0 /{print $NF; exit}')"
echo "[26] libEGL.so.1    -> $(ldconfig -p 2>/dev/null | awk '/libEGL.so.1 /{print $NF; exit}')"
echo "[26] libGLESv2.so.2 -> $(ldconfig -p 2>/dev/null | awk '/libGLESv2.so.2 /{print $NF; exit}')"
echo "[26] libOpenCL.so.1 -> $(ldconfig -p 2>/dev/null | awk '/libOpenCL.so.1 /{print $NF; exit}')"
# --- system-wide Mali EGL vendor (never-software-render) ---------------------------------------------------
# glvnd's default search path has only Mesa; without this entry any process that does not inherit the compositor's
# __EGL_VENDOR_LIBRARY_FILENAMES (ssh, cron, systemd --user, D-Bus activation, portals) renders with llvmpipe on a
# Mali board. The shipped default is Mali; ncz-gpu-switcher removes the entry on a Panthor boot.
if [ -r /opt/cixgpu-compat/share/glvnd/egl_vendor.d/40_cix.json ]; then
    mkdir -p /etc/glvnd/egl_vendor.d
    ln -sfn /opt/cixgpu-compat/share/glvnd/egl_vendor.d/40_cix.json /etc/glvnd/egl_vendor.d/10_cix.json
    echo "[26] registered the Mali EGL vendor system-wide (/etc/glvnd/egl_vendor.d/10_cix.json)"
else
    echo "[26] WARNING: /opt/cixgpu-compat/.../40_cix.json absent; Mali EGL vendor not registered system-wide"
fi

# --- runtime GPU switching lives in ncz-gpu-switcher now -------------------
# This hook used to install /usr/local/sbin/ncz-gpu-profile from
# assets/gpu/ncz-gpu-profile and call it to write a modprobe.d blacklist. Both
# the asset and that tool are retired: selection is now the sky1.gpu= kernel
# cmdline token, applied at boot by ncz-gpu-switcher.service (installed by
# 83-panthor-gpu.sh), so the kernel driver and the userspace half can never
# disagree. The enable_file calls above already leave this image in the mali
# userspace state that 26.7 ships as the default.

echo "[26] CIX mali GL default set (HW GLES/EGL/OpenCL; Vulkan off). Needs /dev/mali0 at boot (82-mali-gpu.sh)."
exit 0
