#!/bin/bash
# 56-icon-theme.sh — NeXT-style black-hole trash icon. NCZ inherits Adwaita.
set -euo pipefail

echo "[56] installing NCZ icon theme (black-hole user-trash)"

VARIANT=desktop
if [ -f /usr/local/lib/cix-installer/BUILD_VARIANT ]; then
    VARIANT=$(tr -d ' \t\r\n' < /usr/local/lib/cix-installer/BUILD_VARIANT)
fi
case "$VARIANT" in
    server|magnetar|headless)
        echo "[56] BUILD_VARIANT=server - Magnetar headless SKU; skipping desktop icon theme"
        exit 0
        ;;
esac

ASSETS=/usr/local/lib/cix-installer/assets/branding/icon-theme
# Source dir is named "NCX" historically (NeXT homage); destination is the
# canonical NCZ brand. r74 had \$ASSETS/NCZ literal-escape that always
# tested the literal string "$ASSETS/NCZ" and silently exited 0, so the
# icon theme never installed. Find whichever source dir is present.
SRC=""
for candidate in "$ASSETS/NCZ" "$ASSETS/NCX"; do
    if [ -d "$candidate" ]; then SRC="$candidate"; break; fi
done
if [ -z "$SRC" ]; then
    echo "[56] WARN: NCZ/NCX icon theme assets missing under $ASSETS — skipping"
    exit 0
fi

# Always install under /usr/share/icons/NCZ — the canonical brand path
# referenced by 50-brand.sh, xsettings, and the GNOME dconf override below.
rm -rf /usr/share/icons/NCZ
cp -r "$SRC" /usr/share/icons/NCZ
chmod -R a+r /usr/share/icons/NCZ
find /usr/share/icons/NCZ -type d -exec chmod a+rx {} \;

# Update icon caches so apps pick up the override
gtk-update-icon-cache /usr/share/icons/NCZ 2>/dev/null || true
gtk-update-icon-cache /usr/share/icons/Adwaita 2>/dev/null || true
gtk-update-icon-cache /usr/share/icons/hicolor 2>/dev/null || true

# === Set NCZ as default icon theme — both XFCE and GNOME ===
# GNOME default-set via dconf
install -d /etc/dconf/db/local.d
# r74 stale-brand cleanup: dconf db file + theme name now use NCZ to match
# /usr/share/icons/NCZ install path + 50-brand.sh icon-theme-name=NCZ.
# The 02-ncx-icon-theme legacy file is removed if present so dconf-update
# doesn't merge two competing settings.
rm -f /etc/dconf/db/local.d/02-ncx-icon-theme
cat > /etc/dconf/db/local.d/02-ncz-icon-theme <<'GNOME'
[org/gnome/desktop/interface]
icon-theme='NCZ'
GNOME

# XFCE default-set via xfconf channel xsettings
# (per-user; landed via /etc/skel xfconf override)
install -d /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml
cat > /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml <<'XSET'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xsettings" version="1.0">
  <property name="Net" type="empty">
    <property name="IconThemeName" type="string" value="NCZ"/>
    <property name="ThemeName" type="string" value="Greybird-dark"/>
  </property>
  <property name="Gtk" type="empty">
    <property name="IconSizes" type="string" value=""/>
    <property name="ApplicationPreferDarkTheme" type="bool" value="true"/>
  </property>
</channel>
XSET

# XFCE window-manager (xfwm4) dark decorations. Without this the WM keeps the
# stock light "Default" theme, so titlebars/borders stay light even with a dark
# GTK theme + dark icons (operator explicitly wanted dark window elements).
# Greybird-dark is the classic Xubuntu dark WM theme (shipped by xubuntu-core)
# and matches the LightDM greeter set in 20-desktop.sh. use_compositing=false
# keeps the WM stable on Mali-G720 (panthor) software-GL.
cat > /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml <<'XFWMEOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="theme" type="string" value="Greybird-dark"/>
    <property name="use_compositing" type="bool" value="false"/>
  </property>
</channel>
XFWMEOF

dconf update 2>/dev/null || true

echo "[56] icon theme installed at /usr/share/icons/NCZ"
echo "    GNOME default set via /etc/dconf/db/local.d/02-ncz-icon-theme"
echo "    XFCE default set via /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml"

# === r55: rewrite NCX index.theme with Inherits= so Qt apps (LXQt) cascade ===
# Without Inherits=, Qt icon engine treats NCX as standalone and shows broken
# icons for everything except the 10 places/* assets we ship.
cat > /usr/share/icons/NCZ/index.theme <<'INDEX'
[Icon Theme]
Name=NCZ
Comment=NCZ 26.6 Reinhardt black-hole trash + elementary-xfce-dark fallback
Inherits=elementary-xfce-dark,elementary-xfce,Adwaita-dark,Adwaita,hicolor
Directories=places/scalable,places/256,places/128,places/96,places/64,places/48,places/32,places/24,places/22,places/16,scalable

[places/scalable]
Size=512
Context=Places
Type=Scalable
MinSize=8
MaxSize=512

[places/256]
Size=256
Context=Places
Type=Fixed

[places/128]
Size=128
Context=Places
Type=Fixed

[places/96]
Size=96
Context=Places
Type=Fixed

[places/64]
Size=64
Context=Places
Type=Fixed

[places/48]
Size=48
Context=Places
Type=Fixed

[places/32]
Size=32
Context=Places
Type=Fixed

[places/24]
Size=24
Context=Places
Type=Fixed

[places/22]
Size=22
Context=Places
Type=Fixed

[places/16]
Size=16
Context=Places
Type=Fixed

[scalable]
Size=512
Context=Places
Type=Scalable
MinSize=8
MaxSize=512
INDEX
gtk-update-icon-cache -f -t /usr/share/icons/NCZ 2>&1 | tail -1 || true



# === r55: MATE — set icon-theme via dconf ===
cat >> /etc/dconf/db/local.d/02-ncz-icon-theme <<'MATE'

MATE
dconf update 2>/dev/null || true

echo "[56] LXQt/MATE icon-theme + Inherits= cascade applied"
