#!/bin/bash
# 84-vpu-mpv.sh — mpv default HW video (CIX Sky1 amvx VPU via V4L2 stateful M2M).
#
# mpv is the shipped default video player. The Sky1 amvx VPU exposes stateful
# V4L2 M2M decoders; mpv's `hwdec=v4l2m2m-copy` decodes on the VPU and copies
# frames to the (Mali GLES) presentation path. Chromium NCZ Sky1 Edition uses
# the same V4L2 decoder (it is built without VA-API). The CIX VA-API driver
# (84-vpu-vaapi.sh) stays installed for vainfo/encode experiments but is NOT
# the playback default: on 7.3 it fails or hangs for decode (measured below).
#
# RUNS INSIDE CHROOT (build-squashfs-layers.sh desktop loop / run-all.sh).
# ARCH GATE (dual-arch parity): Sky1-only hook. run-all.sh runs every hook on every architecture, so
# log and no-op anywhere else (build/lint-hook-arch-gates.sh enforces this).
_ncz_a="${NCZ_TARGET_ARCH:-$(tr -d '[:space:]' < /usr/local/lib/cix-installer/BUILD_ARCH 2>/dev/null)}"
[ -n "$_ncz_a" ] || _ncz_a="$(dpkg --print-architecture 2>/dev/null || true)"
if [ "$_ncz_a" != arm64 ]; then echo "[84] Sky1-only hook; target architecture is '${_ncz_a:-unknown}' -- skipping"; exit 0; fi
unset _ncz_a
set +e

echo "[84] mpv HW video (Sky1 amvx VPU)"

VARIANT=desktop
[ -f /usr/local/lib/cix-installer/BUILD_VARIANT ] && \
    VARIANT=$(tr -d ' \t\r\n' < /usr/local/lib/cix-installer/BUILD_VARIANT)
case "$VARIANT" in
    server|headless)
        echo "[84] BUILD_VARIANT=$VARIANT — headless SKU; skipping mpv HW config"
        exit 0
        ;;
esac

# System-wide mpv config.
#
# 2026-10-06, measured on BOTH the O6N and the MS-R1 (7.3.0-rc6-sky1-ncz,
# cix-vpu-driver-dkms 1.0.2-ncz1, cix-vaapi 1.0.0, mpv 0.41, same clips and
# commands, docs/HW-VIDEO-DECODE-STATUS.md): the VA-API route is broken and the
# V4L2 stateful M2M route is healthy, identically on both boards.
#   hwdec=vaapi (the previous default): H.264 1080p either exits with
#     "Failed to send decoder command" (MS-R1) or silently drops to software
#     at ~68% CPU (O6N); HEVC 4K does not play at all ("SPS is missing",
#     mpv rc=2); VP9/AV1/MPEG-2 are not offered by the driver -> software.
#     ffmpeg -hwaccel vaapi hangs in the driver (futex) until SIGKILL, and the
#     kernel logs "MVX if: Buffer plane too small" / "MMU ABORT": the CIX VA
#     driver hands the VPU capture surfaces smaller than the frame it writes.
#   hwdec=v4l2m2m-copy + vo=gpu-next: hardware decode, 0 dropped frames,
#     H.264 1080p 4% CPU, HEVC/VP9 2160p 13-15% CPU (software: 39-75%);
#     frames bit-identical to software decode (framemd5, 60 frames per clip).
#   hwdec=v4l2m2m + vo=dmabuf-wayland (zero-copy) never engages the VPU: the
#     VO only takes VA-API surfaces, so it decodes in software (70-268% CPU).
# AV1 has no V4L2 M2M decoder in FFmpeg; mpv uses dav1d (1080p30 ~30% CPU).
# hwdec falls back to software per codec; vo falls back gpu-next -> x11.
install -d -m0755 /etc/mpv
_HWDEC=v4l2m2m-copy
_VO="gpu-next,x11"
_NOTE="V4L2 stateful M2M decode on the amvx VPU (VA-API route is broken, see docs/HW-VIDEO-DECODE-STATUS.md)"
cat > /etc/mpv/mpv.conf <<MPVCONF
# NCZ-OS -- HW video on CIX Sky1 (amvx VPU). $_NOTE.
hwdec=$_HWDEC
vo=$_VO
gpu-api=opengl
gpu-context=wayland
# Fall back gracefully (per codec) to software decode when the VPU cannot take a stream.
hwdec-codecs=all
# Keep audio on the PipeWire/Pulse stack.
ao=pipewire,pulse,alsa
MPVCONF

# Ensure the operator can reach the V4L2 VPU nodes (video group). Best-effort;
# 20-desktop already adds the operator to video/render.
OPERATOR_USER=$(awk -F: '$3 >= 1000 && $3 < 65000 {print $1; exit}' /etc/passwd)
[ -z "$OPERATOR_USER" ] && id ncz >/dev/null 2>&1 && OPERATOR_USER=ncz
if [ -n "$OPERATOR_USER" ] && getent group video >/dev/null 2>&1; then
    usermod -aG video "$OPERATOR_USER" 2>/dev/null || true
fi

# Route common video MIME types to mpv by default (Singularity app dir + system).
for MD in /etc/xdg/mimeapps.list; do
    [ -f "$MD" ] || continue
    grep -q 'video/mp4=mpv.desktop' "$MD" 2>/dev/null && continue
    cat >> "$MD" <<'MIMEV'
video/mp4=mpv.desktop
video/x-matroska=mpv.desktop
video/webm=mpv.desktop
video/quicktime=mpv.desktop
MIMEV
done

echo "[84] /etc/mpv/mpv.conf written (hwdec=$_HWDEC)"
