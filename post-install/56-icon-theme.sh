#!/bin/bash
# 56-icon-theme.sh — NeXT-style black-hole trash icon. NCZ inherits Adwaita.
set -euo pipefail

echo "[56] installing NCZ icon theme (black-hole user-trash)"

VARIANT=desktop
if [ -f /usr/local/lib/cix-installer/BUILD_VARIANT ]; then
    VARIANT=$(tr -d ' \t\r\n' < /usr/local/lib/cix-installer/BUILD_VARIANT)
fi
case "$VARIANT" in
    server|headless)
        echo "[56] BUILD_VARIANT=server - Server headless SKU; skipping desktop icon theme"
        exit 0
        ;;
esac

ASSETS=/usr/local/lib/cix-installer/assets/branding/icon-theme
# Source dir is named "NCZ" historically (NeXT homage); destination is the
# canonical NCZ brand. r74 had \$ASSETS/NCZ literal-escape that always
# tested the literal string "$ASSETS/NCZ" and silently exited 0, so the
# icon theme never installed. Find whichever source dir is present.
SRC=""
for candidate in "$ASSETS/NCZ" "$ASSETS/NCZ"; do
    if [ -d "$candidate" ]; then SRC="$candidate"; break; fi
done
if [ -z "$SRC" ]; then
    echo "[56] WARN: NCZ/NCZ icon theme assets missing under $ASSETS — skipping"
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

# === Set NCZ icon theme default (26.7: Singularity is the desktop) ===
# Singularity reads dev.sinty.desktop icon-theme (20-desktop's gschema override
# sets 'Singularity'); the NCZ theme here provides the black-hole trash + a
# GNOME/GTK fallback. Ship a GNOME dconf default too (harmless if unused).
install -d /etc/dconf/db/local.d
rm -f /etc/dconf/db/local.d/02-ncz-icon-theme
cat > /etc/dconf/db/local.d/02-ncz-icon-theme <<'GNOME'
[org/gnome/desktop/interface]
icon-theme='NCZ'
GNOME
dconf update 2>/dev/null || true

echo "[56] icon theme installed at /usr/share/icons/NCZ (Singularity uses dev.sinty.desktop icon-theme)"

# === r55: rewrite NCZ index.theme with Inherits= so Qt apps (LXQt) cascade ===
# Without Inherits=, Qt icon engine treats NCZ as standalone and shows broken
# icons for everything except the 10 places/* assets we ship.
cat > /usr/share/icons/NCZ/index.theme <<'INDEX'
[Icon Theme]
Name=NCZ
Comment=NCZ 26.7 Maximilian black-hole trash + Adwaita fallback
Inherits=Adwaita-dark,Adwaita,hicolor
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
