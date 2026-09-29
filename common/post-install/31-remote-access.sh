#!/bin/bash
# 31-remote-access.sh — graphical remote access.
#
# 26.7 "Maximilian": the desktop is Singularity (labwc/wlroots, WAYLAND). The
# old xrdp + startxfce4 path is X11-only and XFCE is gone, so it no longer
# applies. Wayland remote desktop (wayvnc / labwc screencopy, or
# gnome-remote-desktop RDP) is a RELEASE-TRACK item — not wired for the beta.
# SSH remains the remote path; the local Singularity session is the GUI.
#
# TODO(release-track): ship wayvnc (wlroots screencopy) or the labwc RDP backend
# for headed remote access under Wayland.
set -euo pipefail

VARIANT="desktop"
if [ -f /usr/local/lib/cix-installer/BUILD_VARIANT ]; then
    VARIANT=$(tr -d ' \t\r\n' < /usr/local/lib/cix-installer/BUILD_VARIANT)
fi

case "$VARIANT" in
    server|headless)
        echo "[31] BUILD_VARIANT=$VARIANT — headless SKU; skipping graphical remote access"
        exit 0
        ;;
esac

echo "[31] graphical remote access: xrdp/XFCE path RETIRED (desktop is Wayland/Singularity)."
echo "[31] Wayland RDP/VNC (wayvnc / labwc screencopy) = release-track; SSH is the remote path for beta."

# Neutralise any stale xrdp X11 session config a prior XFCE build left behind so
# it can't half-start a broken session.
if [ -f /etc/xrdp/startwm.sh ] && grep -q startxfce4 /etc/xrdp/startwm.sh 2>/dev/null; then
    systemctl disable xrdp xrdp-sesman 2>/dev/null || true
    echo "[31] disabled stale xfce-based xrdp session"
fi
exit 0
