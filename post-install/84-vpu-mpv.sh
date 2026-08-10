#!/bin/bash
# 84-vpu-mpv.sh — video player policy for the CIX Sky1 VPU.
#
# HISTORICAL NAME. This script used to install /etc/mpv/mpv.conf with
# `hwdec=v4l2m2m-copy` and route every video MIME type to mpv, on the belief
# that mpv was "the HW video FLOOR for the appliance". That was never true on
# this hardware. It is retained under the old filename so run-all.sh ordering
# and any operator muscle memory keep working; what it does now is the opposite.
#
# WHY mpv CANNOT WORK HERE (measured on O6N, rc7, 2026-08-09):
#
# The Linlon VPU accepts every codec on its OUTPUT side:
#     H263 H264 HEVC MPG2 MPG4 VP80 VP90 AV01
# but emits ONLY AFBC-compressed formats on its CAPTURE side:
#     Y0A8 (YUV420 AFBC 8bit), Y0AA (10bit), Y2A8 (YUV422 8bit), Y2AA (10bit)
#
# GStreamer 1.28 copes with that by negotiating dmabuf with DRM format
# modifiers -- video/x-raw(memory:DMABuf), format DMA_DRM -- and letting the
# sink resolve them. FFmpeg's v4l2_m2m has no equivalent path: it wants plain
# NV12/YUV420, probes every node and answers "v4l2 output format not
# supported". So EVERY FFmpeg-backed player decodes in software here.
#
# Verified by fd check (which process holds an open fd on /dev/video*, the only
# metric that does not lie -- counting "MVX session" dmesg lines does NOT work,
# those are a frame-period warning, not a session log):
#
#     HARDWARE  clapper, showtime, singularity-videos, gst playbin
#     SOFTWARE  mpv, VLC, ffplay, Celluloid
#
# mpv is the instructive case: it LISTS h264_v4l2m2m among available decoders,
# then logs "Using software decoding" and picks software anyway -- even when the
# decoder is named explicitly with --vd=lavc:h264_v4l2m2m, and even against our
# ncz-ffmpeg which does carry the extra decoders. Installing ncz-ffmpeg does not
# help, because the AFBC rejection happens before codec choice matters.
#
# RUNS INSIDE CHROOT (build-squashfs-layers.sh desktop loop / run-all.sh).
set +e

echo "[84] video player policy (GStreamer-only HW decode on Sky1 VPU)"

VARIANT=desktop
[ -f /usr/local/lib/cix-installer/BUILD_VARIANT ] && \
    VARIANT=$(tr -d ' \t\r\n' < /usr/local/lib/cix-installer/BUILD_VARIANT)
case "$VARIANT" in
    server|headless)
        echo "[84] BUILD_VARIANT=$VARIANT — headless SKU; skipping player policy"
        exit 0
        ;;
esac

# Remove the ineffective mpv HW config if an older image left one behind.
if [ -f /etc/mpv/mpv.conf ]; then
    rm -f /etc/mpv/mpv.conf
    rmdir /etc/mpv 2>/dev/null
    echo "[84] removed stale /etc/mpv/mpv.conf (hwdec=v4l2m2m-copy never engaged the VPU)"
fi

# VPU access for the operator. 20-desktop already adds video/render; keep this
# idempotent belt-and-braces since decode needs /dev/video*.
OPERATOR_USER=$(awk -F: '$3 >= 1000 && $3 < 65000 {print $1; exit}' /etc/passwd)
[ -z "$OPERATOR_USER" ] && id ncz >/dev/null 2>&1 && OPERATOR_USER=ncz
if [ -n "$OPERATOR_USER" ] && getent group video >/dev/null 2>&1; then
    usermod -aG video "$OPERATOR_USER" 2>/dev/null || true
fi

# Route video MIME types to a GStreamer player. Prefer Clapper (GTK4, Wayland
# native); fall back to Showtime, then the shipped singularity-videos.
PLAYER_DESKTOP=""
for cand in com.github.rafostar.Clapper.desktop org.gnome.Showtime.desktop; do
    if [ -f "/usr/share/applications/$cand" ]; then PLAYER_DESKTOP="$cand"; break; fi
done
if [ -z "$PLAYER_DESKTOP" ] && [ -f /opt/singularity/share/applications/singularity-videos.desktop ]; then
    PLAYER_DESKTOP=singularity-videos.desktop
fi

if [ -n "$PLAYER_DESKTOP" ]; then
    for MD in /etc/xdg/mimeapps.list; do
        [ -f "$MD" ] || touch "$MD"
        # Drop any stale mpv routing from previous images.
        sed -i '/=mpv\.desktop$/d' "$MD" 2>/dev/null
        grep -q "video/mp4=$PLAYER_DESKTOP" "$MD" 2>/dev/null && continue
        cat >> "$MD" <<MIMEV
video/mp4=$PLAYER_DESKTOP
video/x-matroska=$PLAYER_DESKTOP
video/webm=$PLAYER_DESKTOP
video/quicktime=$PLAYER_DESKTOP
MIMEV
    done
    echo "[84] video MIME types routed to $PLAYER_DESKTOP (GStreamer = hardware decode)"
else
    echo "[84] WARNING: no GStreamer player found; video MIME routing left unset"
fi

echo "[84] players: clapper/showtime/singularity-videos = HW. mpv/VLC/ffplay/Celluloid = software, not shipped."
