#!/bin/bash
# 84-vpu-mpv.sh — mpv default HW video (CIX Sky1 amvx VPU via V4L2 stateful M2M).
#
# NCZ-OS 26.7 "Maximilian": mpv is the shipped default video player. The Sky1
# amvx VPU exposes stateful V4L2 M2M decoders; mpv's `hwdec=v4l2m2m-copy` decodes
# on the VPU and copies frames to the (Mali GLES) presentation path. This is the
# HW-video FLOOR for the appliance. Browser HW decode via the cix-vaapi driver
# is now ALSO fixed — see 84-vpu-vaapi.sh (root-caused + hardware-validated
# 2026-07-27: a VA-API driver-name auto-detection mismatch plus an
# ld.so.conf.d priority bug were silently breaking it; both fixed, real
# Chrome hardware AV1/H264/HEVC/VP9 decode confirmed working end-to-end).
#
# RUNS INSIDE CHROOT (build-squashfs-layers.sh desktop loop / run-all.sh).
set +e

echo "[84] mpv HW video (hwdec=vaapi, zero-copy dmabuf — Sky1 amvx VPU)"

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
# 2026-08-04, measured on O6N: hwdec=vaapi with vo=dmabuf-wayland is a
# ZERO-COPY path (VPU decode -> dmabuf -> Wayland -> linlondp overlay plane)
# and runs 1080p30 H.264 at ~7% CPU. The previous default, hwdec=v4l2m2m-copy
# with vo=gpu-next, decoded on the same VPU but copied every frame out to the
# GLES presentation path; software decode for comparison is ~82% CPU. Same
# decoder silicon, but the copy is pure overhead now that the VA-API driver
# loads reliably (84-vpu-vaapi.sh's auto-detection symlink).
#
# vo falls back gpu-next -> x11 if dmabuf-wayland is unavailable (e.g. a
# non-Wayland session), and hwdec falls back to software per codec.
install -d -m0755 /etc/mpv
cat > /etc/mpv/mpv.conf <<'MPVCONF'
# NCZ-OS 26.7 — HW video on CIX Sky1 (amvx VPU via the CIX VA-API driver).
# Zero-copy: VPU decode -> dmabuf -> Wayland -> linlondp overlay plane.
# Measured: 1080p30 H.264 at ~7% CPU (software decode: ~82%).
hwdec=vaapi
vo=dmabuf-wayland,gpu-next,x11
gpu-api=opengl
gpu-context=wayland
# Fall back gracefully if the VPU decoder is unavailable for a given codec.
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

echo "[84] /etc/mpv/mpv.conf written (hwdec=vaapi, zero-copy). Browser HW decode via VA-API — see 84-vpu-vaapi.sh."
