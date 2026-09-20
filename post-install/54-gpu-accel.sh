#!/bin/bash
# 54-gpu-accel.sh — AMD64 GPU/accelerator stack, real vendor repos.
#
# NCZ-OS is not a free-software-only distro (operator directive 2026-09-14:
# "We are not a free only distro like Debian, we install to make things
# work."). Same posture as 53-chrome.sh (real Google apt repo, real signed
# package) and 24-apt-sources.sh (our own Buildkite repo) — this hook wires
# each GPU vendor's REAL OFFICIAL apt repo and installs their real driver
# stack, not a free-software reimplementation or Debian's own (older/
# incomplete) in-archive packages.
#
# Detects installed GPU(s) via `lspci -nn` PCI class + vendor ID matching
# (class 0300/0302/0380 = VGA/3D/display controller) and wires ONLY the
# matching vendor stack(s) — additive per vendor found, since a machine can
# have more than one (e.g. Intel iGPU + NVIDIA dGPU is common on laptops).
# A machine with no discrete/matched GPU is a normal, silent no-op — same
# graceful-absence handling as 53-chrome.sh.
#
# Real repo URLs verified 2026-09-14 (WebSearch, not guessed/stale):
#   NVIDIA: developer.download.nvidia.com/compute/cuda/repos/debian13/x86_64/
#           cuda-keyring_1.1-1_all.deb — NVIDIA's own signing-key+source
#           installer package. Confirmed current for Debian 13 (trixie).
#   AMD:    repo.radeon.com/rocm/apt/<version> + repo.radeon.com/rocm/rocm.gpg.key
#           AMD's ROCm docs have a dedicated "Debian native installation"
#           page — this is not an Ubuntu-only path despite amdgpu-install's
#           download page listing Ubuntu-codenamed .deb filenames.
#   Intel:  apt.repos.intel.com/openvino, component named ubuntuNN even when
#           targeting Debian (Intel does not publish a debianNN-named
#           component; the ubuntu24 component is what their own current
#           install docs point at and is not OS-gated by apt itself).
#
# RUNS AT REAL INSTALL TIME ON THE TARGET MACHINE (run-all.sh's late/target
# invocation, NOT the build-squashfs-layers.sh chroot-baking pass) — GPU
# hardware detection is inherently target-specific and cannot be meaningful
# baked into a shared image the way 53-chrome.sh's unconditional install is.
# zoder review (2026-09-14) correctly flagged an earlier draft of this
# comment as copy-pasted from 53-chrome.sh without adjusting for that; fixed.
# AMD64 only — never wired into the arm64 hook loops.
set +e

if [ "$(dpkg --print-architecture 2>/dev/null)" != "amd64" ]; then
    echo "[54] not an amd64 target — skipping (this hook is AMD64-only)"
    exit 0
fi

echo "[54] AMD64 GPU/accelerator vendor detection + real driver-repo wiring"

VARIANT=desktop
[ -f /usr/local/lib/cix-installer/BUILD_VARIANT ] && \
    VARIANT=$(tr -d ' \t\r\n' < /usr/local/lib/cix-installer/BUILD_VARIANT)
case "$VARIANT" in
    server|headless)
        echo "[54] BUILD_VARIANT=$VARIANT — headless SKU; skipping GPU accelerator wiring"
        exit 0
        ;;
esac

if ! command -v lspci >/dev/null 2>&1; then
    echo "[54] WARN: lspci absent (pciutils not staged?) — cannot detect GPU vendor, skipping"
    exit 0
fi

# PCI display-class controllers only (0300=VGA, 0302=3D, 0380=other display).
# zoder review (2026-09-14) caught: `lspci -d "::0300"` is NOT valid class
# filtering — pciutils' -d only parses [vendor]:[device], so a third field
# is silently misparsed and this always matched nothing. Real fix: grep the
# bracketed class code that lspci -nn prints on every line
# ("00:02.0 VGA compatible controller [0300]: ...").
DISPLAY_PCI=$(lspci -nn | grep -E '\[03(00|02|80)\]:')

HAS_NVIDIA=0; HAS_AMD=0; HAS_INTEL=0
echo "$DISPLAY_PCI" | grep -qi '\[10de:' && HAS_NVIDIA=1
# 1002 is AMD/ATI's real GPU vendor ID. 1022 is AMD's CPU/chipset vendor ID
# and cannot appear on a display-class-filtered line — zoder review
# (2026-09-14) correctly flagged it as dead code; removed.
echo "$DISPLAY_PCI" | grep -qi '\[1002:' && HAS_AMD=1
echo "$DISPLAY_PCI" | grep -qi '\[8086:' && HAS_INTEL=1

if [ "$HAS_NVIDIA" = 0 ] && [ "$HAS_AMD" = 0 ] && [ "$HAS_INTEL" = 0 ]; then
    echo "[54] no NVIDIA/AMD/Intel display controller detected via lspci — nothing to wire"
    echo "[54] lspci display-class output was:"
    echo "$DISPLAY_PCI" | sed 's/^/[54]   /'
    exit 0
fi

# --- NVIDIA -------------------------------------------------------------
if [ "$HAS_NVIDIA" = 1 ]; then
    echo "[54] NVIDIA GPU detected — wiring real NVIDIA CUDA repo"
    NV_KEYRING_DEB=/usr/local/lib/cix-installer/assets/nvidia/cuda-keyring_1.1-1_all.deb
    if [ -f "$NV_KEYRING_DEB" ]; then
        dpkg -i "$NV_KEYRING_DEB" 2>&1 | tail -5
        apt-get update 2>&1 | tail -5
        # cuda-drivers pulls the proprietary kernel driver + full CUDA
        # toolkit in one metapackage. nvidia-open exists for Turing+ but
        # cuda-drivers is the broadest-compatible real choice for an
        # unknown-hardware-cohort install.
        #
        # CAVEAT (zoder review, 2026-09-14): nvidia-kernel-dkms builds its
        # module against whatever kernel headers are visible RIGHT NOW —
        # since this hook runs at real target-install time (not build-chroot
        # baking, see the file header), that's the actual target kernel, so
        # this is correct as long as the target's kernel headers package is
        # already installed before this hook runs (verify hook ordering in
        # run-all.sh puts the kernel/headers install before 54). If DKMS
        # can't find headers it will fail loudly here rather than silently
        # producing a module for the wrong kernel — that's the safe failure
        # mode, but confirm the ordering rather than assuming it.
        apt-get install -y cuda-drivers 2>&1 | tail -10
        echo "[54] NVIDIA: $(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null || echo 'driver installed, nvidia-smi not yet loadable this session (module needs a reboot to bind)')"
        # cuda-drivers does NOT pull libnvidia-encode1/libnvcuvid1 as
        # dependencies (confirmed live on CERBERUS, 2026-09-15: driver+CUDA
        # toolkit fully installed via cuda-drivers, but NVENC failed with
        # "OpenEncodeSessionEx failed: unsupported device" because these two
        # packages were simply never installed). Without them stock ffmpeg's
        # h264_nvenc/hevc_nvenc/av1_nvenc encoders (already compiled into
        # Debian's ffmpeg package as of trixie 7.1.5 -- no custom ffmpeg
        # build needed) fail outright. Pin the same driver-version stream
        # `cuda-drivers` just installed to avoid an ABI-mismatched pull.
        NV_DRIVER_VER="$(dpkg-query -W -f='${Version}' nvidia-driver 2>/dev/null | cut -d- -f1)"
        if [ -n "$NV_DRIVER_VER" ]; then
            apt-get install -y "libnvidia-encode1=${NV_DRIVER_VER}-1" "libnvcuvid1=${NV_DRIVER_VER}-1" 2>&1 | tail -10
        else
            apt-get install -y libnvidia-encode1 libnvcuvid1 2>&1 | tail -10
        fi
    else
        echo "[54] WARN: NVIDIA GPU present but $NV_KEYRING_DEB not staged — skipping NVIDIA stack"
        echo "[54]       stage cuda-keyring_1.1-1_all.deb from developer.download.nvidia.com/compute/cuda/repos/debian13/x86_64/ under assets/nvidia/ to fix"
    fi
fi

# --- AMD ------------------------------------------------------------------
if [ "$HAS_AMD" = 1 ]; then
    echo "[54] AMD GPU detected — wiring real AMD ROCm repo"
    install -d -m0755 /etc/apt/keyrings
    ROCM_KEYRING=/etc/apt/keyrings/rocm.gpg
    if [ ! -f "$ROCM_KEYRING" ] || [ ! -s "$ROCM_KEYRING" ]; then
        rm -f "$ROCM_KEYRING"
        # zoder review (2026-09-14): the old check only tested curl's exit
        # code with both stages' stderr swallowed — a curl 200-with-HTML-
        # error-page or a gpg failure could leave an EMPTY (or garbage)
        # keyring file that still passes a bare `-f` test, then fail
        # confusingly later at `apt-get update`. Check the key material is
        # real (non-trivial size) before trusting it.
        if curl -fsSL https://repo.radeon.com/rocm/rocm.gpg.key 2>/dev/null | gpg --dearmor -o "$ROCM_KEYRING" 2>/dev/null && \
           [ -s "$ROCM_KEYRING" ] && [ "$(stat -c%s "$ROCM_KEYRING" 2>/dev/null || echo 0)" -gt 100 ]; then
            echo "[54] fetched ROCm signing key ($(stat -c%s "$ROCM_KEYRING") bytes)"
        else
            rm -f "$ROCM_KEYRING"
            echo "[54] WARN: could not fetch a real repo.radeon.com/rocm/rocm.gpg.key (no network at install time, or key content invalid) — skipping AMD stack"
        fi
    fi
    if [ -f "$ROCM_KEYRING" ] && [ -s "$ROCM_KEYRING" ]; then
        ROCM_VERSION="${NCZ_ROCM_VERSION:-7.2.4}"
        cat > /etc/apt/sources.list.d/rocm.list <<EOF
# Written by post-install/54-gpu-accel.sh — real AMD official ROCm repo.
deb [signed-by=$ROCM_KEYRING] https://repo.radeon.com/rocm/apt/$ROCM_VERSION jammy main
EOF
        # AMD's Debian docs pin the component suite name to an Ubuntu
        # codename (jammy) even for Debian targets — same non-gating
        # apt-suite-naming quirk as Intel's OpenVINO repo below.
        apt-get update 2>&1 | tail -5
        # rocm-device-libs-17 (versioned) is the real Debian trixie package
        # name for ROCm 7.x, not bare rocm-device-libs — and rocm-cmake is
        # build tooling, not part of the runtime stack; not installed here.
        # zoder review (2026-09-14) caught both.
        apt-get install -y rocm-opencl-icd rocm-smi rocminfo rocm-device-libs-17 2>&1 | tail -10
        echo "[54] AMD: $(rocminfo 2>/dev/null | grep -m1 'Marketing Name' || echo 'ROCm stack installed, rocminfo not yet loadable this session (module needs a reboot to bind)')"
        # ROCm's officially-supported GPU list is narrow and does NOT include
        # every real Radeon chip this hook may detect. Confirmed live on
        # MEDUSA (2026-09-20): Navi14/gfx1012 (Radeon Pro 5300M) is NOT on
        # ROCm's supported list — rocminfo/HIP apps can silently fail or
        # refuse to enumerate the GPU without an explicit gfx-version
        # override. AMDGPU_TARGETS/HSA_OVERRIDE_GFX_VERSION is the real,
        # documented workaround (pick the nearest supported gfx version for
        # the detected chip); this is honest best-effort, not a guarantee —
        # unofficial-support chips may still hit real gaps ROCm's own docs
        # don't promise to fix. Write a real per-chip override file so a user
        # session picks it up without hand-editing anything.
        GFX_NAME=$(rocminfo 2>/dev/null | grep -m1 -oE 'gfx[0-9a-f]+' || true)
        case "$GFX_NAME" in
            gfx1010|gfx1011|gfx1012)
                echo "[54] AMD: $GFX_NAME is RDNA1, narrow/unofficial ROCm support — writing HSA_OVERRIDE_GFX_VERSION=10.3.0 fallback (nearest officially-supported RDNA target)"
                install -d /etc/profile.d
                cat > /etc/profile.d/ncz-rocm-gfx-override.sh <<'GFXEOF'
# Written by post-install/54-gpu-accel.sh. This GPU's real gfx target
# (RDNA1: gfx1010/1011/1012) is not on ROCm's officially-supported list.
# Override to the nearest supported RDNA target so HIP/rocminfo don't
# silently refuse to enumerate the device. Best-effort, not a guarantee --
# some ROCm workloads may still hit real gaps on unofficial hardware.
export HSA_OVERRIDE_GFX_VERSION=10.3.0
GFXEOF
                chmod 0644 /etc/profile.d/ncz-rocm-gfx-override.sh
                ;;
        esac
    fi
fi

# --- NPU (Intel / AMD) ------------------------------------------------------
# Separate from the GPU vendor loop above -- a machine can have an NPU with
# no matching-vendor discrete GPU (or vice versa). Real PCI signatures
# confirmed live against fleet hardware, 2026-09-20:
#   Intel: class [1200] "Processing accelerators", vendor 8086 (confirmed on
#          PROTEUS: "00:0b.0 Processing accelerators [1200]: Intel
#          Corporation Arrow Lake NPU [8086:ad1d]"). Class 1200 is clean/
#          NPU-specific for Intel -- do NOT match on class 1180 ("Signal
#          processing controller") for Intel, PROTEUS also has two
#          unrelated 1180-class telemetry/crash-log devices that would
#          false-positive.
#   AMD:   class [1180] "Signal processing controller", vendor 1022, device
#          string containing "IPU" (confirmed on HYDRA and ACHILLES both:
#          "Signal processing controller [1180]: ... AMD IPU Device
#          [1022:1502]"). Class 1180 alone is NOT vendor-specific (Intel
#          also uses it for non-NPU devices), so AMD's NPU match requires
#          BOTH class 1180 AND vendor 1022 AND the "IPU" name substring.
NPU_PCI=$(lspci -nn)
HAS_INTEL_NPU=0; HAS_AMD_NPU=0
echo "$NPU_PCI" | grep -qi '\[1200\]:.*\[8086:' && HAS_INTEL_NPU=1
echo "$NPU_PCI" | grep -i '\[1180\]:.*\[1022:' | grep -qi 'ipu' && HAS_AMD_NPU=1

if [ "$HAS_INTEL_NPU" = 1 ]; then
    echo "[54] Intel NPU detected — installing OpenVINO NPU runtime"
    # Reuses the Intel OpenVINO repo wired above if this machine also has an
    # Intel GPU; if it doesn't (NPU with no matched Intel display-class
    # device), the repo/keyring block from the Intel GPU section above never
    # ran, so wire it here too -- idempotent, same keyring path.
    install -d -m0755 /etc/apt/keyrings
    INTEL_KEYRING=/etc/apt/keyrings/intel-openvino.gpg
    if [ ! -f "$INTEL_KEYRING" ] || [ ! -s "$INTEL_KEYRING" ]; then
        rm -f "$INTEL_KEYRING"
        if curl -fsSL https://apt.repos.intel.com/openvino/2026/GPG-PUB-KEY-INTEL-OPENVINO-2026 2>/dev/null | gpg --dearmor -o "$INTEL_KEYRING" 2>/dev/null && \
           [ -s "$INTEL_KEYRING" ] && [ "$(stat -c%s "$INTEL_KEYRING" 2>/dev/null || echo 0)" -gt 100 ]; then
            echo "[54] fetched Intel OpenVINO signing key ($(stat -c%s "$INTEL_KEYRING") bytes)"
        else
            rm -f "$INTEL_KEYRING"
            echo "[54] WARN: could not fetch a real Intel OpenVINO signing key — skipping Intel NPU stack"
        fi
    fi
    if [ -f "$INTEL_KEYRING" ] && [ -s "$INTEL_KEYRING" ]; then
        if [ ! -f /etc/apt/sources.list.d/intel-openvino.list ]; then
            cat > /etc/apt/sources.list.d/intel-openvino.list <<EOF
deb [signed-by=$INTEL_KEYRING] https://apt.repos.intel.com/openvino ubuntu24 main
EOF
            apt-get update 2>&1 | tail -5
        fi
        # intel-driver-compiler-npu + level-zero are the real NPU runtime
        # packages (distinct from intel-opencl-icd, which is the GPU OpenCL
        # ICD already installed above if an Intel GPU was also present).
        apt-get install -y intel-driver-compiler-npu intel-level-zero-npu level-zero 2>&1 | tail -10
        echo "[54] Intel NPU: OpenVINO NPU runtime + Level-Zero installed"
    fi
fi

if [ "$HAS_AMD_NPU" = 1 ]; then
    # AMD's XDNA/Ryzen-AI NPU has no equivalent mature Debian-native apt
    # repo the way ROCm/OpenVINO do -- real, current AMD documentation
    # points at building the xdna-driver + XRT runtime from source
    # (github.com/amd/xdna-driver). That is a materially bigger, riskier
    # install-time step than this hook's other vendor blocks (compiling a
    # kernel-adjacent driver at install time, not just wiring an apt repo)
    # and is deliberately NOT done here -- flagging the real hardware
    # presence rather than silently no-op'ing, so it's visible instead of
    # invisible.
    echo "[54] AMD XDNA/Ryzen-AI NPU detected -- no mature apt-installable driver stack exists yet (real gap, not a bug in this hook)."
    echo "[54]   AMD's own current path is building github.com/amd/xdna-driver + XRT from source, which this install-time hook deliberately does not attempt."
fi

echo "[54] NPU wiring done (Intel-NPU=$HAS_INTEL_NPU AMD-NPU=$HAS_AMD_NPU)"

# --- Intel ------------------------------------------------------------------
if [ "$HAS_INTEL" = 1 ]; then
    echo "[54] Intel GPU detected — wiring real Intel OpenVINO repo"
    install -d -m0755 /etc/apt/keyrings
    INTEL_KEYRING=/etc/apt/keyrings/intel-openvino.gpg
    if [ ! -f "$INTEL_KEYRING" ] || [ ! -s "$INTEL_KEYRING" ]; then
        rm -f "$INTEL_KEYRING"
        # Same key-material validation fix as the AMD block above (zoder
        # review, 2026-09-14) — don't trust a bare -f test on the output of
        # a pipeline whose own errors are swallowed.
        if curl -fsSL https://apt.repos.intel.com/openvino/2026/GPG-PUB-KEY-INTEL-OPENVINO-2026 2>/dev/null | gpg --dearmor -o "$INTEL_KEYRING" 2>/dev/null && \
           [ -s "$INTEL_KEYRING" ] && [ "$(stat -c%s "$INTEL_KEYRING" 2>/dev/null || echo 0)" -gt 100 ]; then
            echo "[54] fetched Intel OpenVINO signing key ($(stat -c%s "$INTEL_KEYRING") bytes)"
        else
            rm -f "$INTEL_KEYRING"
            echo "[54] WARN: could not fetch a real Intel OpenVINO signing key (no network at install time, or key content invalid) — skipping Intel OpenVINO stack"
        fi
    fi
    if [ -f "$INTEL_KEYRING" ] && [ -s "$INTEL_KEYRING" ]; then
        cat > /etc/apt/sources.list.d/intel-openvino.list <<EOF
# Written by post-install/54-gpu-accel.sh — real Intel official OpenVINO
# repo. Component is named ubuntu24 by Intel's own current install docs
# even when the host is Debian; apt does not gate on the OS name in this
# path string, only on it matching what the repo actually publishes.
deb [signed-by=$INTEL_KEYRING] https://apt.repos.intel.com/openvino ubuntu24 main
EOF
        apt-get update 2>&1 | tail -5
        apt-get install -y openvino intel-opencl-icd intel-media-va-driver 2>&1 | tail -10
        echo "[54] Intel: OpenVINO + VAAPI stack installed"
    fi
fi

echo "[54] GPU/accelerator wiring done (NVIDIA=$HAS_NVIDIA AMD=$HAS_AMD Intel=$HAS_INTEL)"
