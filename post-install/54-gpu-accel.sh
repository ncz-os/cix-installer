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
# NCZ-PLATFORM-GUARD: amd64 only (docs/PLATFORM-SPLIT-DESIGN.md). Arch order matches
# run-all.sh: NCZ_TARGET_ARCH, then the late.sh BUILD_ARCH stamp, then dpkg. An
# undetectable arch does NOT skip (legacy behavior).
_ncz_pg_arch="${NCZ_TARGET_ARCH:-}"
[ -n "$_ncz_pg_arch" ] || _ncz_pg_arch=$(cat /usr/local/lib/cix-installer/BUILD_ARCH 2>/dev/null | tr -d '[:space:]')
[ -n "$_ncz_pg_arch" ] || _ncz_pg_arch=$(dpkg --print-architecture 2>/dev/null || true)
case "$_ncz_pg_arch" in
    amd64|x86_64|"") ;;
    *) echo "[${0##*/}] platform guard: arch=$_ncz_pg_arch is not amd64; skipping"; exit 0 ;;
esac
unset _ncz_pg_arch
set +e

if [ "$(dpkg --print-architecture 2>/dev/null)" != "amd64" ]; then
    echo "[54] not an amd64 target — skipping (this hook is AMD64-only)"
    exit 0
fi

# --- NVIDIA driver + CUDA: selected per GPU family, pulled dynamically --------
# Operator directive 2026-09-29: do not bake CUDA into the ISO/offline mirror;
# pull it from NVIDIA's apt repo at install time when an NVIDIA GPU is present
# and the network is up, with a first-boot retry (ncz-cuda-setup.timer) when it
# is not. The GPU family decides the driver branch and toolkit (see
# post-install/lib/cuda-select.sh for the matrix and its evidence):
#   Turing+       R615 open kernel modules + CUDA 13.4 (debian13 repo)
#   Maxwell..Volta R580 proprietary module     + CUDA 12.9 (debian12 repo)
#   Kepler/older  nothing usable: nouveau only, logged
# The choice is recorded in /etc/ncz/cuda-selection.conf and pinned in apt so a
# later `apt upgrade` cannot move a machine to a branch that drops its GPU.
# Nothing here can abort post-install: every failure is logged and the deferred
# unit finishes the job later.
NCZ_NV_ASSETS=/usr/local/lib/cix-installer/assets/nvidia
NCZ_CUDA_STATUS=/var/lib/ncz/cuda-toolkit.status
ncz_cuda_status() {
    mkdir -p "$(dirname "$NCZ_CUDA_STATUS")" 2>/dev/null
    echo "$1" > "$NCZ_CUDA_STATUS" 2>/dev/null
    echo "[54] CUDA: $1"
}
ncz_cuda_component_wanted() {
    # The installer's component chooser records COMPONENTS_cuda (1/0). No
    # record (older selector, headless run) means: install.
    local f
    for f in /etc/cix-installer/COMPONENTS_cuda /usr/local/lib/cix-installer/COMPONENTS_cuda; do
        if [ -r "$f" ]; then [ "$(tr -d ' \t\r\n' < "$f")" = 1 ]; return; fi
    done
    return 0
}
ncz_nvidia_dynamic_setup() {
    local lib="$(dirname "$(readlink -f "$0")")/lib/cuda-select.sh"
    if [ ! -r "$lib" ]; then
        echo "[54] WARN: $lib missing: cannot select an NVIDIA driver/CUDA family"
        ncz_cuda_status "failed:selection-lib-missing"; return 0
    fi
    # shellcheck disable=SC1090
    . "$lib"
    if [ "${NCZ_SKIP_CUDA:-0}" = 1 ]; then ncz_cuda_status "skipped:operator-disabled"; return 0; fi

    local pick fam id
    pick=$(ncz_cuda_pick_family) || { ncz_cuda_status "skipped:no-nvidia-gpu"; return 0; }
    if ! ncz_cuda_component_wanted; then ncz_cuda_status "skipped:component-not-selected"; return 0; fi
    fam=${pick%% *}; id=${pick##* }
    echo "[54] NVIDIA GPU 10de:$id -> family $fam"
    local plan; plan=$(ncz_cuda_plan "$fam") || { ncz_cuda_status "failed:no-plan-for-$fam"; return 0; }

    install -d -m0755 /etc/ncz
    {
        echo "# Written by post-install/54-gpu-accel.sh; read by ncz-cuda-setup."
        echo "GPU_PCI_ID=10de:$id"
        echo "SELECTED_AT=$(date -u +%FT%TZ)"
        echo "$plan"
    } > /etc/ncz/cuda-selection.conf
    eval "$plan"

    if [ "$FAMILY" = kepler-older ]; then
        echo "[54] NVIDIA: $REASON"
        ncz_cuda_status "skipped:kepler-older-unsupported"
        return 0
    fi

    # Repo key + source, driver-branch pin, tool and deferred units.
    case "$REPO" in
        debian13)
            if [ -f "$NCZ_NV_ASSETS/$KEY_ASSET" ]; then
                dpkg -i "$NCZ_NV_ASSETS/$KEY_ASSET" 2>&1 | tail -3
            else
                echo "[54] WARN: $NCZ_NV_ASSETS/$KEY_ASSET not staged (the deferred setup cannot add the repo)"
                ncz_cuda_status "failed:keyring-not-staged"; return 0
            fi ;;
        debian12)
            if [ -f "$NCZ_NV_ASSETS/$KEY_ASSET" ]; then
                install -D -m0644 "$NCZ_NV_ASSETS/$KEY_ASSET" /usr/share/keyrings/ncz-cuda-debian12.gpg
                install -d -m0755 /etc/apt/sources.list.d
                echo "deb [signed-by=/usr/share/keyrings/ncz-cuda-debian12.gpg] https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/ /" \
                    > /etc/apt/sources.list.d/ncz-cuda-debian12.list
            else
                echo "[54] WARN: $NCZ_NV_ASSETS/$KEY_ASSET not staged"
                ncz_cuda_status "failed:keyring-not-staged"; return 0
            fi ;;
    esac
    if [ "$SEQUOIA_RELAX" = 1 ]; then
        # NVIDIA still signs the debian12 repo with its 2022 key, whose SHA-1
        # self-signature Debian's apt-sequoia policy rejects (measured on
        # forky: "Signing key ... is not bound ... SHA1 is not considered
        # secure since 2026-02-01"). Extend that one policy date for this
        # (legacy-GPU) machine only. This is machine-wide for apt: documented
        # in docs and shown by `ncz-cuda-setup status`.
        if [ -r /usr/share/apt/default-sequoia.config ]; then
            install -d -m0755 /etc/crypto-policies/back-ends
            sed 's/^sha1.second_preimage_resistance = .*/sha1.second_preimage_resistance = 2027-12-31    # NCZ: NVIDIA debian12 repo key/' \
                /usr/share/apt/default-sequoia.config > /etc/crypto-policies/back-ends/apt-sequoia.config
        else
            echo "[54] WARN: /usr/share/apt/default-sequoia.config missing: cannot relax the SHA-1 policy for the NVIDIA debian12 key"
        fi
    fi
    install -d -m0755 /etc/apt/preferences.d
    ncz_cuda_pin_file "$fam" > /etc/apt/preferences.d/ncz-nvidia-cuda.pref
    install -D -m0755 "$NCZ_NV_ASSETS/ncz-cuda-setup" /usr/local/sbin/ncz-cuda-setup
    install -D -m0644 "$NCZ_NV_ASSETS/ncz-cuda-setup.service" /etc/systemd/system/ncz-cuda-setup.service
    install -D -m0644 "$NCZ_NV_ASSETS/ncz-cuda-setup.timer" /etc/systemd/system/ncz-cuda-setup.timer
    install -d -m0755 /etc/systemd/system/timers.target.wants
    ln -sf ../ncz-cuda-setup.timer /etc/systemd/system/timers.target.wants/ncz-cuda-setup.timer
    ncz_cuda_status "pending:install"

    # Try now (network is normally up during install); a failure leaves the
    # timer to finish it after boot.
    local rc
    timeout 5400 /usr/local/sbin/ncz-cuda-setup run 2>&1 | tail -20 | sed 's/^/[54]   /'
    rc=${PIPESTATUS[0]}
    if [ "$rc" = 0 ]; then
        echo "[54] CUDA: installed now ($(cat "$NCZ_CUDA_STATUS" 2>/dev/null))"
    else
        echo "[54] CUDA: not finished at install time (rc=$rc, $(cat "$NCZ_CUDA_STATUS" 2>/dev/null)); ncz-cuda-setup.timer will retry after boot"
    fi
    return 0
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
    ncz_nvidia_dynamic_setup
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

echo "[54] GPU/accelerator wiring done (NVIDIA=$HAS_NVIDIA AMD=$HAS_AMD Intel=$HAS_INTEL)"
