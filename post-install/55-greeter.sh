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

# --- greetd: run the native greeter wrapper on the active graphical VT --------
cat > /etc/greetd/config.toml <<'GREETD'
# NCZ-OS greetd — NATIVE singularity-greeter (wlr-layer-shell + loginui) on the
# /opt/singularity labwc, CIX Mali GLES. No regreet, no GTK greeter.
[terminal]
# Sky1's active framebuffer console is VT1.  Requesting VT7 leaves greetd's
# session worker blocked in VT_WAITACTIVE forever: no labwc or greeter process
# is ever exec'd, although Mali and DP have already initialized.  Keep greetd
# on VT1 and let it replace the autovt getty for the graphical login surface.
vt = 1

[default_session]
command = "/usr/local/bin/ncz-singularity-greeter"
user = "_greetd"
GREETD

# The production Sky1 kernel deliberately omits generic virtio/bochs DRM.
# In such a headless/KVM boot there is no DRM node for a Wayland compositor,
# so starting greetd can only crash-loop. Card numbering is not stable (the
# live O6 display has been card1), therefore test connectors rather than
# assuming /dev/dri/card0.
cat > /usr/local/bin/ncz-has-drm-output <<'DRMTEST'
#!/bin/sh
for status in /sys/class/drm/card*-*/status; do
    [ -f "$status" ] || continue
    [ "$(cat "$status" 2>/dev/null || true)" = connected ] && exit 0
done
exit 1
DRMTEST
chmod 0755 /usr/local/bin/ncz-has-drm-output

# The Sky1 USB recovery service returns once the kernel publishes a keyboard
# input node, but the usbhid function can finish binding a fraction later.  A
# wlroots/libinput backend started in that gap can miss its initial seat setup
# or feel laggy until the next device event.  Gate greetd on a *settled* event
# keyboard.  The bound is deliberately short and accepts non-USB keyboards for
# KVM/recovery use; USB keyboard boots require the usbhid property.
cat > /usr/local/bin/ncz-wait-input-ready <<'INPUTREADY'
#!/bin/sh
for try in 1 2 3 4 5 6 7 8 9 10; do
    for dev in /dev/input/by-id/*-event-kbd /dev/input/event*; do
        [ -c "$dev" ] || continue
        props=$(udevadm info --query=property --name="$dev" 2>/dev/null || true)
        printf '%s\n' "$props" | grep -qx 'ID_INPUT_KEYBOARD=1' || continue
        if printf '%s\n' "$props" | grep -qx 'ID_BUS=usb'; then
            printf '%s\n' "$props" | grep -qx 'ID_USB_DRIVER=usbhid' || continue
        fi
        udevadm settle --timeout=1 2>/dev/null || true
        logger -t ncz-greetd-input "settled keyboard ready: $dev"
        exit 0
    done
    sleep 0.1
done
logger -t ncz-greetd-input "no settled keyboard after 1s; starting greeter for recovery/KVM"
exit 0
INPUTREADY
chmod 0755 /usr/local/bin/ncz-wait-input-ready

install -d -m0755 /etc/systemd/system/greetd.service.d
cat > /etc/systemd/system/greetd.service.d/10-ncz-drm.conf <<'GREETDDRM'
[Unit]
# labwc needs at least one libinput device at creation; let USB recovery finish
# its bounded keyboard probe before starting the greeter. The splash runs in
# parallel and releases DRM when this wrapper creates its ready marker.
After=cix-detect-display.service ncz-usb2-rescan.service
Wants=cix-detect-display.service ncz-usb2-rescan.service

[Service]
ExecCondition=/usr/local/bin/ncz-has-drm-output
ExecStartPre=/usr/local/bin/ncz-wait-input-ready
GREETDDRM

# --- greeter labwc config: greeter is Labwc's session client -----------------
install -d -m0755 /etc/greetd/singularity-labwc
# ncz-singularity-greeter invokes Labwc with `-S singularity-greeter`, making
# the compositor exit promptly after successful authentication. Do not launch a
# second greeter from autostart: it would hold Labwc open until greetd's
# five-second watchdog force-kills it and reveals a blank text VT.
cat > /etc/greetd/singularity-labwc/autostart <<'LABAUTO'
#!/bin/sh
exit 0
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

# --- _greetd must not be an EXPIRED account ---------------------------------
# The greetd package's account creation lands an expiry field of 1 in
# /etc/shadow (_greetd:!*:NNNNN:::::1:), i.e. expired on 1970-01-02 and expired
# forever regardless of the clock. PAM's account stage then refuses the greeter
# session and the machine boots to a BLACK SCREEN with the display stack fully
# up and DP connected:
#
#   pam_unix(greetd-greeter:account): account _greetd has expired
#   error: authentication error: pam_acct_mgmt: AUTH_ERR
#   greetd.service: Failed with result 'start-limit-hit'
#
# Confirmed shipping in the built desktop layer, so every install inherits it.
# Clear the expiry (-E -1) and make it idempotent.
if getent passwd _greetd >/dev/null 2>&1; then
    if command -v chage >/dev/null 2>&1; then
        chage -E -1 _greetd || echo "[55] WARN: could not clear _greetd account expiry"
    else
        # busybox/minimal image fallback: blank the 8th shadow field in place.
        sed -i -E 's/^(_greetd:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:)[^:]*:/\1:/' /etc/shadow
    fi
    echo "[55] _greetd account expiry cleared: $(getent shadow _greetd 2>/dev/null || grep '^_greetd' /etc/shadow)"
fi

echo "[55] greetd + native singularity-greeter wired: /etc/greetd/{config.toml,singularity-labwc/}, NCZ logo + Maximilian backdrop, _greetd log dir"
