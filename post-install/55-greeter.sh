#!/bin/bash
# 55-greeter.sh — NCZ-OS 26.10 SHIP greeter: greetd + NATIVE singularity-greeter.
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
# Branding: os-release carries LOGO=ncz-os-<codename> (derived in 50-brand.sh),
# so the greeter (and boot-splash) look up
# /usr/share/{pixmaps,icons/.../apps}/ncz-os-<codename>.png for the OS mark (the
# approved Cygnus wordmark as of 26.10); the login backdrop
# is the Cygnus greeter backdrop dropped at the greeter fallback path
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
# The dedicated greeter backdrop (NOT a desktop wallpaper — see the
# fallback-path comment below for why the name says backdrop, not wall).
BACKDROP_SRC=$ASSETS/greeter/cygnus/greeter-backdrop-1920x1080.png

install -d -m0755 /etc/greetd

# The logo file NAME must match os-release LOGO (written by 50-brand.sh), which
# is derived from the release codename.
RELEASE_FILE=/usr/local/lib/cix-installer/RELEASE
[ -s "$RELEASE_FILE" ] || RELEASE_FILE=/etc/cix-installer/RELEASE
# shellcheck disable=SC1090
[ -s "$RELEASE_FILE" ] && . "$RELEASE_FILE"
LOGO_NAME="ncz-os-$(printf '%s' "${NCZ_RELEASE_CODENAME:-Cygnus}" | tr '[:upper:]' '[:lower:]')"

# --- NCZ OS logo (os-release LOGO=$LOGO_NAME -> $LOGO_NAME.png search path) ---
# singularity-greeter/boot-splash try_logo_file() search: pixmaps + hicolor apps.
# Ship the approved Cygnus wordmark. Fall back (in order) to the legacy 256px
# ncz.png, then to converting the lockup -- so a missing Cygnus asset installs
# the older mark instead of aborting.
CYGNUS_LOGO="$ASSETS/greeter/cygnus/ncz-os-cygnus-logo.png"
LOGO_PNG=""
if [ -f "$CYGNUS_LOGO" ]; then
    LOGO_PNG="$CYGNUS_LOGO"
elif [ -f "$ASSETS/logo/ncz.png" ]; then
    LOGO_PNG="$ASSETS/logo/ncz.png"
    echo "[55] WARN: Cygnus logo absent ($CYGNUS_LOGO) — falling back to ncz.png" >&2
elif command -v magick >/dev/null 2>&1; then
    magick "$ASSETS/logo/ncz-icon.jpg" -resize 256x256 /tmp/ncz.png 2>/dev/null && LOGO_PNG=/tmp/ncz.png
elif command -v convert >/dev/null 2>&1; then
    convert "$ASSETS/logo/ncz-icon.jpg" -resize 256x256 /tmp/ncz.png 2>/dev/null && LOGO_PNG=/tmp/ncz.png
fi
if [ -n "$LOGO_PNG" ] && [ -f "$LOGO_PNG" ]; then
    install -d -m0755 /usr/share/pixmaps /usr/share/icons/hicolor/256x256/apps
    install -m0644 "$LOGO_PNG" "/usr/share/pixmaps/$LOGO_NAME.png"
    install -m0644 "$LOGO_PNG" "/usr/share/icons/hicolor/256x256/apps/$LOGO_NAME.png"
    # Also populate the legacy ncz.png name so anything still keyed to it resolves.
    install -m0644 "$LOGO_PNG" /usr/share/pixmaps/ncz.png
    install -m0644 "$LOGO_PNG" /usr/share/icons/hicolor/256x256/apps/ncz.png
    echo "[55] NCZ OS logo installed ($LOGO_NAME.png -> pixmaps + hicolor/256x256/apps)"
else
    echo "[55] WARN: ncz logo asset missing — greeter/boot-splash fall back to emblem-singularity" >&2
fi

# --- square Cygnus mark for icon-theme lookups (MINOR-006) --------------------
# The LOGO name has two kinds of consumer. The greeter and both splashes look
# for a FILE, scalable svg first, then /usr/share/pixmaps, and only then
# hicolor/256x256 -- so they keep finding the wordmark installed in pixmaps
# above. GTK icon-theme lookups (the Singularity About page) read the SIZED
# hicolor directories, where the 696x52 wordmark was squeezed into a square.
# Give those lookups the square mark at every size, including 256x256, which
# replaces the wordmark copy there. Never install it as scalable/apps/*.svg:
# the greeter checks that path first and would lose its wordmark.
MARK_DIR="$ASSETS/logo/cygnus-mark"
if [ -f "$MARK_DIR/256.png" ]; then
    for size in 48 64 96 128 192 256; do
        [ -f "$MARK_DIR/$size.png" ] || continue
        install -d -m0755 "/usr/share/icons/hicolor/${size}x${size}/apps"
        install -m0644 "$MARK_DIR/$size.png" "/usr/share/icons/hicolor/${size}x${size}/apps/$LOGO_NAME.png"
    done
    if [ -f /usr/share/icons/hicolor/icon-theme.cache ] && command -v gtk-update-icon-cache >/dev/null 2>&1; then
        gtk-update-icon-cache -f /usr/share/icons/hicolor >/dev/null 2>&1 \
            || echo "[55] WARN: gtk-update-icon-cache failed for hicolor" >&2
    fi
    echo "[55] square Cygnus mark installed ($LOGO_NAME.png -> hicolor 48..256 apps)"
else
    echo "[55] WARN: Cygnus mark absent ($MARK_DIR) — the About page shows the wordmark" >&2
fi

# --- greeter fallback background = Cygnus greeter backdrop ------------------
# singularity-greeter background priority: per-user AccountsService Background ->
# dev.sinty.desktop uri (current user only) -> fallback file. At the greeter no
# real user is current, so the fallback file is the login backdrop. The greeter
# downscales it to 960 px and box-blurs it twice, so this is a dedicated no-text
# image darkened (branding/cygnus/tools/make-greeter-backdrop.py) to keep white
# UI text >= 4.5:1 after that blur -- not a desktop wallpaper.
if [ -f "$BACKDROP_SRC" ]; then
    install -d -m0755 /usr/share/backgrounds/singularity
    cp -f "$BACKDROP_SRC" /usr/share/backgrounds/singularity/default.png
    echo "[55] greeter backdrop -> Cygnus (/usr/share/backgrounds/singularity/default.png)"
else
    echo "[55] WARN: Cygnus greeter backdrop absent ($BACKDROP_SRC) — greeter uses singularity default backdrop" >&2
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
# Gate greetd on a display being present -- and, on Sky1/arm64 ONLY, LIT (an
# output whose status=connected AND enabled=enabled, i.e. a CRTC is actually
# scanning it out).
#
# On Sky1/trilin the console (or the KMS boot splash) enables the connector
# only after the DP link has trained; starting labwc before that is what
# produced the greeter-vs-connector race, so there the gate waits for the LIT
# state. On every other arch (i915/amdgpu/nvidia) the compositor keeps the
# labwc default and lights the output itself, so requiring a CRTC to already be
# scanning buys nothing and only risks a needless greetd delay on a console that
# never leaves a CRTC enabled -- the amd64 regression that arrived with the
# autoEnableOutputs=no change (2026-10-11). There a CONNECTED output is enough,
# the pre-2026-10-11 behaviour.
#
# amdgpu on T2 Macs (T2 Mac A) publishes its eDP connector ~7-9 s into
# userspace, after greetd's one-shot ExecCondition would already have skipped
# the greeter (measured 2026-10-10: condition 21:25:49, connector 21:25:50).
# The old cix-detect-display wait is arm64-only, so wait here, on every arch,
# up to 30 s.
#
# Fail-open: on arm64, if some output is connected but never reported enabled
# within a short grace window (a platform that does not light DRM from the
# console, or KVM/headless), still start the greeter -- a missing login screen
# is worse than the race, and the grace bound keeps the extra latency small.
case "$(uname -m)" in
    aarch64 | arm64) require_lit=1 ;;
    *) require_lit=0 ;;
esac
# Bounds: up to 120 iterations x 0.25 s = 30 s total (see the header note
# on the amdgpu/T2 eDP connector timing). On arm64 the LIT requirement
# carries an 8 s grace window: a connector that stays connected but is never
# reported enabled for 32 x 0.25 s gives up the wait and fails open.
try=0
conn_since=-1
while [ "$try" -lt 120 ]; do
    connected=0
    for status in /sys/class/drm/card*-*/status; do
        [ -f "$status" ] || continue
        [ "$(cat "$status" 2>/dev/null || true)" = connected ] || continue
        connected=1
        [ "$require_lit" = 1 ] || exit 0
        en=${status%/status}/enabled
        [ -f "$en" ] || continue
        [ "$(cat "$en" 2>/dev/null || true)" = enabled ] && exit 0
    done
    if [ "$require_lit" = 1 ] && [ "$connected" = 1 ]; then
        [ "$conn_since" -lt 0 ] && conn_since=$try
        if [ "$((try - conn_since))" -ge 32 ]; then
            logger -t ncz-greetd-drm "connected output not enabled after 8s; starting greeter anyway"
            exit 0
        fi
    fi
    try=$((try + 1))
    sleep 0.25
done
[ "$connected" = 1 ] && exit 0
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
After=ncz-usb2-rescan.service
Wants=ncz-usb2-rescan.service

[Service]
ExecCondition=/usr/local/bin/ncz-has-drm-output
ExecStartPre=/usr/local/bin/ncz-wait-input-ready
GREETDDRM

# The display-detect ordering is arm64 only. 22-display-fix.sh leaves
# cix-detect-display.service disabled on amd64, but a Wants= here pulled it in
# on every boot anyway (7.4 s in the boot blame on T2 Mac A, r201). Its own
# drop-in so the arch-neutral file above stays identical on both platforms.
_ncz_greeter_arch="${NCZ_TARGET_ARCH:-}"
[ -n "$_ncz_greeter_arch" ] || _ncz_greeter_arch=$(tr -d '[:space:]' < /usr/local/lib/cix-installer/BUILD_ARCH 2>/dev/null)
[ -n "$_ncz_greeter_arch" ] || _ncz_greeter_arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
case "$_ncz_greeter_arch" in
    arm64|aarch64)
        cat > /etc/systemd/system/greetd.service.d/11-ncz-display-detect.conf <<'GREETDDISPLAY'
[Unit]
# arm64 only: let the display-detect oneshot settle the connector set first.
After=cix-detect-display.service
Wants=cix-detect-display.service
GREETDDISPLAY
        ;;
    *)
        rm -f /etc/systemd/system/greetd.service.d/11-ncz-display-detect.conf
        echo "[55] arch=$_ncz_greeter_arch: greetd does not order on the display-detect unit"
        ;;
esac
unset _ncz_greeter_arch

# --- console login when the greeter cannot start -----------------------------
# O6N 2026-10-26 (Preview4 desktop, Mali modules refused by the kernel): the
# greeter exited without a session five times, greetd hit its start limit and
# stayed failed, and the board showed two error lines and nothing else -- no
# login anywhere on the screen. getty@tty1 is not running on a graphical boot
# (the boot splash conflicts with it and greetd owns VT1), so nothing took
# over. When greetd fails for good, put a login on tty1 with a message that
# says why. Software rendering stays refused on a machine with a GPU; this is
# a text console, not a degraded desktop.
cat > /usr/local/sbin/ncz-greeter-fallback <<'FALLBACK'
#!/bin/sh
# ncz-greeter-fallback -- greetd.service OnFailure: text login on tty1.
TTY=${NCZ_FALLBACK_TTY:-/dev/tty1}
ISSUE=${NCZ_FALLBACK_ISSUE:-/etc/issue.d/90-ncz-greeter-failed.issue}
# Name a GPU cause only when ncz-gpu-env logged its refusal on this boot.
why=$(journalctl -b -t ncz-gpu-env -o cat --no-pager 2>/dev/null | grep 'REFUSED' | tail -1)
msg="
NCZ-OS: the graphical login could not start, so this is a text login.${why:+
GPU: $why}
After logging in: 'ncz-gpu-status --require-hardware' shows the GPU state,
'journalctl -b -u greetd' the greeter log, 'sudo systemctl restart greetd' retries.
"
# tty1 first and independently: the message must reach the screen even when
# /etc is not writable.
chvt 1 2>/dev/null || true
printf '%s\n' "$msg" > "$TTY" 2>/dev/null || true
{ printf '%s\n' "$msg" > "${ISSUE}.tmp" && mv -f "${ISSUE}.tmp" "$ISSUE"; } 2>/dev/null || rm -f "${ISSUE}.tmp" 2>/dev/null
logger -t ncz-greeter-fallback "greetd failed; starting a text login on tty1${why:+ ($why)}" 2>/dev/null || true
systemctl --no-block start getty@tty1.service
FALLBACK
chmod 0755 /usr/local/sbin/ncz-greeter-fallback
install -d -m0755 /etc/issue.d
cat > /etc/systemd/system/ncz-greeter-fallback.service <<'FBUNIT'
[Unit]
Description=Text login on tty1 when the graphical greeter cannot start
# Started only by greetd.service OnFailure= (start limit hit, or a hard failure).

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ncz-greeter-fallback
FBUNIT
cat > /etc/systemd/system/greetd.service.d/12-ncz-console-fallback.conf <<'GREETDFB'
[Unit]
# If greetd gives up (the greeter exited without a session until the start
# limit hit), hand tty1 to a text login: see ncz-greeter-fallback.
OnFailure=ncz-greeter-fallback.service

[Service]
# A greeter that starts again (GPU fixed, restart, reboot) must not keep the
# old "could not start" message on the next text login.
ExecStartPre=-/bin/rm -f /etc/issue.d/90-ncz-greeter-failed.issue
GREETDFB
echo "[55] greetd OnFailure -> ncz-greeter-fallback (text login on tty1 when the greeter cannot start)"

# --- greeter labwc config: greeter is Labwc's session client -----------------
install -d -m0755 /etc/greetd/singularity-labwc
# ncz-singularity-greeter invokes Labwc with `-S singularity-greeter`, making
# the compositor exit promptly after successful authentication. Do not launch a
# second greeter from autostart: it would hold Labwc open until greetd's
# five-second watchdog force-kills it and reveals a blank text VT.
cat > /etc/greetd/singularity-labwc/autostart <<'LABAUTO'
#!/bin/sh
# Greeter output mode: never 4K. The login screen is a blurred 960 px backdrop and a
# small card, so a 3840x2160 scanout buys nothing and is the heaviest path for the Mali
# swapchain (decision 2026-10-04). Pick 1920x1080 at 60 Hz on every connected
# output that offers it; outputs without it keep their own mode. Best effort: a failure
# here must never block the greeter, so every path exits 0.
#
# HiDPI (docs/HIDPI-SCALING.md): ncz-display-scale keeps the same never-above-1920x1200
# cap but chooses a mode with the panel's own aspect ratio (a 3072x1920 16:10 laptop
# panel gets 1920x1200, not a letterboxed 1920x1080) and applies the NCZ density
# policy scale for that mode. The fixed 1080p loop below is the fallback when the
# helper is missing or fails.
#
# ORDERING (fix/greeter-dp-handoff-20261011): on Sky1/arm64 ONLY the greeter
# rc.xml sets <core><autoEnableOutputs>no</core>, making this autostart the
# FIRST and ONLY commit that lights each output — labwc must not modeset a
# console-inherited CRTC first, because that disable->enable cycle is the DP
# AUX-engine wedge trigger on trilin Sky1 boards (MS-R1, Orange Pi 6 Plus). On
# every other architecture the rc.xml keeps the labwc default (autoEnable yes):
# there the compositor owns the first modeset and this autostart only adjusts an
# already-lit output's mode. Every wlr-randr call carries --on so a
# still-disabled output is enabled in the same commit; the helper skips any
# output already lit at a capped mode.
command -v wlr-randr >/dev/null 2>&1 || {
    echo "greeter: wlr-randr missing; outputs stay as the compositor left them" >&2
    exit 0
}
_scale=${NCZ_DISPLAY_SCALE_HELPER:-/usr/local/bin/ncz-display-scale}
if [ -x "$_scale" ] && "$_scale" greeter; then
    exit 0
fi
for out in $(wlr-randr 2>/dev/null | awk '/^[A-Za-z]/ {print $1}'); do
    wlr-randr --output "$out" --mode 1920x1080@60Hz --on >/dev/null 2>&1 \
        || wlr-randr --output "$out" --mode 1920x1080 --on >/dev/null 2>&1 \
        || wlr-randr --output "$out" --on >/dev/null 2>&1 || true
done
exit 0
LABAUTO
chmod 0755 /etc/greetd/singularity-labwc/autostart

# <autoEnableOutputs>no</autoEnableOutputs> is a Sky1/arm64-ONLY workaround and
# must not be written on any other arch. With the labwc default (yes) on amd64,
# labwc modesets each output to its preferred (4K) mode at startup and the
# autostart only adjusts the mode — harmless there. With =no on amd64, labwc
# instead tries to DISABLE the CRTC the console/KMS splash left enabled; that
# disable fails on i915 ("Failed to disable CRTC") and the greeter stays black
# (the GU502LV laptop RC2 325c9510, reported and live-tested 2026-10-11). On trilin Sky1
# (MS-R1, Orange Pi 6 Plus) the redundant disable+enable cycle is exactly what
# latches the DP AUX engine busy, so only there is =no written and the autostart
# becomes the single commit that lights each output at the capped mode.
# assets/display/ncz-greeter-rcxml is the single source of truth for the policy.
_ncz_rcxml_src=""
for _r in /cdrom/ncz-payload /usr/local/lib/cix-installer; do
    if [ -f "$_r/assets/display/ncz-greeter-rcxml" ]; then
        _ncz_rcxml_src="$_r/assets/display/ncz-greeter-rcxml"
        break
    fi
done
if [ -n "$_ncz_rcxml_src" ]; then
    # The helper derives the target arch itself (BUILD_ARCH / dpkg / uname).
    sh "$_ncz_rcxml_src" --out /etc/greetd/singularity-labwc/rc.xml ||
        echo "[55] WARN: ncz-greeter-rcxml failed" >&2
else
    # Defensive fallback (the asset ships in the same payload): the compositor
    # default is the universally safe choice — it can never black-screen a
    # greeter, whereas =no can on i915. Sky1 would lose its workaround, so log
    # loudly.
    echo "[55] WARN: assets/display/ncz-greeter-rcxml absent — writing compositor-default rc.xml" >&2
    cat > /etc/greetd/singularity-labwc/rc.xml <<'LABRC'
<?xml version="1.0"?>
<labwc_config>
  <core>
    <gap>0</gap>
    <!-- Labwc default: the compositor owns the first modeset. See
         post-install/55-greeter.sh. -->
  </core>
</labwc_config>
LABRC
fi
unset _ncz_rcxml_src

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


# --- pam_systemd must be ACTIVE in common-session, or the greeter can NEVER
#     get an XDG_RUNTIME_DIR ------------------------------------------------
# libpam-systemd ships in this image (it's a normal apt dependency of greetd/
# systemd-logind usage), but the package being INSTALLED does not mean its PAM
# profile is ENABLED — /usr/share/pam-configs/systemd only gets spliced into
# /etc/pam.d/common-session via pam-auth-update, and nothing in this pipeline
# was ever calling it. Without that line, systemd-logind never creates
# /run/user/<uid> for the _greetd session, XDG_RUNTIME_DIR stays unset, and
# labwc refuses to start:
#
#   [ERROR] [../src/main.c:262] XDG_RUNTIME_DIR is unset
#   error: check_children: greeter exited without creating a session
#   greetd.service: Failed with result 'start-limit-hit'
#
# Same failure SHAPE as the _greetd account-expiry bug above (a PAM session
# gap -> silent crash-loop -> black screen with the display stack otherwise
# fully up) — confirmed live on O6N hardware 2026-09-15, root-caused via
# journalctl -b -u greetd + an empty /run/user/. --package enables just the
# profile(s) shipped by installed packages (systemd's), non-interactively;
# --force re-applies even if pam-auth-update thinks nothing changed, which
# matters here because a base image built once with the bug already recorded
# a (wrong) nothing to do state in its own PAM config state file.
if command -v pam-auth-update >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive pam-auth-update --package --force         || echo '[55] WARN: pam-auth-update failed — greeter will XDG_RUNTIME_DIR-crash-loop'
    if grep -q pam_systemd.so /etc/pam.d/common-session 2>/dev/null; then
        echo '[55] pam_systemd active in common-session (XDG_RUNTIME_DIR will be set for _greetd)'
    else
        echo '[55] WARN: pam_systemd still absent from common-session after pam-auth-update — greeter WILL black-screen'
    fi
else
    echo '[55] WARN: pam-auth-update not present — cannot verify/enable pam_systemd, greeter may black-screen'
fi
echo "[55] greetd + native singularity-greeter wired: /etc/greetd/{config.toml,singularity-labwc/}, NCZ logo + Cygnus backdrop, _greetd log dir"
