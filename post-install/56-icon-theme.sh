#!/bin/bash
# 56-icon-theme.sh — NeXT-style black-hole trash icon. NCX inherits Adwaita.
set -euo pipefail

echo "[56] installing NCZ icon theme (black-hole user-trash)"

ASSETS=/usr/local/lib/cix-installer/assets/branding/icon-theme
DEST=/usr/share/icons/NCZ
[ -d "\$ASSETS/NCZ" ] || { echo "[56] WARN: NCZ icon theme assets missing — skipping"; exit 0; }

cp -r "\$ASSETS/NCZ" /usr/share/icons/
chmod -R a+r /usr/share/icons/NCZ
find /usr/share/icons/NCZ -type d -exec chmod a+rx {} \;

# Update icon caches so apps pick up the override
gtk-update-icon-cache /usr/share/icons/NCZ 2>/dev/null || true
gtk-update-icon-cache /usr/share/icons/Adwaita 2>/dev/null || true
gtk-update-icon-cache /usr/share/icons/hicolor 2>/dev/null || true

# === Set NCX as default icon theme — both XFCE and GNOME ===
# GNOME default-set via dconf
install -d /etc/dconf/db/local.d
cat > /etc/dconf/db/local.d/02-ncx-icon-theme <<'GNOME'
[org/gnome/desktop/interface]
icon-theme='NCX'
GNOME

# XFCE default-set via xfconf channel xsettings
# (per-user; landed via /etc/skel xfconf override)
install -d /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml
cat > /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml <<'XSET'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xsettings" version="1.0">
  <property name="Net" type="empty">
    <property name="IconThemeName" type="string" value="NCZ"/>
    <property name="ThemeName" type="string" value="Adwaita-dark"/>
  </property>
  <property name="Gtk" type="empty">
    <property name="IconSizes" type="string" value=""/>
  </property>
</channel>
XSET

dconf update 2>/dev/null || true

echo "[56] icon theme installed at /usr/share/icons/NCZ"
echo "    GNOME default set via /etc/dconf/db/local.d/02-ncx-icon-theme"
echo "    XFCE default set via /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml"

# === r55: rewrite NCX index.theme with Inherits= so Qt apps (LXQt) cascade ===
# Without Inherits=, Qt icon engine treats NCX as standalone and shows broken
# icons for everything except the 10 places/* assets we ship.
cat > /usr/share/icons/NCZ/index.theme <<'INDEX'
[Icon Theme]
Name=NCX
Comment=NCZ 26.5 Reinhardt black-hole trash + Adwaita-dark fallback
Inherits=Adwaita-dark,Adwaita,elementary-xfce-dark,elementary-xfce,hicolor
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
cat >> /etc/dconf/db/local.d/02-ncx-icon-theme <<'MATE'

MATE
dconf update 2>/dev/null || true

echo "[56] LXQt/MATE icon-theme + Inherits= cascade applied"
