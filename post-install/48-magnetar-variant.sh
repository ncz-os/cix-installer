#!/bin/bash
# 48-magnetar-variant.sh — server-vs-desktop variant toggle (Magnetar SKU prep).
#
# r75 M1 (#102 #108) infrastructure: read /usr/local/lib/cix-installer/BUILD_VARIANT
# and conditionally apply server defaults (multi-user.target + masked DM).
# In r75, BUILD_VARIANT defaults to "desktop" so this hook is a no-op for
# the Reinhardt SKU. The Magnetar Server SKU (M1) will set BUILD_VARIANT=server
# during the build via a future Makefile flag, at which point this hook
# converts a built ISO into a headless boot.
#
# Keeping the toggle in a separate hook makes the Magnetar work explicit
# and reversible: `ncz desktop on` after install flips the default-target
# back to graphical.target if the operator changes their mind.
#
# RUNS INSIDE CHROOT (via run-all.sh).
set -euo pipefail

VARIANT_FILE=/usr/local/lib/cix-installer/BUILD_VARIANT
VARIANT="desktop"   # default

if [ -f "$VARIANT_FILE" ]; then
    VARIANT=$(tr -d ' \t\r\n' < "$VARIANT_FILE")
fi

case "$VARIANT" in
    desktop|reinhardt|"")
        echo "[48] BUILD_VARIANT=desktop — Reinhardt SKU, no Magnetar overrides applied"
        # Persist canonical name for ncz reporting
        echo "desktop" > "$VARIANT_FILE"
        exit 0
        ;;
    server|magnetar|headless)
        echo "[48] BUILD_VARIANT=server — Magnetar SKU, applying headless defaults"
        ;;
    *)
        echo "[48] WARN: BUILD_VARIANT='$VARIANT' is not 'desktop'|'server' — defaulting to desktop"
        echo "desktop" > "$VARIANT_FILE"
        exit 0
        ;;
esac

# Magnetar (server) variant operations:
#  1. Default target = multi-user.target
#  2. Mask any installed display managers so a stray apt install doesn't
#     pull a desktop back in unexpectedly.
#  3. Pre-install NoMachine for headless GUI on demand (per r75 P5 spec).
#     NoMachine .deb is staged under assets/nomachine/ if available.

systemctl set-default multi-user.target
echo "[48] default target set to multi-user.target"

for u in lightdm.service gdm3.service gdm.service sddm.service; do
    if systemctl list-unit-files "$u" 2>/dev/null | grep -q "^$u"; then
        systemctl disable "$u" 2>&1 | sed 's/^/    /' || true
        systemctl mask    "$u" 2>&1 | sed 's/^/    /' || true
        echo "[48] $u disabled+masked (Magnetar headless)"
    fi
done

# Pre-install NoMachine if its .deb was staged on the ISO.
NOMACHINE_DEB="/cdrom/cixmini/assets/nomachine/nomachine_arm64.deb"
if [ -f "$NOMACHINE_DEB" ]; then
    DEBIAN_FRONTEND=noninteractive dpkg -i "$NOMACHINE_DEB" 2>&1 | tail -3 || \
        echo "[48] NoMachine install warn — apt-get -f install"
    apt-get -f install -y 2>&1 | tail -3 || true
    systemctl enable nxserver 2>/dev/null || true
    echo "[48] NoMachine staged + enabled"
else
    echo "[48] NoMachine .deb not in /cdrom payload — skipping (canonical install: ncz install nomachine on first boot)"
fi

# Persist canonical name
echo "server" > "$VARIANT_FILE"

echo
echo "[48] Magnetar (server) variant applied. Boot-up will land in tty1 multi-user."
echo "     SSH stays on; reach the box at port 22 / 4000 (NoMachine)."
echo "     Switch back to desktop with: sudo ncz desktop on"
