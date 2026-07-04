#!/bin/bash
# 55-greeter.sh — LightDM GTK greeter: DARK theme + MAGENTA NCZ brand avatar.
#
# r181 (operator, .66 metal): the greeter (login screen) came up in the stock
# light theme with a default user avatar, because the greeter config lived in
# 20-desktop.sh — which is deliberately NOT baked into the layered-squashfs
# desktop build (its `apt purge --auto-remove` ran maintainer scripts that
# corrupted the installed user DB inside the overlay chroot: the r166-r170
# saga). This hook carries ONLY the safe, cosmetic greeter config:
#   (#3) pin a dark GTK theme (Greybird-dark, ships with xubuntu-core) + dark
#        icons (elementary-xfce-dark), and
#   (#4) install a magenta NCZ avatar as the default user face.
# No apt, no purge, no display-manager churn — safe to run in the overlay.
#
# RUNS INSIDE CHROOT (build-squashfs-layers.sh desktop loop / run-all.sh).
set +e

echo "[55] LightDM greeter: dark theme + magenta NCZ avatar"

VARIANT=desktop
[ -f /usr/local/lib/cix-installer/BUILD_VARIANT ] && \
    VARIANT=$(tr -d ' \t\r\n' < /usr/local/lib/cix-installer/BUILD_VARIANT)
case "$VARIANT" in
    server|magnetar|headless)
        echo "[55] BUILD_VARIANT=$VARIANT — headless SKU; skipping greeter theming"
        exit 0
        ;;
esac

# --- (#3) DARK greeter theme -----------------------------------------------
# lightdm-gtk-greeter merges [greeter] keys across conf.d/ in sort order; the
# wallpaper rotator owns `background` in 55-ncz-rotate.conf. We own theme/icon/
# avatar in a lower-sorting file so it never fights the rotator's background.
install -d -m0755 /etc/lightdm/lightdm-gtk-greeter.conf.d
cat > /etc/lightdm/lightdm-gtk-greeter.conf.d/50-ncz-dark.conf <<'GTKG'
[greeter]
theme-name=Greybird-dark
icon-theme-name=elementary-xfce-dark
default-user-image=/usr/share/pixmaps/ncz-avatar-magenta.png
user-background=false
GTKG

# Belt: also ship a dark fallback background so the greeter is never bright even
# before the rotator paints the cosmic wallpaper (NCZ charcoal).
install -d -m0755 /usr/share/backgrounds/ncz

# --- (#4) MAGENTA NCZ avatar (brand = magenta) -----------------------------
AV=/usr/share/pixmaps/ncz-avatar-magenta.png
cat > /tmp/ncz-avatar-magenta.svg <<'AVSVG'
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256">
  <defs>
    <radialGradient id="mg" cx="50%" cy="40%" r="70%">
      <stop offset="0%" stop-color="#ff5fbf"/>
      <stop offset="45%" stop-color="#e0218a"/>
      <stop offset="100%" stop-color="#5c0836"/>
    </radialGradient>
    <radialGradient id="disk" cx="50%" cy="50%" r="55%">
      <stop offset="52%" stop-color="#000000"/>
      <stop offset="70%" stop-color="#ff9ad6"/>
      <stop offset="100%" stop-color="#e0218a"/>
    </radialGradient>
  </defs>
  <rect width="256" height="256" rx="40" fill="url(#mg)"/>
  <ellipse cx="128" cy="120" rx="94" ry="30" fill="none" stroke="url(#disk)" stroke-width="11" opacity="0.9"/>
  <circle cx="128" cy="112" r="42" fill="#12000a"/>
  <circle cx="128" cy="112" r="42" fill="none" stroke="#ff9ad6" stroke-width="2" opacity="0.85"/>
  <text x="128" y="214" font-family="DejaVu Sans, sans-serif" font-size="42" font-weight="bold" text-anchor="middle" fill="#ffffff">NCZ</text>
</svg>
AVSVG

if command -v rsvg-convert >/dev/null 2>&1; then
    rsvg-convert -w 256 -h 256 /tmp/ncz-avatar-magenta.svg -o "$AV" 2>/dev/null
elif command -v magick >/dev/null 2>&1; then
    magick -background none /tmp/ncz-avatar-magenta.svg "$AV" 2>/dev/null
elif command -v convert >/dev/null 2>&1; then
    convert -background none /tmp/ncz-avatar-magenta.svg "$AV" 2>/dev/null
fi

if [ -f "$AV" ]; then
    chmod 0644 "$AV"
    # default face for every NEW user (skel)
    cp -f "$AV" /etc/skel/.face 2>/dev/null && chmod 0644 /etc/skel/.face 2>/dev/null
    # apply to any EXISTING operator user + AccountsService (greeter reads this)
    install -d /var/lib/AccountsService/icons /var/lib/AccountsService/users
    for d in /home/*; do
        [ -d "$d" ] || continue
        u=$(stat -c %U "$d" 2>/dev/null) || continue
        [ "$u" = "UNKNOWN" ] && continue
        cp -f "$AV" "$d/.face" 2>/dev/null && chown "$u:$u" "$d/.face" 2>/dev/null
        cp -f "$AV" "/var/lib/AccountsService/icons/$u" 2>/dev/null
        if [ -f "/var/lib/AccountsService/users/$u" ] && grep -q '^Icon=' "/var/lib/AccountsService/users/$u" 2>/dev/null; then
            sed -i "s|^Icon=.*|Icon=/var/lib/AccountsService/icons/$u|" "/var/lib/AccountsService/users/$u"
        else
            printf '[User]\nIcon=/var/lib/AccountsService/icons/%s\nSystemAccount=false\n' "$u" \
                > "/var/lib/AccountsService/users/$u"
        fi
    done
    echo "[55] magenta NCZ avatar installed ($AV) + default/user face set"
else
    echo "[55] WARN: could not render magenta avatar (no rsvg-convert/imagemagick)"
fi

echo "[55] greeter themed: Greybird-dark + elementary-xfce-dark + magenta NCZ avatar"
