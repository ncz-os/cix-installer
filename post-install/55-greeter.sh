#!/bin/bash
# 55-greeter.sh — NCZ-OS 26.7 SHIP greeter: greetd + NATIVE singularity-greeter.
#
# ZERO-COMPROMISE NATIVE STACK (supersedes regreet). The greeter is the upstream
# singularity-greeter (github.com/singularityos-lab/singularity-greeter): a raw
# Wayland wlr-layer-shell client that renders through the shared singularity-
# loginui Cairo library — the SAME pixels as singularity-lockscreen, the session
# splash and singularity-boot-splash. It ships INSIDE the /opt/singularity
# payload (20-desktop extracts it), runs on the SAME /opt/singularity labwc as
# the desktop session, and accelerates on the CIX Mali GLES blob (libmali) via
# ncz-gpu-env. NO regreet, NO GTK greeter, NO GTK_USE_PORTAL/dead-bus hacks.
#
# Branding: os-release carries LOGO=ncz, so the greeter (and boot-splash) look up
# /usr/share/{pixmaps,icons/.../apps}/ncz.png for the OS mark; the login backdrop
# is the NCZ Maximilian wallpaper dropped at the greeter fallback path
# /usr/share/backgrounds/singularity/default.png. auth is standard Unix password
# (the greeter only switches to PIN when os-release ID starts "sinty"; ours=ncz).
#
# 20-desktop.sh installs the greeter runtime (payload) + the ncz-singularity-
# greeter wrapper (sources ncz-gpu-env, execs /opt/singularity/bin/labwc on the
# greeter config below). THIS hook writes the greetd config, the greeter labwc
# config, the NCZ branding assets, and the _greetd-owned log dir.
#
# RUNS INSIDE CHROOT (build-squashfs-layers.sh desktop loop).
set +e

echo "[55] greetd + NATIVE singularity-greeter (wlr-layer-shell + loginui, Mali)"

VARIANT=desktop
[ -f /usr/local/lib/cix-installer/BUILD_VARIANT ] && \
    VARIANT=$(tr -d ' \t\r\n' < /usr/local/lib/cix-installer/BUILD_VARIANT)
case "$VARIANT" in
    server|headless)
        echo "[55] BUILD_VARIANT=$VARIANT — headless SKU; skipping greeter"
        exit 0
        ;;
esac

ASSETS=/usr/local/lib/cix-installer/assets/branding
WALL_SRC=/usr/share/backgrounds/ncz/ncz-wallpaper-07-maximilian-blackhole-2k.jpg

install -d -m0755 /etc/greetd

# --- NCZ OS logo (os-release LOGO=ncz -> ncz.png in the icon search path) -----
# singularity-greeter/boot-splash try_logo_file() search: pixmaps + hicolor apps.
# Ship the committed 256px ncz.png; fall back to converting the lockup if absent.
LOGO_PNG="$ASSETS/logo/ncz.png"
if [ ! -f "$LOGO_PNG" ] && command -v magick >/dev/null 2>&1; then
    magick "$ASSETS/logo/ncz-icon.jpg" -resize 256x256 /tmp/ncz.png 2>/dev/null && LOGO_PNG=/tmp/ncz.png
elif [ ! -f "$LOGO_PNG" ] && command -v convert >/dev/null 2>&1; then
    convert "$ASSETS/logo/ncz-icon.jpg" -resize 256x256 /tmp/ncz.png 2>/dev/null && LOGO_PNG=/tmp/ncz.png
fi
if [ -f "$LOGO_PNG" ]; then
    install -d -m0755 /usr/share/pixmaps /usr/share/icons/hicolor/256x256/apps
    install -m0644 "$LOGO_PNG" /usr/share/pixmaps/ncz.png
    install -m0644 "$LOGO_PNG" /usr/share/icons/hicolor/256x256/apps/ncz.png
    echo "[55] NCZ OS logo installed (ncz.png -> pixmaps + hicolor/256x256/apps)"
else
    echo "[55] WARN: ncz logo asset missing — greeter/boot-splash fall back to emblem-singularity" >&2
fi

# --- greeter fallback background = NCZ Maximilian ----------------------------
# singularity-greeter background priority: per-user AccountsService Background ->
# dev.sinty.desktop uri (current user only) -> fallback file. At the greeter no
# real user is current, so the fallback file is the login backdrop.
if [ -f "$WALL_SRC" ]; then
    install -d -m0755 /usr/share/backgrounds/singularity
    # loginui loads by content (gdk-pixbuf), not extension — jpg under .png is fine.
    cp -f "$WALL_SRC" /usr/share/backgrounds/singularity/default.png
    echo "[55] greeter backdrop -> NCZ Maximilian (/usr/share/backgrounds/singularity/default.png)"
else
    echo "[55] WARN: Maximilian wallpaper absent — greeter uses singularity default backdrop" >&2
fi

# --- greetd: run the native greeter wrapper on VT7 as _greetd -----------------
cat > /etc/greetd/config.toml <<'GREETD'
# NCZ-OS greetd — NATIVE singularity-greeter (wlr-layer-shell + loginui) on the
# /opt/singularity labwc, CIX Mali GLES. No regreet, no GTK greeter.
[terminal]
vt = 7

[default_session]
command = "/usr/local/bin/ncz-singularity-greeter"
user = "_greetd"
GREETD

# --- greeter labwc config: autostart the native greeter ----------------------
install -d -m0755 /etc/greetd/singularity-labwc
# greetd sets GREETD_SOCK in the wrapper env -> inherited by labwc -> this
# autostart -> singularity-greeter, which speaks the greetd IPC. greetd tears the
# greeter down when a session is chosen.
cat > /etc/greetd/singularity-labwc/autostart <<'LABAUTO'
#!/bin/sh
exec /opt/singularity/bin/singularity-greeter
LABAUTO
chmod 0755 /etc/greetd/singularity-labwc/autostart

cat > /etc/greetd/singularity-labwc/rc.xml <<'LABRC'
<?xml version="1.0"?>
<labwc_config>
  <core><gap>0</gap></core>
</labwc_config>
LABRC

cat > /etc/greetd/singularity-labwc/environment <<'LABENV'
XCURSOR_THEME=Adwaita
XCURSOR_SIZE=24
LABENV

# --- _greetd-owned greeter log dir (tmpfiles + bake-time create) --------------
# The wrapper redirects labwc output here; _greetd cannot mkdir under /var/log at
# runtime, so pre-create it (tmpfiles re-asserts at boot). Wrapper also falls back
# to XDG_RUNTIME_DIR if this is ever missing.
cat > /etc/tmpfiles.d/ncz-singularity-greeter.conf <<'TMPF'
d /var/log/singularity-greeter 0755 _greetd _greetd -
TMPF
install -d -m0755 /var/log/singularity-greeter
id _greetd >/dev/null 2>&1 && chown _greetd:_greetd /var/log/singularity-greeter 2>/dev/null || true

# --- session list = Singularity only (greeter reads wayland-sessions) --------
# 20-desktop curated /usr/share/wayland-sessions to singularity.desktop and
# removed /usr/share/xsessions; nothing else to do here.

echo "[55] greetd + native singularity-greeter wired: /etc/greetd/{config.toml,singularity-labwc/}, NCZ logo + Maximilian backdrop, _greetd log dir"
