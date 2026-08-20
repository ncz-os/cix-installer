#!/bin/bash
# 95-console-font-autosize.sh — size the virtual-console (VT) font to whatever
# display is actually connected, instead of the kernel's default 8x16.
#
# Why: MEDUSA (a T2 MacBook, Arch, Retina panel) gets a large, legible console
# font with NO explicit config at all — its display is driven by classic EFI
# GOP + legacy fbcon, and fbcon's own font_get_default() auto-scales its
# built-in font by detected resolution. NCZ-OS's Sky1 boards drive the console
# through the DRM fbdev emulation layer (drm_fbdev_generic, backing linlondp),
# which has its own, less aggressive default-font heuristic and — measured on
# O6N 2026-08-20 — did NOT pick a larger font at 3840x2160 the way fbcon does
# on MEDUSA at 3072x1920, even though CONFIG_FONT_TER16x32=y is compiled in.
# The kernel-compiled font is a fallback fbcon uses on its own; it is not
# something userspace can select by name, so this does not try to force that
# specific one — it selects a real Terminus .psf font from the console-setup
# package sized to whatever resolution the framebuffer actually negotiated.
#
# RUNS INSIDE CHROOT (via run-all.sh) — installs the font package, script and
# systemd unit; the unit itself runs at each real boot to auto-detect and
# adjust to whatever's connected, so a board moved between monitors does not
# need the ISO rebuilt to get a legible console.
set -euo pipefail

echo "[95] installing console font auto-sizing"

DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    console-setup kbd 2>&1 | tail -5

install -d -m 0755 /usr/local/bin

cat > /usr/local/bin/ncz-console-font-autosize <<'SCRIPT'
#!/bin/sh
# Pick a VT font sized to whatever the framebuffer actually negotiated at
# KMS time (/sys/class/graphics/fb0/virtual_size), so a board moved between a
# small panel and a 4K monitor gets a legible console either way without a
# rebuild. Thresholds are on vertical resolution, which tracks "is this
# effectively a HiDPI panel" better than horizontal on today's aspect ratios.
set -eu

FB=/sys/class/graphics/fb0/virtual_size
[ -r "$FB" ] || exit 0

IFS=, read -r WIDTH HEIGHT < "$FB"
[ -n "${HEIGHT:-}" ] || exit 0

if [ "$HEIGHT" -ge 2000 ]; then
    FONT=ter-132n    # Terminus 32x16 — 4K/2160p-class and Retina-class panels
elif [ "$HEIGHT" -ge 1200 ]; then
    FONT=ter-120n    # Terminus 20x10 — 1440p-ish
elif [ "$HEIGHT" -ge 900 ]; then
    FONT=ter-116n    # Terminus 16x8 — 1080p
else
    exit 0           # leave the kernel default alone below that
fi

setfont "$FONT" 2>/dev/null || true
SCRIPT
chmod 0755 /usr/local/bin/ncz-console-font-autosize

cat > /etc/systemd/system/ncz-console-font-autosize.service <<'UNIT'
[Unit]
Description=Size the console font to the connected display
# After vconsole-setup (keymap) and the point KMS has picked a mode, so
# fb0/virtual_size reflects the real negotiated resolution, not a boot-stage
# placeholder.
After=systemd-vconsole-setup.service systemd-udev-settle.service
Before=getty@tty1.service greetd.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ncz-console-font-autosize
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
UNIT

systemctl enable ncz-console-font-autosize.service

echo "[95] console font auto-sizing installed (ncz-console-font-autosize.service)"
