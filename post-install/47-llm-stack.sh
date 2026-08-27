#!/bin/bash
# 47-llm-stack.sh — GPU/compute RUNTIME + diagnostics for the LLM and NPU
# tiers, so the appliance ships "plug-in-and-it-works" without manual apt.
#
# Scope narrowed 2026-08-05 to runtime only: vulkan-tools (vulkaninfo), clinfo,
# glmark2. The Vulkan dev headers, glslang/glslc and spirv-tools that used to
# be here were build substrate for workloads that no longer exist on-device —
# llama.cpp ships CPU-only and the NPU embedder runs on NOE/libnoe. This hook
# also removes mesa-vulkan-drivers, whose ICDs are all for other vendors' GPUs.
# Together ~242MB. See docs/DRIVER_FIDELITY_72.md. Idempotent.
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

# mesa-vulkan-drivers is 147MB of Vulkan ICDs for hardware this SoC is not:
# asahi (Apple), broadcom, freedreno (Adreno), gfxstream, intel, nouveau,
# powervr, radeon, virtio, plus lavapipe (software) and panfrost. panfrost is
# the Mesa Mali driver and cannot work here — mali_kbase exposes no DRM render
# node, which is exactly why panthor was abandoned. Our real ICD is the blob's
# /etc/vulkan/icd.d/mali.json.
#
# Removing them is not only size: with 11 ICDs enumerated the Vulkan loader can
# select the wrong one, which is why ncz-gpu-env has to pin VK_DRIVER_FILES.
# Fewer ICDs, less ambiguity.
# The dev packages are BAKED INTO desktop.squashfs by an older layer build, so
# dropping them from the install list above is not enough — they arrive with
# the layer and have to be purged here. (mesa-vulkan-drivers is not in the
# layer; it only ever came in as a dependency.) Verified on O6N: removing all
# of these leaves the desktop, GLES and the blob Vulkan ICD working.
NCZ_GPU_PURGE=""
for p in mesa-vulkan-drivers libvulkan-dev vulkan-validationlayers \
         spirv-tools spirv-headers glslang-tools glslang-dev; do
    dpkg -l "$p" 2>/dev/null | grep -q "^ii" && NCZ_GPU_PURGE="$NCZ_GPU_PURGE $p"
done
if [ -n "$NCZ_GPU_PURGE" ]; then
    echo "[47] purging GPU build stack (~242MB, unusable on this SoC):$NCZ_GPU_PURGE"
    # shellcheck disable=SC2086
    DEBIAN_FRONTEND=noninteractive apt-get remove -y $NCZ_GPU_PURGE 2>&1 | tail -3 || \
        echo "[47] WARN: purge incomplete — continuing (non-fatal)"
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y 2>&1 | tail -2 || true
else
    echo "[47] GPU build stack already absent"
fi

# No glslc / shader compiler: see the note above. Build GPU code on a build
# host, not on the appliance.

echo
echo "[47] verification:"
for tool in vulkaninfo clinfo glmark2; do
    if command -v "$tool" >/dev/null 2>&1; then
        echo "    OK  $tool ($($tool --version 2>&1 | head -1 | sed 's/^/    /'))"
    else
        echo "    --  $tool (not installed)"
    fi
done

# Smoke: can the Vulkan loader enumerate any device? Inside chroot the
# answer is almost certainly "no" (no /dev/dri yet), but vulkaninfo at
# least loading without segfaulting is a good signal that the libs
# linked clean. Don't fail the hook on absence.
if command -v vulkaninfo >/dev/null 2>&1; then
    if vulkaninfo --summary 2>&1 | grep -q "GPU id"; then
        echo "[47] vulkaninfo enumerated a Vulkan device (unexpected in chroot — but fine)"
    else
        echo "[47] vulkaninfo present (no devices in chroot — expected; first boot will see Mali-G720)"
    fi
fi

echo
echo "[47] Vulkan + SPIR-V baked. r75 ships ready for llama.cpp Vulkan + NPU embedder workloads."
echo "     Next-step (post-install): user runs 'ncz install mnemos' to fetch the bge-small-zh.cix model"
echo "     and start the NPU embedder server (P4 scope-2 / r75 task #98)."
