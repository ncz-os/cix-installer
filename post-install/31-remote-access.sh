#!/bin/bash
# 31-remote-access.sh — graphical remote access.
#
# Since 26.7 the desktop is Singularity (labwc/wlroots, WAYLAND). The
# old xrdp + startxfce4 path is X11-only and XFCE is gone, so it no longer
# applies. Wayland remote desktop is wayvnc (wlroots screencopy) against
# the labwc/Singularity session.
# SSH remains the always-on remote path; the local Singularity session is
# the GUI.
#
# WHAT THIS HOOK INSTALLS (desktop variants only):
#   wayvnc                                              VNC server for wlroots
#   /usr/lib/systemd/user/ncz-wayvnc.service            per-user unit, bound
#     to singularity-session.target, listening on 127.0.0.1 only, installed
#     but DISABLED by default (enable per user with
#     `systemctl --user enable ncz-wayvnc`).
# Server/headless variants skip, as before.
#
# Test seam (build/test-remote-access-wayvnc.sh): NCZ_RA_ROOT prefixes the
# wayvnc install paths; the hook never enables or starts the unit, so no
# enable seam is needed (the test asserts systemctl is never called for
# ncz-wayvnc). The stale-xrdp neutralisation below is also rooted under
# $ROOT so the whole hook runs under the seam.
set -euo pipefail

ROOT="${NCZ_RA_ROOT:-}"
VARIANT="desktop"
if [ -f "$ROOT/usr/local/lib/cix-installer/BUILD_VARIANT" ]; then
    VARIANT=$(tr -d ' \t\r\n' < "$ROOT/usr/local/lib/cix-installer/BUILD_VARIANT")
fi

case "$VARIANT" in
    server|headless)
        echo "[31] BUILD_VARIANT=$VARIANT — headless SKU; skipping graphical remote access"
        exit 0
        ;;
esac

echo "[31] graphical remote access: xrdp/XFCE path RETIRED (desktop is Wayland/Singularity)."
echo "[31] installing wayvnc (wlroots screencopy) with a disabled-by-default user unit"

# Neutralise any stale xrdp X11 session config a prior XFCE build left behind so
# it can't half-start a broken session. Both the probe AND the disable run
# under $ROOT: during image builds $ROOT points at the target rootfs, so a
# bare `systemctl disable` would wrongly touch the live build host.
if [ -f "$ROOT/etc/xrdp/startwm.sh" ] && grep -q startxfce4 "$ROOT/etc/xrdp/startwm.sh" 2>/dev/null; then
    if [ -n "$ROOT" ]; then
        systemctl --root="$ROOT" disable xrdp xrdp-sesman 2>/dev/null || true
    else
        systemctl disable xrdp xrdp-sesman 2>/dev/null || true
    fi
    echo "[31] disabled stale xfce-based xrdp session"
fi

DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends wayvnc

# Per-user unit, installed but DISABLED by default: no `systemctl enable`
# here (or --global), no wants symlink. Enable per user with
# `systemctl --user enable ncz-wayvnc`. Localhost only: wayvnc binds where told; 127.0.0.1 keeps the
# desktop off the LAN until the operator opts in.
install -d -m 0755 "$ROOT/usr/lib/systemd/user"
cat > "$ROOT/usr/lib/systemd/user/ncz-wayvnc.service" <<'EOF'
[Unit]
Description=NCZ Wayland remote desktop (wayvnc, localhost only)
Documentation=man:wayvnc(1)
PartOf=singularity-session.target graphical-session.target
After=singularity-session.target graphical-session.target

[Service]
Type=simple
ExecStart=/usr/bin/wayvnc 127.0.0.1
Restart=on-failure
RestartSec=5

[Install]
WantedBy=singularity-session.target
EOF
chmod 0644 "$ROOT/usr/lib/systemd/user/ncz-wayvnc.service"
echo "[31] ncz-wayvnc.service installed (disabled by default; localhost only)"
exit 0
