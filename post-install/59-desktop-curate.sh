#!/bin/bash
# 59-desktop-curate.sh — curate the Singularity app launcher to a clean,
# working, Wayland-only app set. Zero-compromise: only functioning, appropriate
# apps appear.
#
# ROOT CAUSE (OnlyShowIn honoring): the Singularity shell launcher enumerates
# .desktop files via GLib GDesktopAppInfo and calls g_app_info_should_show()
# with XDG_CURRENT_DESKTOP=Singularity (exported by singularity-desktop /
# singularity-desktop-session). So entries carrying OnlyShowIn=<other DE>
# (XFCE/LXQt/Enlightenment/GNOME/KDE/MATE/Unity) or NotShowIn=Singularity or
# NoDisplay=true ARE ALREADY auto-hidden — that mechanism works and needs no
# per-app edit. What leaks into the menu is the set of entries that carry NO
# OnlyShowIn at all (bake-off apps: thunar/xfce4-*/lxqt-*/qterminal/pcmanfm-qt/
# enlightenment_*, X11 apps: xterm/xscreensaver, and base GNOME/system tools).
# This hook removes those two ways:
#   1. PURGE X11-native + leftover bake-off desktop PACKAGES entirely (their
#      .desktop files go with them). Xwayland is KEPT (rootless X-app compat).
#   2. NoDisplay=true the base GNOME/system entries that have no OnlyShowIn and
#      are inappropriate/duplicate for an appliance launcher (kept installed).
# Plus: dedupe Vivaldi, drop stray/broken launchers, drop stale xterm NCZ copies.
#
# Idempotent. present-only purge, NEVER --auto-remove (the r166-r170 truncated-
# /etc/passwd saga). Safe in chroot (bake) and on a live rootfs (O6N). Ordered
# LAST in the desktop layer so it sees every app-creating hook's output
# (20-desktop, 30-agents, 52-vivaldi, ...).
set -uo pipefail

echo "[59] Singularity launcher curation (Wayland-only, working app set)"

VARIANT=desktop
if [ -f /usr/local/lib/cix-installer/BUILD_VARIANT ]; then
    VARIANT=$(tr -d ' \t\r\n' < /usr/local/lib/cix-installer/BUILD_VARIANT)
fi
case "$VARIANT" in
    server|magnetar|headless)
        echo "[59] BUILD_VARIANT=$VARIANT — headless SKU; skipping launcher curation"
        exit 0
        ;;
esac

APPDIR=/usr/share/applications

# ---------------------------------------------------------------------------
# 1) PURGE X11-native + leftover bake-off desktop packages (present-only).
#    X11-native = runs ONLY on Xorg (xterm/xscreensaver/x11-apps/feh) — removed.
#    Wayland-capable GTK/Qt/Electron apps (gimp/vivaldi/mpv/vlc/mousepad/foot/
#    nautilus) are KEPT. Xwayland (the rootless X-compat layer) is KEPT — it is
#    NOT an X11 desktop and is required for any app that still needs X.
#    NEVER --auto-remove; keep libxfce4ui-2-0/xfconf (mousepad depends on them).
# ---------------------------------------------------------------------------
PURGE_CANDIDATES="
  xterm x11-apps x11-utils xbitmaps xscreensaver feh
  epiphany-browser
  enlightenment terminology emixer
  wayfire wcm
  gigolo mugshot pasystray catfish ristretto
  thunar thunar-data thunar-volman thunar-archive-plugin exo-utils
  xfce4-appfinder xfce4-clipman xfce4-clipman-plugin xfce4-cpugraph-plugin
  xfce4-dict xfce4-helpers xfce4-netload-plugin xfce4-notifyd xfce4-panel
  xfce4-panel-profiles xfce4-places-plugin xfce4-power-manager
  xfce4-power-manager-data xfce4-pulseaudio-plugin xfce4-screenshooter
  xfce4-session xfce4-settings xfce4-systemload-plugin xfce4-verve-plugin
  xfce4-weather-plugin xfce4-whiskermenu-plugin xfce4-xkb-plugin xfce4-taskmanager
  xfdesktop4 xfdesktop4-data xfwm4
  lxqt-config lxqt-core lxqt-globalkeys lxqt-notificationd lxqt-panel
  lxqt-policykit lxqt-qtplugin lxqt-runner lxqt-session lxqt-sudo
  lxqt-system-theme lxqt-themes lxqt-wayland-session
  pcmanfm-qt qterminal pavucontrol-qt
"
_present=""
for p in $PURGE_CANDIDATES; do
    dpkg -l "$p" 2>/dev/null | grep -q '^ii' && _present="$_present $p"
done
if [ -n "$_present" ]; then
    echo "[59] purging X11-native + bake-off desktop packages (no --auto-remove):"
    echo "     $_present"
    DEBIAN_FRONTEND=noninteractive apt-get purge -y $_present 2>&1 | tail -4 || true
else
    echo "[59] no X11-native/bake-off packages present (clean base) — nothing to purge"
fi
# Belt-and-braces: xwayland MUST survive (labwc -Dxwayland=enabled compat layer).
if ! dpkg -l xwayland 2>/dev/null | grep -q '^ii'; then
    echo "[59] WARN: xwayland missing after purge — reinstalling (X-app compat)"
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends xwayland 2>&1 | tail -2 || true
fi

# ---------------------------------------------------------------------------
# 2) Drop stray / broken / duplicate launchers.
# ---------------------------------------------------------------------------
# Stray old-codename branding (should be "Maximilian", not "Reinhardt").
rm -f "$APPDIR"/Rheinhardt-Through-and-Beyond.desktop \
      /etc/skel/Desktop/Rheinhardt-Through-and-Beyond.desktop 2>/dev/null || true
# Dedupe Vivaldi: keep vivaldi-stable.desktop (canonical, matches mimeapps +
# x-www-browser); drop the duplicate menu entry.
rm -f "$APPDIR"/Vivaldi.desktop 2>/dev/null || true
# Redundant /usr/share copies of the NCZ launchers — the canonical foot-based
# versions live in /opt/singularity/share/applications (earlier on the session
# XDG_DATA_DIRS, so they mask these). Drop the /usr/share copy whenever the /opt
# canonical exists (covers both the old xterm copies and any foot re-copy).
for n in ClaudeCode NCZ-CLI MNEMOS Install-NCZ-Agents; do
    f="$APPDIR/$n.desktop"
    if [ -f "$f" ] && [ -f "/opt/singularity/share/applications/$n.desktop" ]; then
        rm -f "$f"; echo "[59] dropped redundant /usr/share $n.desktop (/opt canonical kept)"
    fi
done
# Stale Zoder menu copy (the shipped Zoder is a Type=Link desktop-folder shortcut
# in ~/Desktop, not a menu app; an old bake copied a broken one into $APPDIR).
[ -f "$APPDIR/Zoder.desktop" ] && ! grep -q '^Exec=..*[^ ]' "$APPDIR/Zoder.desktop" && rm -f "$APPDIR/Zoder.desktop"

# ---------------------------------------------------------------------------
# 3) NoDisplay=true the base GNOME/system entries that have NO OnlyShowIn (so
#    should_show can't auto-hide them) and are inappropriate/duplicate for the
#    appliance launcher. Kept INSTALLED (offline-apt tooling / libs stay usable
#    from CLI); only hidden from the menu. Singularity ships native equivalents
#    (singularity-monitor, singularity-keyring, singularity-files) so the GNOME
#    duplicates are hidden in favour of the native, branded apps.
# ---------------------------------------------------------------------------
set_nodisplay() {
    local f="$APPDIR/$1"
    [ -f "$f" ] || return 0
    if grep -q '^NoDisplay=' "$f"; then
        sed -i 's/^NoDisplay=.*/NoDisplay=true/' "$f"
    else
        sed -i '0,/^\[Desktop Entry\]/s//[Desktop Entry]\nNoDisplay=true/' "$f"
    fi
    echo "[59]   NoDisplay -> $1"
}
NODISPLAY="
  htop.desktop info.desktop vim.desktop
  synaptic.desktop gdebi.desktop software-properties-gtk.desktop
  software-properties-drivers.desktop menulibre.desktop
  org.gnome.SystemMonitor.desktop gnome-system-monitor-kde.desktop
  gnome-language-selector.desktop org.gnome.seahorse.Application.desktop
  org.gnome.font-viewer.desktop display-im7.q16.desktop
  footclient.desktop foot-server.desktop
"
echo "[59] hiding base GNOME/system cruft (kept installed, NoDisplay):"
for d in $NODISPLAY; do set_nodisplay "$d"; done

# ---------------------------------------------------------------------------
# 4) Rebuild the desktop database so the launcher re-reads the curated set.
# ---------------------------------------------------------------------------
update-desktop-database "$APPDIR" 2>/dev/null || true
update-desktop-database /opt/singularity/share/applications 2>/dev/null || true

# Report the resulting visible count (Type=Application, not NoDisplay, not
# OnlyShowIn-excluded is enforced live by the shell; this is a coarse count).
_vis=$(for f in "$APPDIR"/*.desktop /opt/singularity/share/applications/*.desktop; do
        [ -f "$f" ] || continue
        grep -q '^NoDisplay=true' "$f" && continue
        grep -q '^Type=Link' "$f" && continue
        osi=$(grep -m1 '^OnlyShowIn=' "$f" | cut -d= -f2-)
        [ -n "$osi" ] && ! printf '%s' "$osi" | grep -q 'Singularity' && continue
        basename "$f"
      done | sort -u | wc -l)
echo "[59] launcher curation done — ~$_vis entries visible to the Singularity launcher"
exit 0
