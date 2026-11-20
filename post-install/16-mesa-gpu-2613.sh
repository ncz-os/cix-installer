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
# Sky1 Mesa. Built from source on the MS-R1 reference board; A/B-validated
# +20.6% prefill / +12.9% decode (llama.cpp Vulkan) and rusticl FP16 ~3.6 TFLOPS.
#
# Asset: assets/gpu/mesa-26.1.3-ncz-arm64.tar.gz → staged by the image build to
# /cdrom/ncz-payload/assets/gpu/, copied by late.sh to
# /usr/local/lib/cix-installer/assets/gpu/. Tarball extracts to /opt/mesa-26.1.3.
# NCZ-PLATFORM-GUARD: sky1-arm64 only (docs/PLATFORM-SPLIT-DESIGN.md). Arch order matches
# run-all.sh: NCZ_TARGET_ARCH, then the late.sh BUILD_ARCH stamp, then dpkg. An
# undetectable arch does NOT skip (legacy behavior).
_ncz_pg_arch="${NCZ_TARGET_ARCH:-}"
[ -n "$_ncz_pg_arch" ] || _ncz_pg_arch=$(cat /usr/local/lib/cix-installer/BUILD_ARCH 2>/dev/null | tr -d '[:space:]')
[ -n "$_ncz_pg_arch" ] || _ncz_pg_arch=$(dpkg --print-architecture 2>/dev/null || true)
case "$_ncz_pg_arch" in
    arm64|aarch64|"") ;;
    *) echo "[${0##*/}] platform guard: arch=$_ncz_pg_arch is not sky1-arm64; skipping"; exit 0 ;;
esac
unset _ncz_pg_arch
set -uo pipefail

TARGET_ARCH="$(dpkg --print-architecture 2>/dev/null || true)"
ENVF=/etc/environment
if [ "$TARGET_ARCH" != "arm64" ]; then
    echo "[16] architecture=${TARGET_ARCH:-unknown}: NCZ Mesa 26.1.3 is an arm64/Sky1 payload; leaving the detected GPU's distribution driver settings unchanged"
    if [ -f "$ENVF" ]; then
        sed -i '/^RUSTICL_ENABLE=panfrost$/d;\|^VK_DRIVER_FILES=.*/panfrost_2613_icd\.aarch64\.json$|d' "$ENVF"
        echo "[16] removed any stale Sky1 panfrost environment overrides"
    fi
    exit 0
fi
echo "[16] architecture=$TARGET_ARCH: applying the Sky1 panfrost Vulkan/OpenCL configuration"

SRC=/usr/local/lib/cix-installer/assets/gpu/mesa-26.1.3-ncz-arm64.tar.gz
PREFIX=/opt/mesa-26.1.3
LIBDIR="$PREFIX/lib/aarch64-linux-gnu"
VK_ICD="$PREFIX/share/vulkan/icd.d/panfrost_icd.aarch64.json"
RUSTICL_LIB="$LIBDIR/libRusticlOpenCL.so.1"

touch "$ENVF"
set_env() {  # key value — idempotent replace-or-append
    local k="$1" v="$2"
    if grep -q "^${k}=" "$ENVF" 2>/dev/null; then
        sed -i "s|^${k}=.*|${k}=${v}|" "$ENVF"
    else
        echo "${k}=${v}" >> "$ENVF"
    fi
}

if [ ! -f "$SRC" ]; then
    echo "[16] $SRC missing — using distribution Mesa Vulkan"
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        mesa-vulkan-drivers 2>&1 | tail -6 || \
        echo "[16] WARN: distribution Mesa Vulkan packages unavailable"
    # Mali-only image (order 01:35Z 2026-11-15): GPU OpenCL is the vendor
    # platform (cix-gpu-umd via ocl-icd-libopencl1), not rusticl/panfrost.
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

# --- OpenCL: vendor platform only (order 01:35Z 2026-11-15) ----------------
# rusticl/panfrost was the Panthor OpenCL path; Panthor is not shipped, so no
# rusticl ICD is registered. GPU OpenCL = the vendor platform (cix-gpu-umd's
# ARM Platform via ocl-icd-libopencl1) — the platform clinfo must show.

# --- System-wide activation via /etc/environment ---------------------------
# Mali-only image: pin the blob ICD. The panfrost/panvk ICD has no kernel
# driver (panthor is not shipped) and a system-wide VK_DRIVER_FILES pointed at
# it left vulkaninfo with zero devices on non-session logins (server acceptance:
# "vulkaninfo first device is Mali-G720").
set_env VK_DRIVER_FILES /etc/vulkan/icd.d/mali.json
echo "    /etc/environment: VK_DRIVER_FILES=/etc/vulkan/icd.d/mali.json"

# --- Status doc ------------------------------------------------------------
mkdir -p /usr/share/doc/ncz
cat > /usr/share/doc/ncz/GPU-STATUS.md <<'DOC'
# NCZ GPU compute stack — Cix Sky1 (Mali-G720 MC10)

One GPU driver: the vendor **Mali** stack (mali_kbase + cix-gpu-umd).
Panthor is not shipped (order 01:35Z 2026-11-15).

- Vulkan: `VK_DRIVER_FILES=/etc/vulkan/icd.d/mali.json` (the CIX blob ICD;
  the real device). The bundled Mesa 26.1.3 under `/opt/mesa-26.1.3` still
  installs its panvk ICD file, but it has NO kernel driver on a Mali-only
  image and is not pinned — do not point VK_DRIVER_FILES at it.
- OpenCL: the vendor platform — `clinfo -l` must read
  `Platform #0: ARM Platform / Device #0: Mali-G720-Immortalis`
  (cix-gpu-umd's ICD via ocl-icd-libopencl1). No rusticl ICD is registered;
  mesa-opencl-icd was the Panthor/panfrost OpenCL path and is gone with it.

Verify:
```
vulkaninfo --summary | grep -E 'deviceName|driverName'  # Mali-G720 first
clinfo -l                                              # ARM Platform first
```

Historical (Panthor era, vs stock 26.0.3): panvk +20.6% prefill / +12.9%
decode (llama.cpp Vulkan); rusticl clpeak FP16 ~3.6 TFLOPS, FP32 ~1.98
TFLOPS, INT ~313 GIOPS. Kept for reference only.

**Teflon is NOT enabled.** Mesa's TFLite delegate only targets
Ethos-U / VeriSilicon / Rockchip NPUs — it cannot drive the Mali GPU or the
Zhouyi NPU. Use the Zhouyi/libnoe path for NPU inference instead.
See `AI-ML-STACK.md` for engine routing.
DOC

echo "[16] GPU stack set for vendor Mali (VK_DRIVER_FILES=mali.json). Teflon shipped but not enabled (no Sky1 backend)."
exit 0
