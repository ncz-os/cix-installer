#!/bin/sh
# pick-theme.sh ESP_THEME_DIR -- point themes/cygnus/theme.conf at the
# background whose size matches this machine's panel, so banner_scale
# noscale shows it pixel for pixel. rEFInd has no per-resolution banner
# option, and refind.conf's "resolution max" normally lands on the panel's
# preferred mode, which is the first line of the connected DRM output's
# modes file. Unknown or other sizes keep the 1920x1080 file: rEFInd then
# centers it and fills the rest with the banner's top-left pixel, which is
# pinned to the Cygnus field color, so the edges stay dark.
set -eu
dir=${1:?ESP theme dir, e.g. /boot/efi/EFI/BOOT/themes/cygnus}
mode=""
for s in /sys/class/drm/card*-*/status; do
    [ "$(cat "$s" 2>/dev/null)" = connected ] || continue
    mode=$(head -n1 "${s%/status}/modes" 2>/dev/null || true)
    [ -n "$mode" ] && break
done
case "$mode" in
    3840x2160*) pick=3840x2160 ;;
    2560x1440*) pick=2560x1440 ;;
    *)          pick=1920x1080 ;;
esac
cp "$dir/theme-$pick.conf" "$dir/theme.conf"
echo "cygnus rEFInd theme: ${mode:-no connected output} -> background-$pick.png"
