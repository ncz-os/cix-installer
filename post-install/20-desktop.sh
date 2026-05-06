#!/bin/bash
# 20-desktop.sh — XFCE on LightDM (questing's GDM/Wayland on Mali panthor → black screen).
# r52: LightDM + Xorg + XFCE = reliable; xrdp for remote access.
set -euo pipefail

echo "[20] desktop layer (XFCE + LightDM + xrdp)"

# Drop bogus cdrom-list left over from d-i + use online questing ports repo
rm -f /etc/apt/sources.list.d/cixmini-cdrom.list 2>/dev/null
cat > /etc/apt/sources.list <<'APT'
deb http://ports.ubuntu.com/ubuntu-ports questing main universe restricted multiverse
deb http://ports.ubuntu.com/ubuntu-ports questing-updates main universe restricted multiverse
deb http://ports.ubuntu.com/ubuntu-ports questing-security main universe restricted multiverse
deb http://ports.ubuntu.com/ubuntu-ports questing-backports main universe restricted multiverse
APT

apt-get update -q

# Pre-purge gdm3 if present in the rootfs.tar.zst (questing's default DM).
# Without this, both gdm3 and lightdm fight for /etc/systemd/system/display-manager.service
# and the resulting boot lands on a black screen.
if dpkg -l gdm3 2>/dev/null | grep -q '^ii'; then
    echo "[20] purging gdm3 (questing default DM, conflicts with lightdm)"
    DEBIAN_FRONTEND=noninteractive apt-get purge -y gdm3 ubuntu-session 2>&1 | tail -3 || true
    rm -f /etc/systemd/system/display-manager.service
fi

# Core: XFCE4 + LightDM (display manager) + Xorg fbdev fallback.
# r55: removed broken backslash-continuation that merged a bogus firefox
# install onto this command and made apt fail with "0 newly installed".
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    lightdm lightdm-gtk-greeter xubuntu-core xfce4-session xfce4-terminal \
    xfce4-power-manager xfce4-screenshooter xfce4-taskmanager \
    xserver-xorg-video-fbdev xserver-xorg-video-modesetting \
    xrdp \
    mesa-utils vulkan-tools libglu1-mesa

# r55: NCZ-curated screensaver. xscreensaver replaces xfce4-screensaver because
# xscreensaver's hack catalog (xanalogtv, galaxy, glmatrix, flyingtoasters,
# glslideshow over /usr/share/backgrounds/ncz) fits the NCZ cosmic+retro brand.
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    xscreensaver xscreensaver-data xscreensaver-data-extra \
    xscreensaver-gl xscreensaver-gl-extra 2>&1 | tail -3 || true
DEBIAN_FRONTEND=noninteractive apt-get remove -y xfce4-screensaver 2>&1 | tail -1 || true

# Configure LightDM defaults
mkdir -p /etc/lightdm/lightdm.conf.d
cat > /etc/lightdm/lightdm.conf.d/50-cixmini.conf <<'LIDM'
[Seat:*]
user-session=xfce
greeter-session=lightdm-gtk-greeter
greeter-show-manual-login=true
allow-guest=false
LIDM

# Mesa env: force panthor / panvk path for accelerated GL on Mali-G720
mkdir -p /etc/systemd/system/lightdm.service.d
cat > /etc/systemd/system/lightdm.service.d/cixmini-mesa.conf <<'MESA'
[Service]
Environment=MESA_LOADER_DRIVER_OVERRIDE=panthor
Environment=LIBGL_KOPPER_DRI2=1
MESA
grep -q '^MESA_LOADER_DRIVER_OVERRIDE' /etc/environment 2>/dev/null || cat >> /etc/environment <<'ENV'
MESA_LOADER_DRIVER_OVERRIDE=panthor
LIBGL_KOPPER_DRI2=1
ENV

# Mesa needs linlondp_dri.so (fake symlink to libdril dispatcher)
DRI=/usr/lib/aarch64-linux-gnu/dri
[ -e $DRI/libdril_dri.so ] && ln -sfn libdril_dri.so $DRI/linlondp_dri.so

# Disable GDM (we're using LightDM)
systemctl disable gdm gdm3 2>/dev/null || true
systemctl stop gdm gdm3 2>/dev/null || true
systemctl set-default graphical.target
systemctl enable lightdm
echo "/usr/sbin/lightdm" > /etc/X11/default-display-manager
DEBIAN_FRONTEND=noninteractive dpkg-reconfigure lightdm 2>&1 | tail -2 || true

# xrdp: use XFCE session
cat > /etc/xrdp/startwm.sh <<'XRDP'
#!/bin/sh
unset DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR
[ -r /etc/profile ] && . /etc/profile
exec dbus-launch --exit-with-session startxfce4
XRDP
chmod 0755 /etc/xrdp/startwm.sh
systemctl enable xrdp

# Skip gnome-initial-setup wizard (we already collected user creds via d-i)
install -d -m 0755 /etc/skel/.config
touch /etc/skel/.config/gnome-initial-setup-done

# r75 P1: ensure operator is in render,video,audio,plugdev,input groups
# for Vulkan (/dev/dri/renderD128), V4L2, audio, and removable-media access.
# r74 was missing this — Vulkan failed silently with 'Permission denied'
# until the operator manually ran usermod + logged out / back in.
#
# Discovery pattern matches 35-ssh.sh (first UID >= 1000 < 65000),
# with 'ncz' as explicit fallback.
OPERATOR_USER=$(awk -F: '$3 >= 1000 && $3 < 65000 {print $1; exit}' /etc/passwd)
if [ -z "$OPERATOR_USER" ] && id ncz >/dev/null 2>&1; then
    OPERATOR_USER=ncz
fi
if [ -n "$OPERATOR_USER" ] && id "$OPERATOR_USER" >/dev/null 2>&1; then
    # Add only the groups that already exist on the system. Some
    # (e.g. render) are package-installed later; usermod -aG against
    # a missing group hard-errors otherwise.
    for g in render video audio plugdev input; do
        if getent group "$g" >/dev/null 2>&1; then
            usermod -aG "$g" "$OPERATOR_USER" 2>&1 | sed 's/^/    /'
        else
            echo "    skip group '$g' — not yet present (often appears after later post-install hooks add the package)"
        fi
    done
    echo "[20] operator '$OPERATOR_USER' added to render/video/audio/plugdev/input (those that exist)"
else
    echo "[20] WARN: no operator user found for usermod — Vulkan/V4L2/audio may fail until added manually" >&2
fi

echo "[20] LightDM + XFCE + xrdp + Mesa panthor-override installed"

# r52+ session cleanup: hide all non-working session options.
# GNOME-on-Wayland, GNOME-on-Xorg, Ubuntu-on-Wayland, XFCE-on-Wayland, lightdm-Xsession,
# xubuntu duplicate — all bounce to black screen on Mali-G720 panthor.
# Only XFCE-on-Xorg works reliably. Hide the rest.
mkdir -p /usr/share/xsessions.disabled /usr/share/wayland-sessions.disabled
for f in /usr/share/wayland-sessions/*.desktop; do
    [ -f "$f" ] && mv "$f" /usr/share/wayland-sessions.disabled/ 2>/dev/null
done
for f in /usr/share/xsessions/gnome-xorg.desktop /usr/share/xsessions/lightdm-xsession.desktop /usr/share/xsessions/xubuntu.desktop /usr/share/xsessions/ubuntu*.desktop; do
    [ -f "$f" ] && mv "$f" /usr/share/xsessions.disabled/ 2>/dev/null
done
ls /usr/share/xsessions/ | head
echo "[20] only working session retained: xfce.desktop"

# r53: purge GNOME entirely (mutter/gnome-shell don't work on Mali Sky1 yet —
# r52 ships XFCE only). r53 might re-add GNOME via Sky1-Linux's mesa-sky1 + vk-compat-layer.
DEBIAN_FRONTEND=noninteractive apt-get purge -y --auto-remove \
    ubuntu-desktop-minimal gnome-tweaks gnome-shell gnome-shell-common \
    gnome-shell-extensions gnome-session gnome-session-bin gnome-session-common \
    gnome-session-canberra mutter gnome-control-center \
    gdm gdm3 nautilus xdg-desktop-portal-gtk xdg-desktop-portal-gnome \
    yelp 2>&1 | tail -3 || true

# Hide leftover wayland-sessions (broken on Mali)
mkdir -p /usr/share/wayland-sessions.disabled
for f in /usr/share/wayland-sessions/*.desktop; do
    [ -f "$f" ] && mv "$f" /usr/share/wayland-sessions.disabled/ 2>/dev/null
done

# Install upstream-watch agent
install -d /usr/local/lib/ncx /var/log/ncx /var/lib/ncx
install -m 0755 /usr/local/lib/cix-installer/assets/branding/ncx-upstream-watch.sh \
    /usr/local/lib/ncx/upstream-watch.sh

# systemd timer: every 6 hours
cat > /etc/systemd/system/ncx-upstream-watch.timer <<'UNIT'
[Unit]
Description=NCZ upstream Mali/Mesa/Cix/Sky1 driver watch
[Timer]
OnBootSec=15min
OnUnitActiveSec=6h
Persistent=true
[Install]
WantedBy=timers.target
UNIT
cat > /etc/systemd/system/ncx-upstream-watch.service <<'UNIT'
[Unit]
Description=NCZ upstream watcher (one-shot run)
[Service]
Type=oneshot
ExecStart=/usr/local/lib/ncx/upstream-watch.sh
UNIT
systemctl daemon-reload
systemctl enable --now ncx-upstream-watch.timer 2>&1 | tail -2 || true
echo "[20] GNOME purged, upstream-watch installed (every 6h)"

# r53: ncx-flavor-* metapackage shims — pre-stage apt info but DON'T install by default.
# Users who want alternative DEs run: apt install ncx-flavor-{openbox,wmaker}
# Each flavor metapackage pulls the right apt deps + writes session file.
# XFCE remains the default; alternatives are X11-native + work on Mali Sky1.
mkdir -p /usr/share/ncx/flavors
cat > /usr/share/ncx/flavors/README.md <<'README'
# NCZ Desktop Flavors

NCZ 26.5 "Reinhardt" ships **XFCE** as the default desktop because it works
reliably on Cix Sky1 + Mali-G720. Four additional X11-native desktops are
available via apt (no Vulkan/Wayland deps; will work on this hardware):

| Flavor | Install | Brand fit |
|---|---|---|
| Window Maker (NeXTSTEP) | sudo apt install wmaker | PERFECT (NCZ = black-hole = NeXT) |
| Openbox | sudo apt install openbox | Bare WM |

After install, log out, then pick the flavor at the LightDM greeter (gear icon).

# What does NOT work yet (r52)

- GNOME (gnome-shell on Wayland) — blocked on Mesa panvk gaps + questing GDM-only Wayland
- KDE Plasma 6 — questing dropped X11 startplasma, Wayland-only
- Sway / Hyprland — Wayland deps, same panvk gaps
- Cinnamon — muffin (mutter fork), likely same issues

These are tracked by the upstream-watch agent (/usr/local/lib/ncx/upstream-watch.sh).
README
echo "[20] flavor docs at /usr/share/ncx/flavors/README.md"

# r54 browsers — Firefox snap is too slow on Mali; chromium-browser .deb is also a snap-stub.
# Real chromium via Flathub (arm64). Vivaldi as primary. Falkon + Epiphany as Qt/WebKit alternatives.
# Brave is amd64-only on apt — no ARM64 .deb published.
#
# Pre-create the Qt5 dir falkon's postinst expects (questing is Qt6-only by default; falkon postinst
# tries `ln -s ../hunspell-bdic /usr/share/qt5/qtwebengine_dictionaries` and fails without it).
mkdir -p /usr/share/qt5/qtwebengine_dictionaries

DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    falkon epiphany-browser flatpak gnome-software gnome-software-plugin-flatpak \
    gnome-keyring feh 2>&1 | tail -5 || true

# Vivaldi (ARM64 .deb auto-fetch latest version)
ARCH=$(dpkg --print-architecture)
VIVALDI_URL=$(curl -fsSL https://vivaldi.com/download/?platform=linux 2>/dev/null     | grep -oE "https://downloads.vivaldi.com/stable/vivaldi-stable_[^\"]*_${ARCH}.deb" | head -1)
if [ -n "$VIVALDI_URL" ]; then
    curl -fsSL -o /tmp/vivaldi.deb "$VIVALDI_URL" 2>&1 | tail -1
    DEBIAN_FRONTEND=noninteractive apt-get install -y /tmp/vivaldi.deb 2>&1 | tail -2 || echo "vivaldi: skipped"
    rm -f /tmp/vivaldi.deb
fi

# Flathub remote + real Chromium (arm64 Flatpak — works on Mali, sandboxed properly)
flatpak remote-add --if-not-exists --system flathub https://flathub.org/repo/flathub.flatpakrepo 2>&1 | tail -1 || true
# Install Chromium in background-friendly way (large download); --noninteractive guards
flatpak install -y --system flathub org.chromium.Chromium 2>&1 | tail -3 || echo "flatpak chromium: deferred (network or repo not yet reachable)"

# Replace the snap-redirect /usr/bin/chromium-browser stub with a wrapper that calls Vivaldi.
# Many .desktop files and scripts hardcode "chromium-browser"; this keeps them working.
DEBIAN_FRONTEND=noninteractive apt-get remove -y chromium-browser 2>&1 | tail -1 || true
cat > /usr/local/bin/chromium-browser <<'CHROMWRAP'
#!/bin/sh
# NCZ 26.5: chromium-browser snap-stub replaced by Vivaldi compat wrapper.
exec /usr/bin/vivaldi-stable "$@"
CHROMWRAP
chmod +x /usr/local/bin/chromium-browser

# Hide ALL snap-store launchers (App Center / show-updates) — App Center is broken on Mali.
# We installed gnome-software (.deb) as the real App Center.
for f in /var/lib/snapd/desktop/applications/snap-store_*.desktop; do
    [ -f "$f" ] || continue
    sed -i '/^NoDisplay=/d' "$f"
    echo "NoDisplay=true" >> "$f"
done

# Remove orphan plank-preferences launcher (plank dock not installed).
rm -f /usr/share/applications/plank-preferences.desktop

# Default web browser: Vivaldi (system-wide via update-alternatives + xdg-mime).
update-alternatives --install /usr/bin/x-www-browser x-www-browser /usr/bin/vivaldi-stable 200 2>&1 | tail -1 || true
update-alternatives --install /usr/bin/gnome-www-browser gnome-www-browser /usr/bin/vivaldi-stable 200 2>&1 | tail -1 || true
update-alternatives --set x-www-browser /usr/bin/vivaldi-stable 2>&1 | tail -1 || true
update-alternatives --set gnome-www-browser /usr/bin/vivaldi-stable 2>&1 | tail -1 || true

# Disable snap-Firefox redirect package if present
DEBIAN_FRONTEND=noninteractive apt-mark hold firefox 2>&1 | tail -1 || true

# System-wide xdg mimeapps default
mkdir -p /etc/xdg
cat > /etc/xdg/mimeapps.list <<'MIME'
[Default Applications]
text/html=vivaldi-stable.desktop
x-scheme-handler/http=vivaldi-stable.desktop
x-scheme-handler/https=vivaldi-stable.desktop
x-scheme-handler/ftp=vivaldi-stable.desktop
x-scheme-handler/chrome=vivaldi-stable.desktop
application/x-extension-htm=vivaldi-stable.desktop
application/x-extension-html=vivaldi-stable.desktop
application/xhtml+xml=vivaldi-stable.desktop
inode/directory=thunar.desktop
MIME

echo "[20] browsers: vivaldi (default) + flatpak Chromium + falkon + epiphany; gnome-software as App Center; firefox/snap-store hidden"

# r54 wallpaper unification — every DE flavor (XFCE, MATE, LXQt, WMaker, Openbox) reads
# /usr/share/backgrounds/ncz/default.jpg by default. The 10-min rotator (55-wallpaper-rotator.sh)
# updates default.jpg in place; per-DE configs all point to that fixed path.
NCZ_WP=/usr/share/backgrounds/ncz/default.jpg

# XFCE — system-wide xfconf channel default (read on first session)
mkdir -p /etc/xdg/xfce4/xfconf/xfce-perchannel-xml
cat > /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml <<XFCEEOF
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-desktop" version="1.0">
  <property name="backdrop" type="empty">
    <property name="screen0" type="empty">
      <property name="monitor0" type="empty">
        <property name="workspace0" type="empty">
          <property name="last-image" type="string" value="$NCZ_WP"/>
          <property name="image-style" type="int" value="5"/>
        </property>
      </property>
      <property name="monitorDP-1" type="empty">
        <property name="workspace0" type="empty">
          <property name="last-image" type="string" value="$NCZ_WP"/>
          <property name="image-style" type="int" value="5"/>
        </property>
      </property>
      <property name="monitorHDMI-1" type="empty">
        <property name="workspace0" type="empty">
          <property name="last-image" type="string" value="$NCZ_WP"/>
          <property name="image-style" type="int" value="5"/>
        </property>
      </property>
    </property>
  </property>
</channel>
XFCEEOF

# MATE / GNOME / Cinnamon — dconf system-wide default
mkdir -p /etc/dconf/db/local.d /etc/dconf/profile
cat > /etc/dconf/profile/user <<'DPROFILE'
user-db:user
system-db:local
DPROFILE
cat > /etc/dconf/db/local.d/00-ncx-wallpaper <<DCONFLOCAL
[org/gnome/desktop/background]
picture-uri='file://$NCZ_WP'
picture-uri-dark='file://$NCZ_WP'
picture-options='zoom'

[org/cinnamon/desktop/background]
picture-uri='file://$NCZ_WP'
picture-options='zoom'
DCONFLOCAL
dconf update 2>&1 | tail -1 || true

# r74: removed orphan LXQt heredoc tail (no opener — was a no-op)

# Window Maker — system-wide /etc/skel default (per-user GNUstep file)
mkdir -p /etc/skel/GNUstep/Defaults
cat > /etc/skel/GNUstep/Defaults/WindowMaker <<WMEOF
{
  WorkspaceBack = (spixmap, "$NCZ_WP", "#000000");
  SmoothWorkspaceBack = Yes;
  IconBack = (spixmap, "$NCZ_WP", "#000000");
}
WMEOF

# Openbox — feh autostart in /etc/skel/.config/openbox
mkdir -p /etc/skel/.config/openbox
cat > /etc/skel/.config/openbox/autostart <<OBEOF
# NCZ 26.5 — set wallpaper from rotator-managed default
feh --bg-fill $NCZ_WP &
OBEOF
chmod +x /etc/skel/.config/openbox/autostart

# Default session = XFCE in /etc/skel (matches lightdm default; prevents
# new users getting stuck in a less-tested DE)
cat > /etc/skel/.dmrc <<'DMRC'
[Desktop]
Session=xfce
Language=C.utf8
DMRC

# Cleanup: remove leftover lightdm conf for GNOME-Xorg (we no longer ship GNOME)
rm -f /etc/lightdm/lightdm.conf.d/55-gnome-xorg.conf

echo "[20] wallpapers unified across XFCE/MATE/LXQt/WMaker/Openbox; default session = xfce"

# r55 NCX-themed xscreensaver default config (system-wide via /etc/skel)
cat > /etc/skel/.xscreensaver <<'XSS'
timeout:		0:10:00
cycle:			0:05:00
lock:			True
fade:			True
unfade:			True
fadeSeconds:		0:00:03
mode:			random
selected:		0
chooseRandomImages: True
imageDirectory:	/usr/share/backgrounds/ncz/
dpmsEnabled:	True
dpmsStandby:	2:00:00
dpmsSuspend:	2:00:00
dpmsOff:		4:00:00

programs:								      \
- glslideshow -root --imageDirectory /usr/share/backgrounds/ncz \n\
- xanalogtv -root							      \n\
- galaxy -root							      \n\
- gleidescope -root							      \n\
- moebius -root							      \n\
- glmatrix -root							      \n\
- flyingtoasters -root						      \n\
- stonerview -root							      \n\
- atunnel -root							      \n\
- endgame -root							      \n\
XSS

# Autostart xscreensaver in XFCE/MATE/LXQt/Openbox sessions
mkdir -p /etc/xdg/autostart
cat > /etc/xdg/autostart/xscreensaver.desktop <<'XAUTO'
[Desktop Entry]
Type=Application
Name=XScreenSaver
Comment=NCZ 26.5 cosmic-themed screensaver daemon
Exec=xscreensaver -no-splash
OnlyShowIn=XFCE;LXQt;MATE;Openbox;
StartupNotify=false
Terminal=false
XAUTO
echo "[20] xscreensaver installed with NCZ cosmic theme set"
