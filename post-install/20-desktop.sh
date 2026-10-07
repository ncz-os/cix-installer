#!/bin/bash
# NCZ-MIXED-HOOK: Singularity desktop install; arm64 chromium-ncz-sky1 wrapper plus amd64 branch (line ~961); TODO split arch branches (docs/platform-inventory.tsv; runs on every platform, listed in both hooks.list files)
# 20-desktop.sh — NCZ-OS 26.7 "Maximilian" Singularity Desktop installer.
#
# Singularity Desktop (labwc/wlroots, GTK4/Vala, GLES on CIX libmali) is THE
# desktop. XFCE/X11 is GONE — no Xorg display server, no XFCE session. Wayland
# native, Mali-accelerated. Xwayland is kept (labwc -Dxwayland=enabled) for
# X-app compatibility UNDER Wayland — that is rootless X-compat, not an X11
# desktop. The /opt/singularity runtime is installed from the NCZ-OS apt repo;
# the package postinst configures its shared-library path.
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
    server|headless)
        echo "[20] BUILD_VARIANT=$VARIANT — Server headless SKU; skipping desktop install"
        exit 0
        ;;
esac

# ---------------------------------------------------------------------------
# Offline package install from the bundled /cdrom pool (r130 fat-ISO doctrine).
# The full Singularity runtime closure lives in manifests/desktop.pkgs, mirrored
# by build-desktop-mirror.sh into the ISO pool.  The profile's signed base
# source remains the only online fallback; never add a foreign Ubuntu source.
# ---------------------------------------------------------------------------
echo "[20] desktop packages install OFFLINE from bundled /cdrom pool"
RELEASE=/usr/local/lib/cix-installer/RELEASE
if [ -r "$RELEASE" ]; then
    # shellcheck disable=SC1090
    . "$RELEASE"
fi
NCZ_APT_SUITE="${NCZ_BASE_CODENAME:-forky}"
if [ -d "/cdrom/dists/$NCZ_APT_SUITE" ] && [ ! -f /etc/apt/sources.list.d/cixmini-cdrom.list ]; then
    echo "deb [trusted=yes] file:///cdrom $NCZ_APT_SUITE main" \
        > /etc/apt/sources.list.d/cixmini-cdrom.list
fi
APT_REFRESH_STAMP=/var/lib/apt/lists/.ncz-installer-refreshed
if [ -f "$APT_REFRESH_STAMP" ] && \
   find "$APT_REFRESH_STAMP" -mmin -10 -print -quit 2>/dev/null | grep -q .; then
    echo "[20] package index is current — skipping duplicate apt-get update"
else
    if apt-get update -o Acquire::http::Timeout=8 -o Acquire::https::Timeout=8 \
        -o Acquire::Retries=0 -o Acquire::ForceIPv4=true -q; then
        touch "$APT_REFRESH_STAMP"
    fi
fi

ncz_ports_fallback() {
    # The profile base source is written by 23-base-apt-sources.sh and is
    # already authenticated.  Reuse it instead of crossing distributions.
    echo "[20] WARN: package missing from bundled pool — using the configured NCZ base source"
    if apt-get update -o Acquire::http::Timeout=8 -o Acquire::https::Timeout=8 \
        -o Acquire::Retries=0 -o Acquire::ForceIPv4=true -q; then
        touch "$APT_REFRESH_STAMP"
    fi
}

# Pre-purge any inherited GNOME display manager — it would claim
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
    libgtk-4-1 gir1.2-gtk-4.0 python3-gi libnotify-bin libadwaita-1-0 libgtk4-layer-shell0 \
    libgee-0.8-2 libpeas-2-0 libjson-glib-1.0-0 libsoup-3.0-0 \
    libvte-2.91-gtk4-0 libgtksourceview-5-0 libwebkitgtk-6.0-4 \
    libgraphene-1.0-0 libtinysparql-3.0-0 libupower-glib3 \
    libdbusmenu-glib4 libsodium26 upower \
    foot xsettingsd seatd libseat1 libliftoff0 libinput10 \
    libxcb-composite0 libxcb-ewmh2 libxcb-icccm4 libxcb-res0 libxcb-errors0 \
    swaybg grim slurp fuzzel \
    xwayland \
    polkitd rtkit \
    mesa-utils vulkan-tools libglu1-mesa vainfo \
    libglib2.0-bin"
if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $CORE_DESKTOP; then
    ncz_ports_fallback
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $CORE_DESKTOP || \
        echo "[20] WARN: some core desktop pkgs failed (see closure)"
fi

# chromium-ncz-sky1's launcher wrapper is baked into that package (no source
# recipe of its own -- the .deb is built externally). On this board, Chromium's
# audio-service out-of-process isolation delivers structurally silent PCM to a
# correctly-negotiated PipeWire/Pulse stream (confirmed live: 0% nonzero bytes
# at the sink monitor despite a healthy-looking stream; disabling isolation
# restored real audio, 89.4-93.9% nonzero on repeat captures). Overwrite the
# wrapper post-install so the fix ships regardless of what the upstream .deb
# contains. Idempotent -- only touches the file if the package installed it.
if [ -f /usr/bin/chromium-ncz-sky1 ]; then
    cat > /usr/bin/chromium-ncz-sky1 <<'CHROMIUMWRAPPER'
#!/bin/sh
# Chromium NCZ Sky1 Edition launcher.
#
# Render node: Chromium defaults to the first DRM render node it finds
# (/dev/dri/renderD128). On boards where more than one linlondp instance is
# present -- MS-R1 exposes card0..card3 as CIXH5010:00/:01/:03/:04 with
# renderD128..renderD131 -- that is not the node backing the display, and
# the GPU goes unused. Derive it from whichever connector actually reports
# "connected", the same way ncz-wlr-connected-drm derives WLR_DRM_DEVICES.
# Measured on O6N: card0-DP-2 connected -> renderD128, which is the node
# that board already ran with.
render_node=
for status in /sys/class/drm/card*-*/status; do
    [ -r "$status" ] || continue
    [ "$(cat "$status" 2>/dev/null)" = connected ] || continue
    card=${status#*/drm/}
    card=${card%%-*}
    card_device=$(readlink -f "/sys/class/drm/$card/device" 2>/dev/null) || continue
    [ -n "$card_device" ] || continue
    for render in /sys/class/drm/renderD*; do
        [ -e "$render/device" ] || continue
        [ "$(readlink -f "$render/device")" = "$card_device" ] || continue
        node="/dev/dri/${render##*/}"
        if [ -c "$node" ]; then
            render_node=$node
            break
        fi
    done
    [ -n "$render_node" ] && break
done

# Video decode (measured 2026-10-06 on O6N and MS-R1, docs/SKY1-MEDIA-STATUS.md):
# this build has the V4L2 stateful decoder and no VA-API (no libva in the
# binary), so AcceleratedVideoDecoder is the one switch that matters; it puts
# H.264, VP9 and AV1 (1080p and 2160p) on the VPU via V4L2VideoDecoder at
# real-time speed. VA-API feature names (VaapiVideoDecoder...) would be dead
# weight. HEVC is advertised but fails in this build (PIPELINE_ERROR_DECODE).
# Audio: with AudioServiceOutOfProcess disabled, streams reach PipeWire and
# play normally once the default sink works; a broken default sink stalls the
# media clock and freezes video too, which the audio autoswitch now prevents.
set -- --ozone-platform=wayland \
  --enable-features=AcceleratedVideoDecoder \
  --disable-features=AudioServiceOutOfProcess,AudioServiceSandbox \
  "$@"
# No connected output (headless boot, display asleep): leave Chromium's own
# default rather than pinning a node that may be the wrong one.
[ -n "$render_node" ] && set -- "--render-node-override=$render_node" "$@"
exec /opt/chromium-ncz-sky1/chrome "$@"
CHROMIUMWRAPPER
    chmod 0755 /usr/bin/chromium-ncz-sky1
    echo "[20] chromium-ncz-sky1 wrapper: disabled AudioServiceOutOfProcess/AudioServiceSandbox (silent-PCM fix)"
else
    echo "[20] WARN: chromium-ncz-sky1 wrapper not found; audio fix not applied" >&2
fi

# Audio: PipeWire stack so HDMI/analog reaches apps; pavucontrol for control.
# pulseaudio-utils supplies pactl. PipeWire Pulse supports pactl load-module
# for module-alsa-sink, which the Sky1 HDMI/DP autoswitch helper uses without
# putting static objects in pipewire.conf.d. The helper also needs aplay
# (alsa-utils: hw_params probe of a DP/HDMI PCM before it becomes a sink) and
# pw-dump (pipewire-bin, a pipewire dependency: spots sinks stuck in "error").
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    pipewire pipewire-pulse pipewire-alsa wireplumber pavucontrol pulseaudio-utils alsa-utils 2>&1 | tail -3 || true
systemctl --global enable pipewire pipewire-pulse wireplumber 2>&1 | tail -2 || true

# Asset lookup (2026-09-29 regression fix): the ISO installer exposes the payload
# at /cdrom/ncz-payload, but the image install path has no /cdrom -- there the
# same payload is already copied into the target at
# /usr/local/lib/cix-installer. Looking only under /cdrom skipped this block on
# the image (build 28a868c), so the target had a card but only PipeWire's Dummy
# Output sink. Search both roots; stay loud if neither has the files.
_audio_root=""
for _r in /cdrom/ncz-payload /usr/local/lib/cix-installer; do
    if [ -f "$_r/assets/audio/ncz-sky1-audio-autoswitch.py" ] && \
       [ -f "$_r/assets/audio/ncz-sky1-audio-autoswitch.service" ]; then
        _audio_root="$_r"
        break
    fi
done
if [ -n "$_audio_root" ]; then
    install -m 0755 "$_audio_root/assets/audio/ncz-sky1-audio-autoswitch.py" \
        /usr/local/bin/ncz-sky1-audio-autoswitch
    install -d -m 0755 /etc/systemd/user /usr/share/doc
    install -m 0644 "$_audio_root/assets/audio/ncz-sky1-audio-autoswitch.service" \
        /etc/systemd/user/ncz-sky1-audio-autoswitch.service
    if [ -f "$_audio_root/docs/NCZ-SKY1-AUDIO-AUTOSWITCH.md" ]; then
        install -m 0644 "$_audio_root/docs/NCZ-SKY1-AUDIO-AUTOSWITCH.md" \
            /usr/share/doc/ncz-sky1-audio-autoswitch.md
    fi
    systemctl --global enable ncz-sky1-audio-autoswitch.service 2>&1 | tail -2 || true
    echo "[20] Sky1 HDMI/DP audio autoswitch user service staged (from $_audio_root)"
else
    echo "[20] WARN: Sky1 HDMI/DP audio autoswitch assets not found under /cdrom/ncz-payload or /usr/local/lib/cix-installer; the desktop will have a Dummy Output sink only" >&2
fi

# HiDPI output scale (docs/HIDPI-SCALING.md). ncz-display-scale holds the NCZ
# density policy (>= 192 ppi -> 2, >= 144 ppi -> 1.5, else 1; no or implausible
# EDID size -> 1). 55-greeter.sh calls it to pick the greeter mode and scale.
# The per-login user unit is a first-login safety net only: the Singularity
# shell derives its own default for an output with no saved setting, and the
# helper raises an output only when it is still at 1.0 after the shell settled,
# never once ~/.config/singularity/displays.json exists, and once per display.
_display_root=""
for _r in /cdrom/ncz-payload /usr/local/lib/cix-installer; do
    if [ -f "$_r/assets/display/ncz-display-scale" ]; then
        _display_root="$_r"
        break
    fi
done
if [ -n "$_display_root" ]; then
    install -m 0755 "$_display_root/assets/display/ncz-display-scale" /usr/local/bin/ncz-display-scale
    install -d -m 0755 /usr/lib/systemd/user
    cat > /usr/lib/systemd/user/ncz-display-scale.service <<'DISPLAYSCALE'
[Unit]
Description=NCZ first-login HiDPI output scale (docs/HIDPI-SCALING.md)
PartOf=singularity-session.target graphical-session.target
After=singularity-session.target graphical-session.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ncz-display-scale session
TimeoutStartSec=60

[Install]
WantedBy=singularity-session.target
DISPLAYSCALE
    chmod 0644 /usr/lib/systemd/user/ncz-display-scale.service
    if systemctl --global enable ncz-display-scale.service >/dev/null 2>&1; then
        echo "[20] ncz-display-scale installed; first-login scale unit enabled for all users"
    else
        echo "[20] WARN: could not globally enable ncz-display-scale.service" >&2
    fi
else
    echo "[20] WARN: assets/display/ncz-display-scale not found under /cdrom/ncz-payload or /usr/local/lib/cix-installer; greeter keeps its fixed 1080p mode and no first-login scale safety net" >&2
fi

# Removable media + bluetooth. (NO network-manager-gnome — the base-layer
# sinty-nm daemon replaces NetworkManager.)
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    gvfs gvfs-backends udisks2 bluez blueman 2>&1 | tail -3 || true
systemctl enable bluetooth 2>&1 | tail -1 || true

# Make bluetooth-autoconnect conditional on there actually being a radio.
#
# The vendor cix-debian-misc postinst enables bluetooth-autoconnect and we keep
# that enable (25-cix-proprietary.sh) because boards WITH Bluetooth want it. But
# the unit ships no condition of its own: on hardware without an adapter it runs
# regardless, its Python entry point raises, and every boot ends with a
# permanently failed unit.
#
# Measured on O6N, which has no Bluetooth at all: /sys/class/bluetooth exists but
# is EMPTY (0 entries, 0 hci*, 0 rfkill lines), and bluetooth-autoconnect was the
# ONLY failed unit in the shipped image. With this drop-in systemd reports
# "skipped, unmet condition check" and the board reaches zero failed units.
#
# A failed Condition SKIPS a unit rather than failing it, so this stays correct
# on boards that do have a radio: there the glob matches and the service starts
# exactly as before. Verified in both states on O6N 2026-08-16.
install -d -m 0755 /etc/systemd/system/bluetooth-autoconnect.service.d
cat > /etc/systemd/system/bluetooth-autoconnect.service.d/10-ncz-require-adapter.conf <<'BTCOND'
[Unit]
ConditionPathExistsGlob=/sys/class/bluetooth/*
BTCOND
echo "[20] bluetooth-autoconnect gated on an actual Bluetooth adapter"

# sinty-nm is installed by 19-sinty-nm.sh in the base layer before any desktop
# hook runs. Desktop code may assume /usr/bin/sinty-nmd is present when the
# staged asset exists; 33-network.sh preserves the NetworkManager/netplan
# fallback when it does not.
if [ -x /usr/bin/sinty-nmd ]; then
    echo "[20] native network: sinty-nm already installed by base"
else
    echo "[20] native network: base fallback is NetworkManager (sinty-nm asset absent)"
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

# ---------------------------------------------------------------------------
# Online Accounts (GOA) + the singularity xdg-desktop-portal backend.
#
# Both were shipping with real, complete UI/backend code and no way to run:
#
# - accounts_page.vala (singularity-shell) links against libgoa-1.0 and talks
#   to org.gnome.OnlineAccounts over D-Bus, but only libgoa-1.0-dev (build
#   headers) was ever pulled in -- the actual goa-daemon runtime package was
#   never installed. "Add Account" had nothing to talk to.
#
# - xdg-desktop-portal-singularity implements Screenshot/ScreenCast/etc and
#   installs cleanly (singularity.portal, its systemd --user unit, all
#   correct). xdg-desktop-portal itself resolves and routes requests to it
#   (confirmed live: `gdbus call ... org.freedesktop.portal.Screenshot`
#   returns a valid request object). But its unit ships `preset: enabled`
#   with actual state `disabled` -- the preset was never applied for the real
#   user, so xdg-desktop-portal-singularity.service never activates
#   (`Active: inactive (dead)`, zero journal entries). Every other
#   user-session service in this file gets `systemctl --global enable`
#   (pipewire, wireplumber, the audio-autoswitch unit, wallpaper units) --
#   this one was simply missing from that list.
#
# Confirmed live on O6N 2026-08-27: `systemctl --user status goa-daemon`
# reports "could not be found"; `systemctl --user status
# xdg-desktop-portal-singularity` reports "inactive (dead)" with no journal
# entries despite the portal router successfully dispatching to it.
# ---------------------------------------------------------------------------
if DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    gnome-online-accounts 2>&1 | tail -5; then
    echo "[20] GOA runtime installed"
else
    echo "[20] WARN: gnome-online-accounts install failed -- Online Accounts UI will have nothing to talk to (see closure)" >&2
fi
systemctl --global enable xdg-desktop-portal-singularity.service 2>&1 | tail -2 || true
echo "[20] singularity portal backend: enabled"

# Fonts: Noto base + CJK + colour emoji.
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    fonts-noto-core fonts-noto-cjk fonts-noto-color-emoji fonts-liberation 2>&1 | tail -3 || true

# Video: mpv HW player (84-vpu-mpv wires hwdec=v4l2m2m-copy). Browsers =
# Vivaldi (52-vivaldi, real arm64 .deb, default) and (26.7+) real official
# Google Chrome (google-chrome-stable, post-install/53-chrome.sh) — both
# folded into the offline desktop mirror by build-desktop-mirror.sh, neither
# as a live runtime apt source. Ubuntu Resolute's own chromium-browser
# package remains snap-only; NCZ-OS does not ship snapd. (An earlier
# ungoogled-chromium/XtraDeb stop-gap was dropped 2026-07-27 once real Chrome
# became available for arm64 — superseded outright.)
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    mpv 2>&1 | tail -3 || echo "[20] mpv: deferred"

echo "[20] runtime deps installed (Singularity libs + Wayland stack + Xwayland + audio + mpv)"

# ---------------------------------------------------------------------------
# Diagnostics: real crash traceability for the Singularity desktop session.
# apport's coredump handler doesn't reliably capture desktop-session crashes
# under a Wayland compositor; systemd-coredump does (verified live on O6N —
# apt swaps apport-core-dump-handler for it, expected/safe, they're mutually
# exclusive coredump handlers). G_MESSAGES_DEBUG=all surfaces GLib/GTK4
# warning/debug output the Vala-based Singularity Desktop binaries would
# otherwise swallow silently on error exit (observed: a real session crash
# left literally zero output in its own log, exit code only).
# ---------------------------------------------------------------------------
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    systemd-coredump 2>&1 | tail -3 || true
ENVF=/etc/environment
touch "$ENVF"
set_env() {  # key value — idempotent replace-or-append
    local k="$1" v="$2"
    if grep -q "^${k}=" "$ENVF" 2>/dev/null; then
        sed -i "s|^${k}=.*|${k}=${v}|" "$ENVF"
    else
        echo "${k}=${v}" >> "$ENVF"
    fi
}
set_env G_MESSAGES_DEBUG all
echo "[20] diagnostics: systemd-coredump installed, G_MESSAGES_DEBUG=all set"

# ---------------------------------------------------------------------------
# Install the Singularity payload from the NCZ-OS apt repository.
# post-install/24-apt-sources.sh wires the signed Buildkite Packages (primary)
# + Cloudflare R2 (backup) sources and refreshes the index before this hook
# runs. The package postinst owns ldconfig setup.
# ---------------------------------------------------------------------------
echo "[20] installing Singularity Desktop payload"
# 2026-09-13: guard the /cdrom existence check OUTSIDE the pipeline, same
# class of bug fixed in post-install/10-our-kernel.sh's local_deb() the
# same day. Under `set -euo pipefail` (active in this script), `find` on
# a missing /cdrom/pool/main -- the normal case at squashfs-layer BUILD
# time, since /cdrom only exists when running from the live installed ISO
# -- exits non-zero; pipefail then makes the whole `find | sort -V |
# tail -1` pipeline non-zero, which `set -e` treats as fatal on the
# `VAR=$(...)` assignment, silently killing this hook (the real find
# error was swallowed by 2>/dev/null) before it ever reaches the
# apt-get-install fallback both of these blocks intend to fall through to.
if [ -d /cdrom/pool/main ]; then
    UPOWER_DEB=$(find /cdrom/pool/main -maxdepth 1 -type f -name 'upower_*.deb' 2>/dev/null | sort -V | tail -1)
else
    UPOWER_DEB=""
fi
if [ -n "$UPOWER_DEB" ] && ! dpkg-query -W -f='${Status}\n' upower 2>/dev/null | grep -q '^install ok installed$'; then
    echo "[20] using embedded upower deb: $(basename "$UPOWER_DEB")"
    dpkg -i --force-depends "$UPOWER_DEB" || true
fi
SINTY_DEB=""
# Candidate order matters: the LAST directory that has a deb wins. The payload copy on the install
# medium is built by the same make run as the image, so it goes last. The copy under
# /usr/local/lib/cix-installer/assets/cix-debs is baked into base.squashfs and can be a build older
# than the image (same 20260929+bk0 version string, different content): on 2026-09-29 that stale
# deb was dpkg -i'd over the fresh hotfix layer and every singularity plugin patch was silently
# lost (found by the gate: the Bing plugin lacked its patched Preferred market string).
for _d in /cdrom/pool/main /usr/local/lib/cix-installer/assets/cix-debs /cdrom/ncz-payload/assets/cix-debs; do
    [ -d "$_d" ] || continue
    _c=$(find "$_d" -maxdepth 1 -type f -name 'ncz-singularity-desktop_*.deb' 2>/dev/null | sort -V | tail -1)
    [ -n "$_c" ] && SINTY_DEB="$_c"
done
if [ -n "$SINTY_DEB" ]; then
    echo "[20] using embedded payload deb: $(basename "$SINTY_DEB")"
    dpkg -i "$SINTY_DEB"
elif ! DEBIAN_FRONTEND=noninteractive apt-get install -y ncz-singularity-desktop; then
    # The registry ncz-apt row is required=yes on arm64 desktop. This FATAL
    # is that row, enforced at install time (phase 2). The staged-deb path
    # above is optional and already won if a payload deb was present.
    echo "[20] FATAL: ncz-singularity-desktop not installable from the NCZ-OS apt repo — desktop cannot install (registry: ncz-apt required=yes)" >&2
    echo "[20]        check post-install/24-apt-sources.sh wired the repo, and that the package was published (build/build-singularity-deb.sh)" >&2
    exit 1
fi
test -x /opt/singularity/bin/singularity-desktop
test -x /opt/singularity/bin/singularity-labwc-session

# The packaged Singularity portal unit lives below the isolated /opt prefix,
# which systemd --user does not search.  Its generated launcher also omits the
# payload's actual libexecdir.  Without these two bridges xdg-desktop-portal
# selects singularity.portal but cannot activate
# org.freedesktop.impl.portal.desktop.singularity; the shell logs backend errors
# during every login.  Keep the payload immutable and expose a tiny stable
# launcher plus an /etc user-unit symlink (both survive package upgrades).
if [ -x /opt/singularity/libexec/xdg-desktop-portal-singularity ] && \
   [ -f /opt/singularity/lib/systemd/user/xdg-desktop-portal-singularity.service ]; then
    cat > /usr/local/bin/xdg-desktop-portal-singularity <<'PORTAL'
#!/bin/sh
exec /opt/singularity/libexec/xdg-desktop-portal-singularity "$@"
PORTAL
    chmod 0755 /usr/local/bin/xdg-desktop-portal-singularity
    install -d -m0755 /etc/systemd/user
    ln -sfn /opt/singularity/lib/systemd/user/xdg-desktop-portal-singularity.service \
        /etc/systemd/user/xdg-desktop-portal-singularity.service
    # The comment above only diagnosed HALF the problem. Bridging the
    # systemd user-unit is necessary but not sufficient: xdg-desktop-portal
    # discovers available backends by scanning
    # /usr/share/xdg-desktop-portal/portals/*.portal (plus a couple of other
    # real XDG search paths) -- NOT /opt/singularity/share/.../portals/,
    # where the payload actually ships singularity.portal. Without staging
    # the declaration file itself, xdg-desktop-portal has no way to know a
    # "singularity" backend exists at all, so it can never be selected for
    # ANY interface (Screenshot included), regardless of the service-unit
    # bridge above. Confirmed live on O6N 2026-08-25: Singularity's own
    # screenshot utility reported it could not take screenshots; staging
    # this file and restarting xdg-desktop-portal.service made the
    # 'singularity' backend selectable immediately.
    if [ -f /opt/singularity/share/xdg-desktop-portal/portals/singularity.portal ]; then
        install -d -m0755 /usr/share/xdg-desktop-portal/portals
        install -m0644 /opt/singularity/share/xdg-desktop-portal/portals/singularity.portal \
            /usr/share/xdg-desktop-portal/portals/singularity.portal
        echo "[20] staged singularity.portal declaration (Screenshot/ScreenCast/etc now discoverable)"
    else
        echo "[20] WARN: singularity.portal declaration missing from payload; backend will never be selected" >&2
    fi
    echo "[20] wired Singularity portal into systemd user-unit path"
else
    echo "[20] WARN: Singularity portal payload missing; falling back to stock wlr backend" >&2
    # No dedicated Singularity portal binary on this build. The payload still
    # ships a portals.conf that prefers the stock wlr backend (it implements
    # Screenshot/ScreenCast and labwc is wlroots-based), but xdg-desktop-portal
    # only reads <lowercased-XDG_CURRENT_DESKTOP>-portals.conf from its real
    # search path ($XDG_CONFIG_HOME/xdg-desktop-portal/, then
    # /etc/xdg-desktop-portal/) -- the shipped file sits at
    # /opt/singularity/share/xdg-desktop-portal/labwc-portals.conf, named for
    # the wrong desktop id (this session reports XDG_CURRENT_DESKTOP=Singularity,
    # not labwc) and outside any path xdg-desktop-portal actually searches, so
    # it was silently never applied -- xdg-desktop-portal-wlr never started and
    # screenshots failed with "screenshot service unavailable" (confirmed live
    # on O6N 2026-08-25). Stage it under the correct name and location.
    if [ -f /opt/singularity/share/xdg-desktop-portal/labwc-portals.conf ]; then
        install -d -m0755 /etc/xdg-desktop-portal
        # Write our own singularity-portals.conf rather than copying the
        # payload's file verbatim: the payload's [preferred] default=wlr;*
        # wildcard falls back to ANY installed backend for interfaces wlr
        # does not implement -- confirmed live on O6N 2026-08-25, this pulled
        # in kwallet.portal (org.kde.ksecretd) for org.freedesktop.impl.portal.Secret
        # purely because kwalletd happened to be present, spawning unwanted
        # KDE Wallet prompts on a GTK/labwc desktop that never asked for KDE's
        # secret storage. Keep the wlr preference (Screenshot/ScreenCast) but
        # explicitly disable Secret so the wildcard can never pull it in.
        cat > /etc/xdg-desktop-portal/singularity-portals.conf <<'PORTALCONF'
[preferred]
default=wlr;*
org.freedesktop.impl.portal.Inhibit=none
org.freedesktop.impl.portal.Secret=none
PORTALCONF
        echo "[20] staged singularity-portals.conf (prefers wlr backend for Screenshot/ScreenCast, excludes KDE Wallet)"
    else
        echo "[20] WARN: no labwc-portals.conf in payload either; screenshots/screen-share will stay broken" >&2
    fi
fi

# graphical-session.target is systemd-hardened against direct manual start
# (RefuseManualStart) -- it must be reached via a unit that BindsTo= it.
# singularity-session (the session-launcher subproject) ships exactly that
# as config/systemd-user/singularity-session.target, installed under the
# same isolated /opt prefix as the portal unit above and needing the same
# bridge for the same reason: systemd --user does not search /opt.
#
# Without this bridge, xdg-desktop-portal-singularity.service (WantedBy=
# graphical-session.target, enabled a few lines above) is enabled but NEVER
# STARTS -- confirmed live on O6N 2026-08-27: portal routing worked and
# correctly selected the singularity backend for Screenshot, but the
# backend process itself never launched because nothing had ever started
# graphical-session.target on this system. Root-caused down to this exact
# missing symlink; fixed live, then reproduced from a clean session restart
# with the bridge in place -- both org.freedesktop.portal.Screenshot and
# the native singularity-screenshot binary produced real screenshots.
if [ -f /opt/singularity/lib/systemd/user/singularity-session.target ]; then
    install -d -m0755 /etc/systemd/user
    ln -sfn /opt/singularity/lib/systemd/user/singularity-session.target \
        /etc/systemd/user/singularity-session.target
    echo "[20] wired singularity-session.target into systemd user-unit path (graphical-session.target bridge)"
else
    echo "[20] WARN: singularity-session.target missing from payload; graphical-session.target will never start, breaking Screenshot/ScreenCast and anything else WantedBy=graphical-session.target" >&2
fi

# ---------------------------------------------------------------------------
# GPU userspace selector — ncz-gpu-env (Mali branch has NO
# __EGL_VENDOR_LIBRARY_FILENAMES pin: that pin blackscreens libmali, confirmed
# on O6N). Panthor branch keeps the mesa vendor ICD. Sourced by every session
# launcher AND the greeter wrapper so the SAME binaries render on whichever GPU
# stack booted (chosen per rEFInd entry). Panthor must be bound to a real DRM
# card, not merely resident in lsmod: Sky1's Linlon display controllers expose
# renderD* nodes too, and Mesa cannot render through those.
# ---------------------------------------------------------------------------
install -d -m0755 /usr/local/bin
cat > /usr/local/bin/ncz-gpu-env <<'GPUENV'
#!/bin/sh
# ncz-gpu-env — driver-aware GPU/GL userspace selector for NCZ-OS (CIX Sky1).
# SOURCE this ( ". /usr/local/bin/ncz-gpu-env" ) from every NCZ session launcher
# AND the greeter wrapper, so the SAME binaries render on whichever GPU stack the
# kernel booted. Mali (CIX libmali GLES blob, /dev/mali0, mali_kbase) and Panthor
# (open Mesa/panvk, panthor-bound DRM card) are mutually exclusive, chosen per
# rEFInd boot entry. POSIX sh; safe to source.
_ncz_drm_card_driven_by() {
    for _ncz_dev in "${NCZ_SYSROOT:-}"/sys/class/drm/card*/device/driver; do
        [ -e "$_ncz_dev" ] || continue
        [ "$(basename "$(readlink -f "$_ncz_dev")")" = "$1" ] && return 0
    done
    return 1
}

_ncz_panthor_live() {
    grep -q '^panthor ' "${NCZ_SYSROOT:-}"/proc/modules 2>/dev/null || return 1
    [ -e "${NCZ_SYSROOT:-}"/sys/bus/platform/drivers/panthor/CIXH5000:00 ] || return 1
    _ncz_drm_card_driven_by panthor || return 1
    return 0
}

# Non-Sky1 GPU stacks (amd64, and any other board this script runs on):
# amdgpu/i915/nouveau/radeon/nvidia all ship a working Mesa/glvnd stack out of
# the box and need NO vendor pin, unlike Mali/Panthor above. Before this
# check existed, EVERY amd64 box fell through to the unconditional software
# branch below regardless of having a perfectly good discrete or integrated
# GPU bound, because that branch only knows how to recognize Mali/Panthor.
# Metal-confirmed on MEDUSA (T2 MacBook, AMD Navi14): with this branch,
# NCZ_GPU_BACKEND=amdgpu, radeonsi loads on all EGL platforms, no
# software-render vars set. ncz-wlr-connected-drm (sourced separately by
# every caller of this file) independently picks the DRM device that
# actually has a connected output, so a dual-GPU box (iGPU + discrete) does
# not need explicit discrete-vs-integrated logic here.
_ncz_hw_gpu_driver() {
    for _ncz_drv in amdgpu i915 nouveau radeon nvidia nvidia-drm; do
        _ncz_drm_card_driven_by "$_ncz_drv" && { printf '%s' "$_ncz_drv"; return 0; }
    done
    return 1
}

if _ncz_hw_gpu_driver_name=$(_ncz_hw_gpu_driver); then
    NCZ_GPU_BACKEND=$_ncz_hw_gpu_driver_name
    export NCZ_GPU_BACKEND
    if [ "$_ncz_hw_gpu_driver_name" = amdgpu ]; then
        # singularity-desktop-session defaults GSK_RENDERER to GTK4's legacy
        # "gl" renderer unless already set. GTK4's DMABUF texture-import path
        # (dri2_query_image_common, called from gsk_renderer_render via
        # libEGL_mesa) segfaults singularity-desktop on Mesa 26.1.6/radeonsi
        # (Navi14) on a NULL __DRIimage handle -- a missing-null-check bug in
        # a caller upstream of Mesa (still under investigation as of
        # 2026-09-20, see MNEMOS/cix-installer issue tracking).
        # GSK_RENDERER=ngl does NOT fix this: metal-confirmed on MEDUSA the
        # identical crash still happens under ngl, just later (37-94s
        # instead of immediately) -- the timing shift is real but this is
        # NOT a resolved fix, it only delays the same underlying bug. Kept
        # here because ngl is GTK4's actively-maintained renderer regardless
        # and does not make anything worse; do not remove this line as part
        # of "fixing" the crash without addressing the actual NULL-image
        # root cause first.
        GSK_RENDERER=ngl
        export GSK_RENDERER
        # RDNA1 (Navi 10/12/14 -- the 5300/5500/5600/5700 series, including
        # MEDUSA's Navi14 5300M) has NO AV1 decode fixed-function hardware
        # at all; AMD's first AV1 decode block shipped in RDNA2. Chrome
        # still offers AV1 playback via software dav1d and, per Chromium's
        # own driver bug list, correctly refuses VaapiVideoDecoder for AV1
        # on this hardware (status=kUnsupportedConfig) -- metal-confirmed on
        # MEDUSA via a real media-internals.txt export: every AV1 clip used
        # Dav1dVideoDecoder (kIsPlatformVideoDecoder: false), zero hardware
        # decodes. Disabling Chrome's AV1 decoder entirely makes AV1-capable
        # sites (e.g. YouTube) fall back to VP9 or H.264, both of which
        # Navi14's VCN block DOES decode in hardware -- trading AV1-only
        # software playback for real hardware accel on everything else.
        # Content that is ONLY available in AV1 has no such fallback and
        # will simply fail to play; this is a real tradeoff, not a free fix,
        # so it is scoped strictly to RDNA1 (device IDs 0x7310-0x736f) where
        # AV1 was never hardware-accelerated in the first place -- RDNA2+
        # AMD GPUs (device IDs from 0x73a0 on) get real AV1 hardware decode
        # and must NOT have this flag forced.
        # Read the ACTUAL amdgpu-bound card's PCI device ID directly from
        # sysfs -- not lspci (an extra dependency this script has no other
        # use for, and one that would need to correlate its own device list
        # back to the specific card amdgpu is bound to on a system with more
        # than one AMD PCI function, e.g. an AMD APU alongside a discrete
        # AMD GPU). Matches the same /sys/class/drm/card*/device pattern
        # _ncz_drm_card_driven_by already uses elsewhere in this file.
        _ncz_amd_devid=
        for _ncz_dev in /sys/class/drm/card*/device; do
            [ -e "$_ncz_dev/driver" ] || continue
            [ "$(basename "$(readlink -f "$_ncz_dev/driver")")" = amdgpu ] || continue
            [ -r "$_ncz_dev/device" ] || continue
            _ncz_amd_devid=$(cat "$_ncz_dev/device" 2>/dev/null)
            _ncz_amd_devid=${_ncz_amd_devid#0x}
            break
        done
        case "$_ncz_amd_devid" in
            731[0-9a-fA-F]|732[0-9a-fA-F]|733[0-9a-fA-F]|734[0-9a-fA-F]|735[0-9a-fA-F]|736[0-9a-fA-F])
                _ncz_chrome_flags="$HOME/.config/google-chrome-flags.conf"
                install -d -m0755 "$(dirname "$_ncz_chrome_flags")" 2>/dev/null
                if [ ! -f "$_ncz_chrome_flags" ] || ! grep -q 'AV1Decoder' "$_ncz_chrome_flags" 2>/dev/null; then
                    echo '--disable-features=AV1Decoder' >> "$_ncz_chrome_flags"
                fi
                ;;
        esac
        unset _ncz_amd_devid _ncz_chrome_flags
    fi
    unset _ncz_hw_gpu_driver_name
elif [ -e "${NCZ_SYSROOT:-}"/dev/mali0 ] && grep -q '^mali_kbase ' "${NCZ_SYSROOT:-}"/proc/modules 2>/dev/null; then
    NCZ_GPU_BACKEND=mali
    # Pin the CIX EGL vendor explicitly, mirroring what the panthor branch does
    # for mesa. glvnd otherwise scans /usr/share/glvnd/egl_vendor.d, which ships
    # only 50_mesa.json -- the CIX vendor lives under /opt/cixgpu-compat/share
    # and is never found, so clients silently fall back to Mesa, which cannot
    # drive Mali. Pinning also avoids installing 40_cix.json system-wide, where
    # it would sort BEFORE 50_mesa and get tried first on the PANTHOR boot too.
    __EGL_VENDOR_LIBRARY_FILENAMES=/opt/cixgpu-compat/share/glvnd/egl_vendor.d/40_cix.json
    # NOTE: /opt/cixgpu-compat is NOT added to LD_LIBRARY_PATH. It holds a whole
    # second glvnd + Mesa 24.0.4; loading those alongside the system Mesa 26 is
    # what produced "free(): invalid pointer". Only the blob dir goes on the path.
    LD_LIBRARY_PATH="/opt/cixgpu-pro/lib/aarch64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    WLR_DRM_NO_MODIFIERS=1
    # Explicit ICD pin (not just relying on /etc/vulkan/icd.d/mali.json being
    # enabled): the Vulkan loader's default ICD search does not reliably pick
    # this up on its own (confirmed on O6N — with the ICD file enabled but no
    # VK_DRIVER_FILES set, vulkaninfo still only found Mesa's panvk ICD and
    # failed; VK_DRIVER_FILES fixed it). Legacy VK_ICD_FILENAMES did NOT work
    # on this loader version — use VK_DRIVER_FILES.
    VK_DRIVER_FILES=/etc/vulkan/icd.d/mali.json
    # VPU video acceleration: the CIX VAAPI driver (cix-vaapi). greetd's PAM
    # stack does not apply /etc/environment, so sessions must inherit this
    # here (confirmed on O6N: mpv --hwdec=vaapi fails without it in-session).
    LIBVA_DRIVER_NAME=libcix_va
    export NCZ_GPU_BACKEND LD_LIBRARY_PATH WLR_DRM_NO_MODIFIERS VK_DRIVER_FILES LIBVA_DRIVER_NAME __EGL_VENDOR_LIBRARY_FILENAMES
elif _ncz_panthor_live; then
    # Panthor = open Mesa stack. Point glvnd/EGL at the mesa vendor ICD and strip
    # inherited CIX libmali paths so EGL/GBM resolve to mesa (panfrost/panvk).
    NCZ_GPU_BACKEND=panthor
    __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json
    LD_LIBRARY_PATH=$(printf '%s' "${LD_LIBRARY_PATH:-}" | tr ':' '\n' | grep -v '/opt/cixgpu-' | paste -sd: -)
    # Stripping cixgpu from LD_LIBRARY_PATH is not enough: the ldconfig CACHE
    # still resolves libEGL_mesa.so.0 to /opt/cixgpu-compat's Mesa 24 first
    # (00-/01-cixgpu ld.so.conf.d are laid down for the Mali stack, and a
    # per-boot rEFInd Panthor selection never re-runs ncz-gpu-select/ldconfig).
    # glvnd then loads the 24.0.4 libEGL_mesa against the system Mesa 26
    # gallium and the compositor dies in a heap-corruption segfault before the
    # greeter ever appears (metal-confirmed on O6N, 2026-07-31). Pin the system
    # libdir ahead of the cache so panthor mode resolves ONE Mesa.
    LD_LIBRARY_PATH="/usr/lib/aarch64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    VK_LOADER_LAYERS_DISABLE=VK_LAYER_CIX_window_system_integration
    WLR_DRM_NO_MODIFIERS=1
    # Pin the RENDER node to panthor's own device.
    #
    # ncz-wlr-connected-drm builds WLR_DRM_DEVICES from cards that have a
    # CONNECTED output. On Sky1 that is only card0 = linlondp, the display
    # controller; panthor is render-only and exposes no connectors, so it never
    # appears in that list. With no WLR_RENDER_DRM_DEVICE, wlroots renders on
    # the same device it scans out on -- linlondp -- which has no gallium
    # driver. Mesa falls back to Zink, Zink needs a Vulkan ICD, none is
    # installed, and EGL dies:
    #
    #   MESA: error: ZINK: vkCreateInstance failed (VK_ERROR_INCOMPATIBLE_DRIVER)
    #   [render/egl.c:269]   Failed to initialize EGL
    #   [../src/server.c:586] unable to create renderer
    #
    # greetd's greeter then exits after ~430ms without creating a session and
    # start-limit-hits on the 5th try, so the Panthor boot entry comes up to a
    # black screen while the Mali entry is fine. Mali never hits this because it
    # renders through /dev/mali0 and the libmali blob, not a DRM render node.
    #
    # Metal-confirmed on O6N 2026-09-04 against 7.2.3-sky1-ncz+r263: setting
    # this took the greeter from a crash-loop to "first surface committed" in
    # 458ms with 0 restarts.
    #
    # Resolved dynamically -- renderD numbering is not stable across boots or
    # boards (MS-R1 has four DPUs and lands on a different node than O6N).
    for _ncz_rd in /sys/class/drm/renderD*; do
        [ -e "$_ncz_rd/device/driver" ] || continue
        [ "$(basename "$(readlink -f "$_ncz_rd/device/driver")")" = panthor ] || continue
        if [ -c "/dev/dri/$(basename "$_ncz_rd")" ]; then
            WLR_RENDER_DRM_DEVICE="/dev/dri/$(basename "$_ncz_rd")"
            export WLR_RENDER_DRM_DEVICE
        fi
        break
    done
    unset _ncz_rd
    export NCZ_GPU_BACKEND __EGL_VENDOR_LIBRARY_FILENAMES VK_LOADER_LAYERS_DISABLE WLR_DRM_NO_MODIFIERS
    if [ -n "$LD_LIBRARY_PATH" ]; then export LD_LIBRARY_PATH; else unset LD_LIBRARY_PATH; fi
else
    # NO usable GPU stack -- Mali (/dev/mali0 + mali_kbase) absent AND Panthor either absent or not bound to a DRM
    # card, and no Mesa hardware driver bound.
    #
    # NEVER-SOFTWARE-RENDER policy (operator, 2026-09-29): if this machine HAS a GPU it must not render in software.
    # This branch used to force wlroots(pixman) + llvmpipe unconditionally so a broken GPU stack still showed a
    # (slow) desktop; on a machine with a GPU that hid the fault. Now:
    #   * hardware GPU present (build/../assets/gpu/ncz-gpu-hw-present)  -> REFUSE: NCZ_GPU_BACKEND=failed, a loud
    #     message on stderr / the journal / /var/log/ncz-gpu-health.log, and NO software variables. The compositor
    #     fails visibly instead of quietly crawling on the CPU; ncz-gpu-status --require-hardware reports it.
    #     NCZ_ALLOW_SOFTWARE_FALLBACK=1 restores the old behavior for an operator who wants it.
    #   * no hardware GPU (KVM, headless VM)                              -> software rendering, as before.
    _ncz_hw_present() {
        if [ -n "${NCZ_GPU_HW_PRESENT_CMD:-}" ]; then "$NCZ_GPU_HW_PRESENT_CMD" >/dev/null 2>&1; return $?; fi
        command -v ncz-gpu-hw-present >/dev/null 2>&1 && ncz-gpu-hw-present >/dev/null 2>&1
    }
    if _ncz_hw_present && [ "${NCZ_ALLOW_SOFTWARE_FALLBACK:-0}" != 1 ]; then
        NCZ_GPU_BACKEND=failed
        export NCZ_GPU_BACKEND
        _ncz_msg="ncz-gpu-env: a hardware GPU is present but no hardware GPU stack is usable; software rendering REFUSED (NCZ_ALLOW_SOFTWARE_FALLBACK=1 overrides). Run: ncz-gpu-status --require-hardware"
        echo "$_ncz_msg" >&2
        logger -t ncz-gpu-env "$_ncz_msg" 2>/dev/null || true
        echo "$(date -u +%FT%TZ 2>/dev/null) FAIL $_ncz_msg" >> "${NCZ_GPU_HEALTH_LOG:-/var/log/ncz-gpu-health.log}" 2>/dev/null || true
        unset _ncz_msg
    else
        if _ncz_hw_present; then echo "ncz-gpu-env: WARNING NCZ_ALLOW_SOFTWARE_FALLBACK=1: software rendering ALLOWED on a machine with a GPU" >&2; fi
        NCZ_GPU_BACKEND=software
        WLR_RENDERER=pixman
        WLR_RENDERER_ALLOW_SOFTWARE=1
        LIBGL_ALWAYS_SOFTWARE=1
        GALLIUM_DRIVER=llvmpipe
        export NCZ_GPU_BACKEND WLR_RENDERER WLR_RENDERER_ALLOW_SOFTWARE LIBGL_ALWAYS_SOFTWARE GALLIUM_DRIVER
    fi
    unset -f _ncz_hw_present 2>/dev/null || true
fi

# Export the GPU selection to the systemd --user manager and to D-Bus-activated services. They do NOT inherit the
# compositor's environment, so before this a process started by systemd --user, dbus activation, a portal, flatpak
# or xdg-autostart lost the GPU variables (on Sky1 that meant llvmpipe). Sourced by the session and greeter wrappers
# only; NCZ_GPU_ENV_NO_IMPORT=1 disables it (tests).
if [ -z "${NCZ_GPU_ENV_NO_IMPORT:-}" ] && [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -S "$XDG_RUNTIME_DIR/bus" ]; then
    _ncz_imp=""
    for _ncz_v in NCZ_GPU_BACKEND LD_LIBRARY_PATH VK_DRIVER_FILES __EGL_VENDOR_LIBRARY_FILENAMES VK_LOADER_LAYERS_DISABLE WLR_DRM_NO_MODIFIERS WLR_RENDER_DRM_DEVICE GSK_RENDERER; do
        eval "_ncz_val=\${$_ncz_v:-}"
        [ -n "$_ncz_val" ] && _ncz_imp="$_ncz_imp $_ncz_v"
    done
    if [ -n "$_ncz_imp" ]; then
        command -v systemctl >/dev/null 2>&1 && systemctl --user import-environment $_ncz_imp 2>/dev/null || true
        command -v dbus-update-activation-environment >/dev/null 2>&1 && dbus-update-activation-environment --systemd $_ncz_imp 2>/dev/null || true
    fi
    unset _ncz_imp _ncz_v _ncz_val
fi
unset -f _ncz_drm_card_driven_by _ncz_panthor_live _ncz_hw_gpu_driver 2>/dev/null || true
unset _ncz_dev _ncz_drv _ncz_hw_gpu_driver_name
GPUENV
chmod 0755 /usr/local/bin/ncz-gpu-env

# ---------------------------------------------------------------------------
# Connected KMS selector — constrain wlroots to physical outputs that are
# currently connected.  Sky1 exposes a DRM card for each Linlon DP engine;
# opening disconnected engines in addition to the active connector causes
# material input/paint latency with the Mali stack.  The card number is not
# stable (O6's active output is card1), so inspect connector state instead of
# hard-coding a card.  This is intentionally sourced by *both* compositor
# launchers: greetd's _greetd compositor and the post-login user compositor
# are separate processes and neither can safely reuse the other's DRM lease.
# Do not override an explicit operator WLR_DRM_DEVICES choice.  Leave the
# variable unset when no physical output is connected so headless/KVM paths
# retain wlroots' ordinary backend discovery.
# ---------------------------------------------------------------------------
cat > /usr/local/bin/ncz-wlr-connected-drm <<'DRMENV'
#!/bin/sh
# Source this from a wlroots compositor launcher.
if [ -z "${WLR_DRM_DEVICES:-}" ]; then
    _ncz_drm_devices=
    for _ncz_status in /sys/class/drm/card*-*/status; do
        [ -r "$_ncz_status" ] || continue
        [ "$(cat "$_ncz_status" 2>/dev/null)" = connected ] || continue
        _ncz_card=${_ncz_status#*/drm/}
        _ncz_card=${_ncz_card%%-*}
        _ncz_device=/dev/dri/$_ncz_card
        [ -c "$_ncz_device" ] || continue
        case ":$_ncz_drm_devices:" in
            *:"$_ncz_device":*) ;;
            *) _ncz_drm_devices="${_ncz_drm_devices:+$_ncz_drm_devices:}$_ncz_device" ;;
        esac
    done
    if [ -n "$_ncz_drm_devices" ]; then
        WLR_DRM_DEVICES=$_ncz_drm_devices
        export WLR_DRM_DEVICES
    fi
    unset _ncz_drm_devices _ncz_status _ncz_card _ncz_device
fi
DRMENV
chmod 0755 /usr/local/bin/ncz-wlr-connected-drm

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
# The desktop starts a new, user-owned Labwc after greetd exits.  Apply the
# same dynamic connected-output policy used by the greeter before that Labwc
# is exec'd; otherwise it reopens every (including disconnected) Sky1 DP card.
if [ -r /usr/local/bin/ncz-wlr-connected-drm ]; then
    . /usr/local/bin/ncz-wlr-connected-drm
fi
# Singularity isolated env (singularity libs must precede GPU libs).
export PATH="/opt/singularity/bin:$PATH"
export XDG_DATA_DIRS="/opt/singularity/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
# Some vendored subprojects (e.g. labwc's wlroots->libdisplay-info chain)
# install under the GNU multiarch triplet dir instead of flat lib/, because
# meson's default libdir resolution isn't propagated through 3 levels of
# nested subproject wraps. Cover both so nothing silently fails to dlopen.
export LD_LIBRARY_PATH="/opt/singularity/lib/aarch64-linux-gnu:/opt/singularity/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
# greetd starts the selected command from a TTY PAM context.  Set the complete
# graphical-session identity before labwc starts so D-Bus-activated user
# services (notably Tracker/LocalSearch) do not fail their
# ConditionEnvironment=XDG_SESSION_CLASS=user check and leave a 120s timeout.
export XDG_SESSION_TYPE=wayland
export XDG_SESSION_CLASS=user
export XDG_SESSION_DESKTOP=Singularity
export XDG_CURRENT_DESKTOP=Singularity
# Default terminal = the native Singularity terminal (singularity-leafs, VTE).
# foot is kept installed as a fallback for the scripted NCZ installer launchers
# (they need foot's --hold/-T flags, which leafs does not expose) and greeter
# recovery.
if command -v singularity-leafs >/dev/null 2>&1; then
    export TERMINAL=singularity-leafs
else
    export TERMINAL=foot
fi
# graphical-session.target (2026-09-15): nothing in this script ever pushed
# the session's environment into the systemd --user manager, or told it a
# graphical session had actually started. systemd --user starts in a bare
# environment (it does NOT inherit this script's `export`s just because a
# child process set them) -- so graphical-session.target, and everything in
# graphical-session.target.wants/ (ncz-sky1-audio-autoswitch.service among
# them), sat permanently dormant on every real login. Confirmed live on O6N:
# ALSA hardware itself was fine (`speaker-test -D hw:0,1` played a real
# tone), but `systemctl --user status graphical-session.target` was
# `inactive (dead)`, so PipeWire/WirePlumber only ever exposed the dummy
# `auto_null` sink -- zero journal entries for audio-autoswitch, meaning it
# never even attempted to start.
#
# Backgrounded + gated on the Wayland socket existing, same reasoning and
# same wait-loop shape as the idle-manager block above: systemd --user needs
# a LIVE WAYLAND_DISPLAY value to import, which does not exist until labwc
# (the exec target below) has actually started.
(
    _wd="${WAYLAND_DISPLAY:-wayland-0}"
    _rt="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    _i=0
    while [ ! -S "$_rt/$_wd" ] && [ $_i -lt 100 ]; do sleep 0.2; _i=$((_i+1)); done
    export WAYLAND_DISPLAY="$_wd"
    systemctl --user import-environment WAYLAND_DISPLAY XDG_SESSION_TYPE XDG_SESSION_CLASS XDG_SESSION_DESKTOP XDG_CURRENT_DESKTOP 2>&1
    # graphical-session.target is RefuseManualStart-hardened (see the bridge
    # comment above) -- start singularity-session.target instead, which
    # BindsTo=graphical-session.target and pulls it in as a real dependency
    # job rather than the manual job RefuseManualStart blocks.
    systemctl --user start singularity-session.target 2>&1
    if systemctl --user cat ncz-idle-manager.service >/dev/null 2>&1; then
        systemctl --user restart ncz-idle-manager.service 2>&1
    fi
) &
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
# The greeter and the logged-in desktop each own a separate Labwc process.
# Select all *connected* outputs dynamically rather than assuming card0/card1.
if [ -r /usr/local/bin/ncz-wlr-connected-drm ]; then
    . /usr/local/bin/ncz-wlr-connected-drm
fi
export XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=labwc
export PATH="/opt/singularity/bin:$PATH"
export GSETTINGS_SCHEMA_DIR=/opt/singularity/share/glib-2.0/schemas
export XDG_DATA_DIRS="/opt/singularity/share:/usr/local/share:/usr/share"
# See ncz-singularity's matching comment: some vendored subprojects (labwc's
# wlroots->libdisplay-info chain) install under the multiarch triplet dir.
export LD_LIBRARY_PATH="/opt/singularity/lib/aarch64-linux-gnu:/opt/singularity/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
# _greetd cannot mkdir under /var/log at runtime; 55-greeter pre-creates the dir
# (tmpfiles), but fall back to XDG_RUNTIME_DIR so the exec redirect never fails
# (a failed redirect makes the wrapper exit before exec -> "greeter exited without
# creating a session" -> greetd crash-loop).
LOGDIR=/var/log/singularity-greeter
{ mkdir -p "$LOGDIR" && : >>"$LOGDIR/greeter.log"; } 2>/dev/null || LOGDIR="${XDG_RUNTIME_DIR:-/tmp}"
# The native boot splash watches this marker and drops DRM master before labwc
# starts. Its parent is created world-writable by ncz-boot-splash, so this is
# safe for the unprivileged _greetd account and avoids a black handoff.
if [ -d /run/singularity ] && [ -w /run/singularity ]; then
    : > /run/singularity/greeter-ready
    sleep 0.2
fi
# wlroots' libinput backend hard-refuses to initialize with ZERO input
# devices present ("libinput initialization failed, no input devices" ->
# "Failed to initialize backend" -> labwc exits -> greetd crash-loops ->
# NO VIDEO AT ALL, not even a login screen). ncz-wait-input-ready already
# tolerates this as a legitimate "recovery/KVM" case (a board with nothing
# plugged in) and starts the greeter anyway after its bounded probe -- but
# wlroots itself was never told to tolerate it too. Confirmed live on O6N,
# 2026-09-21: literally zero /dev/input/event* nodes, only the virtual
# /dev/input/mice. Set the escape hatch precisely when there is truly no
# real input device, so a board WITH a keyboard/mouse keeps normal behavior.
if ! ls /dev/input/event* >/dev/null 2>&1; then
    export WLR_LIBINPUT_NO_DEVICES=1
fi
# `-S` is essential: greetd starts the selected user's session as soon as this
# greeter compositor exits. A regular Labwc autostart leaves the compositor
# alive after authentication, causing greetd to wait its five-second watchdog
# and then SIGTERM it. The forced teardown exposes a blank text VT/cursor.
exec /opt/singularity/bin/labwc -C /etc/greetd/singularity-labwc \
    -S /opt/singularity/bin/singularity-greeter >>"$LOGDIR/greeter.log" 2>&1
GRW
chmod 0755 /usr/local/bin/ncz-singularity-greeter
echo "[20] ncz-singularity-greeter wrapper installed (native greeter on /opt/singularity labwc)"

# ---------------------------------------------------------------------------
# Cygnus 26.10 default theme + accent + wallpaper.
#
# Install the Cygnus Singularity theme into libsingularity's system theme search
# path and write the packaged gschema defaults so the out-of-box accent is the
# Cygnus magenta (#D6208C) via accent-color='custom' and the desktop theme is
# Cygnus -- not the old Maximilian red. The accent is written by StyleManager to
# the user gtk.css at runtime; setting it in the schema DEFAULT makes it the
# out-of-box accent, and singularity-theme='Cygnus' makes the shell load the
# theme below.
#
# The accent/theme keys are NOT hand-copied here: they come from
# assets/branding/singularity-theme/99-ncz-cygnus.gschema.override, generated
# from branding/cygnus/tokens.json by branding/cygnus/tools/gen-cygnus.py. The
# installed 99-ncz-defaults.gschema.override STARTS from that generated block
# and appends this build's non-Cygnus defaults into the same group, so a token
# change flows through with no hex literal in this script.
#
# libsingularity's style_manager.vala find_theme_dir() searches
# ~/.local/share/themes, ~/.themes, /usr/local/share/themes and
# /usr/share/themes for <name>/singularity/style.css, so the theme is installed
# to /usr/share/themes/Cygnus. Wallpaper points at the Cygnus default wallpaper
# (default.jpg) (45-wallpaper-rotator installs the NCZ set + can rotate).
# Compiled into the Singularity schema dir (on the session's
# GSETTINGS_SCHEMA_DIR).
# ---------------------------------------------------------------------------
INSTALLER_META=/usr/local/lib/cix-installer
CYGNUS_ASSETS="$INSTALLER_META/assets/branding/singularity-theme"
CYGNUS_THEME_SRC="$CYGNUS_ASSETS/Cygnus"
CYGNUS_GS_SRC="$CYGNUS_ASSETS/99-ncz-cygnus.gschema.override"

# Idempotent: remove any previous copy before extracting, and restore the
# standard theme modes (dirs 0755, files 0644) so a re-run or an upgrade can
# never leave a stale or over-permissive file behind.
if [ -d "$CYGNUS_THEME_SRC" ]; then
    rm -rf /usr/share/themes/Cygnus
    cp -r "$CYGNUS_THEME_SRC" /usr/share/themes/Cygnus
    find /usr/share/themes/Cygnus -type d -exec chmod 0755 {} \;
    find /usr/share/themes/Cygnus -type f -exec chmod 0644 {} \;
    echo "[20] Cygnus theme installed at /usr/share/themes/Cygnus"
else
    echo "[20] WARN: Cygnus theme assets missing at $CYGNUS_THEME_SRC — theme not installed"
fi

SCHEMADIR=/opt/singularity/share/glib-2.0/schemas
if [ -f "$SCHEMADIR/dev.sinty.desktop.gschema.xml" ]; then
    if [ -f "$CYGNUS_GS_SRC" ]; then
        # Generated [dev.sinty.desktop] group: accent-color,
        # custom-accent-color, custom-accent-colors, singularity-theme,
        # theme-mode and dark-mode.
        cp "$CYGNUS_GS_SRC" "$SCHEMADIR/99-ncz-defaults.gschema.override"
    else
        echo "[20] WARN: $CYGNUS_GS_SRC missing — Cygnus accent/theme defaults skipped (accent falls back to the schema default)"
        # Keep the group header so the non-Cygnus keys appended below still land
        # in [dev.sinty.desktop] instead of being dropped.
        printf '[dev.sinty.desktop]\n' > "$SCHEMADIR/99-ncz-defaults.gschema.override"
    fi
    cat >> "$SCHEMADIR/99-ncz-defaults.gschema.override" <<'GSCHEMA'
icon-theme='Singularity'
background-picture-uri='file:///usr/share/backgrounds/ncz/default.jpg'
recent-wallpapers=['file:///usr/share/backgrounds/ncz/default.jpg']
# Which apt source(s) the Desktop settings' Artist Pack browser trusts (see
# post-install/49-artist-pack-browser.sh and packaging/singularity's
# artist-pack-manager patch). This is the ONE place that list is set for
# this build -- the browser's inventory/install backend reads it from here
# at runtime, never a literal in the Vala UI or in 49's own script bodies.
# A different build variant overrides this same key with a different value
# (e.g. a staging repo) without touching the browser code at all. Kept in
# sync with the two sources 24-apt-sources.sh wires (Buildkite PRIMARY,
# Cloudflare R2 backup) -- if that hook's URLs ever change, update this too.
# The privileged installer independently validates the selected URI against
# root-owned apt configuration and the package's live candidate.
artist-pack-apt-sources=['https://packages.buildkite.com/ncz-os/ncz/any/', 'https://pub-d7b784e01679403d9c70fcd23fff5b96.r2.dev']
# Pin the browsers and a terminal to the dock, grouped. The stock
# dev.sinty.desktop pinned-apps default lists only the Sinty first-party apps,
# so a fresh install from this branch had NO browser and NO terminal on the
# dock -- including the two browser builds that are this platform's
# differentiator. Confirmed on O6N with r237.
#
# This is a port of 0967db2 from feat/26.7-panthor-dkms, which never landed on
# rtc-efi-rt, with two deliberate changes:
#   - firefox-ncz-sky1.desktop is DROPPED. That branch ships Firefox; this one
#     does not (no firefox .desktop on a r237 install), and pinning an absent
#     app leaves a dead tile on the dock.
#   - org.gnome.Console.desktop is ADDED. The original pinned no terminal at
#     all. Console is the user-facing terminal here; foot is kept only as the
#     fallback for the scripted NCZ installer launchers (see above), so it is
#     the wrong thing to put on the dock.
# Every id below was verified present in /usr/share/applications or
# /opt/singularity/share/applications on a real r237 install.
pinned-apps=['dev.sinty.files.desktop', 'chromium-ncz-sky1.desktop', 'google-chrome.desktop', 'org.gnome.Console.desktop', 'dev.sinty.write.desktop', 'dev.sinty.store.desktop', 'dev.sinty.calculator.desktop']
# Upstream 795da47 (2026-09-18) split OCS/Bing/stock wallpaper browsing out
# of the shell into plugins, disabled by default (schema default lacks
# them). They were always-on before that refactor. Keep the in-app
# wallpaper browser's prior behavior by opting them back in here.
enabled-plugins=['mpris-dock', 'downloads-dock', 'telegram-dock', 'launcher-entry-dock', 'tray-icons', 'emoji-search', 'tailscale', 'exe-icon', 'wallpapers-ocs', 'wallpapers-bing', 'sensors']
GSCHEMA
    # The Sky1 image ships chromium-ncz-sky1, but the AMD64 manifest
    # deliberately does not. Leaving its desktop ID in pinned-apps makes
    # Singularity synthesize a broken generic "chromium" dock/launcher item
    # even though no Chromium package or .desktop file exists on AMD64.
    if [ "$(dpkg --print-architecture)" = amd64 ]; then
        sed -i "s/'chromium-ncz-sky1.desktop', //" \
            "$SCHEMADIR/99-ncz-defaults.gschema.override"
        echo "[20] amd64 launcher defaults: omitted absent chromium-ncz-sky1"
    fi
    glib-compile-schemas "$SCHEMADIR" 2>&1 | tail -1 || \
        echo "[20] WARN: glib-compile-schemas failed (schemas compile on first session)"
    echo "[20] gschema override: Cygnus accent/theme, dark-mode, Cygnus wallpaper"
else
    echo "[20] WARN: dev.sinty.desktop schema absent — accent/wallpaper defaults skipped"
fi

# ---------------------------------------------------------------------------
# Wallpaper session handoff.
#
# The NCZ wallpaper engine is a systemd --user service installed by
# 45-wallpaper-rotator.sh. On Singularity/labwc the user manager can start that
# service before the compositor session has imported WAYLAND_DISPLAY and the
# /opt/singularity runtime environment. Measured on O6N, 2026-08-23: the daemon
# was active and rotating state, but its process environment lacked
# WAYLAND_DISPLAY, XDG_CURRENT_DESKTOP, GSETTINGS_SCHEMA_DIR, PATH and
# LD_LIBRARY_PATH from the live session; the visible swaybg stayed on
# /opt/singularity/share/backgrounds/singularity/singularity-epic.png.
#
# Hook the packaged session launcher at the point where those variables are
# known. The helper delays slightly so singularity-desktop can create its
# initial wallpaper layer, then restarts the user service under the imported
# environment so ncz-wallpaper-rotate writes GSettings in the live session.
# The native shell owns the wallpaper; no second background layer is needed.
# ---------------------------------------------------------------------------
cat > /usr/local/bin/ncz-wallpaper-session-ready <<'WPREADY'
#!/bin/sh
(
    sleep "${NCZ_WALLPAPER_SESSION_DELAY:-5}"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl --user import-environment \
            DISPLAY WAYLAND_DISPLAY XDG_SESSION_TYPE XDG_CURRENT_DESKTOP DESKTOP_SESSION \
            XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS GSETTINGS_SCHEMA_DIR XDG_DATA_DIRS \
            GI_TYPELIB_PATH PATH LD_LIBRARY_PATH 2>/dev/null || true
        if systemctl --user cat ncz-wallpaper-rotator.service >/dev/null 2>&1; then
            systemctl --user restart ncz-wallpaper-rotator.service 2>/dev/null || \
                systemctl --user start ncz-wallpaper-rotator.service 2>/dev/null || true
            exit 0
        fi
    fi
    if [ -x /usr/local/bin/ncz-wallpaper-daemon ]; then
        nohup /usr/local/bin/ncz-wallpaper-daemon >/dev/null 2>&1 &
    fi
) >/dev/null 2>&1 &
WPREADY
chmod 0755 /usr/local/bin/ncz-wallpaper-session-ready

_SINTY_SESSION=/opt/singularity/bin/singularity-desktop-session
if [ -f "$_SINTY_SESSION" ]; then
    if grep -q 'ncz-wallpaper-session-ready' "$_SINTY_SESSION"; then
        echo "[20] Singularity session already has NCZ wallpaper handoff"
    elif grep -q 'systemctl --user restart --no-block xdg-desktop-portal' "$_SINTY_SESSION"; then
        cp -a "$_SINTY_SESSION" "$_SINTY_SESSION.ncz-pre-wallpaper"
        awk '
            { print }
            /systemctl --user restart --no-block xdg-desktop-portal/ {
                print "if [ -x /usr/local/bin/ncz-wallpaper-session-ready ]; then"
                print "    /usr/local/bin/ncz-wallpaper-session-ready"
                print "fi"
            }
        ' "$_SINTY_SESSION.ncz-pre-wallpaper" > "$_SINTY_SESSION"
        chmod 0755 "$_SINTY_SESSION"
        echo "[20] Singularity session patched to import env + restart NCZ wallpaper rotator"
    else
        echo "[20] WARN: could not find session hook point for NCZ wallpaper handoff" >&2
    fi
else
    echo "[20] WARN: $_SINTY_SESSION absent — NCZ wallpaper handoff not patched" >&2
fi
unset _SINTY_SESSION

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
# app dir (on the session XDG_DATA_DIRS). Agent installation is intentionally
# CLI-only via `sudo ncz agent install`; do not add an installer launcher here.
# ---------------------------------------------------------------------------
APPDIR=/opt/singularity/share/applications
install -d -m0755 "$APPDIR"
cat > "$APPDIR/NCZ-CLI.desktop" <<'DAPP'
[Desktop Entry]
Version=1.0
Type=Application
Name=NCZ CLI
Comment=NCZ command-line — agents, NPU status (ncz help)
Exec=foot --hold -T NCZ /usr/local/bin/ncz help
Icon=utilities-terminal
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

# ---------------------------------------------------------------------------
# greetd = the display manager (SHIP greeter). The native singularity-greeter is
# wired by 55-greeter (config.toml, greeter labwc config, branding, tmpfiles);
# this hook installs the ncz-singularity-greeter wrapper above. Here we make
# greetd the DM and put the _greetd user in the seat/GPU groups so labwc/wlroots
# can open the DRM/seat. Singularity is the ONLY session.
# VALIDATED (O6N/Mali): the native greeter renders (Cygnus greeter backdrop,
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

# _greetd user (created by the greetd package's postinst) needs GPU + seat +
# input access so labwc can render the greeter on Mali. Real incident
# 2026-09-19: this used to be a single `if id _greetd` check with every
# usermod suppressed by `|| true` -- on a real build, this hook can run in a
# chroot pass BEFORE the greetd package's postinst has actually created the
# account yet, so the `if` silently evaluated false and the whole block
# no-opped. `_greetd` shipped with ZERO supplementary groups, seatd refused
# it, greetd crash-looped past systemd's start-limit, and the box never got
# a display (black screen) -- reproduced again on a fresh install from an
# otherwise-correct ISO, confirming this is a real, repeatable build defect,
# not one-off bad luck. `seat` is intentionally NOT in the group list: no
# `seat` group exists on this system at all (confirmed live), the old code's
# `getent group "$g" || true` masked that too.
_GREETD_WAIT=0
while ! id _greetd >/dev/null 2>&1; do
    _GREETD_WAIT=$((_GREETD_WAIT + 1))
    if [ "$_GREETD_WAIT" -gt 30 ]; then
        echo "[20] FATAL: _greetd account never appeared after ${_GREETD_WAIT}s -- greetd package not installed or postinst failed; refusing to ship a greeter with no seat/GPU access" >&2
        exit 1
    fi
    sleep 1
done
for g in video render input; do
    if getent group "$g" >/dev/null 2>&1; then
        usermod -aG "$g" _greetd
    else
        echo "[20] FATAL: required group '$g' does not exist -- cannot grant _greetd seat/GPU access" >&2
        exit 1
    fi
done
echo "[20] _greetd added to video/render/input (waited ${_GREETD_WAIT}s for the account)"
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

# Default browser routing. amd64: Vivaldi (52-vivaldi) primary, Google Chrome
# (53-chrome.sh) secondary. Sky1/arm64: chromium-ncz-sky1 primary (r201) --
# it decodes on the VPU through V4L2; Vivaldi and Chrome take the session's
# VA-API path, and the CIX VA-API driver hangs on H.264/HEVC
# (docs/SKY1-MEDIA-STATUS.md). /usr/local/bin/vivaldi-stable and
# google-chrome-stable are the VA-API-off wrappers on arm64
# (lib/sky1-browser-policy.sh, applied by 52/53), so they come before /usr/bin.
_ncz_br_arch="${NCZ_TARGET_ARCH:-}"
[ -n "$_ncz_br_arch" ] || _ncz_br_arch=$(tr -d '[:space:]' 2>/dev/null < /usr/local/lib/cix-installer/BUILD_ARCH || true)
[ -n "$_ncz_br_arch" ] || _ncz_br_arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
case "$_ncz_br_arch" in
    arm64|aarch64)
        _ncz_br_order="/usr/bin/chromium-ncz-sky1 /usr/local/bin/vivaldi-stable /usr/local/bin/google-chrome-stable /usr/bin/chromium /usr/bin/chromium-browser"
        _bd=chromium-ncz-sky1.desktop ;;
    *)
        _ncz_br_order="/usr/bin/vivaldi-stable /usr/bin/google-chrome-stable /usr/bin/chromium /usr/bin/chromium-browser"
        _bd=vivaldi-stable.desktop ;;
esac
cat > /usr/local/bin/x-www-browser <<BRWRAP
#!/bin/sh
for b in $_ncz_br_order; do
    [ -x "\$b" ] && exec "\$b" "\$@"
done
exec xdg-open "\$@"
BRWRAP
chmod 0755 /usr/local/bin/x-www-browser
unset _ncz_br_arch _ncz_br_order
mkdir -p /etc/xdg
cat > /etc/xdg/mimeapps.list <<MIME
[Default Applications]
text/html=$_bd
x-scheme-handler/http=$_bd
x-scheme-handler/https=$_bd
application/xhtml+xml=$_bd
MIME
echo "[20] default browser: $_bd (arm64: chromium-ncz-sky1, amd64: Vivaldi; Google Chrome secondary; snap-free)"

# Appliance noise reduction — mask services that fail for no benefit here.
for u in iscsid.service apport.service; do
    if systemctl list-unit-files "$u" 2>/dev/null | grep -q "^$u"; then
        systemctl disable "$u" 2>&1 | sed 's/^/    /' || true
        systemctl mask    "$u" 2>&1 | sed 's/^/    /' || true
    fi
done

echo "[20] Singularity Desktop installed: /opt/singularity + greetd/native singularity-greeter (Mali) + Wayland-only session"

# Ship-critical dynamic-link closure. `seatd` only Recommends libseat1 on
# resolute, and --no-install-recommends therefore produced a fully installed
# desktop whose greeter immediately died on missing libseat.so.1. Validate the
# actual binaries that own the boot-to-login path so this class of defect fails
# the installer instead of becoming a metal-only surprise.
_missing_runtime=0
for _bin in /opt/singularity/bin/labwc \
            /opt/singularity/bin/singularity-greeter \
            /opt/singularity/bin/singularity-desktop; do
    [ -x "$_bin" ] || {
        echo "[20] ERROR: ship-critical desktop binary missing: $_bin" >&2
        _missing_runtime=1
        continue
    }
    _missing=$(ldd "$_bin" 2>&1 | awk '/not found/ { print }')
    if [ -n "$_missing" ]; then
        echo "[20] ERROR: unresolved runtime libraries for $_bin:" >&2
        printf '%s\n' "$_missing" | sed 's/^/[20]   /' >&2
        _missing_runtime=1
    fi
done
if [ "$_missing_runtime" -ne 0 ]; then
    echo "[20] FATAL: Singularity boot/login runtime closure is incomplete" >&2
    exit 1
fi
echo "[20] verified: Singularity boot/login dynamic-link closure complete"

# --- 26.7 Maximilian: VPU/VAAPI media production apps (video edit + transcode + audio) ---
echo "[20] installing media production apps (Shotcut/HandBrake/Audacity + players)"
# Install one at a time. A single apt transaction fails WHOLESALE when any
# one name is unavailable, and a catch-all "|| echo WARN" then hides WHICH
# package was missing -- that combination silently defeated this whole step
# from 2026-08-27 until it was caught on CHIMERA 2026-09-29 (see 5f04513).
# Every name below must also exist in manifests/desktop.pkgs, or it can
# never resolve on an offline install.
_ncz_media_ok=""; _ncz_media_missing=""
for _app in shotcut handbrake ffmpeg audacity mpv ; do
    if DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
           "$_app" >/dev/null 2>&1 ; then
        _ncz_media_ok="$_ncz_media_ok $_app"
    else
        _ncz_media_missing="$_ncz_media_missing $_app"
    fi
done
[ -n "$_ncz_media_ok" ] && echo "[20] media apps installed:$_ncz_media_ok"
if [ -n "$_ncz_media_missing" ]; then
    echo "[20] WARN: media apps NOT in the offline mirror:$_ncz_media_missing"
    echo "[20]       (add them to manifests/desktop.pkgs so the closure carries them,"
    echo "[20]        or drop them from this list -- naming a package here that the"
    echo "[20]        manifest omits can never succeed on an offline install)"
fi
