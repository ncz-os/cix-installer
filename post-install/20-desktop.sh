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
# GREETER (SHIP): greetd + NATIVE singularity-greeter (wlr-layer-shell + loginui,
# proven Mali-rendered (libmali/libEGL_cix, no llvmpipe), NCZ-branded, zero
# compromise. Greeter ships in the /opt/singularity payload; this hook installs
# the launch wrapper; 55-greeter writes the greetd config + branding.
#
# RUNS INSIDE CHROOT at desktop-layer bake time (build-squashfs-layers.sh
# desktop loop), NOT via install-time MACHINE_HOOKS.

set -euo pipefail
echo "[20] Singularity Desktop layer (labwc/wlroots + greetd/native singularity-greeter, Mali)"

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
# for X-app compat). GREETER = greetd + NATIVE singularity-greeter (ships in the
# /opt/singularity payload; renders via Cairo/loginui, no GTK). NO lightdm, NO
# Xorg server, NO XFCE, NO regreet. grim = greeter/lock screenshot util.
CORE_DESKTOP="greetd glycin-loaders \
    libgtk-4-1 libadwaita-1-0 libgtk4-layer-shell0 \
    libgee-0.8-2 libpeas-2-0 libjson-glib-1.0-0 libsoup-3.0-0 \
    libvte-2.91-gtk4-0 libgtksourceview-5-0 libwebkitgtk-6.0-4 \
    libgraphene-1.0-0 \
    foot xsettingsd seatd swaybg grim slurp fuzzel \
    xwayland \
    polkitd \
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

# Removable media + bluetooth. (NO network-manager-gnome — the native sinty-nm
# daemon replaces NetworkManager; see the "Native network" block below.)
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    gvfs gvfs-backends udisks2 bluez blueman 2>&1 | tail -3 || true
systemctl enable bluetooth 2>&1 | tail -1 || true

# ---------------------------------------------------------------------------
# Native network — sinty-nm (singularityos-lab/sinty-nm).
# sinty-nm is a static Go daemon that OWNS org.freedesktop.NetworkManager on the
# system bus and serves the same object tree, so nmcli / libnm / portals / the
# panel network indicator all keep working unchanged. It is a full NM REPLACEMENT
# (not a frontend): WiFi via iwd, L2/L3 via rtnetlink, IPv4 via a built-in DHCP
# client, VPN via WireGuard. Two daemons cannot own the name, so NetworkManager
# is purged + masked. Binary is a staged build-time blob (assets/sinty-nm/).
# ---------------------------------------------------------------------------
echo "[20] native network: sinty-nm (replaces NetworkManager)"
# Backends: iwd (WiFi) + wireguard-tools (VPN). Installed even on ethernet-only
# boards (O6N) for completeness across the fleet.
if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends iwd wireguard-tools; then
    ncz_ports_fallback
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends iwd wireguard-tools || \
        echo "[20] WARN: iwd/wireguard-tools install failed (WiFi/VPN backends)"
fi
SINTY_NMD=""
for c in /usr/local/lib/cix-installer/assets/sinty-nm/sinty-nmd \
         /cdrom/assets/sinty-nm/sinty-nmd \
         /run/cixmini/assets/sinty-nm/sinty-nmd; do
    [ -f "$c" ] && { SINTY_NMD="$c"; break; }
done
if [ -n "$SINTY_NMD" ]; then
    _AD="$(dirname "$SINTY_NMD")"
    install -m0755 "$SINTY_NMD" /usr/bin/sinty-nmd
    install -D -m0644 "$_AD/sinty-nm.service" /usr/lib/systemd/system/sinty-nm.service
    # D-Bus system policy — grants sinty-nmd ownership of the NM name (replaces
    # the policy NetworkManager used to ship; without it the bus refuses the name).
    install -D -m0644 "$_AD/org.freedesktop.NetworkManager.conf" \
        /usr/share/dbus-1/system.d/org.freedesktop.NetworkManager.conf
    # Purge NetworkManager + its GTK applet/editor (present-only, NEVER
    # --auto-remove — the r166-r170 truncated-/etc/passwd saga). Two daemons
    # cannot own org.freedesktop.NetworkManager.
    _nm_present=""
    for p in network-manager network-manager-gnome network-manager-applet nm-connection-editor; do
        dpkg -l "$p" 2>/dev/null | grep -q '^ii' && _nm_present="$_nm_present $p"
    done
    if [ -n "$_nm_present" ]; then
        echo "[20] purging NetworkManager (sinty-nm owns the name now):$_nm_present"
        DEBIAN_FRONTEND=noninteractive apt-get purge -y $_nm_present 2>&1 | tail -3 || true
    fi
    # Belt-and-braces: mask any NM units that survive (e.g. NM pulled back as a
    # dep) so they never contend for the bus name at boot.
    systemctl disable NetworkManager.service NetworkManager-wait-online.service \
        NetworkManager-dispatcher.service 2>/dev/null || true
    systemctl mask NetworkManager.service NetworkManager-wait-online.service 2>/dev/null || true
    # sinty-nm writes /etc/resolv.conf directly — it must be a writable regular
    # file, not a read-only/systemd-resolved symlink.
    if [ -L /etc/resolv.conf ] || [ ! -e /etc/resolv.conf ]; then
        rm -f /etc/resolv.conf
        : > /etc/resolv.conf
        chmod 0644 /etc/resolv.conf
    fi
    systemctl enable iwd.service 2>/dev/null || true
    systemctl enable sinty-nm.service 2>/dev/null || true
    echo "[20] sinty-nm installed + enabled (iwd WiFi backend, WireGuard VPN); NetworkManager purged/masked"
else
    echo "[20] WARN: assets/sinty-nm/sinty-nmd not staged — falling back to NetworkManager" >&2
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends network-manager 2>&1 | tail -2 || true
    systemctl enable NetworkManager 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Native keyring — singularity-keyring (in /opt/singularity) is THE Secret
# Service. Its D-Bus-activated org.freedesktop.secrets service ships in the
# payload; it only wins if gnome-keyring is NOT present (gnome-keyring grabs the
# name first at session start). Purge gnome-keyring (takes seahorse — a
# gnome-keyring frontend — with it) and remove its autostart so the native
# daemon is D-Bus-activated on first secrets request.
# ---------------------------------------------------------------------------
_gk_present=""
for p in gnome-keyring seahorse; do
    dpkg -l "$p" 2>/dev/null | grep -q '^ii' && _gk_present="$_gk_present $p"
done
if [ -n "$_gk_present" ]; then
    echo "[20] purging gnome-keyring (native singularity-keyring is the Secret Service):$_gk_present"
    DEBIAN_FRONTEND=noninteractive apt-get purge -y $_gk_present 2>&1 | tail -3 || true
fi
rm -f /etc/xdg/autostart/gnome-keyring-*.desktop 2>/dev/null || true
echo "[20] keyring: native singularity-keyring (org.freedesktop.secrets, D-Bus-activated)"

# Fonts: Noto base + CJK + colour emoji.
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    fonts-noto-core fonts-noto-cjk fonts-noto-color-emoji fonts-liberation 2>&1 | tail -3 || true

# Video: mpv HW player (84-vpu-mpv wires hwdec=v4l2m2m-copy). Browser = Vivaldi
# (52-vivaldi, real arm64 .deb) — resolute has no chromium deb (snap-only).
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    mpv 2>&1 | tail -3 || echo "[20] mpv: deferred"

echo "[20] runtime deps installed (Singularity libs + Wayland stack + Xwayland + audio + mpv)"

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
# Default terminal = the native Singularity terminal (singularity-leafs, VTE).
# foot is kept installed as a fallback for the scripted NCZ installer launchers
# (they need foot's --hold/-T flags, which leafs does not expose) and greeter
# recovery.
if command -v singularity-leafs >/dev/null 2>&1; then
    export TERMINAL=singularity-leafs
else
    export TERMINAL=foot
fi
# Native Wayland screensaver (idle->lock). Started once the compositor socket is
# up; backgrounded, dies with the session. Wayland-native (swayidle -> the native
# Singularity lockscreen); no X11. ncz-idle-manager reads the dev.ncz.screensaver
# GSettings schema and restarts swayidle live when the operator changes a setting
# in the "Screensaver & Lock" app — timeouts are configured, NOT hardcoded.
# Installed by 57-screensaver.sh.
if command -v swayidle >/dev/null 2>&1 && [ -x /usr/local/bin/ncz-idle-manager ]; then
    (
        _wd="${WAYLAND_DISPLAY:-wayland-0}"
        _rt="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
        _i=0
        while [ ! -S "$_rt/$_wd" ] && [ $_i -lt 100 ]; do sleep 0.2; _i=$((_i+1)); done
        export WAYLAND_DISPLAY="$_wd"
        exec /usr/local/bin/ncz-idle-manager
    ) &
fi
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
# NATIVE greeter wrapper — singularity-greeter (wlr-layer-shell + loginui) on the
# /opt/singularity labwc, CIX Mali GLES. The greeter binary itself ships in the
# /opt/singularity payload (extracted above), so there is NO separate greeter
# binary to stage — just the launch wrapper. 55-greeter writes the greetd +
# greeter-labwc config + NCZ branding. No regreet, no GTK, no portal/dead-bus hack
# (the native greeter draws with Cairo/loginui — it never touches GTK or a portal).
# ---------------------------------------------------------------------------
cat > /usr/local/bin/ncz-singularity-greeter <<'GRW'
#!/bin/sh
# ncz-singularity-greeter — NCZ-OS greetd greeter: NATIVE singularity-greeter
# (raw Wayland wlr-layer-shell + Cairo/loginui) on the SAME /opt/singularity
# labwc as the session, on CIX Mali GLES (libmali). No GTK, no regreet.
if [ -r /usr/local/bin/ncz-gpu-env ]; then . /usr/local/bin/ncz-gpu-env; fi
unset LIBGL_ALWAYS_SOFTWARE
export XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=labwc
export PATH="/opt/singularity/bin:$PATH"
export GSETTINGS_SCHEMA_DIR=/opt/singularity/share/glib-2.0/schemas
export XDG_DATA_DIRS="/opt/singularity/share:/usr/local/share:/usr/share"
export LD_LIBRARY_PATH="/opt/singularity/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
# _greetd cannot mkdir under /var/log at runtime; 55-greeter pre-creates the dir
# (tmpfiles), but fall back to XDG_RUNTIME_DIR so the exec redirect never fails
# (a failed redirect makes the wrapper exit before exec -> "greeter exited without
# creating a session" -> greetd crash-loop).
LOGDIR=/var/log/singularity-greeter
{ mkdir -p "$LOGDIR" && : >>"$LOGDIR/greeter.log"; } 2>/dev/null || LOGDIR="${XDG_RUNTIME_DIR:-/tmp}"
exec /opt/singularity/bin/labwc -C /etc/greetd/singularity-labwc >>"$LOGDIR/greeter.log" 2>&1
GRW
chmod 0755 /usr/local/bin/ncz-singularity-greeter
echo "[20] ncz-singularity-greeter wrapper installed (native greeter on /opt/singularity labwc)"

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
# greetd = the display manager (SHIP greeter). The native singularity-greeter is
# wired by 55-greeter (config.toml, greeter labwc config, branding, tmpfiles);
# this hook installs the ncz-singularity-greeter wrapper above. Here we make
# greetd the DM and put the _greetd user in the seat/GPU groups so labwc/wlroots
# can open the DRM/seat. Singularity is the ONLY session.
# VALIDATED (O6N/Mali): the native greeter renders (NCZ Maximilian backdrop,
# loginui clock, user picker, Password auth, Singularity session) and a real
# login through greetd succeeds. Boot-path (splash->greeter) metal timing is
# tangled with the Sky1 DP-link-training work — validate on-metal with that fix.
# ---------------------------------------------------------------------------
systemctl disable gdm gdm3 2>/dev/null || true
systemctl stop gdm gdm3 2>/dev/null || true
# Ensure no lightdm lingers as a competing DM (belt-and-braces; not installed).
systemctl disable lightdm 2>/dev/null || true
rm -f /etc/X11/default-display-manager 2>/dev/null || true
systemctl set-default graphical.target
systemctl enable greetd 2>/dev/null || true
ln -sf /lib/systemd/system/greetd.service /etc/systemd/system/display-manager.service

# seatd for seat management under Wayland (labwc/wlroots). greetd's labwc opens
# the seat via seatd/logind.
systemctl enable seatd 2>/dev/null || true

# _greetd user (created by the greetd package) needs GPU + seat + input access so
# labwc can render the greeter on Mali.
if id _greetd >/dev/null 2>&1; then
    for g in video render input seat; do
        getent group "$g" >/dev/null 2>&1 && usermod -aG "$g" _greetd 2>/dev/null || true
    done
    echo "[20] _greetd added to video/render/input/seat"
fi
echo "[20] greetd = display manager (native singularity-greeter wired by 55-greeter)"

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

# Default browser routing — Vivaldi (52-vivaldi, real arm64 .deb) primary.
# mimeapps + a runtime-resolving x-www-browser shim (chromium only if an
# operator later sideloads it).
cat > /usr/local/bin/x-www-browser <<'BRWRAP'
#!/bin/sh
for b in /usr/bin/vivaldi-stable /usr/bin/chromium /usr/bin/chromium-browser; do
    [ -x "$b" ] && exec "$b" "$@"
done
exec xdg-open "$@"
BRWRAP
chmod 0755 /usr/local/bin/x-www-browser
_bd=vivaldi-stable.desktop
mkdir -p /etc/xdg
cat > /etc/xdg/mimeapps.list <<MIME
[Default Applications]
text/html=$_bd
x-scheme-handler/http=$_bd
x-scheme-handler/https=$_bd
application/xhtml+xml=$_bd
MIME
echo "[20] default browser: $_bd (Vivaldi via 52-vivaldi; resolute has no chromium deb)"

# Appliance noise reduction — mask services that fail for no benefit here.
for u in iscsid.service apport.service; do
    if systemctl list-unit-files "$u" 2>/dev/null | grep -q "^$u"; then
        systemctl disable "$u" 2>&1 | sed 's/^/    /' || true
        systemctl mask    "$u" 2>&1 | sed 's/^/    /' || true
    fi
done

echo "[20] Singularity Desktop installed: /opt/singularity + greetd/native singularity-greeter (Mali) + Wayland-only session"
