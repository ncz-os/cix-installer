#!/bin/bash
# 57-screensaver.sh — NCZ native Wayland screensaver / idle-lock.
#
# REPLACES the retired X11 xscreensaver path (Singularity is Wayland-only on CIX
# Mali; xscreensaver is an Xorg program — wrong stack, and the bake-off XFCE that
# used to pull it is gone). The lock/idle here is 100% Wayland-native:
#
#   idle timer : swayidle  (a wlroots ext-idle-notify-v1 client — NOT X11)
#   lock       : the native Singularity lockscreen (/opt/singularity/bin/
#                singularity-lockscreen, Mali GLES) via /usr/local/bin/ncz-lock,
#                with swaylock as a blank-screen fallback
#   screen off : wlopm (wlr-output-power-management) when the compositor supports
#                it (DPMS-off after the lock)
#
# It is driven ENTIRELY by the dev.sinty.lockscreen GSettings schema
# (lock-enabled / idle-delay / lock-on-suspend), so the operator controls the
# screensaver/lock from Singularity Settings — no bespoke config file. The daemon
# (/usr/local/bin/ncz-screensaver) is launched by /usr/local/bin/ncz-singularity
# (written in 20-desktop.sh) once the compositor socket is up.
#
# Config-only + idempotent. Safe in chroot (writes files + gschema default;
# starts no daemon). RUNS INSIDE CHROOT (build-squashfs-layers.sh desktop loop /
# run-all.sh).
set -uo pipefail

echo "[57] NCZ native Wayland screensaver (swayidle + Singularity lockscreen)"

VARIANT=desktop
if [ -f /usr/local/lib/cix-installer/BUILD_VARIANT ]; then
    VARIANT=$(tr -d ' \t\r\n' < /usr/local/lib/cix-installer/BUILD_VARIANT)
fi
case "$VARIANT" in
    server|magnetar|headless)
        echo "[57] BUILD_VARIANT=$VARIANT — headless SKU; skipping screensaver"
        exit 0
        ;;
esac

# ---------------------------------------------------------------------------
# 1) Purge the retired X11 xscreensaver + scrub any config a prior build left.
# ---------------------------------------------------------------------------
if dpkg -l xscreensaver 2>/dev/null | grep -q '^ii'; then
    echo "[57] purging xscreensaver (X11 — wrong stack for Wayland/Mali)"
    DEBIAN_FRONTEND=noninteractive apt-get purge -y xscreensaver 2>&1 | tail -3 || true
fi
rm -f /etc/skel/.xscreensaver /etc/xdg/autostart/xscreensaver.desktop 2>/dev/null || true
for h in /home/*; do [ -f "$h/.xscreensaver" ] && rm -f "$h/.xscreensaver" 2>/dev/null || true; done

# ---------------------------------------------------------------------------
# 2) Install the Wayland idle/lock utilities (offline from the bundled pool;
#    also listed in manifests/desktop.pkgs so they're in the closure).
# ---------------------------------------------------------------------------
NEED=""
for p in swayidle swaylock wlopm; do
    dpkg -l "$p" 2>/dev/null | grep -q '^ii' || NEED="$NEED $p"
done
if [ -n "$NEED" ]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $NEED 2>&1 | tail -3 || \
        echo "[57] WARN: idle/lock utils not fully installed:$NEED (swayidle is required)"
fi

# ---------------------------------------------------------------------------
# 3) ncz-lock — idempotent native lock wrapper.
# ---------------------------------------------------------------------------
install -d -m0755 /usr/local/bin
cat > /usr/local/bin/ncz-lock <<'LOCK'
#!/bin/sh
# ncz-lock — lock the screen with the native Singularity lockscreen (Wayland,
# Mali-accelerated), idempotent (never double-locks). Falls back to swaylock
# only if the native lock binary is unavailable. Wayland-native; no X11.
if pgrep -x singularity-lockscreen >/dev/null 2>&1 || pgrep -x swaylock >/dev/null 2>&1; then
    exit 0
fi
if [ -x /opt/singularity/bin/singularity-lockscreen ]; then
    exec /opt/singularity/bin/singularity-lockscreen "$@"
elif command -v swaylock >/dev/null 2>&1; then
    exec swaylock -f -c 000000
fi
exit 0
LOCK
chmod 0755 /usr/local/bin/ncz-lock

# ---------------------------------------------------------------------------
# 4) ncz-screensaver — the idle->lock daemon, driven by dev.sinty.lockscreen.
# ---------------------------------------------------------------------------
cat > /usr/local/bin/ncz-screensaver <<'SS'
#!/bin/sh
# ncz-screensaver — native Wayland idle->lock (the NCZ "screensaver"/lock).
# Idle timer = swayidle (a wlroots ext-idle-notify-v1 client; Wayland-native,
# NOT X11 like the retired xscreensaver). Lock = the native Singularity
# lockscreen (Mali GLES). Screen power-off via wlopm (wlr-output-power-
# management) when the compositor supports it. Driven ENTIRELY by the
# dev.sinty.lockscreen GSettings schema so the operator controls it from
# Singularity Settings:
#   lock-enabled (b)    — master on/off
#   idle-delay   (i)    — seconds of inactivity before lock (0 = never)
#   lock-on-suspend (b) — handled here via swayidle before-sleep
# Started (backgrounded, socket-gated) by /usr/local/bin/ncz-singularity.
command -v swayidle >/dev/null 2>&1 || exit 0

SCHEMA=dev.sinty.lockscreen
gs() { GSETTINGS_SCHEMA_DIR=/opt/singularity/share/glib-2.0/schemas gsettings get "$SCHEMA" "$1" 2>/dev/null; }

[ "$(gs lock-enabled)" = "false" ] && exit 0
delay=$(gs idle-delay)
case "$delay" in ''|*[!0-9]*) delay=300 ;; esac
[ "$delay" -eq 0 ] 2>/dev/null && exit 0

LOCK=/usr/local/bin/ncz-lock
[ -x "$LOCK" ] || LOCK=/opt/singularity/bin/singularity-lockscreen
DPMS=$((delay + 60))

set -- -w timeout "$delay" "$LOCK" before-sleep "$LOCK"
if command -v wlopm >/dev/null 2>&1; then
    set -- "$@" timeout "$DPMS" "wlopm --off '*'" resume "wlopm --on '*'"
fi
exec swayidle "$@"
SS
chmod 0755 /usr/local/bin/ncz-screensaver

# ---------------------------------------------------------------------------
# 5) Guarantee the shipped schema defaults (screensaver ON at 5 min). The
#    dev.sinty.lockscreen defaults already are enabled/300/lock-on-suspend, but
#    pin them via a gschema override so a future schema change can't silently
#    turn the screensaver off in the shipped image. Operator can still change it
#    live in Singularity Settings.
# ---------------------------------------------------------------------------
SCHEMADIR=/opt/singularity/share/glib-2.0/schemas
if [ -f "$SCHEMADIR/dev.sinty.lockscreen.gschema.xml" ]; then
    cat > "$SCHEMADIR/98-ncz-screensaver.gschema.override" <<'GS'
[dev.sinty.lockscreen]
lock-enabled=true
idle-delay=300
lock-on-suspend=true
GS
    glib-compile-schemas "$SCHEMADIR" 2>&1 | tail -1 || \
        echo "[57] WARN: glib-compile-schemas failed (schemas compile on first session)"
    echo "[57] dev.sinty.lockscreen default pinned: lock on, 5-min idle, lock-on-suspend"
else
    echo "[57] NOTE: dev.sinty.lockscreen schema absent — relying on daemon defaults (300s)"
fi

echo "[57] native Wayland screensaver installed (swayidle idle -> Singularity lockscreen; xscreensaver purged)"
exit 0
