#!/bin/bash
# 26-gpu-default-open.sh — make the open Mesa stack the COMPLETE default GPU
# stack (OpenGL/GLX + Vulkan + OpenCL) by demoting every CIX proprietary GPU
# component out of the loaders' search paths.
#
# All CIX GPU userspace runs a "CIX driver check" that requires the CIX
# mali_kbase kernel driver. That driver is NOT present on this image (the
# in-tree panthor driver owns the Mali-G720), so each CIX component either
# shadows the open loader or HARD-ABORTS:
#
#   * /opt/cixgpu-pro    (00-cixgpu-pro.conf)    — libOpenCL.so.1 is a non-ICD
#     vendor lib that shadows ocl-icd, so /etc/OpenCL/vendors/rusticl.icd is
#     never honored ("No mali devices found").
#   * /opt/cixgpu-compat (01-cixgpu-compat.conf) — the cix-libglvnd
#     libGLX.so.0 runs the CIX driver check and calls abort() (SIGABRT). Xorg
#     loads glvnd's libGLX -> "CIX driver check failed" -> Xorg dies -> lightdm
#     crash-loops -> NO DESKTOP (boots to a console that looks like "server").
#     This is the big one.
#   * /etc/vulkan/icd.d/mali.json — CIX Vulkan ICD (dead without kbase).
#   * /etc/vulkan/implicit_layer.d/VkLayer_window_system_integration.json —
#     CIX WSI implicit layer; its driver check fails vkCreateInstance for ALL
#     Vulkan apps (including panvk), even when VK_DRIVER_FILES restricts ICDs
#     (implicit layers are NOT filtered by VK_DRIVER_FILES).
#
# Disabling these makes Mesa the default for GL (libGLX_mesa), Vulkan (panvk
# 26.1.3), and OpenCL (rusticl 26.1.3). Each CIX file is renamed .disabled
# (kept on disk) so a future opt-in GPU switcher (panthor <-> cix mali_kbase,
# landing with the 7.1 DKMS kbase) can re-enable them.
#
# Must run AFTER 25-cix-* (which installs these files). RUNS INSIDE CHROOT
# (via run-all.sh). Offline-safe, idempotent.
set -uo pipefail

disable_file() {  # path label
    local f="$1" label="$2"
    if [ -e "$f" ]; then
        mv "$f" "$f.disabled"
        echo "[26] demoted CIX $label: $(basename "$f")"
    elif [ -e "$f.disabled" ]; then
        echo "[26] CIX $label already demoted"
    else
        echo "[26] CIX $label absent ($f) — open Mesa already default"
    fi
}

# --- OpenGL/GLX + OpenCL: dynamic-linker search paths ----------------------
disable_file /etc/ld.so.conf.d/00-cixgpu-pro.conf    "OpenCL libmali (ld path)"
disable_file /etc/ld.so.conf.d/01-cixgpu-compat.conf "GL/GLX glvnd (ld path; was aborting Xorg)"
ldconfig 2>/dev/null || true

# --- Vulkan: ICD + implicit layer manifest dirs ----------------------------
disable_file /etc/vulkan/icd.d/mali.json "Vulkan ICD"
disable_file /etc/vulkan/implicit_layer.d/VkLayer_window_system_integration.json "Vulkan WSI layer"

# --- Report winners --------------------------------------------------------
echo "[26] libGLX.so.0    -> $(ldconfig -p 2>/dev/null | awk '/libGLX.so.0 /{print $NF; exit}')"
echo "[26] libEGL.so.1    -> $(ldconfig -p 2>/dev/null | awk '/libEGL.so.1 /{print $NF; exit}')"
echo "[26] libOpenCL.so.1 -> $(ldconfig -p 2>/dev/null | awk '/libOpenCL.so.1 /{print $NF; exit}')"
echo "[26] Vulkan ICDs:   $(ls /usr/share/vulkan/icd.d/*.json 2>/dev/null | xargs -n1 basename 2>/dev/null | tr '\n' ' ')"
exit 0
