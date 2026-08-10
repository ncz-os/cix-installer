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
for f in "$ASSETS"/ncz-wallpaper-0*-2k.jpg; do
    [ -f "$f" ] && install -m 0644 "$f" "$DEST/"
done
# Default = the Maximilian backdrop (26.7 release wallpaper).
ln -sfn ncz-wallpaper-07-maximilian-blackhole-2k.jpg "$DEST/default.jpg"

# Rotator: pick + apply. 26.7 default DE = Singularity (Wayland, GTK4): set the
# backdrop via `dev.sinty.desktop background-picture-uri` (gsettings) and swaybg.
cat > /usr/local/bin/ncz-wallpaper-rotate <<'ROT'
#!/bin/sh
WP_DIR=/usr/share/backgrounds/ncz
PIC=$(ls $WP_DIR/ncz-wallpaper-0*.jpg 2>/dev/null | shuf -n1)
[ -z "$PIC" ] && exit 0
ln -sfn "$(basename "$PIC")" "$WP_DIR/default.jpg" 2>/dev/null || true

DE=""
case "${XDG_CURRENT_DESKTOP:-}${DESKTOP_SESSION:-}" in
    *Singularity*|*singularity*) DE=singularity ;;
    *GNOME*|*gnome*)      DE=gnome ;;
esac
if [ -z "$DE" ]; then
    # NOTE: `pgrep -x singularity-desktop` NEVER matches. Linux comm names are
    # capped at 15 characters, so the running process is "singularity-des" and
    # an exact-name match silently fails. That is exactly what happened: DE
    # stayed empty, the case below fell through without setting anything, and
    # the desktop booted with background-picture-uri = '' -- no wallpaper at
    # all, which read as "all branding customizations are lost". Match on the
    # full command line instead.
    if   pgrep -u "$USER" -f singularity-desktop >/dev/null 2>&1; then DE=singularity
    elif pgrep -u "$USER" -f gnome-shell >/dev/null 2>&1; then DE=gnome
    # Last resort: if the Singularity schema is installed, assume Singularity.
    elif [ -d /opt/singularity/share/glib-2.0/schemas ]; then DE=singularity
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

# Autostart. NOTE: the Singularity session does NOT process /etc/xdg/autostart.
# Measured on O6N after a clean boot -- EVERY entry in /etc/xdg/autostart was
# dead: blueman, geoclue-demo-agent, ncz-qotd, ncz-trust-desktop-icons,
# ncz-wallpaper-rotator and gsd-disk-utility-notify all showed no process. The
# only autostart-directory entries with a live process were at-spi and
# gnome-keyring, and those are D-Bus activated rather than launched from here.
# So the XDG entry alone silently started nothing, and three NCZ desktop
# features (wallpaper rotation, QOTD, desktop-icon trust) never ran.
#
# labwc DOES have its own autostart, sourced as a shell script, so drive the
# daemon from there. The XDG entry is kept as well: harmless where it is
# ignored, and correct on any session that does honour it.
mkdir -p /etc/xdg/labwc
LABWC_AUTOSTART=/etc/xdg/labwc/autostart
touch "$LABWC_AUTOSTART"
if ! grep -q 'ncz-wallpaper-daemon' "$LABWC_AUTOSTART" 2>/dev/null; then
    printf '%s\n' '/usr/local/bin/ncz-wallpaper-daemon &' >> "$LABWC_AUTOSTART"
fi
chmod 0644 "$LABWC_AUTOSTART"

mkdir -p /etc/xdg/autostart
cat > /etc/xdg/autostart/ncz-wallpaper-rotator.desktop <<'AUTO'
[Desktop Entry]
Type=Application
Name=NCZ Wallpaper Rotator
Exec=/usr/local/bin/ncz-wallpaper-daemon
NoDisplay=true
OnlyShowIn=Singularity;
StartupNotify=false
Terminal=false
AUTO

echo "[45] Singularity wallpaper rotator written (labwc autostart + XDG entry; default = Maximilian)"

# Greeter background = the static NCZ Maximilian wallpaper installed by 55-greeter
# at the native greeter's fallback path /usr/share/backgrounds/singularity/
# default.png. The greeter is greetd + native singularity-greeter (Wayland/Mali,
# Cairo/loginui), which reads that fallback file — no lightdm conf.d, no regreet.
