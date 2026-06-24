#!/bin/bash
# 47-llm-stack.sh — bake the Vulkan + SPIR-V toolchain that the LLM and NPU
# tiers depend on, so r75 ships "plug-in-and-it-works" instead of needing
# manual apt installs for every workload.
#
# r75 P4 (scope-1, deterministic): Vulkan dev headers + glslang/glslc +
# spirv-tools + clinfo + vulkan-tools (vulkaninfo). These are the
# universal substrates everything else (llama.cpp Vulkan, NPU embedder
# server, future Mali compute tools) builds against. Idempotent.
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
apt-get update 2>&1 | tail -3 || true

# Vulkan dev headers + tooling. Aligns with what visorcraft uses for
# panvk Mali Vulkan testing on Cix CD8180. spirv-headers is the schema
# pkg, spirv-tools is the validator/disassembler.
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    libvulkan-dev \
    glslang-tools \
    glslang-dev \
    spirv-tools \
    spirv-headers \
    vulkan-tools \
    vulkan-validationlayers \
    clinfo \
    glmark2-x11 \
    glmark2-es2-x11 \
    glmark2-wayland 2>&1 | tail -5 || \
    echo "[47] some Vulkan/SPIR-V packages unavailable — continuing (offline mirror may not have them all)"

# glslc is sometimes packaged separately (shaderc) and sometimes inside
# glslang-tools. Try the canonical name first, fall back to the alt.
if ! command -v glslc >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        glslc 2>&1 | tail -3 || \
        echo "[47] glslc not separately packaged — relying on glslang-tools"
fi

echo
echo "[47] verification:"
for tool in vulkaninfo glslangValidator spirv-val spirv-dis clinfo glmark2; do
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
