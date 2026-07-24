#!/bin/bash
# 55-greeter.sh — NCZ-OS 26.7 SHIP greeter: greetd + regreet (GTK4, Mali).
#
# regreet renders on the CIX Mali GLES blob (libmali/libEGL_cix, no llvmpipe) on
# labwc — the same accelerated stack as the Singularity shell. GTK3 gtkgreet
# blackscreened on libmali; GTK4 regreet does not. NCZ-branded: Maximilian
# wallpaper, red accent (#e0121f) login/power buttons, "NCZ-OS Maximilian" title.
#
# 20-desktop.sh installs the regreet binary (/opt/regreet/bin/regreet), the
# /usr/local/bin/ncz-regreet-greeter wrapper (the critical GTK_USE_PORTAL=0 +
# dead-session-bus fix that stops GTK4 blocking 120s on xdg-desktop-portal), and
# makes greetd the display manager. THIS hook writes the greetd + regreet + labwc
# config. (lightdm is gone — Singularity is Wayland/Mali native.)
#
# RUNS INSIDE CHROOT (build-squashfs-layers.sh desktop loop).
set +e

echo "[55] greetd + regreet greeter (GTK4, Mali-accelerated)"

VARIANT=desktop
[ -f /usr/local/lib/cix-installer/BUILD_VARIANT ] && \
    VARIANT=$(tr -d ' \t\r\n' < /usr/local/lib/cix-installer/BUILD_VARIANT)
case "$VARIANT" in
    server|magnetar|headless)
        echo "[55] BUILD_VARIANT=$VARIANT — headless SKU; skipping greeter"
        exit 0
        ;;
esac

WALL=/usr/share/backgrounds/ncz/ncz-wallpaper-07-maximilian-blackhole-2k.jpg
ACCENT="#e0121f"

install -d -m0755 /etc/greetd

# --- greetd: run our regreet wrapper on VT7 as _greetd ---------------------
cat > /etc/greetd/config.toml <<'GREETD'
[terminal]
vt = 7

[default_session]
command = "/usr/local/bin/ncz-regreet-greeter"
user = "_greetd"
GREETD

# --- regreet config: NCZ Maximilian bg, dark, red-accent, title ------------
cat > /etc/greetd/regreet.toml <<REGTOML
[background]
path = "$WALL"
fit = "Cover"

[GTK]
application_prefer_dark_theme = true
theme_name = "Adwaita-dark"
icon_theme_name = "Adwaita"
cursor_theme_name = "Adwaita"
font_name = "Cantarell 14"

[commands]
reboot = [ "systemctl", "reboot" ]
poweroff = [ "systemctl", "poweroff" ]

[appearance]
greeting_msg = "NCZ-OS Maximilian"

[widget.clock]
format = "%a %d %b  %H:%M"
REGTOML

# --- regreet CSS: red accent on login/reboot/power + title -----------------
cat > /etc/greetd/regreet.css <<REGCSS
/* NCZ-OS Maximilian — red accent (#e0121f). regreet is GTK4/libadwaita. */
@define-color accent_color $ACCENT;
@define-color accent_bg_color $ACCENT;
@define-color accent_fg_color #ffffff;

button.suggested-action,
#login_button,
#reboot_button,
#poweroff_button {
  background-color: $ACCENT;
  background-image: none;
  color: #ffffff;
  font-weight: bold;
}
button.suggested-action:hover,
#login_button:hover {
  background-color: shade($ACCENT, 1.12);
}
/* Title / greeting */
label.title-label,
#greeting_label {
  color: #ffffff;
  font-weight: bold;
  font-size: 200%;
}
REGCSS

# --- labwc config for the greeter compositor -------------------------------
install -d -m0755 /etc/greetd/regreet-labwc
# autostart: launch regreet (greetd tears the greeter down when a session starts)
cat > /etc/greetd/regreet-labwc/autostart <<'LABAUTO'
#!/bin/sh
# Launch regreet on the greeter labwc. When regreet completes a login, greetd
# terminates this greeter process group and starts the user session.
exec /opt/regreet/bin/regreet
LABAUTO
chmod 0755 /etc/greetd/regreet-labwc/autostart

# minimal labwc rc.xml; maximize the greeter window so regreet fills the screen
cat > /etc/greetd/regreet-labwc/rc.xml <<'LABRC'
<?xml version="1.0"?>
<labwc_config>
  <core>
    <gap>0</gap>
  </core>
  <windowRules>
    <windowRule identifier="*">
      <action name="Maximize"/>
    </windowRule>
  </windowRules>
</labwc_config>
LABRC

cat > /etc/greetd/regreet-labwc/environment <<'LABENV'
XCURSOR_THEME=Adwaita
XCURSOR_SIZE=24
LABENV

# --- runtime dirs (owned _greetd) via tmpfiles + bake-time mkdir ------------
cat > /etc/tmpfiles.d/ncz-regreet.conf <<'TMPF'
d /var/log/regreet   0755 _greetd _greetd -
d /var/lib/regreet   0755 _greetd _greetd -
d /var/cache/regreet 0755 _greetd _greetd -
TMPF
# Create them now too (systemd-tmpfiles runs at boot; this covers first start).
for d in /var/log/regreet /var/lib/regreet /var/cache/regreet; do
    install -d -m0755 "$d"
    id _greetd >/dev/null 2>&1 && chown _greetd:_greetd "$d" 2>/dev/null || true
done

# --- session list = Singularity only (regreet reads wayland-sessions) -------
# 20-desktop already curated /usr/share/wayland-sessions to singularity.desktop
# and removed /usr/share/xsessions; nothing else to do here.

echo "[55] greetd+regreet wired: /etc/greetd/{config.toml,regreet.toml,regreet.css,regreet-labwc/}, tmpfiles, Maximilian bg, red accent $ACCENT"
