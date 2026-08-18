#!/bin/bash
# 45-wallpaper-rotator.sh - install 7 NCZ wallpapers + auto-rotate
# every 10 minutes. r55: instant apply on login (was 30s) + xrandr-driven monitor
# discovery so wallpaper sticks across xfconf monitor-name shifts.
set -euo pipefail

echo "[45] installing 7 NCZ wallpapers + 10-minute autoswitcher"

VARIANT=desktop
if [ -f /usr/local/lib/cix-installer/BUILD_VARIANT ]; then
    VARIANT=$(tr -d ' \t\r\n' < /usr/local/lib/cix-installer/BUILD_VARIANT)
fi
case "$VARIANT" in
    server|headless)
        echo "[45] BUILD_VARIANT=server - Server headless SKU; skipping wallpaper rotator"
        exit 0
        ;;
esac

ASSETS=/usr/local/lib/cix-installer/assets/branding/wallpaper
DEST=/usr/share/backgrounds/ncz
mkdir -p "$DEST"
for f in "$ASSETS"/ncz-wallpaper-*-2k.jpg; do
    [ -f "$f" ] && install -m 0644 "$f" "$DEST/"
done
# Default = the Maximilian backdrop (26.7 release wallpaper).
ln -sfn ncz-wallpaper-07-maximilian-blackhole-2k.jpg "$DEST/default.jpg"

# Rotator: pick + apply. 26.7 default DE = Singularity (Wayland, GTK4): set the
# backdrop via `dev.sinty.desktop background-picture-uri` (gsettings) and swaybg.
cat > /usr/local/bin/ncz-wallpaper-rotate <<'ROT'
#!/bin/sh
WP_DIR=/usr/share/backgrounds/ncz
PIC=$(ls $WP_DIR/ncz-wallpaper-*.jpg 2>/dev/null | shuf -n1)
[ -z "$PIC" ] && exit 0
# default.jpg is a convenience pointer, not the mechanism -- the wallpaper is
# applied through gsettings/swaybg below. The rotator runs as the logged-in
# user and $WP_DIR is root-owned 0755, so this ln FAILS with EPERM every time.
# It was already suppressed with "|| true", which turned a guaranteed failure
# into silence. Only attempt it when the directory is actually writable.
if [ -w "$WP_DIR" ]; then
    ln -sfn "$(basename "$PIC")" "$WP_DIR/default.jpg" 2>/dev/null || true
fi

DE=""
case "${XDG_CURRENT_DESKTOP:-}${DESKTOP_SESSION:-}" in
    *Singularity*|*singularity*) DE=singularity ;;
    *GNOME*|*gnome*)      DE=gnome ;;
esac
if [ -z "$DE" ]; then
    if   pgrep -u "$USER" -x singularity-desktop >/dev/null 2>&1; then DE=singularity
    elif pgrep -u "$USER" -x gnome-shell >/dev/null 2>&1; then DE=gnome
    fi
fi

case "$DE" in
    singularity)
        URI="file://$PIC"
        # Singularity reads dev.sinty.desktop; its schema lives in the isolated
        # /opt/singularity prefix, so point gsettings at that schema dir.
        SSD=/opt/singularity/share/glib-2.0/schemas
        if command -v gsettings >/dev/null 2>&1 && [ -d "$SSD" ]; then
            GSETTINGS_SCHEMA_DIR="$SSD" gsettings set dev.sinty.desktop background-picture-uri "$URI" 2>/dev/null || true
        fi
        # Belt: repaint the live wallpaper layer via swaybg (single instance).
        if command -v swaybg >/dev/null 2>&1 && [ -n "${WAYLAND_DISPLAY:-}" ]; then
            pkill -x swaybg 2>/dev/null || true
            swaybg -m fill -i "$PIC" >/dev/null 2>&1 &
        fi
        ;;
    gnome)
        URI="file://$PIC"
        gsettings set org.gnome.desktop.background picture-uri "$URI" 2>/dev/null || true
        gsettings set org.gnome.desktop.background picture-uri-dark "$URI" 2>/dev/null || true
        gsettings set org.gnome.desktop.background picture-options zoom 2>/dev/null || true
        ;;
esac
echo "$PIC" > ${XDG_RUNTIME_DIR:-/tmp}/ncz-wallpaper-state 2>/dev/null
ROT
chmod 0755 /usr/local/bin/ncz-wallpaper-rotate

# Daemon: 2s warm-up (was 30s), then rotate every 10 min
cat > /usr/local/bin/ncz-wallpaper-daemon <<'DAEMON'
#!/bin/sh
# r110: single-instance guard so session restarts don't stack daemons
LOCK="${XDG_RUNTIME_DIR:-/tmp}/ncz-wallpaper-daemon.lock"
if [ -e "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; then exit 0; fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT
sleep 2
/usr/local/bin/ncz-wallpaper-rotate
while true; do
    sleep 600
    /usr/local/bin/ncz-wallpaper-rotate
done
DAEMON
chmod 0755 /usr/local/bin/ncz-wallpaper-daemon

# HOW THINGS ACTUALLY START IN THIS SESSION.
#
# MEASURED on an O6N running the shipped image, 2026-08-18: NOTHING processes
# /etc/xdg/autostart here. There is no dex, no xdg-autostart-generator, no
# gnome-session or lxsession, and no xdg-desktop-autostart.target among the
# user units. An autostart .desktop is therefore inert -- which is why the
# wallpaper rotator was installed, correct, and had never once run.
#
# The session is systemd --user driven. The active user targets are basic,
# default, paths, sockets and timers. graphical-session.target is NOT active,
# and singularity-session.target -- which the session script tries to start --
# does not exist as a unit at all. So default.target is the only reliable
# anchor, and `systemctl --global enable` is what applies a user unit to every
# account without needing a per-user enable at first login.
#
# The .desktop file is still written: it costs nothing and is the correct
# mechanism on desktops that DO honour it. It is a fallback here, not the
# mechanism.

install -d /usr/lib/systemd/user
cat > /usr/lib/systemd/user/ncz-wallpaper-rotator.service <<'UNIT'
[Unit]
Description=NCZ wallpaper rotator
PartOf=graphical-session.target
After=graphical-session.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ncz-wallpaper-daemon
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
UNIT
chmod 0644 /usr/lib/systemd/user/ncz-wallpaper-rotator.service

if systemctl --global enable ncz-wallpaper-rotator.service >/dev/null 2>&1; then
    echo "[45]   enabled ncz-wallpaper-rotator.service for all users (systemd --global)"
else
    echo "[45]   WARN: could not globally enable ncz-wallpaper-rotator.service"
fi

# Fallback for desktops that honour XDG autostart. Inert on Singularity.
mkdir -p /etc/xdg/autostart
cat > /etc/xdg/autostart/ncz-wallpaper-rotator.desktop <<'AUTO'
[Desktop Entry]
Type=Application
Name=NCZ Wallpaper Rotator
Exec=/usr/local/bin/ncz-wallpaper-daemon
NoDisplay=true
StartupNotify=false
Terminal=false
AUTO

echo "[45] Singularity wallpaper rotator + autostart written (default = Maximilian)"

# Greeter background = the static NCZ Maximilian wallpaper installed by 55-greeter
# at the native greeter's fallback path /usr/share/backgrounds/singularity/
# default.png. The greeter is greetd + native singularity-greeter (Wayland/Mali,
# Cairo/loginui), which reads that fallback file — no lightdm conf.d, no regreet.
