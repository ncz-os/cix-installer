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

THEME_DIR=/usr/share/plymouth/themes/nclawzero
mkdir -p "$THEME_DIR"

ASSETS=/usr/local/lib/cix-installer/assets/branding
PLYMOUTH_ASSETS="$ASSETS/plymouth"
LOGO_ASSETS="$ASSETS/logo"

# Lay down the theme files.
[ -f "$PLYMOUTH_ASSETS/nclawzero.plymouth" ] && \
    install -m 0644 "$PLYMOUTH_ASSETS/nclawzero.plymouth" "$THEME_DIR/" || true
[ -f "$PLYMOUTH_ASSETS/nclawzero.script" ] && \
    install -m 0644 "$PLYMOUTH_ASSETS/nclawzero.script" "$THEME_DIR/" || true

# Convert JPG assets to the PNG names referenced by nclawzero.script.
if command -v magick >/dev/null 2>&1; then
    [ -f "$PLYMOUTH_ASSETS/background.jpg" ] && \
        magick "$PLYMOUTH_ASSETS/background.jpg" "$THEME_DIR/background.png" 2>/dev/null || true
    [ -f "$LOGO_ASSETS/nclawzero-lockup.jpg" ] && \
        magick "$LOGO_ASSETS/nclawzero-lockup.jpg" "$THEME_DIR/lockup.png" 2>/dev/null || true
elif command -v convert >/dev/null 2>&1; then
    [ -f "$PLYMOUTH_ASSETS/background.jpg" ] && \
        convert "$PLYMOUTH_ASSETS/background.jpg" "$THEME_DIR/background.png" 2>/dev/null || true
    [ -f "$LOGO_ASSETS/nclawzero-lockup.jpg" ] && \
        convert "$LOGO_ASSETS/nclawzero-lockup.jpg" "$THEME_DIR/lockup.png" 2>/dev/null || true
fi

MISSING_THEME_ASSETS=0
for required in \
    "$THEME_DIR/nclawzero.plymouth" \
    "$THEME_DIR/nclawzero.script" \
    "$THEME_DIR/background.png" \
    "$THEME_DIR/lockup.png"; do
    if [ ! -s "$required" ]; then
        echo "[60] ERROR: missing Plymouth theme asset: $required" >&2
        MISSING_THEME_ASSETS=1
    fi
done
if [ "$MISSING_THEME_ASSETS" -ne 0 ]; then
    exit 1
fi

# Set as default; explicit target-kernel rebuild happens below.
if command -v plymouth-set-default-theme >/dev/null 2>&1; then
    plymouth-set-default-theme -R nclawzero 2>&1 || \
        plymouth-set-default-theme -R spinner 2>&1 || \
        echo "[60] plymouth theme set failed — keeping default"
fi

# r78: DO NOT mask plymouth-quit.service OR plymouth-quit-wait.service.
# - plymouth-quit.service issues the actual `plymouth quit` to plymouthd
#   (TimeoutSec=20, so cannot hang indefinitely).
# - plymouth-quit-wait.service is the systemd ordering barrier (`plymouth
#   --wait`); getty@tty1.service is After= this unit, so masking it
#   prevents getty@tty1 from ever starting.
# Masking BOTH (per r51) caused tty1 to be unusable on r74 install — only
# tty2 worked for console login. The r51 "Failed to start" journal noise
# was cosmetic; accept it rather than break tty1.
# Both units must stay unmasked together: masking only -quit leaves -wait
# waiting forever (no quit event ever arrives).
systemctl unmask plymouth-quit.service plymouth-quit-wait.service 2>/dev/null || true

echo "[60] plymouth splash configured (quit + quit-wait both unmasked for tty1)"

# r56: explicit plymouth theme set + initramfs rebuild
# (the older plymouth-set-default-theme binary isn't always installed; do it by hand)
mkdir -p /etc/plymouth
cat > /etc/plymouth/plymouthd.conf <<EOF
[Daemon]
Theme=nclawzero
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
