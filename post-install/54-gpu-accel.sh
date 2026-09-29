#!/bin/bash
# 54-gpu-accel.sh - AMD64 GPU/accelerator stack.
#
# NCZ-OS is not a free-software-only distro (operator directive 2026-09-14:
# "We are not a free only distro like Debian, we install to make things
# work."). Same posture as 53-chrome.sh (real Google apt repo, real signed
# package) and 24-apt-sources.sh (our own Buildkite repo) — this hook wires
# each GPU vendor's appropriate package source. AMD uses Debian's native ROCm
# packages because AMD does not publish a Debian suite.
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
#   AMD:    Debian's configured repositories. Do not mix Ubuntu ROCm packages
#           into Debian; repo.radeon.com publishes jammy and noble suites but
#           no Debian suite.
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

# Shared PCI helpers (nvidia_turing_plus_present). Absence is handled by
# ncz_cuda_toolkit_install, which then logs a skip instead of guessing.
_HW_DETECT="$(dirname "$(readlink -f "$0")")/lib/hw-detect.sh"
# shellcheck disable=SC1090
[ -r "$_HW_DETECT" ] && . "$_HW_DETECT"

# --- CUDA 13.4 toolkit (NVIDIA route only) ----------------------------------
# CUDA 13.4 no longer bundles the driver (NVIDIA CUDA 13.4 installation guide:
# "the CUDA Toolkit and the NVIDIA driver are installed and versioned
# independently"), so the driver install (NVIDIA branch below) and this toolkit step are separate.
# Decision record, measured on PEGASUS (forky, kernel 7.2.8-t2, RTX 2060,
# driver 615.71.09) 2026-09-29:
#   - Set: cuda-compiler-13-4 (nvcc) + cuda-cudart-dev-13-4 + cuda-libraries-13-4
#     = 32 packages, 1.39 GB download / 2.74 GB installed, zero removals.
#     The full cuda-toolkit-13-4 (66 packages, +~2.0 GB download / +~4.2 GB
#     installed; Nsight Compute alone is 1.5 GB) is left to a live
#     `apt install`.
#   - Host compiler: CUDA 13.4 nvcc supports GCC 6-16; Debian forky's default
#     gcc 16.2.0 compiled and ran a kernel unmodified, so no -ccbin / alternate
#     gcc / -allow-unsupported-compiler is configured.
#   - Layout: /usr/local/cuda-13.4 plus the /usr/local/cuda alternatives link
#     and /etc/ld.so.conf.d/*cuda*.conf come from the packages themselves; this
#     step adds only PATH via /etc/profile.d and the apt pin, then runs ldconfig.
# Status is recorded in /var/lib/ncz/cuda-toolkit.status as one of
#   installed:<nvcc pkg version> | skipped:<reason> | failed:<reason>
# so the installed-target gate (build/verify-cuda-installed-target.sh) can tell
# a deliberate skip from a silent failure. A failure here is logged loudly but
# NEVER aborts the rest of post-install.
NCZ_CUDA_STATUS=/var/lib/ncz/cuda-toolkit.status
NCZ_CUDA_PKGS="cuda-compiler-13-4 cuda-cudart-dev-13-4 cuda-libraries-13-4"
ncz_cuda_status() {
    mkdir -p "$(dirname "$NCZ_CUDA_STATUS")" 2>/dev/null
    echo "$1" > "$NCZ_CUDA_STATUS" 2>/dev/null
    echo "[54] CUDA toolkit: $1"
}
ncz_cuda_toolkit_install() {
    if [ "${NCZ_SKIP_CUDA:-0}" = 1 ]; then
        ncz_cuda_status "skipped:operator-disabled"; return 0
    fi
    if ! type nvidia_turing_plus_present >/dev/null 2>&1; then
        ncz_cuda_status "skipped:hw-detect-lib-missing"; return 0
    fi
    if ! nvidia_turing_plus_present; then
        ncz_cuda_status "skipped:no-turing-plus-gpu"; return 0
    fi
    # Zero removals or nothing (operator rule: simulate before installing).
    local sim
    sim=$(apt-get install -s -y --no-install-recommends $NCZ_CUDA_PKGS 2>&1)
    if [ $? -ne 0 ]; then
        echo "[54] ERROR: CUDA toolkit set is not installable:"; echo "$sim" | tail -15 | sed 's/^/[54]   /'
        ncz_cuda_status "failed:not-installable"; return 0
    fi
    if echo "$sim" | grep -q '^Remv '; then
        echo "[54] ERROR: installing the CUDA toolkit would REMOVE packages -- refusing:"
        echo "$sim" | grep '^Remv ' | sed 's/^/[54]   /'
        ncz_cuda_status "failed:would-remove-packages"; return 0
    fi
    apt-get install -y --no-install-recommends $NCZ_CUDA_PKGS > /var/log/ncz-cuda-install.log 2>&1
    tail -15 /var/log/ncz-cuda-install.log | sed 's/^/[54]   /'
    ldconfig 2>/dev/null || true
    if [ ! -x /usr/local/cuda-13.4/bin/nvcc ] || ! dpkg -s cuda-nvcc-13-4 >/dev/null 2>&1; then
        echo "[54] ERROR: CUDA toolkit install did not produce /usr/local/cuda-13.4/bin/nvcc"
        ncz_cuda_status "failed:nvcc-missing"; return 0
    fi
    install -d -m0755 /etc/profile.d
    cat > /etc/profile.d/ncz-cuda.sh <<'PROFEOF'
# Written by post-install/54-gpu-accel.sh. CUDA 13.4 toolkit on PATH; the
# runtime libraries are found through /etc/ld.so.conf.d (no LD_LIBRARY_PATH).
if [ -d /usr/local/cuda/bin ]; then
    case ":$PATH:" in *:/usr/local/cuda/bin:*) ;; *) PATH="$PATH:/usr/local/cuda/bin" ;; esac
    export PATH
fi
PROFEOF
    chmod 0644 /etc/profile.d/ncz-cuda.sh
    ncz_cuda_status "installed:$(dpkg-query -W -f='${Version}' cuda-nvcc-13-4 2>/dev/null)"
    echo "[54] CUDA: $(/usr/local/cuda-13.4/bin/nvcc --version 2>/dev/null | tail -2 | tr '\n' ' ')"
}

echo "[54] AMD64 GPU/accelerator vendor detection + real driver-repo wiring"

VARIANT=desktop
[ -f /usr/local/lib/cix-installer/BUILD_VARIANT ] && \
    VARIANT=$(tr -d ' \t\r\n' < /usr/local/lib/cix-installer/BUILD_VARIANT)
case "$VARIANT" in
    server|headless)
        echo "[54] BUILD_VARIANT=$VARIANT — headless SKU; skipping GPU accelerator wiring"
        ncz_cuda_status "skipped:headless-variant"
        exit 0
        ;;
esac

if ! command -v lspci >/dev/null 2>&1; then
    echo "[54] WARN: lspci absent (pciutils not staged?) — cannot detect GPU vendor, skipping"
    ncz_cuda_status "skipped:lspci-absent"
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

if [ "$HAS_NVIDIA" = 0 ]; then
    ncz_cuda_status "skipped:no-nvidia-gpu"
fi

if [ "$HAS_NVIDIA" = 0 ] && [ "$HAS_AMD" = 0 ] && [ "$HAS_INTEL" = 0 ]; then
    echo "[54] no NVIDIA/AMD/Intel display controller detected via lspci — nothing to wire"
    echo "[54] lspci display-class output was:"
    echo "$DISPLAY_PCI" | sed 's/^/[54]   /'
    exit 0
fi

# --- NVIDIA -------------------------------------------------------------
if [ "$HAS_NVIDIA" = 1 ]; then
    echo "[54] NVIDIA GPU detected — determining driver generation before wiring a repo"
    # NVIDIA's proprietary driver is generation-tiered, not one package:
    # Debian ships nvidia-driver (current), nvidia-legacy-470xx-driver
    # (Kepler/some Maxwell), nvidia-legacy-390xx-driver (Fermi) -- and has
    # NO working proprietary driver at all for pre-Fermi chips (nouveau
    # only, no CUDA). Delegate the chip->branch mapping to Debian's own
    # nvidia-detect tool rather than hand-rolling a PCI-ID table -- it
    # already encodes this exact mapping. nvidia-detect lives in the
    # contrib component, which this project's base sources do not enable
    # by default (confirmed live on PROTEUS, 2026-09-20: only
    # main+non-free-firmware enabled, `apt-cache show nvidia-detect` ->
    # "No packages found") -- enable contrib+non-free just for this probe
    # if not already present.
    # BUG FIXED 2026-09-29 (found live on PEGASUS): this used to read
    # VERSION_CODENAME from /etc/os-release, which on NCZ-OS is the product
    # codename "maximilian", not a Debian suite -- the written source then
    # 404'd and broke every later `apt-get update` (E: ... maximilian Release
    # does not have a Release file). The Debian suite is NCZ_BASE_CODENAME
    # from the installer RELEASE file. Also look at deb822 *.sources: 23-base-
    # apt-sources already enables contrib there, so no extra source is needed.
    NV_CODENAME=$( . /usr/local/lib/cix-installer/RELEASE 2>/dev/null; echo "${NCZ_BASE_CODENAME:-forky}")
    if [ -n "$NV_CODENAME" ] && ! grep -rqs 'contrib' /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources 2>/dev/null; then
        cat > /etc/apt/sources.list.d/ncz-nvidia-detect.list <<EOF
deb http://deb.debian.org/debian/ $NV_CODENAME contrib non-free
EOF
        apt-get update 2>&1 | tail -5
    fi
    apt-get install -y nvidia-detect >/tmp/ncz-nvidia-detect-install.log 2>&1

    NV_ROUTE=current
    NV_BRANCH_PKG=""
    if command -v nvidia-detect >/dev/null 2>&1; then
        NV_DETECT_OUT="$(nvidia-detect 2>&1)"
        echo "[54] nvidia-detect: $(echo "$NV_DETECT_OUT" | tr '\n' ' ' | cut -c1-200)"
        case "$NV_DETECT_OUT" in
            *nvidia-legacy-390xx-driver*) NV_ROUTE=legacy; NV_BRANCH_PKG=nvidia-legacy-390xx-driver ;;
            *nvidia-legacy-470xx-driver*) NV_ROUTE=legacy; NV_BRANCH_PKG=nvidia-legacy-470xx-driver ;;
            *nvidia-driver*)              NV_ROUTE=current ;;
            *)                            NV_ROUTE=unsupported ;;
        esac
    else
        echo "[54] WARN: nvidia-detect unavailable (contrib unreachable or install failed, see /tmp/ncz-nvidia-detect-install.log) -- cannot do generation-aware routing, falling back to the current-branch (cuda-drivers) install unconditionally"
    fi

    if [ "$NV_ROUTE" = "unsupported" ]; then
        # Only fall back to nouveau for hardware nvidia-detect itself says
        # has no supported driver branch (pre-Fermi). Any card with a real
        # proprietary branch -- even the old 390xx one -- is preferred over
        # nouveau below, since nouveau cannot provide CUDA/compute at all,
        # which is the entire point of this hook.
        ncz_cuda_status "skipped:no-supported-nvidia-driver-branch"
        echo "[54] NVIDIA: nvidia-detect found no supported driver branch for this card (pre-Fermi or unrecognized) -- leaving nouveau (in-kernel default) as the only real option, no proprietary/CUDA path exists for this hardware. Logic-verified against NVIDIA/Debian's own branch documentation, NOT boot-tested -- no NVIDIA hardware of any generation exists in the fleet to validate this or any NVIDIA branch against (operator-confirmed 2026-09-20, oldest fleet machine is an Intel-graphics-only Mac Mini)."
    elif [ "$NV_ROUTE" = "legacy" ]; then
        # Legacy branches are Debian in-archive packages, NOT NVIDIA's own
        # cuda-keyring repo -- that repo only tracks the current branch and
        # carries no drivers for Kepler/Fermi-class chips.
        ncz_cuda_status "skipped:legacy-nvidia-branch-no-cuda-13"
        echo "[54] NVIDIA: routing to legacy branch $NV_BRANCH_PKG (nvidia-detect recommendation)"
        apt-get install -y "$NV_BRANCH_PKG" 2>&1 | tail -10
        echo "[54] NVIDIA: legacy driver installed. NOTE: NVIDIA's CUDA toolkit repo (cuda-keyring) only supports the current driver branch -- a matching older CUDA toolkit version must be sourced separately for this branch if CUDA (not just display/video accel) is required. Logic-verified against NVIDIA/Debian's own branch documentation, NOT boot-tested (no Kepler/Fermi-class NVIDIA hardware exists in the fleet to validate against, 2026-09-20)."
    else
        echo "[54] NVIDIA: wiring real NVIDIA CUDA repo (current driver branch)"
        NV_KEYRING_DEB=/usr/local/lib/cix-installer/assets/nvidia/cuda-keyring_1.1-1_all.deb
        if [ -f "$NV_KEYRING_DEB" ]; then
            dpkg -i "$NV_KEYRING_DEB" 2>&1 | tail -5
            # Keep the driver family on R615 (CUDA 13.4's branch) BEFORE any
            # NVIDIA package is resolved.
            NV_PREF="$(dirname "$NV_KEYRING_DEB")/ncz-nvidia-cuda.pref"
            if [ -f "$NV_PREF" ]; then
                install -D -m0644 "$NV_PREF" /etc/apt/preferences.d/ncz-nvidia-cuda.pref
            else
                echo "[54] WARN: $NV_PREF not staged -- driver/CUDA are NOT pinned to R615"
            fi
            # Offline install: the driver and CUDA closure is in the bundled
            # /cdrom pool (same wiring as 20-desktop.sh). Live apt update
            # keeps working through the NVIDIA source the keyring package
            # just wrote; an unreachable network here is not fatal.
            NCZ_APT_SUITE="$( . /usr/local/lib/cix-installer/RELEASE 2>/dev/null; echo "${NCZ_BASE_CODENAME:-forky}")"
            if [ -d "/cdrom/dists/$NCZ_APT_SUITE" ] && [ ! -f /etc/apt/sources.list.d/cixmini-cdrom.list ]; then
                echo "deb [trusted=yes] file:///cdrom $NCZ_APT_SUITE main" \
                    > /etc/apt/sources.list.d/cixmini-cdrom.list
            fi
            apt-get update -o Acquire::http::Timeout=8 -o Acquire::https::Timeout=8 -o Acquire::Retries=0 2>&1 | tail -5
            # cuda-drivers is the driver-only metapackage (nvidia-open, the
            # Turing+ open kernel modules; since CUDA 13.4 it no longer
            # brings any toolkit -- ncz_cuda_toolkit_install below does).
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
            if ! nvidia_turing_plus_present 2>/dev/null; then
                echo "[54] WARN: NVIDIA GPU older than Turing: R615 open kernel modules and CUDA 13 do not support it; cuda-drivers was installed by the pre-CUDA-13 logic but will not bind. Use Debian's nvidia-driver (550 branch, live apt) for Maxwell/Pascal/Volta."
            fi
            # Driver first (kernel modules + userspace), then the toolkit.
            ncz_cuda_toolkit_install
        else
            echo "[54] WARN: NVIDIA GPU present but $NV_KEYRING_DEB not staged — skipping NVIDIA stack"
            ncz_cuda_status "failed:keyring-not-staged"
            echo "[54]       stage cuda-keyring_1.1-1_all.deb from developer.download.nvidia.com/compute/cuda/repos/debian13/x86_64/ under assets/nvidia/ to fix"
        fi
    fi
fi

# --- AMD ------------------------------------------------------------------
if [ "$HAS_AMD" = 1 ]; then
    echo "[54] AMD GPU detected: using Debian-native ROCm packages; no AMD Ubuntu repository will be configured"
    # Remove files produced by older revisions of this hook so an upgrade or
    # rerun cannot keep the unpinned jammy source active.
    rm -f /etc/apt/sources.list.d/rocm.list /etc/apt/keyrings/rocm.gpg \
        /etc/profile.d/ncz-rocm-gfx-override.sh
    echo "[54] removed any legacy repo.radeon.com source, keyring, and RDNA1 override"
    apt-get update 2>&1 | tail -5
    ROCM_DEBIAN_PACKAGES="rocminfo rocm-smi rocm-opencl-icd rocm-device-libs-21 libamdhip64-6 hipcc rocm-cmake"
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $ROCM_DEBIAN_PACKAGES 2>&1 | tail -12
    ROCM_INSTALL_RC=${PIPESTATUS[0]}
    if [ "$ROCM_INSTALL_RC" -eq 0 ]; then
        echo "[54] AMD: Debian-native ROCm packages installed"
    else
        echo "[54] WARN: Debian-native ROCm package installation was incomplete"
    fi
    if GFX_NAME=$(rocminfo 2>/dev/null | grep -m1 -oE 'gfx[0-9a-f]+'); then
        echo "[54] AMD: rocminfo detected $GFX_NAME; workload support still depends on the GPU generation"
    else
        echo "[54] AMD: rocminfo did not enumerate a GPU in the installer session; no OpenCL support claim is made"
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

# One final ldconfig so the CUDA ld.so.conf.d entries are in the cache no
# matter which hooks ran before (the installed system has an ldconfig
# first-boot race; see preseed/extract-rootfs.sh).
ldconfig 2>/dev/null || true

echo "[54] GPU/accelerator wiring done (NVIDIA=$HAS_NVIDIA AMD=$HAS_AMD Intel=$HAS_INTEL)"
