#!/bin/bash
# 16-mesa-gpu-2613.sh — deploy the NCZ Mesa 26.1.3 GPU compute stack (Cix Sky1).
#
# Why: the stock Sky1 Mesa 26.0.3 (pinned by 15-mesa-sky1-pin.sh) is fine for
# desktop GL, but its panvk could not run GPU compute (VK_ERROR_OUT_OF_DEVICE_MEMORY,
# 16-entry storage-buffer cap → broke Dawn/WebGPU + LiteRT-LM GPU) and the base
# image shipped NO GPU OpenCL (mesa-opencl-icd removed → CPU pocl only).
#
# This hook installs a from-source Mesa 26.1.3 under /opt and redirects ONLY the
# Vulkan + OpenCL loaders to it (panvk + rusticl). Desktop GL stays on the stock
# Sky1 Mesa. Built from source on the .66 reference board; A/B-validated
# +20.6% prefill / +12.9% decode (llama.cpp Vulkan) and rusticl FP16 ~3.6 TFLOPS.
#
# Asset: assets/gpu/mesa-26.1.3-ncz-arm64.tar.gz → staged by build-iso to
# /cdrom/cixmini/assets/gpu/, copied by late.sh to
# /usr/local/lib/cix-installer/assets/gpu/. Tarball extracts to /opt/mesa-26.1.3.
set -uo pipefail

SRC=/usr/local/lib/cix-installer/assets/gpu/mesa-26.1.3-ncz-arm64.tar.gz
PREFIX=/opt/mesa-26.1.3
LIBDIR="$PREFIX/lib/aarch64-linux-gnu"
VK_ICD="$PREFIX/share/vulkan/icd.d/panfrost_icd.aarch64.json"
RUSTICL_LIB="$LIBDIR/libRusticlOpenCL.so.1"

if [ ! -f "$SRC" ]; then
    echo "[16] WARN: $SRC missing — skipping Mesa 26.1.3 GPU stack (GPU Vulkan compute + GPU OpenCL will be unavailable)"
    exit 0
fi

echo "[16] installing NCZ Mesa 26.1.3 GPU compute stack → $PREFIX"
mkdir -p /opt
tar xzf "$SRC" -C /opt
if [ ! -f "$VK_ICD" ] || [ ! -f "$RUSTICL_LIB" ]; then
    echo "[16] WARN: extracted tree incomplete (missing ICD or rusticl lib) — leaving stock GPU stack in place"
    exit 0
fi

# --- Vulkan: route panvk to 26.1.3, disable the stock panfrost ICD ---------
mkdir -p /usr/share/vulkan/icd.d
install -m644 "$VK_ICD" /usr/share/vulkan/icd.d/panfrost_2613_icd.aarch64.json
for stock in /usr/share/vulkan/icd.d/panfrost_icd.json \
             /usr/share/vulkan/icd.d/panfrost_icd.aarch64.json; do
    if [ -f "$stock" ] && [ ! -e "$stock.2603-disabled" ]; then
        mv "$stock" "$stock.2603-disabled"
        echo "    disabled stock Vulkan ICD: $(basename "$stock")"
    fi
done
echo "    Vulkan ICD: panfrost_2613_icd.aarch64.json (panvk 26.1.3)"

# --- OpenCL: install rusticl ICD (restores GPU OpenCL) ---------------------
mkdir -p /etc/OpenCL/vendors
echo "$RUSTICL_LIB" > /etc/OpenCL/vendors/rusticl.icd
echo "    OpenCL ICD: /etc/OpenCL/vendors/rusticl.icd → $RUSTICL_LIB"

# --- System-wide activation via /etc/environment ---------------------------
ENVF=/etc/environment
touch "$ENVF"
set_env() {  # key value — idempotent replace-or-append
    local k="$1" v="$2"
    if grep -q "^${k}=" "$ENVF" 2>/dev/null; then
        sed -i "s|^${k}=.*|${k}=${v}|" "$ENVF"
    else
        echo "${k}=${v}" >> "$ENVF"
    fi
}
set_env VK_DRIVER_FILES /usr/share/vulkan/icd.d/panfrost_2613_icd.aarch64.json
set_env RUSTICL_ENABLE  panfrost
echo "    /etc/environment: VK_DRIVER_FILES + RUSTICL_ENABLE=panfrost"

# --- Status doc ------------------------------------------------------------
mkdir -p /usr/share/doc/ncz
cat > /usr/share/doc/ncz/GPU-STATUS.md <<'DOC'
# NCZ GPU compute stack — Cix Sky1 (Mali-G720 MC10 / panthor)

This system ships a from-source **Mesa 26.1.3** under `/opt/mesa-26.1.3`,
redirected to be the system **Vulkan (panvk)** and **OpenCL (rusticl)**
provider. Desktop GL stays on the stock Sky1 Mesa.

- Vulkan: `VK_DRIVER_FILES=/usr/share/vulkan/icd.d/panfrost_2613_icd.aarch64.json`
- OpenCL: `/etc/OpenCL/vendors/rusticl.icd` + `RUSTICL_ENABLE=panfrost`

Verify:
```
vulkaninfo | grep -E 'deviceName|driverInfo'   # Mali-G720 / Mesa 26.1.3
clinfo     | grep -E 'Device Name|Driver Ver'  # Mali-G720 (Panfrost) / 26.1.3
```

Measured (vs stock 26.0.3): panvk +20.6% prefill / +12.9% decode (llama.cpp
Vulkan); rusticl clpeak FP16 ~3.6 TFLOPS, FP32 ~1.98 TFLOPS, INT ~313 GIOPS.

**Teflon is NOT enabled.** Mesa's TFLite delegate only targets
Ethos-U / VeriSilicon / Rockchip NPUs — it cannot drive the Mali GPU or the
Zhouyi NPU. Use the Zhouyi/libnoe path for NPU inference instead.
See `AI-ML-STACK.md` for engine routing.
DOC

echo "[16] Mesa 26.1.3 GPU compute stack installed (panvk + rusticl). Teflon shipped but not enabled (no Sky1 backend)."
exit 0
