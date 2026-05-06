#!/bin/bash
# 60-plymouth.sh — Plymouth boot splash (NCX black-hole theme). Optional.
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

# Lay down the theme files (best-effort)
[ -f "$ASSETS/plymouth/nclawzero.plymouth" ] && \
    install -m 0644 "$ASSETS/plymouth/nclawzero.plymouth" "$THEME_DIR/" || true
[ -f "$ASSETS/plymouth/nclawzero.script" ] && \
    install -m 0644 "$ASSETS/plymouth/nclawzero.script" "$THEME_DIR/" || true

# Convert background JPG → PNG for plymouth (best-effort)
if command -v convert >/dev/null 2>&1; then
    [ -f "$ASSETS/plymouth/background.jpg" ] && \
        convert "$ASSETS/plymouth/background.jpg" "$THEME_DIR/background.png" 2>/dev/null || true
fi

# Set as default — accept failure (theme may not be fully populated)
if command -v plymouth-set-default-theme >/dev/null 2>&1; then
    plymouth-set-default-theme -R nclawzero 2>&1 || \
        plymouth-set-default-theme -R spinner 2>&1 || \
        echo "[60] plymouth theme set failed — keeping default"
fi

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
update-initramfs -u 2>&1 | tail -3 || true
echo "[60] plymouth: nclawzero theme set + initramfs rebuilt"
