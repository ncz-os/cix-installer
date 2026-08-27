#!/bin/bash
# 83-vpu-ffmpeg.sh — install the CIX Sky1 Linlon/amvx VPU-accelerated ffmpeg
# (cix-ffmpeg 7.1.2) for hardware video decode/encode/transcode on 26.7.
#
# The kernel VPU driver (amvx, in-tree on 7.2 with the vb2 q->lock fix — patch
# 0173) exposes V4L2 m2m nodes, but STOCK Ubuntu ffmpeg 8.0's h264_v4l2m2m
# FAILS at real resolutions (1080p) on the Linlon. The vendor debian13
# cix-ffmpeg 7.1.2 has patched *_v4l2m2m codecs that actually drive the VPU;
# it runs on Ubuntu 26.04 arm64 with its own bundled ffmpeg-7.1 runtime libs
# (26.04 ships ffmpeg 8.0 = different sonames), fully self-contained via
# LD_LIBRARY_PATH — the stock system ffmpeg is left untouched.
#
# Metal-validated on O6N 2026-07-23: HW decode H264->VPU (89x), HW encode
# raw->H264 (/dev/video1), full HW->HW transcode H264->HEVC incl 1920x1080.
# Codecs: dec H264/HEVC/VP9/AV1/MPEG2/4/VC1/VP8/H263; enc H264/HEVC/MJPEG/VP8/
# MPEG4/H263.
#
# Self-contained bundle (assets/cix-mm/bundle.tgz) -> /opt/cix-ffmpeg + wrappers
# /usr/local/bin/cix-{ffmpeg,ffprobe,ffplay}. RUNS INSIDE CHROOT via run-all.sh
# (no sudo — we are already root in the target). Skips cleanly if the bundle
# is absent (e.g. server variant without multimedia).
set -uo pipefail

BUNDLE="/usr/local/lib/cix-installer/assets/cix-mm/bundle.tgz"
DEST=/opt/cix-ffmpeg

if [ ! -s "$BUNDLE" ]; then
    echo "[83] cix-ffmpeg bundle absent ($BUNDLE) — skipping VPU userspace"
    exit 0
fi

echo "[83] installing cix-ffmpeg (VPU HW transcode) -> $DEST"
mkdir -p "$DEST"
tar xzf "$BUNDLE" -C "$DEST"

for t in ffmpeg ffprobe ffplay; do
    cat > "/usr/local/bin/cix-$t" <<WRAP
#!/bin/sh
# CIX Sky1 VPU-accelerated $t. Self-contained; stock system $t is untouched.
CIX_ROOT=$DEST
exec env LD_LIBRARY_PATH="\$CIX_ROOT/cixlib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}" "\$CIX_ROOT/bin/$t" "\$@"
WRAP
    chmod 0755 "/usr/local/bin/cix-$t"
done

echo "[83] cix-ffmpeg installed. Usage: cix-ffmpeg -c:v h264_v4l2m2m -i in.mp4 -c:v hevc_v4l2m2m out.mp4"
echo "[83] (needs amvx VPU driver + /dev/video-cixdec0 — in-tree on the 7.2 kernel w/ vb2 fix)"
exit 0
