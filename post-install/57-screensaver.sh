#!/bin/bash
# 57-screensaver.sh — NCZ screensaver: GL-enabled xscreensaver on native Panfrost.
#
# Supersedes the r112 workaround in 20-desktop.sh (which removed the GL hacks,
# shimmed the xscreensaver-gl-visual EGL probe, and forced LIBGL_ALWAYS_SOFTWARE=1).
# That workaround was a reaction to broken GL: the CIX proprietary GPU userland
# (cix-gpu-umd libmali/libgbm/libEGL under /opt/cixgpu-*) is prepended to the
# loader path via /etc/ld.so.conf.d/{00-cixgpu-pro,01-cixgpu-compat}.conf and
# SHADOWS Mesa. libmali is built for the out-of-tree mali_kbase KMD, but this
# image runs the in-tree panthor driver -> "No mali devices found", the broken
# CIX libgbm made native Panfrost GL fail, and Mesa fell back to zink-over-panvk
# reporting only OpenGL 2.1 (X11 EGL probes also failed -> "no GL visuals").
#
# 26-gpu-default-open now demotes that CIX stack, so GL runs NATIVELY:
#   Mali-G720 MC10 (Panfrost), OpenGL 3.1 Mesa 26.0.3, direct rendering Yes;
#   glxgears ~60fps; GL hacks (molecule/gears/cubestorm/pipes/atlantis/...)
#   render fullscreen via the xscreensaver daemon (verified .66 metal 2026-07-04).
#
# This hook makes the GL screensavers the shipped default:
#   1. Un-diverts any legacy xscreensaver-gl-visual shim (the real EGL probe
#      succeeds now on native Panfrost).
#   2. /etc/skel/.xscreensaver: mode random over the full installed catalog
#      (GL + 2D), appliance-safe (lock + DPMS off).
#   3. Autostarts the xscreensaver daemon in XFCE via /etc/xdg/autostart using
#      HARDWARE GL (no LIBGL_ALWAYS_SOFTWARE) so GL hacks use the Mali GPU.
#
# Config-only + idempotent. Safe in chroot (writes files; starts no daemon).
# Ordered after 20-desktop (owns the final screensaver config) and after
# 25/26 (GL driver selection). RUNS INSIDE CHROOT (via run-all.sh / bake loop).
set -uo pipefail

echo "[57] NCZ GL screensaver setup (native Mali-G720 Panfrost)"

# 1. restore the real EGL visual probe if a prior build shimmed it away
GLV=/usr/libexec/xscreensaver/xscreensaver-gl-visual
if [ -e "$GLV.real" ]; then
    rm -f "$GLV"
    dpkg-divert --quiet --local --rename --remove "$GLV" 2>&1 | tail -1 || true
    echo "[57] restored real xscreensaver-gl-visual (un-shimmed — native GL works)"
fi

# 2. system-wide default config (new users inherit it via /etc/skel)
cat > /etc/skel/.xscreensaver <<'XSS'
timeout:	0:05:00
cycle:		0:05:00
lock:		False
fade:		True
unfade:		True
fadeSeconds:	0:00:03
mode:		random
selected:	-1
dpmsEnabled:	False
XSS
echo "[57] /etc/skel/.xscreensaver (mode random over GL+2D catalog, lock off)"

# best-effort: drop the default for an already-provisioned primary user whose
# home predates the /etc/skel copy (baked images may ship an operator home).
for h in /home/*; do
    [ -d "$h" ] || continue
    u=$(basename "$h")
    id "$u" >/dev/null 2>&1 || continue
    [ -e "$h/.xscreensaver" ] && continue
    cp /etc/skel/.xscreensaver "$h/.xscreensaver" 2>/dev/null && \
        chown "$u:$u" "$h/.xscreensaver" 2>/dev/null || true
done

# 3. autostart the daemon in XFCE (hardware GL — GL hacks use the Mali GPU)
mkdir -p /etc/xdg/autostart
cat > /etc/xdg/autostart/xscreensaver.desktop <<'XAUTO'
[Desktop Entry]
Type=Application
Name=XScreenSaver
Comment=NCZ cosmic-themed screensaver daemon (native Mali-G720 Panfrost GL)
Exec=xscreensaver -no-splash
OnlyShowIn=XFCE;LXQt;MATE;Openbox;
StartupNotify=false
Terminal=false
XAUTO
echo "[57] /etc/xdg/autostart/xscreensaver.desktop (hardware GL, XFCE autostart)"

exit 0
