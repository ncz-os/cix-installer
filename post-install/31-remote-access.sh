#!/bin/bash
# 31-remote-access.sh - NoMachine (preferred for Mali) + xrdp (fallback) for graphical remote access.
# r55: xrdp had broken WM (default startwm.sh ran /etc/X11/Xsession which didnt
# wrap with dbus-launch, plus xfwm4 compositor failed over RDP-side Xorg).
# Fixed both. NoMachine added as first-class option since NX protocol handles
# Mali GPU graceful-fallback better than xrdp.
set -euo pipefail

VARIANT="desktop"
if [ -f /usr/local/lib/cix-installer/BUILD_VARIANT ]; then
    VARIANT=$(tr -d ' \t\r\n' < /usr/local/lib/cix-installer/BUILD_VARIANT)
fi

case "$VARIANT" in
    server|magnetar|headless)
        echo "[31] BUILD_VARIANT=server - Magnetar headless SKU; skipping graphical remote access"
        exit 0
        ;;
esac

echo "[31] NoMachine + xrdp setup"

# === NoMachine 9.4 ARM64 ===
NM_URL="https://web9001.nomachine.com/download/9.4/Arm/nomachine_9.4.14_1_arm64.deb"
echo "  fetching NoMachine ARM64 .deb..."
if curl -fsSL -o /tmp/nomachine.deb "$NM_URL" && [ -s /tmp/nomachine.deb ]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y /tmp/nomachine.deb 2>&1 | tail -5
    rm -f /tmp/nomachine.deb
    echo "  NoMachine installed (port 4000)"
else
    echo "  WARN: NoMachine .deb fetch failed; xrdp will be the only RDP option"
fi

# === xrdp fix: dbus-launch + startxfce4 + disable xfwm4 compositor ===
cat > /etc/xrdp/startwm.sh <<'XRDP'
#!/bin/sh
# NCZ 26.6 xrdp session: XFCE with dbus-launch wrapper.
# Without dbus-launch the WM exits in <1s. Disable xfwm4 compositor -
# the RDP-side Xorg has no panthor/DRI, so GL accel attempts cause window-decoration glitches.
unset DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR
[ -r /etc/profile ] && . /etc/profile
[ -r ~/.profile ] && . ~/.profile
export XFWM4_USE_COMPOSITING=false
exec dbus-launch --exit-with-session startxfce4
XRDP
chmod 0755 /etc/xrdp/startwm.sh

# Disable xfwm4 compositor system-wide via /etc/skel xfconf
mkdir -p /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml
cat > /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml <<'XFWM'
<?xml version="1.1" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="use_compositing" type="bool" value="false"/>
    <property name="theme" type="string" value="Default"/>
    <property name="title_alignment" type="string" value="center"/>
  </property>
</channel>
XFWM

systemctl enable xrdp xrdp-sesman 2>&1 | tail -1
echo "[31] xrdp fixed (dbus-launch wrapper + xfwm4 compositor off)"
