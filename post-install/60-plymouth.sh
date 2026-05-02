#!/bin/bash
# 60-plymouth.sh — install the custom nclawzero Plymouth theme.
#
# Bundled assets:
#   - assets/branding/plymouth/nclawzero.plymouth   (theme manifest)
#   - assets/branding/plymouth/nclawzero.script     (animation script)
#   - assets/branding/plymouth/background.jpg       (circuit-mesh dark bg)
#   - assets/branding/logo/nclawzero-lockup.jpg     (NCZ + nclawzero)
#
# Plymouth requires PNG inputs (its image loader is libpng-based, not
# libjpeg). We convert .jpg → .png at install-time via ImageMagick.
set -euo pipefail

echo "[60] Plymouth boot splash"

DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    plymouth plymouth-themes imagemagick

THEME_DIR=/usr/share/plymouth/themes/nclawzero
mkdir -p "$THEME_DIR"

ASSETS=/usr/local/lib/cix-installer/assets/branding

install -m 0644 "$ASSETS/plymouth/nclawzero.plymouth" "$THEME_DIR/nclawzero.plymouth"
install -m 0644 "$ASSETS/plymouth/nclawzero.script"   "$THEME_DIR/nclawzero.script"

# Convert canonical .jpg assets → .png (Plymouth requires PNG)
convert "$ASSETS/plymouth/background.jpg"      "$THEME_DIR/background.png"
convert "$ASSETS/logo/nclawzero-lockup.jpg"    "$THEME_DIR/lockup.png"

plymouth-set-default-theme -R nclawzero

# Kernel cmdline needs `splash quiet` so Plymouth gets the screen
# instead of dmesg taking over. 70-bootloader.sh picks this fragment up.
mkdir -p /etc/kernel/cmdline.d
cat > /etc/kernel/cmdline.d/10-splash.conf <<'EOF'
splash quiet
EOF
