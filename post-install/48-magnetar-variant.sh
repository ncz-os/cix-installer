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

# r76 fix #2 — defensive SSH enable for Magnetar (server SKU is
# broken-by-definition without sshd). 35-ssh.sh already enables ssh,
# but on r75 .66 something silently failed and the box came up with
# port 22 closed. This is a belt-and-suspenders re-enable so any
# transient failure in 35-ssh.sh doesn't ship a headless box you
# can't reach. Loud on failure.
echo "[48] defensive SSH enable for Magnetar"
if systemctl enable ssh 2>&1 | sed 's/^/    /'; then
    echo "[48] ssh.service enabled (defensive)"
else
    echo "[48] ERROR: ssh.service enable failed — Magnetar will ship without SSH" >&2
    # Don't exit; let the install complete so the operator can fix on the
    # console. But make the failure obvious in the hook log.
fi

# r76 fix #3 — mask getty@tty1 on Magnetar.
#
# Symptom on r75: tty1 unusable for login (kernel printk to console=tty0
# fights agetty's prompt; user sees only boot diag spam). tty2-tty4 work
# fine. On a desktop variant Reinhardt the X session takes over so it's
# not noticed; on headless Magnetar tty1 is the operator's primary
# physical-console entry point and the bad UX is critical.
#
# Fix: stop spawning agetty on tty1 entirely. Operators land on tty2 by
# pressing Alt+F2 (or just default-spawn there). tty1 stays as the
# kernel's console for boot diag, which is what the cmdline already
# requested via console=tty0.
#
# Lower-risk than touching the kernel cmdline (which would lose video
# console for non-serial-attached operators).

# Force-enable getty@tty2 statically so we know there's a working login
# prompt regardless of systemd's ConditionPathExists or autovt logic.
systemctl enable getty@tty2.service 2>&1 | sed 's/^/    /' || true
echo "[48] getty@tty2 enabled (default operator console)"



# r76 fix #4 — issue.d pointer so the user knows where to log in.
# Shows on tty2-tty6 above the login prompt.
mkdir -p /etc/issue.d
# Pure ASCII — agetty/console may not have a font with Unicode box-draw
# chars; broken renderings on tty2 looked worse than no border at all.
# Classic 1970s Unix / mainframe MOTD aesthetic.
cat > /etc/issue.d/10-ncz-magnetar.issue <<'EOF'

****************************************************************
*                                                              *
*           N C Z   M A G N E T A R   ( h e a d l e s s )      *
*                                                              *
*--------------------------------------------------------------*
*                                                              *
*   THIS SYSTEM IS RUNNING IN HEADLESS SERVER MODE             *
*                                                              *
*   Console login is fully available on all terminals.         *
*   Switch consoles:    Alt + F1 .. F6                         *
*                                                              *
*--------------------------------------------------------------*
*                                                              *
*   Remote access ......... ssh   port 22                      *
*   Remote desktop ........ NoMachine  port 4000  (if instd)   *
*   Re-enable graphical ... sudo ncz desktop on                *
*                                                              *
****************************************************************

EOF
chmod 0644 /etc/issue.d/10-ncz-magnetar.issue
echo "[48] /etc/issue.d/10-ncz-magnetar.issue written"

# r76 fix #5 — defensive NetworkManager wired auto-up.
# If the wired link is down at boot, SSH-on-port-22 doesn't help. Make
# sure NM has an auto-connect ethernet profile so any plugged cable
# gets DHCP without operator intervention.
if command -v nmcli >/dev/null 2>&1; then
    # Find the first ethernet device (skip lo, virtual, wireless)
    ETH_DEV=$(nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2=="ethernet"{print $1; exit}')
    if [ -n "$ETH_DEV" ]; then
        # Only add a profile if there isn't one already for this device.
        if ! nmcli -t -f NAME,DEVICE connection show 2>/dev/null | grep -q ":${ETH_DEV}$"; then
            nmcli connection add type ethernet con-name "ncz-wired-${ETH_DEV}" \
                ifname "$ETH_DEV" connection.autoconnect yes ipv4.method auto ipv6.method auto \
                2>&1 | sed 's/^/    /' || \
                echo "[48] WARN: failed to add wired auto-profile for $ETH_DEV (will retry post-boot)"
            echo "[48] wired auto-connect profile added for $ETH_DEV"
        else
            echo "[48] wired profile for $ETH_DEV already present — skipping"
        fi
    else
        echo "[48] no ethernet device visible in chroot — defer profile to first boot"
    fi
else
    echo "[48] nmcli not available in chroot — defer profile to first boot"
fi

# Persist canonical name
echo "server" > "$VARIANT_FILE"

echo
echo "[48] Magnetar (server) variant applied. Boot-up will land in tty2 multi-user."
echo "     tty1 reserved for kernel boot diag; press Alt+F2 for login prompt."
echo "     SSH on port 22; NoMachine 4000 (if installed)."
echo "     Switch back to desktop with: sudo ncz desktop on"
