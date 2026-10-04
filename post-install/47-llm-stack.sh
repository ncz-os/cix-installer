#!/bin/bash
# NCZ-MIXED-HOOK: vulkan/clinfo runtime; explicit arm64 and amd64 branches (lines ~83,132); TODO split (docs/platform-inventory.tsv; runs on every platform, listed in both hooks.list files)
# 47-llm-stack.sh — GPU/compute RUNTIME + diagnostics for the LLM and NPU
# tiers, so the appliance ships "plug-in-and-it-works" without manual apt.
#
# Scope narrowed 2026-08-05 to runtime only: vulkan-tools (vulkaninfo), clinfo,
# glmark2. The Vulkan dev headers, glslang/glslc and spirv-tools that used to
# be here were build substrate for workloads that no longer exist on-device —
# llama.cpp ships CPU-only and the NPU embedder runs on NOE/libnoe. This hook
# also removes the Vulkan dev/build packages (headers, glslang, spirv-tools,
# validation layers), ~95MB. mesa-vulkan-drivers is KEPT on arm64: the Panthor
# entry needs Mesa's PanVK, so only the Mali entry's VK_DRIVER_FILES pin keeps
# the two ICDs apart. See docs/DRIVER_FIDELITY_72.md. Idempotent.
#
# Removal verified on O6N live hardware: desktop session untouched (greetd,
# labwc, shell all still up), GLES still Mali-G720 at glmark2 7532, and the
# blob Vulkan ICD still resolves to the G720 — mesa-vulkan-drivers owns only
# ICD JSONs and Vulkan layers, never GL/GLES/EGL/GBM (those are libgles2,
# libegl1, libgbm1).
#
# Out of scope for this hook (deferred to P4 scope-2 = `ncz install mnemos`):
#   - llama.cpp Vulkan binaries (large, model-loadout-specific)
#   - npu_embed_v2.py wrapper + bge-small-zh.cix (.cix is LFS ~150MB,
#     pulled at first run via `ncz models pull` task #99)
#   - libnoe runtime (already in cix-noe-umd deb installed by 25-cix-ppa.sh)
#
# Scope-2 will add another hook (or extend ncz CLI) once `ncz install
# mnemos` is wired through.
#
# RUNS INSIDE CHROOT (via run-all.sh).
set -euo pipefail

echo "[47] baking GPU/NPU/LLM substrate (Vulkan + SPIR-V + tools)"

# Best-effort apt update — offline mirror is present, network may not be.
apt-get update -o Acquire::http::Timeout=8 -o Acquire::https::Timeout=8 -o Acquire::Retries=0 -o Acquire::ForceIPv4=true 2>&1 | tail -3 || true

# RUNTIME ONLY. The shader compilers and Vulkan dev headers are deliberately
# NOT installed (2026-08-05): nothing in the shipped image compiles GPU code at
# runtime. They were here as build substrate for "llama.cpp Vulkan, the NPU
# embedder, and future Mali compute tools" — but llama.cpp now ships CPU-only
# (a Vulkan-linked build costs 13.6x CPU throughput even with the GPU unused,
# and loses to the CPU when the GPU does engage — see DRIVER_FIDELITY_72.md),
# and the NPU embedder runs on NOE/libnoe, not Vulkan. Dropping
# libvulkan-dev + glslang + spirv-tools + validationlayers saves ~95MB.
#
# vulkan-tools stays: vulkaninfo is how you diagnose the blob ICD.
# clinfo stays: OpenCL 3.0 is live on the blob and the CIX media engine
# (libcme) ships .cl kernels. glmark2 stays: the GLES smoke test.
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    vulkan-tools \
    clinfo \
    glmark2-x11 \
    glmark2-es2-x11 \
    glmark2-wayland 2>&1 | tail -5 || \
    echo "[47] some Vulkan/OpenCL runtime packages unavailable — continuing (offline mirror may not have them all)"

# Keep mesa-vulkan-drivers. On arm64 it carries PanVK, the only Vulkan driver
# the Panthor entry (sky1.gpu=mesa) has: the switcher disables the blob's
# /etc/vulkan/icd.d/mali.json there, so purging the package left Panthor with an
# empty ICD directory (O6N 2026-10-04). The Mali entry pins
# VK_DRIVER_FILES=/etc/vulkan/icd.d/mali.json, so the extra ICDs do not
# interfere there. Only the Vulkan dev/build packages are purged.
#
# The dev packages are BAKED INTO desktop.squashfs by an older layer build, so
# dropping them from the install list above is not enough — they arrive with
# the layer and have to be purged here. Verified on O6N: removing them leaves
# the desktop, GLES and the blob Vulkan ICD working.
#
# CIX-Sky1-ONLY. This entire "our real ICD is a vendor blob" premise is false
# on amd64/x86_64: there is no vendor blob there, and mesa-vulkan-drivers
# (RADV/ANV) IS the real, only Vulkan ICD. Confirmed live on a real T2 MacBook
# (Navi14/AMD Radeon Pro 5300M, 2026-09-20): this purge ran unconditionally,
# deleted mesa-vulkan-drivers, and left the box with a real hardware-capable
# EGL/GLES path (radeonsi, confirmed via eglinfo) but NO Vulkan ICD at all —
# /usr/share/vulkan/icd.d/ empty — which made labwc/wlroots' Vulkan renderer
# path fall back to software (lavapipe), read by the operator as "GPU accel
# is broken" even though the GPU driver itself was fine the whole time. Only
# run this dev-stack purge on the Sky1/arm64 image, where the Mali blob ICD
# genuinely replaces it.
TARGET_ARCH="$(dpkg --print-architecture 2>/dev/null || true)"
if [ "$TARGET_ARCH" = "arm64" ]; then
    # Keep mesa-vulkan-drivers. The Mali entry pins the vendor blob ICD with
    # VK_DRIVER_FILES, so it does not interfere there, but the Panthor entry has
    # no vendor Vulkan at all and needs Mesa's PanVK. Purging the package left
    # Panthor with an empty ICD directory (O6N 2026-10-04); only the Vulkan
    # build/dev packages (dev headers, shader compilers, validation layers) are
    # removed. manifests/desktop.pkgs ships mesa-vulkan-drivers for exactly this.
    echo "[47] architecture=$TARGET_ARCH: purging only the Vulkan build/dev stack (mesa-vulkan-drivers kept for PanVK)"
    NCZ_GPU_PURGE=""
    for p in libvulkan-dev vulkan-validationlayers \
             spirv-tools spirv-headers glslang-tools glslang-dev; do
        dpkg -l "$p" 2>/dev/null | grep -q "^ii" && NCZ_GPU_PURGE="$NCZ_GPU_PURGE $p"
    done
    if [ -n "$NCZ_GPU_PURGE" ]; then
        echo "[47] purging Vulkan build/dev stack (unusable on this SoC):$NCZ_GPU_PURGE"
        # shellcheck disable=SC2086
        DEBIAN_FRONTEND=noninteractive apt-get remove -y $NCZ_GPU_PURGE 2>&1 | tail -3 || \
            echo "[47] WARN: purge incomplete — continuing (non-fatal)"
        DEBIAN_FRONTEND=noninteractive apt-get autoremove -y 2>&1 | tail -2 || true
    else
        echo "[47] Vulkan build/dev stack already absent"
    fi
    # Idempotent: guarantee the PanVK ICD is present even if the desktop layer
    # did not install it, so the Panthor entry always has Vulkan.
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends mesa-vulkan-drivers 2>&1 | tail -5 || \
        echo "[47] WARN: mesa-vulkan-drivers install failed — continuing (non-fatal)"
else
    echo "[47] architecture=${TARGET_ARCH:-unknown}: keeping mesa-vulkan-drivers; Mesa ICDs are required off arm64"
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends mesa-vulkan-drivers 2>&1 | tail -5 || \
        echo "[47] WARN: mesa-vulkan-drivers install failed — continuing (non-fatal)"
fi

# No glslc / shader compiler: see the note above. Build GPU code on a build
# host, not on the appliance.

echo
echo "[47] verification:"
for tool in clinfo glmark2; do
    if command -v "$tool" >/dev/null 2>&1; then
        echo "    OK  $tool is executable"
    else
        echo "    --  $tool (not installed)"
    fi
done

# A chroot normally has no GPU device nodes, so device enumeration is not a
# valid install-time assertion. Verify the installed loader tool and the ICD
# configuration that it will consume at first boot instead. These checks are
# deliberately fatal: an empty command substitution is not proof of Vulkan.
VULKAN_TOOLS_VERSION="$(dpkg-query -W -f='${Version}' vulkan-tools 2>/dev/null || true)"
if [ -z "$VULKAN_TOOLS_VERSION" ] || ! command -v vulkaninfo >/dev/null 2>&1; then
    echo "[47] ERROR: vulkan-tools/vulkaninfo is not installed" >&2
    exit 1
fi
if ldd "$(command -v vulkaninfo)" 2>&1 | grep -q 'not found'; then
    echo "[47] ERROR: vulkaninfo has unresolved shared-library dependencies" >&2
    exit 1
fi

if [ "$TARGET_ARCH" = "amd64" ] && ! dpkg-query -W -f='${Status}' mesa-vulkan-drivers 2>/dev/null | grep -q '^install ok installed$'; then
    echo "[47] ERROR: amd64 requires the mesa-vulkan-drivers package" >&2
    exit 1
fi

shopt -s nullglob
VULKAN_ICDS=(/etc/vulkan/icd.d/*.json /usr/share/vulkan/icd.d/*.json)
shopt -u nullglob
if [ "${#VULKAN_ICDS[@]}" -eq 0 ]; then
    echo "[47] ERROR: no Vulkan ICD JSON is installed" >&2
    exit 1
fi
echo "    OK  vulkaninfo (vulkan-tools $VULKAN_TOOLS_VERSION)"
echo "    OK  ${#VULKAN_ICDS[@]} Vulkan ICD JSON file(s) installed"

echo
echo "[47] Vulkan runtime verification passed; diagnostic tools are staged."
echo "     Next-step (post-install): user runs 'ncz install mnemos' to fetch the bge-small-zh.cix model"
echo "     and start the NPU embedder server (P4 scope-2 / r75 task #98)."
