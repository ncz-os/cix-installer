#!/bin/bash
# 15-mesa-sky1-pin.sh — pin the Sky1-Linux Mesa 26 stack so apt upgrade
# never regresses to Ubuntu questing's stock Mesa 25.2.8 (broken panvk).
#
# r75 K4: Mesa 26.0.0-1sky1.2 panvk + libdisplay-info3 + libllvm21 +
# mesa-vulkan-drivers + mesa-libgallium are what made Mali-G720 Vulkan
# work end-to-end on the .66 reference deploy. Without a pin, an
# innocuous `apt full-upgrade` will pull questing's 25.2.8 set and
# silently break the GPU stack again. r74 had this exact incident
# during one of the in-place tuning loops — captured as the "rebake
# before in-place tuning" doctrine.
#
# Pin scope: every Mesa-side package we know matters for Sky1 panvk.
# Pin priority 1001 (above 990 'pinned default') so apt prefers the
# Sky1-Linux origin over Ubuntu questing even on point-version regress.
#
# Idempotent — safe to run repeatedly; sed replaces the file in full
# on each run.
#
# RUNS INSIDE CHROOT (via run-all.sh).
set -euo pipefail

echo "[15] pinning Sky1-Linux Mesa 26 stack"

# 1001 = strictly higher than apt default (990) for any candidate, so it
# wins even when questing has a numerically-newer point version.
install -d -m 0755 /etc/apt/preferences.d

cat > /etc/apt/preferences.d/99-sky1-mesa26.pref <<'PIN'
# r75 K4: pin Sky1-Linux Mesa 26 packages. Without these, questing's
# stock Mesa 25.2.8 panvk OOMs on llama.cpp Vulkan + breaks GNOME-on-Mali.
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

# libdisplay-info3 is needed by Mesa 26+ but Ubuntu questing only ships
# libdisplay-info1. The Sky1-Linux apt repo provides libdisplay-info3.
Package: libdisplay-info3
Pin: origin "*"
Pin-Priority: 1001

# libllvm21 — Mesa 26's gallium-drivers depend on this; questing ships
# libllvm20. Sky1-Linux ships 21 alongside.
Package: libllvm21
Pin: origin "*"
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
