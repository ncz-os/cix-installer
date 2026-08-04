#!/bin/bash
# 28-vaapi-media.sh — VPU-accelerated media defaults (CIX VAAPI).
#
# Validated on O6N 2026-08-04 (7.2.0-rc6-sky1-ncz, Mali boot):
#   decode: mpv --hwdec=vaapi --vo=dmabuf-wayland = zero-copy
#           (VPU -> dmabuf -> Wayland -> linlondp overlay plane),
#           1080p30 H.264 at ~7% CPU vs ~82% software.
#   encode: ffmpeg h264_vaapi = 13.2x realtime at 1080p30.
#
# Requires the CIX 2026Q2 media userspace (vendored via 25-cix-proprietary):
#   cix-vaapi (libcix_va_drv_video.so), cix-libva*, cix-libcme (hard dep of
#   the VA driver: dlopen fails without libcme.so.1), cix-vpu-firmware.
#
# DO NOT install cix-gstreamer: it drops GStreamer 1.22 core libraries into
# /usr/share/cix/lib, which is on the ldconfig path, silently shadowing the
# distro's newer GStreamer for every process. On trixie that broke libgtk-4
# (undefined symbol gst_video_info_dma_drm_to_video_info) and crash-looped
# the desktop shell at login. General rule: vendor debs must never place
# libraries in an ldconfig'd directory that also serves the distro.
set -euo pipefail

ROOT="${1:-/}"

# Soft dependency check: the configs below are inert without the CIX VAAPI
# userspace (cix-vaapi + cix-libcme, staged by 25-cix-proprietary). Warn
# rather than fail -- media acceleration is not install-critical.
if [ ! -e "$ROOT/usr/lib/aarch64-linux-gnu/dri/libcix_va_drv_video.so" ]; then
    echo "[28] WARN: libcix_va_drv_video.so not present -- VAAPI defaults installed but inactive until cix-vaapi/cix-libcme are installed"
fi

# systemd user services (session launchers additionally export this via
# ncz-gpu-env — greetd's PAM does not read /etc/environment).
install -d "$ROOT/etc/environment.d"
cat > "$ROOT/etc/environment.d/60-ncz-vaapi.conf" <<'EOF'
LIBVA_DRIVER_NAME=libcix_va
EOF

# mpv: hardware decode + zero-copy presentation by default. Only written if
# absent so an operator-customized mpv.conf is never clobbered on re-runs.
# No vaapi-device pin: mpv's default is the first render node, which on a
# Mali boot is always the first linlondp instance -- the CIX VA driver works
# against any of them.
install -d "$ROOT/etc/mpv"
if [ ! -e "$ROOT/etc/mpv/mpv.conf" ]; then
    cat > "$ROOT/etc/mpv/mpv.conf" <<'EOF'
# NCZ-OS defaults: VPU-accelerated playback via the CIX VAAPI driver.
# Zero-copy: VAAPI (VPU) decode -> dmabuf -> Wayland -> linlondp overlay.
# Measured on O6: 1080p30 H.264 at ~7% CPU vs ~82% software decode.
hwdec=vaapi
vo=dmabuf-wayland,gpu,x11
EOF
fi

echo "[28] VAAPI media defaults installed (LIBVA_DRIVER_NAME + mpv.conf)"
