#!/bin/bash
# 55-wallpaper-rotator.sh — install 6 NCX FLUX-generated wallpapers + auto-rotate
# every 10 minutes. r55: instant apply on login (was 30s) + xrandr-driven monitor
# discovery so wallpaper sticks across xfconf monitor-name shifts.
set -euo pipefail

echo "[55] installing 6 NCZ wallpapers + 10-minute autoswitcher"

ASSETS=/usr/local/lib/cix-installer/assets/branding/wallpaper
DEST=/usr/share/backgrounds/ncz
mkdir -p "$DEST"
for f in "$ASSETS"/ncx-wallpaper-0*-2k.jpg; do
    [ -f "$f" ] && install -m 0644 "$f" "$DEST/"
done
ln -sfn ncx-wallpaper-01-cinematic-2k.jpg "$DEST/default.jpg"

# Rotator: pick + apply across DEs, use xrandr to discover live monitors
cat > /usr/local/bin/ncz-wallpaper-rotate <<'ROT'
#!/bin/sh
WP_DIR=/usr/share/backgrounds/ncz
PIC=$(ls $WP_DIR/ncx-wallpaper-0*.jpg 2>/dev/null | shuf -n1)
[ -z "$PIC" ] && exit 0
ln -sfn "$(basename "$PIC")" "$WP_DIR/default.jpg" 2>/dev/null || true

DE=""
case "${XDG_CURRENT_DESKTOP:-}${DESKTOP_SESSION:-}" in
    *XFCE*|*xfce*)        DE=xfce ;;
    *Openbox*|*openbox*)  DE=openbox ;;
    *Window*Maker*|*wmaker*) DE=wmaker ;;
esac
if [ -z "$DE" ]; then
    if   pgrep -u "$USER" -x xfdesktop >/dev/null 2>&1; then DE=xfce
    elif pgrep -u "$USER" -x wmaker    >/dev/null 2>&1; then DE=wmaker
    elif pgrep -u "$USER" -x openbox   >/dev/null 2>&1; then DE=openbox
    fi
fi

case "$DE" in
    xfce)
        for prop in $(xfconf-query -c xfce4-desktop -l 2>/dev/null | grep -E "/last-image$"); do
            xfconf-query -c xfce4-desktop -p "$prop" -s "$PIC" 2>/dev/null || true
        done
        if command -v xrandr >/dev/null 2>&1; then
            for OUT in $(xrandr 2>/dev/null | awk "/ connected/{print \$1}"); do
                xfconf-query -c xfce4-desktop -p "/backdrop/screen0/monitor${OUT}/workspace0/last-image" -t string -s "$PIC" --create 2>/dev/null || true
                xfconf-query -c xfce4-desktop -p "/backdrop/screen0/monitor${OUT}/workspace0/image-style" -t int -s 5 --create 2>/dev/null || true
            done
        fi
        ;;
    wmaker)  wmsetbg -s -u "$PIC" 2>/dev/null || true ;;
    openbox) feh --bg-fill "$PIC" 2>/dev/null || true ;;
esac
echo "$PIC" > ${XDG_RUNTIME_DIR:-/tmp}/ncz-wallpaper-state 2>/dev/null
ROT
chmod 0755 /usr/local/bin/ncz-wallpaper-rotate

# Daemon: 2s warm-up (was 30s), then rotate every 10 min
cat > /usr/local/bin/ncz-wallpaper-daemon <<'DAEMON'
#!/bin/sh
sleep 2
/usr/local/bin/ncz-wallpaper-rotate
while true; do
    sleep 600
    /usr/local/bin/ncz-wallpaper-rotate
done
DAEMON
chmod 0755 /usr/local/bin/ncz-wallpaper-daemon

# Autostart in XFCE/Openbox/WMaker sessions
mkdir -p /etc/xdg/autostart
cat > /etc/xdg/autostart/ncz-wallpaper-rotator.desktop <<'AUTO'
[Desktop Entry]
Type=Application
Name=NCZ Wallpaper Rotator
Exec=/usr/local/bin/ncz-wallpaper-daemon
NoDisplay=true
X-XFCE-Autostart-enabled=true
StartupNotify=false
Terminal=false
AUTO

# r55: pre-populate /etc/skel xfce4-desktop.xml with wallpaper on EVERY plausible monitor name
# so brand-new logins do not show default-blue while waiting for the daemon.
WP=/usr/share/backgrounds/ncz/default.jpg
mkdir -p /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml
{
    echo "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
    echo "<channel name=\"xfce4-desktop\" version=\"1.0\">"
    echo "  <property name=\"backdrop\" type=\"empty\">"
    echo "    <property name=\"screen0\" type=\"empty\">"
    for m in monitor0 monitor1 monitorDP-1 monitorDP-2 monitorDP-3 monitorDP-4 monitorDP-5 monitorDP-6 monitorHDMI-1 monitorHDMI-2 monitorVNC-0 monitorVirtual-1 monitorXineRama-0; do
        echo "      <property name=\"$m\" type=\"empty\">"
        for ws in workspace0 workspace1 workspace2 workspace3; do
            echo "        <property name=\"$ws\" type=\"empty\">"
            echo "          <property name=\"last-image\" type=\"string\" value=\"$WP\"/>"
            echo "          <property name=\"image-style\" type=\"int\" value=\"5\"/>"
            echo "        </property>"
        done
        echo "      </property>"
    done
    echo "    </property>"
    echo "  </property>"
    echo "  <property name=\"desktop-icons\" type=\"empty\">"
    echo "    <property name=\"style\" type=\"int\" value=\"2\"/>"
    echo "    <property name=\"file-icons\" type=\"empty\">"
    echo "      <property name=\"show-filesystem\" type=\"bool\" value=\"false\"/>"
    echo "      <property name=\"show-home\" type=\"bool\" value=\"true\"/>"
    echo "      <property name=\"show-trash\" type=\"bool\" value=\"true\"/>"
    echo "      <property name=\"show-removable\" type=\"bool\" value=\"true\"/>"
    echo "    </property>"
    echo "  </property>"
    echo "</channel>"
} > /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml

echo "[55] rotator + 13-monitor xfconf default written"
