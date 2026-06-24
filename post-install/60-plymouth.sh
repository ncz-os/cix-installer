#!/bin/bash
# 60-plymouth.sh - Plymouth boot splash (NCZ black-hole theme). Optional.
# r52: handle plymouth-quit.service failures gracefully (cosmetic, doesn't block boot).
set -euo pipefail

echo "[60] Plymouth boot splash"

DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    plymouth plymouth-theme-spinner imagemagick || {
    echo "[60] plymouth packages not available — skipping splash setup"
    exit 0
}

# r130.5 (operator request): use the STOCK Ubuntu 'spinner' boot animation
# (same as Xubuntu's) but rebranded with the NCZ logo — we cannot ship the
# Xubuntu watermark. Earlier builds tried to apply a bespoke 'nclawzero' script
# theme, but it never actually showed because the plymouth packages were not in
# the offline pool (the install line failed → hook hit its `|| exit 0` guard →
# Xubuntu's default logo remained). r130.4 bundles them; here we keep it simple:
# overwrite the spinner theme's watermark with the NCZ wordmark and tint its
# background to the NCZ charcoal so the mark blends, then pin spinner as default.
SPIN_DIR=/usr/share/plymouth/themes/spinner
SPIN_PLY="$SPIN_DIR/spinner.plymouth"
ASSETS=/usr/local/lib/cix-installer/assets/branding
LOGO_ASSETS="$ASSETS/logo"
LOCKUP="$LOGO_ASSETS/nclawzero-lockup.jpg"

if [ ! -f "$SPIN_PLY" ]; then
    echo "[60] spinner theme not installed at $SPIN_DIR — cannot rebrand splash; skipping"
    exit 0
fi

# Pick imagemagick binary (v7 'magick', v6 'convert').
IM=""
command -v magick  >/dev/null 2>&1 && IM=magick
[ -z "$IM" ] && command -v convert >/dev/null 2>&1 && IM=convert

# Replace the distro (Xubuntu) watermark with the NCZ wordmark. The lockup is a
# 1024x1024 white "NCZ / nclawzero" mark on charcoal #0b0f14; crop the centre
# band to a tight watermark. If imagemagick is somehow absent, fall back to the
# full JPG re-saved as PNG so we still ship OUR logo, never Xubuntu's.
if [ -n "$IM" ] && [ -f "$LOCKUP" ]; then
    if "$IM" "$LOCKUP" -gravity center -crop 640x300+0+15 +repage "$SPIN_DIR/watermark.png" 2>/dev/null; then
        echo "[60] installed NCZ watermark into spinner theme (cropped wordmark)"
    else
        "$IM" "$LOCKUP" "$SPIN_DIR/watermark.png" 2>/dev/null && \
            echo "[60] installed NCZ watermark (full lockup; crop failed)"
    fi
elif [ -f "$LOCKUP" ]; then
    # No imagemagick: at least make sure the Xubuntu watermark is gone. Copy the
    # JPG bytes to watermark.png (plymouth reads by content, not extension).
    cp -f "$LOCKUP" "$SPIN_DIR/watermark.png" && \
        echo "[60] WARN: no imagemagick — copied raw lockup as watermark (uncropped)"
else
    echo "[60] WARN: NCZ lockup asset missing — leaving stock watermark" >&2
fi

# Tint the spinner background to NCZ charcoal (#0b0f14) so the cropped wordmark
# (which carries that same charcoal) blends into a seamless splash. Idempotent.
if grep -qE '^BackgroundStartColor=' "$SPIN_PLY"; then
    sed -i -E 's/^BackgroundStartColor=.*/BackgroundStartColor=0x0b0f14/' "$SPIN_PLY"
else
    printf 'BackgroundStartColor=0x0b0f14\n' >> "$SPIN_PLY"
fi
if grep -qE '^BackgroundEndColor=' "$SPIN_PLY"; then
    sed -i -E 's/^BackgroundEndColor=.*/BackgroundEndColor=0x0b0f14/' "$SPIN_PLY"
else
    printf 'BackgroundEndColor=0x0b0f14\n' >> "$SPIN_PLY"
fi

# r130.5 (operator: logo was at the bottom, wants it at the TOP). The spinner
# (two-step) module places the watermark by WatermarkVerticalAlignment, a
# fraction where 0=top and 1=bottom (stock Ubuntu uses ~.96 = bottom). Move it
# near the top; .08 leaves a small margin so the 640x300 wordmark isn't jammed
# against the edge on low-res GOP modes.
if grep -qE '^WatermarkVerticalAlignment=' "$SPIN_PLY"; then
    sed -i -E 's/^WatermarkVerticalAlignment=.*/WatermarkVerticalAlignment=.08/' "$SPIN_PLY"
else
    printf 'WatermarkVerticalAlignment=.08\n' >> "$SPIN_PLY"
fi

# Pin spinner as the default Plymouth theme. r123 lesson: register in MANUAL
# (sticky) mode via update-alternatives --set so xubuntu-logo (from
# xubuntu-default-settings, higher AUTO priority) cannot win and get embedded in
# the initramfs instead. The target-kernel initramfs rebuild below then embeds
# spinner (two-step module) + our watermark.
export PATH="/usr/sbin:/sbin:/usr/bin:/bin:${PATH:-}"
DEFAULT_PLY=/usr/share/plymouth/themes/default.plymouth
update-alternatives --install "$DEFAULT_PLY" default.plymouth "$SPIN_PLY" 200
update-alternatives --set default.plymouth "$SPIN_PLY"
command -v plymouth-set-default-theme >/dev/null 2>&1 && \
    plymouth-set-default-theme spinner 2>/dev/null || true
echo "[60] default.plymouth -> $(readlink -f "$DEFAULT_PLY" 2>/dev/null) (manual)"

# r130.5 (CRITICAL — operator: r130.5 hangs at the rebranded splash, box
# unreachable): DO NOT mask plymouth-quit / plymouth-quit-wait. The old r51/r52
# mask was only ever REACHED once the plymouth pkgs were bundled (r130.4+);
# before that the hook exited at the apt-get `|| exit 0` guard, so the mask never
# applied and boots worked. With the mask now active, the splash is never torn
# down at the display-manager handoff and — together with the
# NetworkManager-wait-online unmask in 33-network.sh — boot wedges behind the
# splash (the operator sees the rendered NCZ logo, then nothing). The original
# "plymouth-quit.service failed to start" was cosmetic and does NOT block boot.
# Proactively UNMASK in case an earlier build left these units masked.
systemctl unmask plymouth-quit.service plymouth-quit-wait.service 2>/dev/null || true

echo "[60] plymouth splash configured (spinner + NCZ watermark); plymouth-quit left enabled"

# r56: explicit plymouth theme set + initramfs rebuild
# (the older plymouth-set-default-theme binary isn't always installed; do it by hand)
mkdir -p /etc/plymouth
cat > /etc/plymouth/plymouthd.conf <<EOF
[Daemon]
Theme=spinner
ShowDelay=0
DeviceTimeout=8
EOF

KERNELS=""
for sidecar in /usr/local/lib/cix-installer/KVER_LTS /usr/local/lib/cix-installer/KVER_NEXT; do
    if [ -s "$sidecar" ]; then
        kver=$(tr -d ' \t\r\n' < "$sidecar")
        if [ -n "$kver" ] && [ -d "/lib/modules/$kver" ]; then
            KERNELS="$KERNELS $kver"
        fi
    fi
done
if [ -z "$KERNELS" ]; then
    for initrd in /boot/initrd.img-*; do
        [ -e "$initrd" ] || continue
        kver=${initrd#/boot/initrd.img-}
        [ -d "/lib/modules/$kver" ] && KERNELS="$KERNELS $kver"
    done
fi
KERNELS=$(printf '%s\n' $KERNELS | awk 'NF && !seen[$0]++')
if [ -z "$KERNELS" ]; then
    echo "[60] ERROR: no target kernels found for Plymouth initramfs rebuild" >&2
    exit 1
fi

for kver in $KERNELS; do
    if [ -f "/boot/initrd.img-$kver" ]; then
        update-initramfs -u -k "$kver" 2>&1 | tail -3
    else
        update-initramfs -c -k "$kver" 2>&1 | tail -3
    fi
done
echo "[60] plymouth: nclawzero theme set + target initramfs rebuilt for:$KERNELS"
