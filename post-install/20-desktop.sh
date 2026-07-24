#!/bin/bash
# 20-desktop.sh — NCZ-OS 26.7 "Maximilian" Singularity Desktop installer.
#
# Singularity Desktop (labwc/wlroots, GTK4/Vala, GLES on CIX libmali) is THE
# desktop. XFCE/X11 is GONE — no Xorg display server, no XFCE session. Wayland
# native, Mali-accelerated. Xwayland is kept (labwc -Dxwayland=enabled) for
# X-app compatibility UNDER Wayland — that is rootless X-compat, not an X11
# desktop.
#
# Runtime configs here are the proven-working versions captured from the O6N
# bring-up box (Radxa Orion O6N, CIX Sky1). GPU userspace is swappable via
# ncz-gpu-env (Mali libmali GLES today; Panthor/Mesa experimental).
#
# GREETER (beta): lightdm + lightdm-gtk-greeter, NCZ-branded. This is a
# TEMPORARY dev placeholder — the shipping greeter is greetd + regreet (GTK4,
# Mali-accelerated Wayland), built by a separate agent. The swap is one block:
# see the "GREETER SWAP POINT" marker below.
#
# RUNS INSIDE CHROOT at desktop-layer bake time (build-squashfs-layers.sh
# desktop loop), NOT via install-time MACHINE_HOOKS.

set -euo pipefail
echo "[20] Singularity Desktop layer (labwc/wlroots + LightDM-branded greeter [beta])"

VARIANT=desktop
if [ -f /usr/local/lib/cix-installer/BUILD_VARIANT ]; then
    VARIANT=$(tr -d ' \t\r\n' < /usr/local/lib/cix-installer/BUILD_VARIANT)
fi
case "$VARIANT" in
    server|magnetar|headless)
        echo "[20] BUILD_VARIANT=$VARIANT — Magnetar headless SKU; skipping desktop install"
        exit 0
        ;;
esac

# ---------------------------------------------------------------------------
# Offline package install from the bundled /cdrom pool (r130 fat-ISO doctrine).
# The full Singularity runtime closure lives in manifests/desktop.pkgs, mirrored
# by build-desktop-mirror.sh into the ISO pool. ports.ubuntu.com is a fallback
# only when a package is genuinely absent from the offline closure.
# ---------------------------------------------------------------------------
echo "[20] desktop packages install OFFLINE from bundled /cdrom pool"
if [ ! -f /etc/apt/sources.list.d/cixmini-cdrom.list ]; then
    echo "deb [trusted=yes] file:///cdrom resolute main" \
        > /etc/apt/sources.list.d/cixmini-cdrom.list
fi
apt-get update -o Acquire::http::Timeout=8 -o Acquire::https::Timeout=8 \
    -o Acquire::Retries=0 -o Acquire::ForceIPv4=true -q || true

ncz_ports_fallback() {
    if [ -f /etc/apt/sources.list.d/ncz-ports-fallback.list ]; then return 0; fi
    echo "[20] WARN: package(s) missing from bundled pool — enabling ports.ubuntu.com fallback"
    cat > /etc/apt/sources.list.d/ncz-ports-fallback.list <<'PORTS'
deb http://ports.ubuntu.com/ubuntu-ports resolute main universe restricted multiverse
deb http://ports.ubuntu.com/ubuntu-ports resolute-updates main universe restricted multiverse
deb http://ports.ubuntu.com/ubuntu-ports resolute-security main universe restricted multiverse
deb http://ports.ubuntu.com/ubuntu-ports resolute-backports main universe restricted multiverse
PORTS
    apt-get update -o Acquire::http::Timeout=8 -o Acquire::https::Timeout=8 \
        -o Acquire::Retries=0 -o Acquire::ForceIPv4=true -q || true
}

# Pre-purge resolute's default GNOME display manager — gdm3 + lightdm both claim
# display-manager.service and the loser black-screens.
if dpkg -l gdm3 2>/dev/null | grep -q '^ii'; then
    echo "[20] purging gdm3 (resolute default DM, conflicts with lightdm)"
    DEBIAN_FRONTEND=noninteractive apt-get purge -y gdm3 ubuntu-session 2>&1 | tail -3 || true
    rm -f /etc/systemd/system/display-manager.service
fi

# Core Singularity runtime + Wayland stack + greeter. These are the SYSTEM libs
# the /opt/singularity binaries link against, plus the session infra (labwc runs
# from the tarball; foot terminal; seatd; swaybg; xsettingsd; polkit; Xwayland
# for X-app compat). LightDM is the beta greeter. NO Xorg server, NO XFCE.
CORE_DESKTOP="lightdm lightdm-gtk-greeter \
    libgtk-4-1 libadwaita-1-0 libgtk4-layer-shell0 \
    libgee-0.8-2 libpeas-2-0 libjson-glib-1.0-0 libsoup-3.0-0 \
    libvte-2.91-gtk4-0 libgtksourceview-5-0 libwebkitgtk-6.0-4 \
    libgraphene-1.0-0 \
    foot xsettingsd seatd swaybg grim slurp fuzzel \
    xwayland \
    polkit polkitd \
    mesa-utils vulkan-tools libglu1-mesa \
    libglib2.0-bin"
if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $CORE_DESKTOP; then
    ncz_ports_fallback
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $CORE_DESKTOP || \
        echo "[20] WARN: some core desktop pkgs failed (see closure)"
fi

# Audio: PipeWire stack so HDMI/analog reaches apps; pavucontrol for control.
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    pipewire pipewire-pulse pipewire-alsa wireplumber pavucontrol 2>&1 | tail -3 || true
systemctl --global enable pipewire pipewire-pulse wireplumber 2>&1 | tail -2 || true

# Removable media + network applet + bluetooth.
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    gvfs gvfs-backends udisks2 network-manager-gnome bluez blueman 2>&1 | tail -3 || true
systemctl enable bluetooth 2>&1 | tail -1 || true

# Fonts: Noto base + CJK + colour emoji.
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    fonts-noto-core fonts-noto-cjk fonts-noto-color-emoji fonts-liberation 2>&1 | tail -3 || true

# Video: mpv HW player (84-vpu-mpv wires hwdec=v4l2m2m-copy). Browser (Chromium)
# comes from the mirror; Vivaldi via 52-vivaldi.
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    mpv chromium 2>&1 | tail -3 || echo "[20] mpv/chromium: some deferred"

echo "[20] runtime deps installed (Singularity libs + Wayland stack + Xwayland + audio + mpv + chromium)"

# ---------------------------------------------------------------------------
# Extract the Singularity payload -> /opt/singularity.
# The tarball extracts to opt/singularity/... (touches only /opt/singularity —
# safe on a live rootfs, never clobbers /lib). Staged by build-squashfs-layers
# (baked) into /usr/local/lib/cix-installer/assets/singularity/, or at install
# time under /cdrom/assets/singularity/ (build-iso-di stages both).
# ---------------------------------------------------------------------------
SINGTGZ=""
for c in /usr/local/lib/cix-installer/assets/singularity/singularity-opt.tgz \
         /cdrom/assets/singularity/singularity-opt.tgz \
         /run/cixmini/assets/singularity/singularity-opt.tgz; do
    [ -f "$c" ] && { SINGTGZ="$c"; break; }
done
if [ -z "$SINGTGZ" ]; then
    echo "[20] FATAL: singularity-opt.tgz not staged — desktop cannot install" >&2
    echo "[20]        expected assets/singularity/singularity-opt.tgz (build/build-singularity.sh)" >&2
    exit 1
fi
echo "[20] extracting Singularity payload: $SINGTGZ -> /opt/singularity"
tar -C / -xzf "$SINGTGZ"
test -x /opt/singularity/bin/singularity-desktop
test -x /opt/singularity/bin/singularity-labwc-session
# ldconfig for /opt/singularity/lib so the shell resolves libsingularity.
echo "/opt/singularity/lib" > /etc/ld.so.conf.d/singularity.conf
ldconfig 2>/dev/null || true

# ---------------------------------------------------------------------------
# GPU userspace selector — ncz-gpu-env (Mali branch has NO
# __EGL_VENDOR_LIBRARY_FILENAMES pin: that pin blackscreens libmali, confirmed
# on O6N). Panthor branch keeps the mesa vendor ICD. Sourced by every session
# launcher AND the greeter wrapper so the SAME binaries render on whichever GPU
# stack booted (chosen per rEFInd entry).
# ---------------------------------------------------------------------------
install -d -m0755 /usr/local/bin
cat > /usr/local/bin/ncz-gpu-env <<'GPUENV'
#!/bin/sh
# ncz-gpu-env — driver-aware GPU/GL userspace selector for NCZ-OS (CIX Sky1).
# SOURCE this ( ". /usr/local/bin/ncz-gpu-env" ) from every NCZ session launcher
# AND the greeter wrapper, so the SAME binaries render on whichever GPU stack the
# kernel booted. Mali (CIX libmali GLES blob, /dev/mali0, mali_kbase) and Panthor
# (open Mesa/panvk, /dev/dri/renderD128, panthor) are mutually exclusive, chosen
# per rEFInd boot entry. POSIX sh; safe to source.
if [ -e /dev/mali0 ] && grep -q '^mali_kbase ' /proc/modules 2>/dev/null; then
    NCZ_GPU_BACKEND=mali
    LD_LIBRARY_PATH="/opt/cixgpu-pro/lib/aarch64-linux-gnu:/opt/cixgpu-compat/lib/aarch64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    WLR_DRM_NO_MODIFIERS=1
    export NCZ_GPU_BACKEND LD_LIBRARY_PATH WLR_DRM_NO_MODIFIERS
elif grep -q '^panthor ' /proc/modules 2>/dev/null; then
    # Panthor = open Mesa stack. Point glvnd/EGL at the mesa vendor ICD and strip
    # inherited CIX libmali paths so EGL/GBM resolve to mesa (panfrost/panvk).
    NCZ_GPU_BACKEND=panthor
    __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json
    LD_LIBRARY_PATH=$(printf '%s' "${LD_LIBRARY_PATH:-}" | tr ':' '\n' | grep -v '/opt/cixgpu-' | paste -sd: -)
    VK_LOADER_LAYERS_DISABLE=VK_LAYER_CIX_window_system_integration
    WLR_DRM_NO_MODIFIERS=1
    export NCZ_GPU_BACKEND __EGL_VENDOR_LIBRARY_FILENAMES VK_LOADER_LAYERS_DISABLE WLR_DRM_NO_MODIFIERS
    if [ -n "$LD_LIBRARY_PATH" ]; then export LD_LIBRARY_PATH; else unset LD_LIBRARY_PATH; fi
else
    NCZ_GPU_BACKEND=software
    export NCZ_GPU_BACKEND
fi
GPUENV
chmod 0755 /usr/local/bin/ncz-gpu-env

# Singularity session launcher (sources ncz-gpu-env; /opt/singularity on
# PATH/XDG_DATA_DIRS/LD_LIBRARY_PATH; TERMINAL=foot).
cat > /usr/local/bin/ncz-singularity <<'SINGLAUNCH'
#!/bin/bash
# NCZ Singularity Desktop session (isolated /opt/singularity).
# GPU backend is SWAPPABLE: source the shared selector (Mali/libmali or Panthor/Mesa).
if [ -r /usr/local/bin/ncz-gpu-env ]; then
    . /usr/local/bin/ncz-gpu-env
else
    export LD_LIBRARY_PATH="/opt/cixgpu-pro/lib/aarch64-linux-gnu:/opt/cixgpu-compat/lib/aarch64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export WLR_DRM_NO_MODIFIERS=1
fi
# Singularity isolated env (singularity libs must precede GPU libs).
export PATH="/opt/singularity/bin:$PATH"
export XDG_DATA_DIRS="/opt/singularity/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
export LD_LIBRARY_PATH="/opt/singularity/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export TERMINAL=foot
exec /opt/singularity/bin/singularity-labwc-session
SINGLAUNCH
chmod 0755 /usr/local/bin/ncz-singularity

# Wayland session entry (the ONLY session — Singularity is Wayland-only).
install -d -m0755 /usr/share/wayland-sessions
cat > /usr/share/wayland-sessions/singularity.desktop <<'WSESS'
[Desktop Entry]
Name=Singularity (NCZ)
Comment=Singularity Desktop Environment (isolated /opt/singularity, CIX Mali GLES)
Exec=/usr/local/bin/ncz-singularity
TryExec=/usr/local/bin/ncz-singularity
Type=Application
DesktopNames=Singularity
WSESS
echo "[20] ncz-gpu-env + ncz-singularity + singularity.desktop installed"

# ---------------------------------------------------------------------------
# Packaged gschema defaults — red accent + dark mode + NCZ Maximilian wallpaper.
# The accent is written by StyleManager to the user gtk.css at runtime; setting
# it in the schema DEFAULT makes red the out-of-box accent. Wallpaper points at
# the NCZ Maximilian backdrop (45-wallpaper-rotator installs the NCZ set + can
# rotate). Compiled into the Singularity schema dir (on the session's
# GSETTINGS_SCHEMA_DIR).
# ---------------------------------------------------------------------------
SCHEMADIR=/opt/singularity/share/glib-2.0/schemas
if [ -f "$SCHEMADIR/dev.sinty.desktop.gschema.xml" ]; then
    cat > "$SCHEMADIR/99-ncz-defaults.gschema.override" <<'GSCHEMA'
[dev.sinty.desktop]
accent-color='red'
dark-mode=true
theme-mode='dark'
icon-theme='Singularity'
background-picture-uri='file:///usr/share/backgrounds/ncz/ncz-wallpaper-07-maximilian-blackhole-2k.jpg'
recent-wallpapers=['file:///usr/share/backgrounds/ncz/ncz-wallpaper-07-maximilian-blackhole-2k.jpg']
GSCHEMA
    glib-compile-schemas "$SCHEMADIR" 2>&1 | tail -1 || \
        echo "[20] WARN: glib-compile-schemas failed (schemas compile on first session)"
    echo "[20] gschema override: accent=red, dark-mode, Maximilian wallpaper"
else
    echo "[20] WARN: dev.sinty.desktop schema absent — accent/wallpaper defaults skipped"
fi

# ---------------------------------------------------------------------------
# Corner-hint fix — the hot-corner "Overview  Super+Space" hint window
# (.corner-hint) fails to dismiss on pointer-leave over gtk4-layer-shell
# surfaces, leaving a stuck pill over the global-menu row. Suppress the visual
# (the hot-corner ACTION still works). Applied to the THEME gtk.css (not a user
# file StyleManager rewrites) so it persists. NOT `.pill` alone (would hit legit
# rounded buttons) — only the corner-hint classes.
# TODO(release-track): fix the shell's hide_hint() dismiss upstream (Vala) —
# docs/upstream/singularity/ — and drop this CSS suppression.
# ---------------------------------------------------------------------------
CORNERCSS='
/* === NCZ-corner-hint-suppress (reversible: delete this block) ============= */
window.corner-hint,
.corner-hint,
.corner-hint-tl, .corner-hint-tr,
.corner-hint-glow, .corner-hint-badge {
  opacity: 0;
  background: transparent;
  background-image: none;
  box-shadow: none;
}
'
for tv in gtk-4.0 gtk-3.0; do
    TC="/opt/singularity/share/themes/Singularity/$tv/gtk.css"
    if [ -f "$TC" ] && ! grep -q 'NCZ-corner-hint-suppress' "$TC"; then
        printf '%s\n' "$CORNERCSS" >> "$TC"
    fi
done
echo "[20] corner-hint pill suppressed in Singularity theme (gtk-4.0/gtk-3.0)"

# ---------------------------------------------------------------------------
# NCZ .desktop launchers — foot-based (not xterm). Installed into the Singularity
# app dir (on the session XDG_DATA_DIRS). The agent-installer + CLI launchers.
# ---------------------------------------------------------------------------
APPDIR=/opt/singularity/share/applications
install -d -m0755 "$APPDIR"
cat > "$APPDIR/Install-NCZ-Agents.desktop" <<'DAPP'
[Desktop Entry]
Version=1.0
Type=Application
Name=⭐ Install AI Agents & MNEMOS
GenericName=AI agent + MNEMOS installer
Comment=Start here — pull + launch your AI agents and the MNEMOS memory server
Exec=foot -T "Install AI Agents and MNEMOS" /usr/local/bin/ncz-install-stack
Icon=ncz-rocket
Terminal=false
StartupNotify=true
Categories=System;Settings;Network;
DAPP
cat > "$APPDIR/NCZ-CLI.desktop" <<'DAPP'
[Desktop Entry]
Version=1.0
Type=Application
Name=NCZ CLI
Comment=NCZ command-line — agents, NPU status (ncz help)
Exec=foot --hold -T NCZ /usr/local/bin/ncz help
Icon=ncz-rocket
Terminal=false
Categories=System;Settings;
DAPP
cat > "$APPDIR/ClaudeCode.desktop" <<'DAPP'
[Desktop Entry]
Version=1.0
Type=Application
Name=Claude Code
Comment=Anthropic Claude Code CLI
Exec=foot -T ClaudeCode claude
Icon=utilities-terminal
Terminal=false
Categories=Development;
DAPP
cat > "$APPDIR/MNEMOS.desktop" <<'DAPP'
[Desktop Entry]
Version=1.0
Type=Application
Name=Install MNEMOS
GenericName=MNEMOS memory server installer
Comment=Pull + start the MNEMOS memory server (REST + MCP + OpenAI gateway on :5002)
Exec=foot --hold -T "Install MNEMOS" bash -c "sudo ncz install mnemos"
Icon=applications-science
Terminal=false
StartupNotify=true
Categories=System;Development;Network;
DAPP
update-desktop-database "$APPDIR" 2>/dev/null || true
echo "[20] NCZ .desktop launchers (foot) installed -> $APPDIR"

# Stage the agent installer on the Desktop for new users (r110: use the real
# staged path, guarded).
install -d -m0755 /etc/skel/Desktop
_agent_launcher=/usr/local/lib/cix-installer/assets/install_ncz_agents.sh
if [ -f "$_agent_launcher" ]; then
    install -m 0755 "$_agent_launcher" /etc/skel/Desktop/install_ncz_agents.sh
elif [ -f /install_ncz_agents.sh ]; then
    install -m 0755 /install_ncz_agents.sh /etc/skel/Desktop/install_ncz_agents.sh
fi

# ---------------------------------------------------------------------------
# LightDM — beta greeter. Singularity is the ONLY session. NO X11/XFCE session.
# ---------------------------------------------------------------------------
mkdir -p /etc/lightdm/lightdm.conf.d
cat > /etc/lightdm/lightdm.conf.d/50-cixmini.conf <<'LIDM'
[Seat:*]
user-session=singularity
greeter-session=lightdm-gtk-greeter
greeter-show-manual-login=true
allow-guest=false
LIDM

# GREETER SWAP POINT ========================================================
# BETA: lightdm-gtk-greeter (X11), NCZ-branded. TEMPORARY placeholder.
# SHIPPING: greetd + regreet (GTK4, Mali-accelerated Wayland) on labwc — built
# by the native-greeter agent. To cut over, replace the two lines below with the
# greetd enable + /usr/local/bin/ncz-regreet-greeter wrapper (already proven on
# O6N: labwc -C /etc/greetd/regreet-labwc, sources ncz-gpu-env), and disable
# lightdm. That is the ONLY change needed here — the session (singularity.desktop)
# is greeter-agnostic.
#   systemctl disable lightdm ; systemctl enable greetd
#   (ship /etc/greetd/config.toml -> command = "/usr/local/bin/ncz-regreet-greeter")
# ===========================================================================
GREETER_BACKEND="${NCZ_GREETER:-lightdm}"   # future: set NCZ_GREETER=greetd to swap
echo "[20] greeter backend = $GREETER_BACKEND (beta placeholder; greetd/regreet = shipping)"

# Brand the lightdm-gtk-greeter (dark, NCZ Maximilian bg). 55-greeter refines
# theme + avatar; 45-wallpaper-rotator owns the rotating background.
mkdir -p /etc/lightdm/lightdm-gtk-greeter.conf.d
cat > /etc/lightdm/lightdm-gtk-greeter.conf.d/50-ncz.conf <<'GTKG'
[greeter]
background=/usr/share/backgrounds/ncz/ncz-wallpaper-07-maximilian-blackhole-2k.jpg
user-background=false
theme-name=Adwaita-dark
icon-theme-name=Adwaita
GTKG

systemctl disable gdm gdm3 2>/dev/null || true
systemctl stop gdm gdm3 2>/dev/null || true
systemctl set-default graphical.target
systemctl enable lightdm
echo "/usr/sbin/lightdm" > /etc/X11/default-display-manager
ln -sf /lib/systemd/system/lightdm.service /etc/systemd/system/display-manager.service
DEBIAN_FRONTEND=noninteractive dpkg-reconfigure lightdm 2>&1 | tail -2 || true

# seatd for seat management under Wayland (labwc/wlroots).
systemctl enable seatd 2>/dev/null || true

# Skip gnome-initial-setup wizard (creds already collected by d-i).
install -d -m 0755 /etc/skel/.config
touch /etc/skel/.config/gnome-initial-setup-done

# ---------------------------------------------------------------------------
# Operator groups — render/video/audio/plugdev/input (Vulkan/V4L2/audio/media)
# + seat (seatd). Only groups that already exist (some appear via later hooks).
# ---------------------------------------------------------------------------
OPERATOR_USER=$(awk -F: '$3 >= 1000 && $3 < 65000 {print $1; exit}' /etc/passwd)
if [ -z "$OPERATOR_USER" ] && id ncz >/dev/null 2>&1; then OPERATOR_USER=ncz; fi
if [ -n "$OPERATOR_USER" ] && id "$OPERATOR_USER" >/dev/null 2>&1; then
    for g in render video audio plugdev input seat; do
        if getent group "$g" >/dev/null 2>&1; then
            usermod -aG "$g" "$OPERATOR_USER" 2>&1 | sed 's/^/    /'
        fi
    done
    echo "[20] operator '$OPERATOR_USER' added to render/video/audio/plugdev/input/seat"
else
    echo "[20] WARN: no operator user for usermod — GPU/V4L2/audio may need manual group add" >&2
fi

# ---------------------------------------------------------------------------
# Session curation — Singularity is the ONLY session. Remove ALL X11 sessions
# (Wayland-only) and any non-Singularity wayland sessions.
# ---------------------------------------------------------------------------
mkdir -p /usr/share/xsessions.disabled /usr/share/wayland-sessions.disabled
if [ -d /usr/share/xsessions ]; then
    for f in /usr/share/xsessions/*.desktop; do
        [ -f "$f" ] && mv "$f" /usr/share/xsessions.disabled/ 2>/dev/null || true
    done
fi
for f in /usr/share/wayland-sessions/*.desktop; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in
        singularity.desktop) ;;  # keep
        *) mv "$f" /usr/share/wayland-sessions.disabled/ 2>/dev/null || true ;;
    esac
done
echo "[20] sessions curated: Singularity (Wayland) only; X11 sessions = none"

# ---------------------------------------------------------------------------
# XFCE/Xorg-desktop remnant sweep. In practice NOTHING here is installed:
# desktop.pkgs dropped xubuntu-core/xfce4-*, and the base already purged GNOME
# (build_base). So this is a guarded, TARGETED no-op safety net — we purge ONLY
# packages that are actually present, and NEVER --auto-remove (the r166-r170
# saga: a broad purge --auto-remove in the overlay cascaded ~80 maintainer
# scripts and truncated /etc/passwd,shadow,group → dpkg abort → install failed).
# Xwayland (/usr/bin/Xwayland) is KEPT — do NOT purge xwayland/xserver-common.
# ---------------------------------------------------------------------------
_to_purge=""
for p in xubuntu-core xfce4-session xfdesktop4 xfwm4 gnome-shell mutter; do
    dpkg -l "$p" 2>/dev/null | grep -q '^ii' && _to_purge="$_to_purge $p"
done
for p in $(dpkg -l 'xfce4-*' 2>/dev/null | awk '/^ii/{print $2}'); do _to_purge="$_to_purge $p"; done
if [ -n "$_to_purge" ]; then
    echo "[20] purging installed X11/XFCE remnants (no --auto-remove):$_to_purge"
    DEBIAN_FRONTEND=noninteractive apt-get purge -y $_to_purge 2>&1 | tail -3 || true
else
    echo "[20] no XFCE/X11-desktop packages present — nothing to purge (Singularity-only)"
fi

# Default browser routing — Chromium (mirror) primary; Vivaldi (52-vivaldi) if
# present. mimeapps + a runtime-resolving x-www-browser shim.
cat > /usr/local/bin/x-www-browser <<'BRWRAP'
#!/bin/sh
for b in /usr/bin/vivaldi-stable /usr/bin/chromium /usr/bin/chromium-browser; do
    [ -x "$b" ] && exec "$b" "$@"
done
exec xdg-open "$@"
BRWRAP
chmod 0755 /usr/local/bin/x-www-browser
if command -v chromium >/dev/null 2>&1; then _bd=chromium.desktop
elif command -v vivaldi-stable >/dev/null 2>&1; then _bd=vivaldi-stable.desktop
else _bd=chromium.desktop; fi
mkdir -p /etc/xdg
cat > /etc/xdg/mimeapps.list <<MIME
[Default Applications]
text/html=$_bd
x-scheme-handler/http=$_bd
x-scheme-handler/https=$_bd
application/xhtml+xml=$_bd
MIME
echo "[20] default browser: $_bd (Chromium shipped; Vivaldi via 52-vivaldi)"

# Appliance noise reduction — mask services that fail for no benefit here.
for u in iscsid.service apport.service; do
    if systemctl list-unit-files "$u" 2>/dev/null | grep -q "^$u"; then
        systemctl disable "$u" 2>&1 | sed 's/^/    /' || true
        systemctl mask    "$u" 2>&1 | sed 's/^/    /' || true
    fi
done

echo "[20] Singularity Desktop installed: /opt/singularity + LightDM-branded greeter (beta) + Wayland-only session"
