#!/bin/bash
# 20-desktop.sh — GNOME desktop + chromium + Wayland-native RDP.
#
# Apt-installs the same set Cix's stock factory image ships, layered
# on top of our base install. apt resolves all deps from Debian's
# bookworm + cix non-free + bookworm-updates archives.
set -euo pipefail

echo "[20] desktop layer (GNOME + chromium + RDP)"

apt-get update -q

# Core desktop
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    gnome-core \
    gdm3 \
    gnome-terminal \
    gnome-system-monitor \
    gnome-text-editor \
    gnome-disk-utility \
    gnome-keyring \
    gnome-tweaks \
    nautilus \
    network-manager-gnome \
    pipewire \
    wireplumber \
    pavucontrol \
    fonts-dejavu \
    fonts-liberation \
    fonts-noto \
    fonts-noto-color-emoji \
    xdg-utils \
    xdg-user-dirs

# Browser
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    chromium

# RDP — Wayland-native
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    gnome-remote-desktop || \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends xrdp

# Default to graphical login
systemctl set-default graphical.target

# Enable gdm
systemctl enable gdm3 || systemctl enable gdm
