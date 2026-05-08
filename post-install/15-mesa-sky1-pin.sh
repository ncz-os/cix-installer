#!/bin/bash
# 15-mesa-sky1-pin.sh — pin the Sky1-Linux Mesa 26 stack when present.
#
# r75 K4: Mesa 26.0.0-1sky1.2 panvk + libdisplay-info3 + libllvm21 +
# mesa-vulkan-drivers + mesa-libgallium are what made Mali-G720 Vulkan
# work end-to-end on the .66 reference deploy. Resolute's stock Mesa is
# already Mesa 26.0.3, but the Sky1-Linux builds remain the known-good
# package origin for the current hardware validation.
#
# Pin scope: every Mesa-side package we know matters for Sky1 panvk.
# Pin priority 1001 (above 990 'pinned default') so apt prefers the
# Sky1-Linux origin over Ubuntu resolute even on point-version regress.
#
# Idempotent — safe to run repeatedly; sed replaces the file in full
# on each run.
#
# RUNS INSIDE CHROOT (via run-all.sh).
set -euo pipefail

echo "[15] pinning Sky1-Linux Mesa 26 stack"

# 1001 = strictly higher than apt default (990) for any candidate, so it
# wins even when resolute has a numerically-newer point version.
install -d -m 0755 /etc/apt/preferences.d

cat > /etc/apt/preferences.d/99-sky1-mesa26.pref <<'PIN'
# r75 K4 / r78 resolute: pin Sky1-Linux Mesa 26 packages when available.
# Resolute stock Mesa is 26.0.3; Sky1 packages still carry the validated
# board-specific integration.
# Source: https://github.com/Sky1-Linux/sky1-image-build (Sky1-Linux apt repo).

Package: mesa-vulkan-drivers
Pin: version 26*-1sky1*
Pin-Priority: 1001

Package: mesa-libgallium
Pin: version 26*-1sky1*
Pin-Priority: 1001

Package: libgl1-mesa-dri
Pin: version 26*-1sky1*
Pin-Priority: 1001

Package: libegl-mesa0
Pin: version 26*-1sky1*
Pin-Priority: 1001

Package: libgbm1
Pin: version 26*-1sky1*
Pin-Priority: 1001

Package: libglapi-mesa
Pin: version 26*-1sky1*
Pin-Priority: 1001

Package: libosmesa6
Pin: version 26*-1sky1*
Pin-Priority: 1001

# libdisplay-info3 is needed by the Sky1-Linux Mesa 26 package set.
# The Sky1-Linux apt repo provides libdisplay-info3 when stock Ubuntu does not.
# r75 Codex MED fix — version-glob the sky1 suffix so random apt origins
# offering the same package name cannot outrank this priority-1001 pin.
Package: libdisplay-info3
Pin: version *sky1*
Pin-Priority: 1001

# libllvm21 — Mesa 26's gallium-drivers can depend on this; Sky1-Linux
# ships 21 alongside the stack (epoch 1: prefix is the
# Debian/Ubuntu llvm package convention).
Package: libllvm21
Pin: version *sky1*
Pin-Priority: 1001
PIN

echo "[15] /etc/apt/preferences.d/99-sky1-mesa26.pref written"
echo
echo "[15] verify with: apt-cache policy mesa-vulkan-drivers"
echo

# Best-effort show: only run apt-cache policy if apt has any sources.
# In offline-only post-install mode this just confirms the pin file
# parses (apt-config validates the pref file).
if apt-config dump 2>&1 | grep -q "Dir::Etc::sourceparts"; then
    apt-cache policy mesa-vulkan-drivers 2>&1 | head -10 | sed 's/^/    /' || true
fi
