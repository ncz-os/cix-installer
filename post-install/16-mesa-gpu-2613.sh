#!/bin/bash
# 16-mesa-gpu-2613.sh — ship the NCZ Mesa 26.1.3 GPU compute stack for Cix Sky1.
#
# WHY: Resolute stock Mesa is 26.0.3. On Mali-G720 (panvk/panfrost) the 26.0.3
# panvk could not run GPU compute end-to-end — Dawn/WebGPU (LiteRT-LM) hard-failed
# with VK_ERROR_OUT_OF_DEVICE_MEMORY (maxMemoryAllocationCount) and a
# descriptor-storage-buffer limit of 16. Additionally, the base image ships NO
# working GPU OpenCL at all (mesa-opencl-icd is removed → only CPU pocl).
#
# Mesa 26.1.3 (built from source for arm64) fixes both:
#   - panvk:  maxMemoryAllocationCount 4.29B, maxStorageBufferRange 4 GiB,
#             apiVersion 1.4.348 → LiteRT-LM GPU now runs (0 errors).
#             llama.cpp Vulkan: +20.6% prefill / +12.9% decode vs 26.0.3.
#   - rusticl: working GPU OpenCL 3.0 on Mali-G720 (FP16 ~3.6 TFLOPS,
#             FP32 ~1.98 TFLOPS, INT ~313 GIOPS) — restores GPU OpenCL the
#             base image lacks.
#
# STRATEGY (safe ICD-redirect): the 26.1.3 stack lives in /opt, and we point
# ONLY the Vulkan + OpenCL loaders at it via ICD files + /etc/environment.
# The desktop GL/EGL stack is left on the validated system Mesa (see
# 15-mesa-sky1-pin.sh) so the compositor is never destabilized.
#
# NOT SHIPPED: Teflon (libteflon.so is in the tarball but inert). Teflon only
# targets Ethos-U / VeriSilicon / Rockchip NPUs — it cannot use the Mali GPU
# or the Zhouyi NPU, and on this SoC it fails with "Couldn't open kernel device".
# The real NPU path is the Zhouyi/cix-noe-umd stack (see 80-npu.sh).
#
# Idempotent — safe to re-run.
# RUNS INSIDE CHROOT (via run-all.sh). All paths are relative to system root.

set +e

PREFIX=/opt/mesa-26.1.3
LIBDIR="$PREFIX/lib/aarch64-linux-gnu"
VK_ICD_SRC="$PREFIX/share/vulkan/icd.d/panfrost_icd.aarch64.json"
VK_ICD_DST=/usr/share/vulkan/icd.d/panfrost_2613_icd.aarch64.json
RUSTICL_LIB="$LIBDIR/libRusticlOpenCL.so.1"

ASSETS=/usr/local/lib/cix-installer/assets/gpu
if [ ! -d "$ASSETS" ] && [ -d /cdrom/cixmini/assets/gpu ]; then
    ASSETS=/cdrom/cixmini/assets/gpu
fi
TARBALL="$ASSETS/mesa-26.1.3-ncz-arm64.tar.gz"

echo "[16] installing NCZ Mesa 26.1.3 GPU compute stack (panvk + rusticl)"

# --- Step 1: lay down the /opt prefix ---
if [ -f "$RUSTICL_LIB" ] && [ -f "$VK_ICD_SRC" ]; then
    echo "[16] $PREFIX already present, skipping extract"
elif [ -f "$TARBALL" ]; then
    install -d -m 0755 /opt
    tar -xzf "$TARBALL" -C /opt && echo "[16] extracted $TARBALL → /opt"
else
    echo "[16] WARN: $TARBALL missing and $PREFIX absent — GPU stack NOT installed"
    exit 0
fi

# --- Step 2: Vulkan ICD redirect → panvk 26.1.3 ---
if [ -f "$VK_ICD_SRC" ]; then
    install -D -m 0644 "$VK_ICD_SRC" "$VK_ICD_DST"
    # Disable the stock 26.0.3 panfrost ICD so only 26.1.3 is enumerated.
    if [ -f /usr/share/vulkan/icd.d/panfrost_icd.json ]; then
        mv -f /usr/share/vulkan/icd.d/panfrost_icd.json \
              /usr/share/vulkan/icd.d/panfrost_icd.json.2603-disabled
    fi
    echo "[16] Vulkan panvk 26.1.3 ICD installed (system 26.0.3 panfrost ICD disabled)"
else
    echo "[16] WARN: $VK_ICD_SRC missing; Vulkan redirect skipped"
fi

# --- Step 3: OpenCL ICD → rusticl 26.1.3 (absolute path) ---
if [ -f "$RUSTICL_LIB" ]; then
    install -d -m 0755 /etc/OpenCL/vendors
    echo "$RUSTICL_LIB" > /etc/OpenCL/vendors/rusticl.icd
    echo "[16] rusticl 26.1.3 OpenCL ICD installed"
else
    echo "[16] WARN: $RUSTICL_LIB missing; OpenCL redirect skipped"
fi

# --- Step 4: make both loaders default to 26.1.3 system-wide ---
# VK_DRIVER_FILES forces the loader to use ONLY our panvk (the shared
# icd.d carries ~11 other-vendor ICDs whose device-chain probes can abort
# vulkaninfo). RUSTICL_ENABLE=panfrost exposes the Mali device to rusticl.
touch /etc/environment
grep -q '^VK_DRIVER_FILES=' /etc/environment \
    || echo "VK_DRIVER_FILES=$VK_ICD_DST" >> /etc/environment
grep -q '^RUSTICL_ENABLE=' /etc/environment \
    || echo "RUSTICL_ENABLE=panfrost" >> /etc/environment
echo "[16] /etc/environment: VK_DRIVER_FILES + RUSTICL_ENABLE set"

# --- Step 5: status doc ---
mkdir -p /usr/share/doc/ncz
cat > /usr/share/doc/ncz/GPU-STATUS.md << 'EOF'
# NCZ — Cix Sky1 / Mali-G720 GPU compute stack (Mesa 26.1.3)

## What ships
- **panvk (Vulkan)** Mesa 26.1.3 — Vulkan 1.4.348 on Mali-G720 MC10.
- **rusticl (OpenCL 3.0)** Mesa 26.1.3 — GPU OpenCL on Mali-G720 MC10.
- Installed under `/opt/mesa-26.1.3`; desktop GL/EGL stays on the validated
  system Mesa (see the 15-mesa-sky1-pin pin). Only the Vulkan + OpenCL
  loaders are redirected, via ICD files + `/etc/environment`.

## Why a newer Mesa than stock (26.0.3)
- Stock panvk 26.0.3 could not run GPU compute end-to-end:
  `VK_ERROR_OUT_OF_DEVICE_MEMORY` + a 16-entry storage-buffer limit broke
  Dawn/WebGPU (LiteRT-LM) and large Vulkan dispatches.
- The base image also ships **no** working GPU OpenCL (`mesa-opencl-icd`
  removed → only CPU pocl). 26.1.3 rusticl restores it.

## Measured on the .66 reference (kernel 7.0.12-cix-sky1-main)
- panvk limits: maxMemoryAllocationCount 4.29B, maxStorageBufferRange 4 GiB.
- llama.cpp Vulkan vs stock 26.0.3: **+20.6% prefill, +12.9% decode**.
- rusticl clpeak: FP16 ~3.6 TFLOPS, FP32 ~1.98 TFLOPS, INT ~313 GIOPS, 44.8 GB/s.
- LiteRT-LM GPU (Dawn→Vulkan): broken on 26.0.3 → **works, 0 errors** on 26.1.3.

## Use it
```bash
vulkaninfo | grep -E 'deviceName|driverInfo'     # → Mali-G720 MC10 / Mesa 26.1.3
clinfo     | grep -E 'Device Name|Driver Version' # → Mali-G720 (Panfrost) / 26.1.3
```

## Honest caveats
- GPU decode (batch=1) is bandwidth-bound and still **slower than CPU** for
  tiny LLMs; the GPU win is **prefill** and larger/parallel compute.
- Very large Vulkan prefill batches (e.g. llama.cpp pp512) can still crash
  panvk — a remaining driver limit.
- **Teflon is intentionally not enabled** — no backend exists for Mali or
  the Zhouyi NPU on this SoC. Use the Zhouyi/cix-noe-umd path for NPU.

## Rebuild recipe (arm64, native on Sky1)
```bash
curl -LO https://archive.mesa3d.org/mesa-26.1.3.tar.xz && tar xf mesa-26.1.3.tar.xz
cd mesa-26.1.3
# deps: meson ninja-build pkg-config bison flex python3-mako python3-ply
#       libdrm-dev libexpat1-dev libwayland-dev wayland-protocols libx11*-dev
#       llvm-dev clang libclang-dev libclang-cpp-dev libclc-20 spirv-tools
#       libllvmspirvlib-21-dev  rustc cargo bindgen
meson setup build --prefix=/opt/mesa-26.1.3 -Dbuildtype=release \
  -Dvulkan-drivers=panfrost -Dgallium-drivers=panfrost \
  -Dgallium-rusticl=true -Dteflon=true -Dllvm=enabled \
  -Dplatforms=x11,wayland -Dglx=dri -Degl=enabled -Dgbm=enabled
ninja -C build && sudo ninja -C build install
```
EOF
chmod 0644 /usr/share/doc/ncz/GPU-STATUS.md

echo "[16] Mesa 26.1.3 GPU stack installed: panvk + rusticl (Teflon not enabled)"
echo "[16] verify: vulkaninfo | grep driverInfo  ;  clinfo | grep 'Driver Version'"
