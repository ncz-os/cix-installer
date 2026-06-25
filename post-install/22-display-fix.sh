#!/bin/bash
# 22-display-fix.sh — Sky1 DRM card numbering shifts between boots due to
# driver-init race. Detector runs at every boot AFTER udev-settle, with a
# 30-second retry loop because Sky1 linlondp probes asynchronously.
# CRITICAL: never wipes existing Xorg config when no display is detected
# (otherwise a transient detection failure bricks the next boot).
set -euo pipefail

echo "[22] installing dynamic primary-display detector + Xorg config"

VARIANT=desktop
if [ -f /usr/local/lib/cix-installer/BUILD_VARIANT ]; then
    VARIANT=$(tr -d ' \t\r\n' < /usr/local/lib/cix-installer/BUILD_VARIANT)
fi
case "$VARIANT" in
    server|magnetar|headless)
        echo "[22] BUILD_VARIANT=server - Magnetar headless SKU; skipping Xorg display detector"
        exit 0
        ;;
esac

install -d /usr/local/lib/cix-installer
cat > /usr/local/lib/cix-installer/detect-primary-display.sh <<'DET'
#!/bin/sh
LOG=/var/log/ncx-display-detect.log
exec >>"$LOG" 2>&1
echo "=== $(date -u) ==="

CONN_CARD=""; CONN_OUTPUT=""
# 30s retry loop: Sky1 DRM probe is async, cards may not all be enumerated
# at the moment this runs from systemd-udev-settle.service.
for try in 1 2 3 4 5 6; do
    for c in /sys/class/drm/card*-DP-* /sys/class/drm/card*-HDMI-*; do
        [ -e "$c/status" ] || continue
        if [ "$(cat $c/status 2>/dev/null)" = "connected" ]; then
            CONN_CARD=$(echo "$c" | sed -nE "s|^/sys/class/drm/(card[0-9]+)-.*|\\1|p")
            CONN_OUTPUT=$(basename "$c" | sed -nE "s|^card[0-9]+-(.*)|\\1|p")
            break 2
        fi
    done
    sleep 5
done

if [ -z "$CONN_CARD" ]; then
    # NEVER wipe existing Xorg config — a transient detect-fail must not brick the next boot.
    echo "  no connected display this boot — keeping existing config"
    exit 0
fi

echo "  connected: $CONN_CARD ($CONN_OUTPUT)"

mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/10-cixmini-primary-display.conf <<XCONF
Section "ServerLayout"
    Identifier "Cixmini"
    Screen "PrimaryScreen"
EndSection
Section "Device"
    Identifier "PrimaryDevice"
    Driver "modesetting"
    Option "kmsdev" "/dev/dri/$CONN_CARD"
EndSection
Section "Screen"
    Identifier "PrimaryScreen"
    Device "PrimaryDevice"
    Monitor "PrimaryMonitor"
    DefaultDepth 24
    SubSection "Display"
        Depth 24
    EndSubSection
EndSection
Section "Monitor"
    Identifier "PrimaryMonitor"
    Option "DPMS" "false"
EndSection
Section "ServerFlags"
    Option "BlankTime"   "0"
    Option "StandbyTime" "0"
    Option "SuspendTime" "0"
    Option "OffTime"     "0"
    Option "AutoAddGPU"  "false"
    Option "DefaultServerLayout" "Cixmini"
EndSection
XCONF

{
  echo "# Auto-generated $(date -u) — keep master-of-seat ONLY on $CONN_CARD"
  for n in 0 1 2 3 4 5 6 7; do
      [ "card$n" = "$CONN_CARD" ] && continue
      echo "ACTION==\"add|change\", SUBSYSTEM==\"drm\", KERNEL==\"card$n\", TAG-=\"master-of-seat\", TAG-=\"seat\""
      echo "ACTION==\"add|change\", SUBSYSTEM==\"drm\", KERNEL==\"card$n-*\", TAG-=\"master-of-seat\", TAG-=\"seat\""
  done
} > /etc/udev/rules.d/73-cixmini-primary-display.rules
udevadm control --reload-rules 2>/dev/null
echo "  -> /dev/dri/$CONN_CARD pinned"
DET
chmod 0755 /usr/local/lib/cix-installer/detect-primary-display.sh

cat > /etc/systemd/system/cix-detect-display.service <<UNIT
[Unit]
Description=NCX Sky1 connected-display autodetect
DefaultDependencies=no
After=systemd-udev-settle.service
Before=display-manager.service lightdm.service basic.target
RequiresMountsFor=/var/log

[Service]
Type=oneshot
ExecStart=/usr/local/lib/cix-installer/detect-primary-display.sh
RemainAfterExit=true
TimeoutStartSec=60

[Install]
WantedBy=sysinit.target
UNIT
systemctl enable cix-detect-display.service 2>&1 | tail -1

# Mask the CIX factory display watchdog. cix-debian-misc ships
# cix-check-display.service -> /usr/bin/restart-display, hardcoded to
# GNOME/gdm3; on our lightdm+XFCE stack it fails every boot with
# "Unit gdm3.service not found" (operator-reported 2026-06-25 on r131).
# Our cix-detect-display.service above handles display bring-up. Mask via a
# /etc symlink to /dev/null so it wins even though cix-debian-misc installs
# later (25-cix-proprietary.sh).
ln -sf /dev/null /etc/systemd/system/cix-check-display.service
echo "[22] masked vendor cix-check-display.service (GNOME-only; we use lightdm+XFCE)"

# Run once during install
/usr/local/lib/cix-installer/detect-primary-display.sh

echo "[22] dynamic primary-display detector installed (retry loop + safe-on-fail)"
