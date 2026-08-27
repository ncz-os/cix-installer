#!/bin/bash
# 84-vpu-vaapi.sh — fix VA-API auto-detection so browser (and any VA-API
# consumer) hardware video decode actually works on the CIX Sky1 amvx VPU.
#
# Root-caused + hardware-validated on O6N 2026-07-27, using real Google
# Chrome (google-chrome-stable, official arm64 build) as the test consumer.
# Two independent bugs were stacking to make VA-API silently non-functional
# despite the CIX vaapi driver (cix-vaapi package, libcix_va_drv_video.so)
# being correctly installed the whole time:
#
# 1. ld.so.conf.d priority (fixed in 25-cix-proprietary.sh, not here): the
#    conf file pointing at /usr/share/cix/lib sorted AFTER Ubuntu's own
#    aarch64-linux-gnu.conf, so the SYSTEM libva 2.23.0 always won over
#    CIX's version-matched libva 2.22.1. The mismatch is a hard ABI break —
#    the driver only exports __vaDriverInit_1_22, the system libva looks for
#    __vaDriverInit_1_23 — so va_openDriver() failed outright for every
#    VA-API consumer, every time, regardless of anything below.
#
# 2. VA-API driver-name auto-detection (fixed HERE): libva guesses the
#    driver filename to load by querying DRM_IOCTL_VERSION on a DRM render
#    node and appending "_drv_video.so" (no "lib" prefix — that's the real
#    VA-API convention, e.g. i965_drv_video.so). On this SoC, mali_kbase
#    (the CIX proprietary GPU driver) does NOT register a DRM render node at
#    all -- it uses its own /dev/mali0 device instead, unlike upstream
#    panthor. So EVERY /dev/dri/renderD* node on this system is actually
#    bound to the "linlondp" display-controller driver (confirmed: all of
#    renderD128/129/130 report DRIVER=linlondp via sysfs), and libva's
#    auto-detection therefore always guesses "linlondp_drv_video.so" -- a
#    file that doesn't exist, because "linlondp" is a display driver name,
#    not a video-decode driver name. No naming convention Chrome or any
#    other app could set would fix this without either patching every
#    consumer or fixing it once here: a compatibility symlink so the name
#    VA-API will ALWAYS auto-detect on this hardware resolves to the real
#    CIX driver. This is not a hack specific to this one symlink name — as
#    long as mali_kbase doesn't expose a DRM render node, "linlondp" is
#    what every VA-API auto-detection call will compute, so this symlink is
#    the correct, durable fix for the actual driver-name space this SoC's
#    DRM topology produces, not a one-off workaround.
#
# Verified end-to-end on O6N with both fixes applied: `vainfo` (zero env
# vars beyond a working ld cache) reports va_openDriver() returns 0 and a
# full real profile list -- H264 (Baseline/Main/High/High10), HEVC
# (Main/Main10), VP9 (Profile0/2), AND AV1 (Profile0), decode entrypoints
# all VAEntrypointVLD. Confirmed via /proc/<pid>/maps that a real Chrome
# GPU process picks up libcix_va_drv_video.so + the matched libva 2.22.1
# runtime + libmali.so together automatically, no browser flags needed.
#
# This unblocks real browser hardware video decode (Chrome, and any other
# VA-API-aware browser/app) -- the "release-track, gated on cix-vaapi fix"
# note in 84-vpu-mpv.sh is resolved as of this hook.
#
# RUNS INSIDE CHROOT (build-squashfs-layers.sh desktop loop / run-all.sh).
set +e

echo "[84] VA-API auto-detection fix (linlondp_drv_video.so compat symlink)"

VARIANT=desktop
[ -f /usr/local/lib/cix-installer/BUILD_VARIANT ] && \
    VARIANT=$(tr -d ' \t\r\n' < /usr/local/lib/cix-installer/BUILD_VARIANT)
case "$VARIANT" in
    server|headless)
        echo "[84] BUILD_VARIANT=$VARIANT — headless SKU; skipping VA-API fix (no browser/display)"
        exit 0
        ;;
esac

VA_DIR=/usr/lib/aarch64-linux-gnu/dri
REAL_DRIVER="$VA_DIR/libcix_va_drv_video.so"
if [ ! -f "$REAL_DRIVER" ]; then
    echo "[84] $REAL_DRIVER absent — cix-vaapi package not installed, skipping"
    exit 0
fi

# Confirm the DRM topology is actually what this fix assumes (all render
# nodes bound to linlondp, none to a Mali/mali_kbase driver) before wiring a
# symlink under that name -- if a future kernel/driver combo DOES expose a
# real DRM render node for the GPU, this check keeps this hook from wiring a
# stale assumption in silently.
FOUND_NON_LINLONDP=0
for rn in /sys/class/drm/renderD*; do
    [ -e "$rn/device/uevent" ] || continue
    drv=$(grep -m1 '^DRIVER=' "$rn/device/uevent" 2>/dev/null | cut -d= -f2)
    if [ -n "$drv" ] && [ "$drv" != "linlondp" ]; then
        FOUND_NON_LINLONDP=1
        echo "[84] NOTE: $rn is bound to '$drv', not 'linlondp' — DRM topology has changed since this fix was written; verify the symlink target is still correct"
    fi
done
[ "$FOUND_NON_LINLONDP" = 0 ] && echo "[84] confirmed: all DRM render nodes report DRIVER=linlondp (expected on this mali_kbase/no-DRM-render-node combo)"

ln -sf "$(basename "$REAL_DRIVER")" "$VA_DIR/linlondp_drv_video.so"

# Belt and braces for consumers that never reach libva's auto-detection (a
# sandboxed child with a scrubbed environment still inherits the symlink, but
# an explicit driver name costs nothing and helps anything that bypasses the
# DRM-name guess entirely). greetd's PAM stack does not apply /etc/environment,
# so systemd user services need environment.d and session launchers get the
# same export from ncz-gpu-env.
install -d -m0755 /etc/environment.d
cat > /etc/environment.d/60-ncz-vaapi.conf <<'VAENV'
LIBVA_DRIVER_NAME=libcix_va
VAENV
echo "[84] $VA_DIR/linlondp_drv_video.so -> $(basename "$REAL_DRIVER")"

ldconfig 2>/dev/null || true
echo "[84] VA-API fix applied (relies on 25-cix-proprietary.sh's 00-cix-noe.conf ld priority fix for the matched libva runtime)"
