#!/bin/bash
# Verify a Chromium NCZ Sky1 build actually decodes, on real hardware.
#
# Runs on a Sky1 board. Compares hardware decode against software decode
# byte-for-byte for each codec. Nothing else counts as verification:
#
#   - a build that compiles proves nothing
#   - an open /dev/video* fd proves nothing (it accompanied flat green frames)
#   - a player's "using hardware decoding" log line proves nothing (mpv printed
#     it for HEVC while producing zero output)
#   - md5 alone proves nothing: two empty files share
#     d41d8cd98f00b204e9800998ecf8427e, which already produced one false pass
#
# So: byte counts AND checksums, on non-empty output.
set -u

MEDIA="${NCZ_TEST_MEDIA:-/home/mini/vatest}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FRAMES=20
FAIL=0

export LIBVA_DRIVER_NAME=libcix_va

check() {
    name="$1"; file="$2"; fmt="${3:-nv12}"; pix="${4:-yuv420p}"
    [ -f "$file" ] || { printf '  %-6s SKIP (no test file)\n' "$name"; return; }

    ffmpeg -hide_banner -loglevel error -i "$file" -frames:v $FRAMES \
        -pix_fmt "$pix" -f rawvideo "$WORK/sw_$name" 2>/dev/null

    # -hwaccel_output_format is required: without it ffmpeg silently falls back
    # to software and exits 0, which looks like a pass.
    timeout 120 ffmpeg -hide_banner -loglevel error \
        -init_hw_device vaapi=va:/dev/dri/renderD128 \
        -hwaccel vaapi -hwaccel_device va -hwaccel_output_format vaapi \
        -i "$file" -frames:v $FRAMES -vf "hwdownload,format=$fmt" \
        -pix_fmt "$pix" -f rawvideo "$WORK/hw_$name" 2>/dev/null

    sw=$(stat -c %s "$WORK/sw_$name" 2>/dev/null || echo 0)
    hw=$(stat -c %s "$WORK/hw_$name" 2>/dev/null || echo 0)

    if [ "$hw" = 0 ] || [ "$sw" = 0 ]; then
        printf '  %-6s FAIL  sw=%s hw=%s (empty output)\n' "$name" "$sw" "$hw"
        FAIL=1; return
    fi
    if [ "$sw" != "$hw" ]; then
        printf '  %-6s FAIL  size mismatch sw=%s hw=%s\n' "$name" "$sw" "$hw"
        FAIL=1; return
    fi
    ms=$(md5sum "$WORK/sw_$name" | cut -d' ' -f1)
    mh=$(md5sum "$WORK/hw_$name" | cut -d' ' -f1)
    if [ "$ms" != "$mh" ]; then
        printf '  %-6s FAIL  bytes differ (%s vs %s)\n' "$name" "${ms:0:8}" "${mh:0:8}"
        FAIL=1; return
    fi
    printf '  %-6s PASS  %s bytes, md5 %s\n' "$name" "$hw" "${mh:0:8}"
}

echo "=== VA-API driver: $(sha256sum /usr/lib/aarch64-linux-gnu/dri/libcix_va_drv_video.so 2>/dev/null | cut -c1-16) ==="
check h264 "$MEDIA/test1080.mp4"
check vp9  "$MEDIA/vp9-720p.webm"
check hevc "$MEDIA/hevc-720p.mp4"

# AV1 through VA-API is expected to be unavailable: the profile is deliberately
# withheld because the driver cannot assemble a decodable AV1 bitstream. It is
# checked through the browser's V4L2 path instead, below.
echo "=== browser V4L2 path ==="
if [ -x /opt/chromium-ncz-sky1/chrome ]; then
    for page in hwtest.html av1test.html; do
        [ -f "$MEDIA/$page" ] || continue
        prof="$WORK/prof-$page"
        sudo -u mini env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 \
            XDG_SESSION_TYPE=wayland /opt/chromium-ncz-sky1/chrome \
            --ozone-platform=wayland --enable-features=AcceleratedVideoDecoder \
            --user-data-dir="$prof" --no-first-run --no-default-browser-check \
            --autoplay-policy=no-user-gesture-required --window-size=1280,800 \
            "file://$MEDIA/$page" >/dev/null 2>&1 &
        sleep 28
        holder=""
        for p in $(ls /proc | grep -E '^[0-9]+$'); do
            ls -l "/proc/$p/fd" 2>/dev/null | grep -q /dev/video && holder="yes"
        done
        # An fd alone is weak evidence; it is reported as such, and the
        # bit-exact ffmpeg checks above carry the actual verdict.
        printf '  %-14s VPU held: %s\n' "$page" "${holder:-no}"
        pkill -u mini -f "user-data-dir=$prof" 2>/dev/null
        sleep 3
    done
else
    echo "  chromium-ncz-sky1 not installed, skipping browser check"
fi

[ "$FAIL" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $FAIL
