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

# Register nclawzero as the default Plymouth theme. r123 fix: the old path used
# `plymouth-set-default-theme`, which (a) is often not on PATH in the in-target
# chroot and (b) registers the alternative in AUTO mode — so xubuntu-logo (from
# xubuntu-default-settings, higher priority) wins and the initramfs hook embeds
# THAT, not nclawzero. Result: theme shipped but never actually used. Pin it via
# update-alternatives --set (MANUAL/sticky) with full paths so it can't be
# silently reverted by later auto-mode recalculation. The target-kernel
# initramfs rebuild below then embeds nclawzero + its script module.
export PATH="/usr/sbin:/sbin:/usr/bin:/bin:${PATH:-}"
DEFAULT_PLY=/usr/share/plymouth/themes/default.plymouth
NCZ_PLY="$THEME_DIR/nclawzero.plymouth"
update-alternatives --install "$DEFAULT_PLY" default.plymouth "$NCZ_PLY" 200
update-alternatives --set default.plymouth "$NCZ_PLY"
# Bonus: run the helper too if present (harmless; rebuilds current-kernel initrd).
command -v plymouth-set-default-theme >/dev/null 2>&1 && \
    plymouth-set-default-theme nclawzero 2>/dev/null || true
echo "[60] default.plymouth -> $(readlink -f "$DEFAULT_PLY" 2>/dev/null) (manual)"

# Mask plymouth-quit if it keeps failing (cosmetic, doesn't affect boot)
# r51 saw "plymouth-quit.service Failed to start" in journal. Disable cleanly.
systemctl mask plymouth-quit.service plymouth-quit-wait.service 2>/dev/null || true

echo "[60] plymouth splash configured (or fallback) + plymouth-quit.service masked"

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
