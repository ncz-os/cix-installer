#!/bin/bash
# 86-gpu-nvidia.sh — NVIDIA proprietary GPU driver for amd64 targets.
#
# amd64/PEGASUS port (2026-07-27): first-ever non-CIX GPU hook in this repo.
# There is no arm64/Mali equivalent of this file — it is amd64-only and
# self-guards on BUILD_ARCH (see run-all.sh) so it is a safe no-op if it ever
# ships on CIX Sky1 media.
#
# SCOPE: install NVIDIA's proprietary driver (nouveau stays disabled/unused,
# per operator directive: "NVIDIA proprietary, not nouveau"), wire basic
# Xorg/Wayland GL, and handle PRIME render-offload on hybrid (Optimus)
# laptops. CUDA toolkit packaging is explicitly OUT of scope here (separate,
# much larger NVIDIA-repo-based effort) — this hook only gets the driver +
# GL/Vulkan userspace + KMS working for the desktop session.
#
# HARDWARE REALITY CHECK (done before writing this hook, not assumed):
#   PEGASUS (192.168.207.85, the amd64 bring-up target) is a hybrid Optimus
#   laptop: Intel CometLake-H UHD (i915, PCI 00:02.0) drives the internal
#   eDP-1 panel; NVIDIA RTX 2060 Mobile (PCI 01:00.0) is a SECONDARY
#   render-only GPU with no display connectors of its own (confirmed via
#   `readlink -f /sys/class/drm/card*/device` + vendor IDs: card1=0x8086
#   Intel owns eDP-1, card2=0x10de NVIDIA, DP-1/HDMI-A-1 disconnected).
#   `ubuntu-drivers devices` on the live host recommends nvidia-driver-595-open,
#   available directly from Ubuntu's own restricted archive component
#   (resolute/restricted, resolute-updates/restricted) — NO third-party NVIDIA
#   apt repo is needed for the base driver.
#
#   PRACTICAL UPSHOT: Singularity Desktop (labwc/wlroots-0.20) will do its
#   primary KMS/compositing on Intel i915 + Mesa — the SAME well-trodden path
#   every other wlroots-on-Intel laptop uses. The historically painful
#   NVIDIA+wlroots friction (EGLStreams vs GBM, explicit sync) only applies
#   when NVIDIA is the PRIMARY/KMS-owning GPU, which it is not on this
#   hardware. NVIDIA only needs to work for: (a) PRIME render-offload of
#   individual GPU-heavy apps, (b) CUDA/compute workloads outside the scope
#   of this hook. wlroots-0.20 (bundled by build-singularity.sh) has explicit
#   sync support (landed 0.19+) so IF a future amd64 target has NVIDIA as the
#   ONLY/primary GPU, GBM-based compositing should also work — untested here
#   since PEGASUS is not that case. Flagging this as the one part of the
#   NVIDIA story that has NOT been hardware-validated.
#
# RUNS INSIDE CHROOT via run-all.sh (Phase 2, optional — a failure here must
# not abort the install; the desktop still needs to boot on Intel alone).
set -uo pipefail

BUILD_ARCH_FILE=/usr/local/lib/cix-installer/BUILD_ARCH
BUILD_ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
[ -f "$BUILD_ARCH_FILE" ] && BUILD_ARCH=$(tr -d ' \t\r\n' < "$BUILD_ARCH_FILE")
if [ "$BUILD_ARCH" != "amd64" ]; then
    echo "[86] BUILD_ARCH=$BUILD_ARCH — not amd64, skipping (no NVIDIA hardware story on CIX Sky1)"
    exit 0
fi

# Desktop-only: a headless Server build has no compositor to wire GL for.
# (CUDA-for-compute-on-Server is a real future use case but out of scope —
# see file header.)
VARIANT=desktop
if [ -f /usr/local/lib/cix-installer/BUILD_VARIANT ]; then
    VARIANT=$(tr -d ' \t\r\n' < /usr/local/lib/cix-installer/BUILD_VARIANT)
fi
case "$VARIANT" in
    server|headless)
        echo "[86] BUILD_VARIANT=$VARIANT — Server headless SKU; skipping NVIDIA GL/desktop wiring"
        exit 0
        ;;
esac

echo "[86] NVIDIA proprietary GPU driver (amd64)"

# ---------------------------------------------------------------------------
# Driver selection. Prefer the distro's own ubuntu-drivers autodetect (same
# mechanism Ubuntu Desktop's installer uses for "install third-party
# drivers") so the package name tracks whatever the resolute archive
# currently recommends, rather than a version pinned at repo-write time going
# stale. Falls back to a known-good explicit pin if ubuntu-drivers is
# unavailable or ambiguous (e.g. offline chroot with no PCI access to a real
# GPU to probe — this IS a chroot, not the real target hardware, at build
# time).
# ---------------------------------------------------------------------------
# NOTE on the fallback pin: verified live 2026-07-27 via `ubuntu-drivers
# devices` on PEGASUS itself against its real RTX 2060 Mobile — the archive
# recommends nvidia-driver-595-open (open-kernel-module variant; Turing+
# supports it) and it is genuinely present in resolute/resolute-updates
# restricted. This is a real, checked value, not a guess -- but it WILL go
# stale as the archive rolls forward, hence the ubuntu-drivers devices probe
# is tried first.
NVIDIA_PKG=""
if command -v ubuntu-drivers >/dev/null 2>&1; then
    # `ubuntu-drivers devices` needs real PCI enumeration of the GPU; in a
    # chroot with no passthrough to the actual target hardware it typically
    # finds nothing, hence the explicit fallback below is not just
    # theoretical -- it is the expected path when this hook runs at
    # build/bake time rather than on the real booted target.
    NVIDIA_PKG=$(ubuntu-drivers devices 2>/dev/null | grep -oE 'nvidia-driver-[0-9]+-open' | sort -u | tail -1)
fi
NVIDIA_PKG="${NVIDIA_PKG:-nvidia-driver-595-open}"
NVIDIA_GL_PKG="libnvidia-gl-$(printf '%s' "$NVIDIA_PKG" | grep -oE '[0-9]+' | head -1)"

echo "[86] installing $NVIDIA_PKG (+ nvidia-prime, nvidia-settings, vulkan/GL userspace)"
if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        "$NVIDIA_PKG" nvidia-prime nvidia-settings \
        "$NVIDIA_GL_PKG" mesa-vulkan-drivers vulkan-tools 2>&1 | tail -20; then
    echo "[86] WARN: exact package set failed (likely stale version pin) — retrying with autoinstall" >&2
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        nvidia-prime nvidia-settings 2>&1 | tail -10 || true
    if command -v ubuntu-drivers >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive ubuntu-drivers autoinstall 2>&1 | tail -20 \
            || echo "[86] ERROR: NVIDIA driver install failed entirely — desktop will fall back to nouveau/llvmpipe" >&2
    fi
fi

# ---------------------------------------------------------------------------
# KMS modeset — required for the NVIDIA DRM/KMS path (and for PRIME offload
# to hand buffers to the DRM-KMS-owning GPU cleanly). Bootloader-agnostic:
# a modprobe.d option, not a kernel cmdline flag, so it works whether the
# amd64 bootloader ends up being GRUB or something else (70-bootloader.sh is
# still rEFInd/arm64-only as of this writing — amd64 bootloading is a
# separate, not-yet-ported piece of work; this option does not depend on it).
# ---------------------------------------------------------------------------
install -d -m0755 /etc/modprobe.d
cat > /etc/modprobe.d/nvidia-drm-modeset.conf <<'MODPROBE'
# NCZ-OS amd64: enable NVIDIA DRM KMS (required for Wayland/PRIME offload).
options nvidia-drm modeset=1
MODPROBE
echo "[86] /etc/modprobe.d/nvidia-drm-modeset.conf written (nvidia-drm.modeset=1)"

# ---------------------------------------------------------------------------
# PRIME mode. Default = on-demand: Intel stays the primary/KMS GPU (correct
# for PEGASUS's actual Optimus wiring — see file header), NVIDIA is available
# on request via render-offload. A future NVIDIA-only/MUX-switch amd64 target
# would instead need `prime-select nvidia` (full-time mode) — that is a real
# hardware-dependent choice this hook cannot make blind in a chroot (no
# access to the real target's GPU topology at build/bake time), so it is left
# as documented operator guidance rather than silently guessed.
# ---------------------------------------------------------------------------
if command -v prime-select >/dev/null 2>&1; then
    prime-select on-demand 2>&1 | sed 's/^/    /' || \
        echo "[86] WARN: prime-select on-demand failed (non-fatal — apply manually post-install if needed)"
    echo "[86] PRIME mode: on-demand (Intel primary/KMS, NVIDIA available via offload)"
    echo "[86]   NOTE: on an NVIDIA-only or MUX-switch machine (no Intel iGPU), an"
    echo "[86]         operator should instead run: sudo prime-select nvidia"
else
    echo "[86] WARN: prime-select not present (nvidia-prime install may have failed above)"
fi

# ---------------------------------------------------------------------------
# nvidia-offload helper — the standard Arch-wiki-style wrapper for running a
# single GPU-heavy app on the NVIDIA GPU under PRIME on-demand mode, without
# forcing the whole session onto NVIDIA. Mirrors the spirit of ncz-gpu-env
# (post-install/20-desktop.sh) for the CIX Mali/Panthor case: same "small
# sourceable/exec wrapper" pattern, NVIDIA-appropriate content.
# ---------------------------------------------------------------------------
install -d -m0755 /usr/local/bin
cat > /usr/local/bin/nvidia-offload <<'OFFLOAD'
#!/bin/sh
# nvidia-offload CMD [ARGS...] — run CMD on the NVIDIA GPU via PRIME render
# offload, leaving the rest of the desktop session on the primary (Intel) GPU.
# Standard __NV_PRIME_RENDER_OFFLOAD / __GLX_VENDOR_LIBRARY_NAME /
# __VK_LAYER_NV_optimus trio; works under both Xwayland and native Wayland
# clients that respect glvnd/Vulkan ICD selection.
export __NV_PRIME_RENDER_OFFLOAD=1
export __NV_PRIME_RENDER_OFFLOAD_PROVIDER=NVIDIA-G0
export __GLX_VENDOR_LIBRARY_NAME=nvidia
export __VK_LAYER_NV_optimus=NVIDIA_only
exec "$@"
OFFLOAD
chmod 0755 /usr/local/bin/nvidia-offload
echo "[86] /usr/local/bin/nvidia-offload installed (run: nvidia-offload <cmd> to force NVIDIA render)"

# ---------------------------------------------------------------------------
# Vulkan ICD sanity — libnvidia-gl ships /usr/share/vulkan/icd.d/nvidia_icd.json;
# just confirm it landed rather than silently shipping a GPU-less Vulkan
# closure. Non-fatal either way (Mesa's Intel ICD still covers the primary
# GPU on the Optimus case).
# ---------------------------------------------------------------------------
if [ -f /usr/share/vulkan/icd.d/nvidia_icd.json ]; then
    echo "[86] NVIDIA Vulkan ICD present: /usr/share/vulkan/icd.d/nvidia_icd.json"
else
    echo "[86] WARN: NVIDIA Vulkan ICD not found — Vulkan offload to NVIDIA will not work (Intel Vulkan via Mesa is unaffected)"
fi

# ---------------------------------------------------------------------------
# Operator groups — the greeter/session user needs render/video group
# membership for DRM access, same set 20-desktop.sh already adds for Mali;
# harmless to re-assert here for the NVIDIA render node.
# ---------------------------------------------------------------------------
OPERATOR_USER=$(awk -F: '$3 >= 1000 && $3 < 65000 {print $1; exit}' /etc/passwd)
if [ -n "$OPERATOR_USER" ] && id "$OPERATOR_USER" >/dev/null 2>&1; then
    for g in render video; do
        getent group "$g" >/dev/null 2>&1 && usermod -aG "$g" "$OPERATOR_USER" 2>/dev/null || true
    done
fi

echo "[86] NVIDIA GPU driver stage done ($NVIDIA_PKG, PRIME on-demand, nvidia-drm.modeset=1)"
exit 0
