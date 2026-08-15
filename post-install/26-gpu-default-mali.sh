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
enable_file /etc/ld.so.conf.d/01-cixgpu-compat.conf "GL/GLX/GLES glvnd compat (ld path)"
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
# --- install the runtime GPU profile switch --------------------------------
# The same logic that ran above, exposed as a tool, so the kernel driver and the
# userspace stack can only ever move together. Switching one without the other
# yields a machine that boots and cannot render (measured on O6N 2026-08-15).
for _src in "$INSTALLER_META/assets/gpu/ncz-gpu-profile" /cdrom/cixmini/assets/gpu/ncz-gpu-profile; do
    if [ -f "$_src" ]; then
        install -D -m 0755 "$_src" /usr/local/sbin/ncz-gpu-profile
        echo "[26] installed /usr/local/sbin/ncz-gpu-profile"
        # Record state + write the modprobe.d blacklist. Driver selection lives
        # in modprobe.d, NOT the kernel cmdline: ncz-refind-refresh regenerates
        # refind.conf on apt operations and drops cmdline edits.
        /usr/local/sbin/ncz-gpu-profile mali >/dev/null 2>&1 \
            && echo "[26] gpu profile set to mali (modprobe.d + ld paths + ICD)" \
            || echo "[26] WARN: ncz-gpu-profile mali failed"
        break
    fi
done

echo "[26] CIX mali GL default set (HW GLES/EGL/OpenCL; Vulkan off). Needs /dev/mali0 at boot (82-mali-gpu.sh)."
exit 0
