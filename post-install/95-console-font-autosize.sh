#!/bin/bash
# 95-console-font-autosize.sh — size the virtual-console (VT) font to whatever
# display is actually connected, instead of the kernel's default 8x16.
#
# Why: T2 Mac B (a T2 MacBook, Arch, Retina panel) gets a large, legible console
# font with NO explicit config at all — its display is driven by classic EFI
# GOP + legacy fbcon, and fbcon's own font_get_default() auto-scales its
# built-in font by detected resolution. NCZ-OS's Sky1 boards drive the console
# through the DRM fbdev emulation layer (drm_fbdev_generic, backing linlondp),
# which has its own, less aggressive default-font heuristic and — measured on
# O6N 2026-08-20 — did NOT pick a larger font at 3840x2160 the way fbcon does
# on T2 Mac B at 3072x1920, even though CONFIG_FONT_TER16x32=y is compiled in.
# The kernel-compiled font is a fallback fbcon uses on its own; it is not
# something userspace can select by name, so this does not try to force that
# specific one — it selects a real Terminus .psf font from the console-setup
# package sized to whatever resolution the framebuffer actually negotiated.
#
# RUNS INSIDE CHROOT (via run-all.sh) — installs the font package, script and
# systemd unit; the unit itself runs at each real boot to auto-detect and
# adjust to whatever's connected, so a board moved between monitors does not
# need the image rebuilt to get a legible console.
set -euo pipefail

echo "[95] installing console font auto-sizing"

DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    console-setup kbd 2>&1 | tail -5

install -d -m 0755 /usr/local/bin

cat > /usr/local/bin/ncz-console-font-autosize <<'SCRIPT'
#!/bin/sh
# Pick a VT font sized to the panel's REAL physical DPI, not raw pixel count.
#
# Raw-resolution thresholds are a poor proxy for "is this a HiDPI panel":
# a 16" MacBook Retina panel at 3072x1920 (~229 DPI) and a 24" 1920x1200
# desktop monitor (~94 DPI) can land in the same pixel-height bucket while
# needing very different font sizes. Measured live on T2 Mac B (T2 MacBook,
# 2026-09-20): its eDP-1 EDID reports a 340mm x 220mm physical panel at
# 3072x1920, i.e. ~229 DPI -- a true Retina panel -- but the old
# height>=2000 threshold put it in the 20x10 bucket (height=1920, just
# under 2000), producing the tiny/illegible console font the operator
# photographed. DPI-based selection puts a 229 DPI panel in the correct
# largest-font bucket regardless of its exact pixel height, and treats a
# generic PC monitor or a Sky1 Mali panel identically -- same EDID-derived
# number, no per-board special-casing.
#
# Method: read the connected DRM connector's EDID base block. Bytes 21/22
# (0-indexed) are the standard "max horizontal/vertical image size" fields
# in whole centimeters (EDID 1.x spec). DPI = negotiated pixel width /
# (physical width in inches). Falls back to the old resolution-only
# heuristic when a display reports no physical size in EDID (0x0 -- seen
# on some projectors/TVs that deliberately omit it) or has no EDID at all.
#
# Text mode: the kernel only accepts a font change while the VT is in KD_TEXT
# mode. The KMS boot splash, Plymouth and the greeter compositor switch tty1
# to KD_GRAPHICS, and the splash does not switch it back when it exits. The
# unit is ordered before the splash; if the console is still found in
# graphics mode (a unit restart under a running greeter, another splash),
# there is no text console to size, so log that and exit 0 instead of
# failing the boot.
set -eu

LOG=ncz-console-font-autosize
CONSOLE=${NCZ_CONSOLE_TTY:-/dev/tty0}
FB=${NCZ_FB_VIRTUAL_SIZE:-/sys/class/graphics/fb0/virtual_size}
DRM_DIR=${NCZ_DRM_SYSFS:-/sys/class/drm}
FONT_DIR=${NCZ_CONSOLEFONTS_DIR:-/usr/share/consolefonts}

if [ ! -r "$FB" ]; then
    echo "$LOG: no framebuffer console ($FB absent); nothing to size"
    exit 0
fi
FB_WIDTH="" FB_HEIGHT=""
IFS=, read -r FB_WIDTH FB_HEIGHT < "$FB" || true

# kbdinfo prints "text" or "graphics"; when it cannot answer, fall through
# to setfont, whose own error is classified below.
mode=$(kbdinfo -C "$CONSOLE" getmode 2>/dev/null || true)
if [ "$mode" = graphics ]; then
    echo "$LOG: $CONSOLE is in graphics mode (splash or compositor owns it); console font left unchanged"
    exit 0
fi

DPI=""
for edid in "$DRM_DIR"/card*-*/edid; do
    conn_dir=$(dirname "$edid")
    [ -r "$conn_dir/status" ] || continue
    [ "$(cat "$conn_dir/status")" = "connected" ] || continue
    [ -r "$edid" ] || continue
    hcm=$(dd if="$edid" bs=1 skip=21 count=1 2>/dev/null | od -An -tu1 | tr -d ' ')
    [ -n "${hcm:-}" ] || continue
    [ "$hcm" -gt 0 ] 2>/dev/null || continue
    [ -n "${FB_WIDTH:-}" ] || continue
    # DPI = px * 25.4mm-per-inch / (hcm * 10mm-per-cm)
    DPI=$(( (FB_WIDTH * 254) / (hcm * 100) ))
    break
done

# DEBIAN font names. The upstream/Arch "ter-132n" style names do NOT exist on
# Debian: console-setup ships Terminus as Lat15-Terminus<H>x<W>. Using the
# upstream names made setfont exit 66 (font not found) on EVERY install, and
# the old "2>/dev/null || true" swallowed it, so a 3840x2160 panel was left on
# the 8x16 "Fixed" default and the console was unreadable (measured on the MS-R1 test board,
# 2026-08-22). Verify the font exists and report failure instead of hiding it.
if [ -n "${DPI:-}" ]; then
    if [ "$DPI" -ge 180 ]; then
        FONT=Lat15-TerminusBold32x16   # true HiDPI/Retina (e.g. 229 DPI MacBook panel)
    elif [ "$DPI" -ge 120 ]; then
        FONT=Lat15-Terminus20x10       # moderately dense (e.g. 14" 1440p laptop panel)
    elif [ "$DPI" -ge 90 ]; then
        FONT=Lat15-Terminus16          # standard desktop-monitor DPI (~96)
    else
        # low-DPI large display: kernel default is fine
        echo "$LOG: ${DPI} DPI display; kernel default font kept"
        exit 0
    fi
else
    # No usable EDID physical size -- fall back to the old resolution-only
    # heuristic rather than leaving the console unscaled.
    if [ -z "${FB_HEIGHT:-}" ]; then
        echo "$LOG: $FB reports no mode; nothing to size"
        exit 0
    fi
    if [ "$FB_HEIGHT" -ge 2000 ]; then
        FONT=Lat15-TerminusBold32x16
    elif [ "$FB_HEIGHT" -ge 1200 ]; then
        FONT=Lat15-Terminus20x10
    elif [ "$FB_HEIGHT" -ge 900 ]; then
        FONT=Lat15-Terminus16
    else
        echo "$LOG: ${FB_WIDTH}x${FB_HEIGHT} display; kernel default font kept"
        exit 0
    fi
fi

if [ ! -f "$FONT_DIR/$FONT.psf.gz" ]; then
    echo "$LOG: $FONT missing - is console-setup installed?" >&2
    exit 1
fi
if err=$(setfont -C "$CONSOLE" "$FONT" 2>&1); then
    echo "$LOG: $CONSOLE font set to $FONT (${FB_WIDTH}x${FB_HEIGHT}${DPI:+, $DPI DPI})"
    exit 0
fi
case "$err" in
    *"not in text mode"*)
        # Lost a race with a graphics owner between the check and setfont.
        echo "$LOG: $CONSOLE switched to graphics mode; console font left unchanged"
        exit 0
        ;;
esac
[ -z "$err" ] || printf '%s\n' "$err" >&2
echo "$LOG: setfont $FONT failed" >&2
exit 1
SCRIPT
chmod 0755 /usr/local/bin/ncz-console-font-autosize

cat > /etc/systemd/system/ncz-console-font-autosize.service <<'UNIT'
[Unit]
Description=Size the console font to the connected display
# Early-boot unit: the font can only be changed while tty1 is in text mode.
# The KMS boot splash (and later greetd's compositor) switch tty1 to graphics
# mode, so run before them. Runs after vconsole-setup (keymap) and udev
# coldplug, so the KMS driver has bound and fb0/virtual_size reflects the
# negotiated mode. VTs opened later (getty on tty2..) start from this font.
DefaultDependencies=no
After=systemd-vconsole-setup.service systemd-udev-trigger.service systemd-udev-settle.service local-fs.target
Before=singularity-boot-splash.service getty@tty1.service greetd.service shutdown.target
Conflicts=shutdown.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ncz-console-font-autosize
RemainAfterExit=yes
# Never hold the splash or greetd for long.
TimeoutStartSec=10s

[Install]
WantedBy=sysinit.target
UNIT

systemctl enable ncz-console-font-autosize.service

echo "[95] console font auto-sizing installed (ncz-console-font-autosize.service)"
