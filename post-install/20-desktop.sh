#!/bin/bash
# 20-desktop.sh — GNOME desktop + chromium + Wayland-native RDP.
#
# Apt-installs the same set Cix's stock factory image ships, layered
# on top of our base install. apt resolves all deps from Debian's
# bookworm + cix non-free + bookworm-updates archives.
set -euo pipefail

echo "[20] desktop layer (GNOME + chromium + RDP)"

# Drop the d-i-injected `deb cdrom:[...]` line. By the time post-install
# runs, the install media is no longer available to the chroot via apt;
# a stale cdrom: entry makes every `apt-get update` exit non-zero with
# "does not have a Release file", which set -e then kills the hook.
# Comment-out is preferable to deletion so the line stays auditable.
sed -i 's|^deb cdrom:|# deb cdrom:|' /etc/apt/sources.list

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

# ------------------------------------------------------------------
# Brand the GDM login screen + GNOME default wallpaper
# ------------------------------------------------------------------
ASSETS=/usr/local/lib/cix-installer/assets/branding

# Stage canonical assets into /usr/share/nclawzero/branding/ — survives
# package upgrades that might overwrite /usr/share/backgrounds/ etc.
install -d /usr/share/nclawzero/branding
install -m 0644 "$ASSETS/gdm/background.jpg"       /usr/share/nclawzero/branding/gdm-background.jpg
install -m 0644 "$ASSETS/wallpaper/default.jpg"    /usr/share/nclawzero/branding/wallpaper-default.jpg
install -m 0644 "$ASSETS/logo/ncz-icon.jpg"        /usr/share/nclawzero/branding/ncz-icon.jpg
install -m 0644 "$ASSETS/logo/nclawzero-lockup.jpg" /usr/share/nclawzero/branding/nclawzero-lockup.jpg

# Convert ncz-icon to PNG for GDM logo (GNOME prefers PNG for logos)
apt-get install -y --no-install-recommends imagemagick >/dev/null 2>&1 || true
convert /usr/share/nclawzero/branding/ncz-icon.jpg \
        /usr/share/nclawzero/branding/ncz-icon.png 2>/dev/null || \
    cp /usr/share/nclawzero/branding/ncz-icon.jpg /usr/share/nclawzero/branding/ncz-icon.png

# GDM dconf override — login screen background + logo
install -d /etc/dconf/db/gdm.d
cat > /etc/dconf/db/gdm.d/01-nclawzero <<'GDM'
[org/gnome/login-screen]
logo='/usr/share/nclawzero/branding/ncz-icon.png'

[org/gnome/desktop/screensaver]
picture-uri='file:///usr/share/nclawzero/branding/gdm-background.jpg'

[org/gnome/desktop/background]
picture-uri='file:///usr/share/nclawzero/branding/gdm-background.jpg'
picture-uri-dark='file:///usr/share/nclawzero/branding/gdm-background.jpg'
picture-options='zoom'
GDM

install -d /etc/dconf/profile
cat > /etc/dconf/profile/gdm <<'PROF'
user-db:user
system-db:gdm
file-db:/usr/share/gdm/greeter-dconf-defaults
PROF

# GNOME desktop default wallpaper — first-login defaults via dconf
install -d /etc/dconf/db/local.d
cat > /etc/dconf/db/local.d/01-nclawzero-wallpaper <<'LOCAL'
[org/gnome/desktop/background]
picture-uri='file:///usr/share/nclawzero/branding/wallpaper-default.jpg'
picture-uri-dark='file:///usr/share/nclawzero/branding/wallpaper-default.jpg'
picture-options='zoom'
primary-color='#0b0f14'
secondary-color='#0b0f14'

[org/gnome/desktop/screensaver]
picture-uri='file:///usr/share/nclawzero/branding/wallpaper-default.jpg'
LOCAL

cat > /etc/dconf/profile/user <<'USERPROF'
user-db:user
system-db:local
USERPROF

dconf update || true
