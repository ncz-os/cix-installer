#!/bin/bash
# 16-gpu-userspace.sh — install GPU userspace tooling + libraries.
#
# Runs AFTER 15-mesa-sky1-pin.sh (which pins Sky1-Linux Mesa 26 origin)
# and BEFORE 20-desktop.sh / 22-display-fix.sh (which assume the libs
# are present). The Thin cdrom mirror doesn't ship these by default —
# they're pulled from the ports.ubuntu.com archive that 21-internet-apt.sh
# enables (yes, 21 runs after 16 — but 16's apt installs are best-effort:
# any miss here lands cleanly when the operator runs apt later).
#
# Packages:
#   mesa-utils      — glxinfo, glxgears (GL debug + smoke tests)
#   vulkan-tools    — vulkaninfo, vkcube (Vulkan debug + smoke tests)
#   libdrm-tests    — drmtest userspace probes
#   libvulkan1      — runtime loader (apps link against this)
#
# Display server: this hook is server-tier prerequisite only. The
# actual display-server decision (Wayland vs X11) is made by 20-desktop.sh
# based on BUILD_VARIANT. Wayland needs libwayland-* + xwayland (already
# bundled in resolute base); X11 needs xserver-xorg-core (also base).
# 22-display-fix.sh wires up the dynamic primary-display detector.
#
# Vulkan driver mismatch vs panthor:
#   - Mali-G720 needs panvk (from Sky1-Linux Mesa 26 stack, pinned by 15).
#   - panthor kernel driver still exposes /dev/dri/card0 + render128.
#   - libvulkan1 loader auto-detects panvk via /usr/share/vulkan/icd.d/.
#   - If a stock libvulkan-mesa lands without panvk, vulkaninfo segfaults.
#   - The 15-mesa-sky1-pin pin (priority 1001) prevents apt from
#     downgrading panvk to stock-only mesa. This hook intentionally does
#     NOT explicitly pull libvulkan-mesa — Sky1 packages provide the
#     mesa-vulkan-drivers binding that wires panvk to libvulkan1.
#
# Idempotent + best-effort: apt failures don't break the install.
set -uo pipefail

echo "[16] installing GPU userspace tooling"

PACKAGES=(
    mesa-utils
    vulkan-tools
    libdrm-tests
    libvulkan1
)

# DEBIAN_FRONTEND=noninteractive prevents debconf prompts during chroot
# late_command. -yq = yes-quiet. --no-install-recommends keeps the
# closure tight (no GUI suggests like wine32-development).
export DEBIAN_FRONTEND=noninteractive

if apt-get install -yq --no-install-recommends "${PACKAGES[@]}" 2>&1 | tail -10; then
    echo "[16] installed: ${PACKAGES[*]}"
else
    echo "[16] WARN: apt-get install did not complete cleanly"
    echo "[16]       packages may not all be present; operator can re-run apt later"
    echo "[16]       21-internet-apt.sh adds the ports.ubuntu.com source if missing"
fi

# Smoke check (best-effort, non-fatal). vulkaninfo prints a Vulkan
# loader/driver inventory — useful for the post-install build log so
# operator can grep for the expected panvk + linlondp entries.
if command -v vulkaninfo >/dev/null 2>&1; then
    vulkaninfo --summary 2>&1 | head -20 || echo "[16] vulkaninfo failed (no GPU node yet in chroot — normal)"
fi
if command -v glxinfo >/dev/null 2>&1; then
    glxinfo -B 2>&1 | head -10 || echo "[16] glxinfo failed (no display in chroot — normal)"
fi

exit 0
