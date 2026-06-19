#!/bin/bash
# 20-desktop.sh — XFCE on LightDM (resolute's GDM/Wayland on Mali panthor → black screen).
# --- NCZ 26.6: Stage the Agent installer on the Desktop.
# r110 (codex UX audit): the asset is staged by the installer at
# /usr/local/lib/cix-installer/assets/, NOT at chroot-root "/". The old
# `cp /install_ncz_agents.sh` ran before `set -e` and silently no-op'd, so the
# Desktop launcher never appeared. Use the real staged path, guarded.
install -d -m 0755 /etc/skel/Desktop
_agent_launcher=/usr/local/lib/cix-installer/assets/install_ncz_agents.sh
if [ -f "$_agent_launcher" ]; then
    install -m 0755 "$_agent_launcher" /etc/skel/Desktop/install_ncz_agents.sh
elif [ -f /install_ncz_agents.sh ]; then
    install -m 0755 /install_ncz_agents.sh /etc/skel/Desktop/install_ncz_agents.sh
else
    echo "[20] WARN: install_ncz_agents.sh not staged; Desktop launcher skipped"
fi

# r52: LightDM + Xorg + XFCE = reliable; xrdp for remote access.
set -euo pipefail

echo "[20] desktop layer (XFCE + LightDM + xrdp)"

VARIANT=desktop
if [ -f /usr/local/lib/cix-installer/BUILD_VARIANT ]; then
    VARIANT=$(tr -d ' \t\r\n' < /usr/local/lib/cix-installer/BUILD_VARIANT)
fi
case "$VARIANT" in
    server|magnetar|headless)
        echo "[20] BUILD_VARIANT=server - Magnetar headless SKU; skipping desktop install"
        exit 0
        ;;
esac

# NCZ policy (2026-06): the embedded ISO mirror is SERVER-only (Magnetar base);
# desktop / end-user packages are NOT carried offline. We "follow the Ubuntu
# Server package library" ourselves and path the desktop long tail out to Ubuntu
# (ports.ubuntu.com) directly, accepting slower fetches. So the desktop layer
# always installs ONLINE — the server-only /cdrom mirror has none of these.
echo "[20] desktop packages install online from ports.ubuntu.com (server-offline policy)"
rm -f /etc/apt/sources.list.d/cixmini-cdrom.list 2>/dev/null
cat > /etc/apt/sources.list <<'APT'
deb http://ports.ubuntu.com/ubuntu-ports resolute main universe restricted multiverse
deb http://ports.ubuntu.com/ubuntu-ports resolute-updates main universe restricted multiverse
deb http://ports.ubuntu.com/ubuntu-ports resolute-security main universe restricted multiverse
deb http://ports.ubuntu.com/ubuntu-ports resolute-backports main universe restricted multiverse
APT

apt-get update -q || true

# Pre-purge gdm3 if present in the rootfs.tar.zst (resolute's default DM).
# Without this, both gdm3 and lightdm fight for /etc/systemd/system/display-manager.service
# and the resulting boot lands on a black screen.
if dpkg -l gdm3 2>/dev/null | grep -q '^ii'; then
    echo "[20] purging gdm3 (resolute default DM, conflicts with lightdm)"
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

# ----------------------------------------------------------------------
# r111 (operator request — fuller desktop): a base xubuntu-core leaves the
# appliance with NO sound server, NO removable-media mounting, NO network
# applet, NO CJK/emoji fonts, and no archive/PDF/media/image apps. Add them.
# Online fetch (desktop policy: embedded mirror is server-only). All groups
# are best-effort — 20-desktop is a Phase 2 optional hook, so a transient
# mirror miss won't abort the install.
# ----------------------------------------------------------------------

# Audio: PipeWire + Pulse shim + WirePlumber so the (kernel-verified) HDMI/
# analog audio actually reaches apps; pavucontrol + panel plugin for control.
# (recommends on: pulls the helper bits that make the stack work end-to-end)
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    pipewire pipewire-pulse pipewire-alsa wireplumber \
    pavucontrol xfce4-pulseaudio-plugin 2>&1 | tail -3 || true
# Enable the PipeWire user stack for the operator + every future login.
systemctl --global enable pipewire pipewire-pulse wireplumber 2>&1 | tail -2 || true

# Removable media: gvfs + udisks so USB/MTP auto-mount in Thunar; disk GUI.
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    gvfs gvfs-backends udisks2 gnome-disk-utility 2>&1 | tail -3 || true

# Network: panel applet (WiFi/wired picker) for NetworkManager.
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    network-manager-gnome 2>&1 | tail -2 || true

# Bluetooth: stack + GTK applet (Sky1 MT7922 has BT).
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    bluez blueman 2>&1 | tail -3 || true
systemctl enable bluetooth 2>&1 | tail -1 || true

# Fonts: Noto base + CJK (bge-small-zh model / Chinese web) + colour emoji.
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    fonts-noto-core fonts-noto-cjk fonts-noto-color-emoji 2>&1 | tail -3 || true

# Archives: GUI + Thunar right-click extract + 7z/rar.
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    xarchiver thunar-archive-plugin p7zip-full unrar-free 2>&1 | tail -3 || true

# Core apps: PDF viewer, media player, image viewer, text editor.
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    evince mpv ristretto mousepad 2>&1 | tail -3 || true

# Panel UX: Whisker (modern app menu) + clipboard manager.
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    xfce4-whiskermenu-plugin xfce4-clipman-plugin 2>&1 | tail -3 || true

echo "[20] r111 fuller desktop: pipewire-audio + media-mount + nm-applet + bluetooth + Noto/CJK/emoji fonts + archives + evince/mpv/ristretto/mousepad + whisker/clipman"

# r55: NCZ-curated screensaver. xscreensaver replaces xfce4-screensaver.
# r112: GL hacks (xscreensaver-gl / -gl-extra) are intentionally NOT installed.
# The Sky1 desktop runs software-only GL (llvmpipe) and Mesa here has no X11
# EGL platform, so every GL hack aborts at runtime with "no GL visuals". We
# ship only the 2D hacks (xscreensaver-data / -data-extra: xanalogtv, galaxy,
# fireworkx, phosphor, apple2, xmatrix, ...) which render fine and fit the
# cosmic+retro brand.
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    xscreensaver xscreensaver-data xscreensaver-data-extra 2>&1 | tail -3 || true
# Belt-and-suspenders: if a metapackage dragged the GL hacks in, drop them so
# random selection can never land on a hack that aborts.
DEBIAN_FRONTEND=noninteractive apt-get remove -y xscreensaver-gl xscreensaver-gl-extra 2>&1 | tail -2 || true
DEBIAN_FRONTEND=noninteractive apt-get remove -y xfce4-screensaver 2>&1 | tail -1 || true

# r112: xscreensaver 6.x ALWAYS runs xscreensaver-gl-visual (an EGL probe) at
# blank time to pick a GL visual. On this Xorg the probe fails ("eglGetDisplay
# failed") and that failure blocks the ENTIRE hack-launch pipeline — even 2D
# hacks never start, leaving a black screen + "no GL visuals" diagnostic.
# Shim the probe so it reports the default X visual and exits 0; gfx then
# launches the (2D-only) hacks normally. dpkg-divert keeps the shim across
# xscreensaver package upgrades.
if [ -x /usr/libexec/xscreensaver/xscreensaver-gl-visual ]; then
    dpkg-divert --quiet --local --rename \
        --divert /usr/libexec/xscreensaver/xscreensaver-gl-visual.real \
        --add /usr/libexec/xscreensaver/xscreensaver-gl-visual 2>&1 | tail -1 || true
    cat > /usr/libexec/xscreensaver/xscreensaver-gl-visual <<'GLVSHIM'
#!/bin/sh
# NCZ 26.6 shim: this desktop has software-only GL and no X11 EGL platform, so
# the upstream EGL probe fails and blocks all xscreensaver hacks. Report the
# default X visual so xscreensaver-gfx proceeds. GL hacks are not installed;
# only 2D hacks run, which do not need this visual.
disp="$DISPLAY"
[ "$1" = "-display" ] && disp="$2"
vid=$(xdpyinfo -display "$disp" 2>/dev/null | awk '/default visual id/{print $NF; exit}')
[ -n "$vid" ] && echo "$vid" || echo 0x21
exit 0
GLVSHIM
    chmod 0755 /usr/libexec/xscreensaver/xscreensaver-gl-visual
    echo "[20] r112: xscreensaver-gl-visual shimmed (no X11 EGL) + GL hacks removed"
fi
# xdpyinfo (x11-utils) is needed by the shim at runtime.
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends x11-utils 2>&1 | tail -1 || true

# Configure LightDM defaults
mkdir -p /etc/lightdm/lightdm.conf.d
cat > /etc/lightdm/lightdm.conf.d/50-cixmini.conf <<'LIDM'
[Seat:*]
user-session=xfce
greeter-session=lightdm-gtk-greeter
greeter-show-manual-login=true
allow-guest=false
LIDM

# r109: brand the greeter (login) screen with the NCZ wallpaper. Without this
# the lightdm-gtk-greeter shows the default grey background before login, which
# reads as "default XFCE" until the user session paints the NCZ backdrop.
# Points at the rotator-managed default.jpg so it tracks the active wallpaper.
mkdir -p /etc/lightdm/lightdm-gtk-greeter.conf.d
cat > /etc/lightdm/lightdm-gtk-greeter.conf.d/50-ncz.conf <<GTKG
[greeter]
background=/usr/share/backgrounds/ncz/default.jpg
user-background=false
theme-name=Greybird-dark
icon-theme-name=elementary-xfce-dark
GTKG

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
# r110 (codex audit): never use --now in the chroot (no PID 1); enable now,
# let the unit start on first boot. Best-effort start in case we are live.
systemctl enable ncx-upstream-watch.timer 2>&1 | tail -2 || true
systemctl start ncx-upstream-watch.timer 2>&1 | tail -2 || true
echo "[20] GNOME purged, upstream-watch installed (every 6h)"

# r53: ncx-flavor-* metapackage shims — pre-stage apt info but DON'T install by default.
# Users who want alternative DEs run: apt install ncx-flavor-{openbox,wmaker}
# Each flavor metapackage pulls the right apt deps + writes session file.
# XFCE remains the default; alternatives are X11-native + work on Mali Sky1.
mkdir -p /usr/share/ncx/flavors
cat > /usr/share/ncx/flavors/README.md <<'README'
# NCZ Desktop Flavors

NCZ 26.6 "Reinhardt" ships **XFCE** as the default desktop because it works
reliably on Cix Sky1 + Mali-G720. Four additional X11-native desktops are
available via apt (no Vulkan/Wayland deps; will work on this hardware):

| Flavor | Install | Brand fit |
|---|---|---|
| Window Maker (NeXTSTEP) | sudo apt install wmaker | PERFECT (NCZ = black-hole = NeXT) |
| Openbox | sudo apt install openbox | Bare WM |

After install, log out, then pick the flavor at the LightDM greeter (gear icon).

# What does NOT work yet (r52)

- GNOME (gnome-shell on Wayland) — blocked on Mesa panvk gaps + resolute GDM-only Wayland
- KDE Plasma 6 — resolute dropped X11 startplasma, Wayland-only
- Sway / Hyprland — Wayland deps, same panvk gaps
- Cinnamon — muffin (mutter fork), likely same issues

These are tracked by the upstream-watch agent (/usr/local/lib/ncx/upstream-watch.sh).
README
echo "[20] flavor docs at /usr/share/ncx/flavors/README.md"

# r54 browsers — Firefox snap is too slow on Mali; chromium-browser .deb is also a snap-stub.
# Real chromium via Flathub (arm64). Vivaldi as primary. Falkon + Epiphany as Qt/WebKit alternatives.
# Brave is amd64-only on apt — no ARM64 .deb published.
#
# Pre-create the Qt5 dir falkon's postinst expects (resolute is Qt6-only by default; falkon postinst
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
# r110 (codex audit): make the chromium-browser shim resolve a browser at
# RUNTIME so it never execs a missing binary if a network-dependent install
# (Vivaldi/flatpak Chromium) failed. Falls through Vivaldi -> falkon ->
# epiphany -> flatpak Chromium -> xdg-open.
cat > /usr/local/bin/chromium-browser <<'CHROMWRAP'
#!/bin/sh
# NCZ 26.6: chromium-browser compat shim — exec the first browser that exists.
for b in /usr/bin/vivaldi-stable /usr/bin/falkon /usr/bin/epiphany; do
    [ -x "$b" ] && exec "$b" "$@"
done
if command -v flatpak >/dev/null 2>&1 && flatpak info org.chromium.Chromium >/dev/null 2>&1; then
    exec flatpak run org.chromium.Chromium "$@"
fi
exec xdg-open "$@"
CHROMWRAP
chmod +x /usr/local/bin/chromium-browser

# r110 (codex audit): resolve the actual default-browser .desktop for the
# alternatives + mimeapps defaults below, so a failed Vivaldi install does not
# leave links pointing at a non-existent vivaldi-stable.desktop.
if command -v vivaldi-stable >/dev/null 2>&1; then
    BROWSER_BIN=/usr/bin/vivaldi-stable; BROWSER_DESKTOP=vivaldi-stable.desktop
elif command -v falkon >/dev/null 2>&1; then
    BROWSER_BIN=/usr/bin/falkon; BROWSER_DESKTOP=org.kde.falkon.desktop
elif command -v epiphany >/dev/null 2>&1; then
    BROWSER_BIN=/usr/bin/epiphany; BROWSER_DESKTOP=org.gnome.Epiphany.desktop
elif flatpak info org.chromium.Chromium >/dev/null 2>&1; then
    BROWSER_BIN=""; BROWSER_DESKTOP=org.chromium.Chromium.desktop
else
    BROWSER_BIN=""; BROWSER_DESKTOP=""
fi
echo "[20] default browser resolved to: ${BROWSER_DESKTOP:-<none>} (${BROWSER_BIN:-flatpak/xdg})"

# Hide ALL snap-store launchers (App Center / show-updates) — App Center is broken on Mali.
# We installed gnome-software (.deb) as the real App Center.
for f in /var/lib/snapd/desktop/applications/snap-store_*.desktop; do
    [ -f "$f" ] || continue
    sed -i '/^NoDisplay=/d' "$f"
    echo "NoDisplay=true" >> "$f"
done

# Remove orphan plank-preferences launcher (plank dock not installed).
rm -f /usr/share/applications/plank-preferences.desktop

# Default web browser via update-alternatives (only when we have a real binary
# path — skip for the flatpak-only case, mimeapps below still routes it).
if [ -n "${BROWSER_BIN:-}" ] && [ -x "$BROWSER_BIN" ]; then
    update-alternatives --install /usr/bin/x-www-browser x-www-browser "$BROWSER_BIN" 200 2>&1 | tail -1 || true
    update-alternatives --install /usr/bin/gnome-www-browser gnome-www-browser "$BROWSER_BIN" 200 2>&1 | tail -1 || true
    update-alternatives --set x-www-browser "$BROWSER_BIN" 2>&1 | tail -1 || true
    update-alternatives --set gnome-www-browser "$BROWSER_BIN" 2>&1 | tail -1 || true
else
    echo "[20] no single-binary browser for update-alternatives (flatpak/none) — relying on mimeapps"
fi

# Disable snap-Firefox redirect package if present
DEBIAN_FRONTEND=noninteractive apt-mark hold firefox 2>&1 | tail -1 || true

# System-wide xdg mimeapps default. r110: route to the resolved browser
# .desktop (falls back to vivaldi-stable.desktop only as a last resort).
mkdir -p /etc/xdg
_bd=${BROWSER_DESKTOP:-vivaldi-stable.desktop}
cat > /etc/xdg/mimeapps.list <<MIME
[Default Applications]
text/html=$_bd
x-scheme-handler/http=$_bd
x-scheme-handler/https=$_bd
x-scheme-handler/ftp=$_bd
x-scheme-handler/chrome=$_bd
application/x-extension-htm=$_bd
application/x-extension-html=$_bd
application/xhtml+xml=$_bd
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

# XFCE WM — disable GPU compositing by default. On Mali-G720 (panthor) the
# zink/kopper GL compositor cannot create an X11 swapchain on the 7.0.x kernel
# ("zink: could not create swapchain"); xfwm4 treats that GL init failure as
# fatal and exits -> the session comes up with no window manager. Compositing
# off keeps the WM stable; the GPU stays fully available for Vulkan/OpenCL/NPU
# compute (which does not use the GL presentation path). See DRIVER_FIDELITY_7012.md.
mkdir -p /etc/xdg/xfce4/xfconf/xfce-perchannel-xml
cat > /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml <<'XFWMEOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="use_compositing" type="bool" value="false"/>
  </property>
</channel>
XFWMEOF

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
# NCZ 26.6 — set wallpaper from rotator-managed default
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

# r55/r112 NCZ xscreensaver default config (system-wide via /etc/skel).
# NOTE: we deliberately do NOT set a custom "programs:" list. In xscreensaver
# 6.x, mode "random" ignores a ~/.xscreensaver programs list and instead picks
# from the installed hack catalog (/usr/share/applications/screensavers/). Since
# the GL hack packages are not installed, that catalog is 2D-only — exactly what
# we want — so random just works. lock/dpms are off for appliance behaviour.
cat > /etc/skel/.xscreensaver <<'XSS'
timeout:		0:10:00
cycle:			0:01:00
lock:			False
fade:			True
unfade:			True
fadeSeconds:		0:00:03
mode:			random
selected:		-1
dpmsEnabled:		False
XSS

# Autostart xscreensaver in XFCE/MATE/LXQt/Openbox sessions
mkdir -p /etc/xdg/autostart
cat > /etc/xdg/autostart/xscreensaver.desktop <<'XAUTO'
[Desktop Entry]
Type=Application
Name=XScreenSaver
Comment=NCZ 26.6 cosmic-themed screensaver daemon
Exec=xscreensaver -no-splash
OnlyShowIn=XFCE;LXQt;MATE;Openbox;
StartupNotify=false
Terminal=false
XAUTO
echo "[20] xscreensaver installed (2D-only hacks + gl-visual shim; random from catalog)"
