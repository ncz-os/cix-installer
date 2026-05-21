#!/bin/bash
# 26-gpu-userspace.sh — install Mesa / Vulkan / VA-API userspace for Sky1 GPU.
#
# RATIONALE (2026-05-20):
#
# The Sky1 integrated GPU is detected and HW-initialized correctly on every
# fresh install (panthor driver loads + binds to Mali-G720-Immortalis +
# linlon-d60 display controller link-trains). But the Thin cdrom mirror
# ships zero graphics userspace:
#
#   * No Mesa GL stack — glxinfo / GL apps cannot run.
#   * No Vulkan ICD / vulkaninfo.
#   * No vainfo (VA-API consumer-side diagnostic).
#   * No glmark2 benchmark for smoke testing.
#
# Operators get a panthor /dev/dri/renderD128 with no way to render through
# it. That's an unusably-incomplete graphics tier 1 deliverable for a $700
# desktop appliance. Bake the userspace into every install.
#
# Validated 2026-05-20 on .66 — Mesa 26.0.3, Vulkan 1.4.341, vainfo 2.22,
# glmark2 2023.01 all install cleanly once /etc/apt/sources.list.d/
# ubuntu-archive.list (from 21-internet-apt.sh) is in place.
#
# 15-mesa-sky1-pin.sh handles Sky1-blessed version pinning AFTER Mesa
# packages are present; this hook installs the packages so the pin has
# something to pin. (Naming: 15 < 26 looks backwards but 15 pin is a
# guard for OPERATOR `apt upgrade` runs post-install; it doesn't itself
# install anything. The pin reads existing versions from cache.)
#
# KNOWN ISSUE for next-image work (see docs/KNOWN-ISSUES-NEXT-IMAGE.md
# section P1 #4): mesa-vulkan-drivers ships a vulkan-asahi ICD that tries
# to bind /dev/dri/renderD128 (Sky1's panthor render node) and fails with
# VK_ERROR_INCOMPATIBLE_DRIVER. Sky1 needs panvk (still experimental
# upstream). For now we accept the warning — GL still works through
# panthor; only Vulkan apps see the failed device.
set -uo pipefail

echo "[26] installing Sky1 GPU userspace (Mesa GL + Vulkan + VA-API + glmark2)"

# Bail cleanly if apt has no usable source — happens when 21-internet-apt.sh
# couldn't reach the network during chroot late_command. The hook will be
# re-run by the first-boot fixup oneshot (next-image work) when the network
# is up.
if ! apt-get update -o Acquire::Retries=2 2>&1 | tail -3; then
    echo "[26] WARN: apt-get update did not complete cleanly — skipping GPU userspace install"
    echo "[26]       On first boot run:"
    echo "[26]         sudo apt-get update && sudo bash $0"
    exit 0
fi

GPU_PKGS=(
    # OpenGL userspace + diagnostic
    mesa-utils
    libgl1-mesa-dri
    libegl1
    libegl-mesa0
    # Vulkan userspace + diagnostic (Sky1 needs panvk for full HW path —
    # ships Asahi ICD by default; tracked in KNOWN-ISSUES-NEXT-IMAGE.md)
    mesa-vulkan-drivers
    vulkan-tools
    # VA-API consumer-side diagnostic + Mesa-side drivers (HW video decode
    # comes from cix-vpu-driver-dkms once task #66 ships kernel-headers)
    vainfo
    mesa-va-drivers
    # Smoke test
    glmark2
    glmark2-es2
    # Operator diagnostics
    pciutils
    lshw
)

if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        "${GPU_PKGS[@]}" 2>&1 | tail -8; then
    echo "[26] WARN: one or more GPU userspace packages failed to install"
    echo "[26]       inspect /var/log/apt/term.log for details"
    # Don't exit non-zero — bootloader + diagnostics must still run.
fi

# Sanity-check the install: glxinfo + vulkaninfo + vainfo must be on PATH.
# (Their RUNTIME behavior depends on a display server / DRM access which
# this chroot lacks — that's fine; we're verifying the packages landed.)
MISSING=()
for cmd in glxinfo vulkaninfo vainfo glmark2-es2; do
    command -v "$cmd" >/dev/null 2>&1 || MISSING+=("$cmd")
done
if [ "${#MISSING[@]}" -ne 0 ]; then
    echo "[26] WARN: post-install commands missing: ${MISSING[*]}"
    echo "[26]       GPU userspace install was partial"
else
    echo "[26] GPU userspace OK — glxinfo / vulkaninfo / vainfo / glmark2-es2 all on PATH"
fi

# Suppress the Asahi Vulkan ICD so vulkaninfo doesn't emit a scary
# "VK_ERROR_INCOMPATIBLE_DRIVER" on every probe. The ICD targets Apple
# Silicon's M-series GPU, not Sky1; leaving it enabled gives the false
# impression that Vulkan is broken when in fact no Sky1 ICD is installed
# yet (panvk pending — see KNOWN-ISSUES-NEXT-IMAGE.md P1 #4).
ASAHI_ICD=/usr/share/vulkan/icd.d/asahi_icd.aarch64.json
if [ -f "$ASAHI_ICD" ]; then
    mv "$ASAHI_ICD" "${ASAHI_ICD}.disabled"
    echo "[26] disabled mismatched vulkan-asahi ICD ($ASAHI_ICD)"
fi

# Display server is NOT installed here — that's a separate, heavier
# decision (gdm + gnome-session ~600 MB). Operators who want a desktop
# tier can install via: sudo apt-get install ubuntu-desktop-minimal

echo "[26] Sky1 GPU userspace install complete"
exit 0
