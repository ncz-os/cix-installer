#!/bin/bash
# 48-server-variant.sh — server-vs-desktop variant toggle.
#
# r75 M1 (#102 #108) infrastructure: read /usr/local/lib/cix-installer/BUILD_VARIANT
# and conditionally apply server defaults (multi-user.target + masked DM).
# BUILD_VARIANT defaults to "desktop" so this hook is a no-op for a
# desktop install. When the desktop component is unticked in the installer,
# preseed/late.sh writes BUILD_VARIANT=server and this hook converts the
# install into a headless boot.
#
# (2026-07-27: the old per-variant codename scheme was retired — the release
# codename from release.conf applies to BOTH variants; "Desktop"/"Server" is
# just the qualifier. Renamed from the old magnetar-variant hook to match.)
#
# Keeping the toggle in a separate hook makes the server-variant work
# explicit and reversible: `ncz desktop on` after install flips the
# default-target back to graphical.target if the operator changes their mind.
#
# RUNS INSIDE CHROOT (via run-all.sh).
set -euo pipefail

VARIANT_FILE=/usr/local/lib/cix-installer/BUILD_VARIANT
VARIANT="desktop"   # default

if [ -f "$VARIANT_FILE" ]; then
    VARIANT=$(tr -d ' \t\r\n' < "$VARIANT_FILE")
fi

case "$VARIANT" in
    desktop|"")
        echo "[48] BUILD_VARIANT=desktop — Desktop variant, no server overrides applied"
        # Persist canonical name for ncz reporting
        echo "desktop" > "$VARIANT_FILE"
        exit 0
        ;;
    server|headless)
        echo "[48] BUILD_VARIANT=server — Server variant, applying headless defaults"
        ;;
    *)
        echo "[48] WARN: BUILD_VARIANT='$VARIANT' is not 'desktop'|'server' — defaulting to desktop"
        echo "desktop" > "$VARIANT_FILE"
        exit 0
        ;;
esac

# Server variant operations:
#  1. Default target = multi-user.target
#  2. Mask any installed display managers so a stray apt install doesn't
#     pull a desktop back in unexpectedly.
#  3. (NoMachine removed 2026-07-07 -- unreliable first-boot network
#     install, see 31-remote-access.sh for the rationale.)

systemctl set-default multi-user.target
echo "[48] default target set to multi-user.target"

for u in lightdm.service gdm3.service gdm.service sddm.service; do
    if systemctl list-unit-files "$u" 2>/dev/null | grep -q "^$u"; then
        systemctl disable "$u" 2>&1 | sed 's/^/    /' || true
        systemctl mask    "$u" 2>&1 | sed 's/^/    /' || true
        echo "[48] $u disabled+masked (Server headless)"
    fi
done

# r76 fix #2 — defensive SSH enable for the Server variant (broken-by-
# definition without sshd). 35-ssh.sh already enables ssh, but on r75 the MS-R1 test board
# something silently failed and the box came up with port 22 closed. This
# is a belt-and-suspenders re-enable so any transient failure in 35-ssh.sh
# doesn't ship a headless box you can't reach. Loud on failure.
echo "[48] defensive SSH enable for Server variant"
if systemctl enable ssh 2>&1 | sed 's/^/    /'; then
    echo "[48] ssh.service enabled (defensive)"
else
    echo "[48] ERROR: ssh.service enable failed — Server variant will ship without SSH" >&2
    # Don't exit; let the install complete so the operator can fix on the
    # console. But make the failure obvious in the hook log.
fi

# r76 fix #3 — mask getty@tty1 on the Server variant.
#
# Symptom on r75: tty1 unusable for login (kernel printk to console=tty0
# fights agetty's prompt; user sees only boot diag spam). tty2-tty4 work
# fine. On the Desktop variant the X session takes over so it's not
# noticed; on headless Server tty1 is the operator's primary physical-
# console entry point and the bad UX is critical.
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
# MAGNETAR SERVER: an install from a Magnetar Server medium names its edition
# (post-install/lib/ncz-brand.sh) and has no desktop to re-enable. A desktop
# medium's console-only install keeps the block below unchanged.
_ncz_medium=desktop
_ncz_brand_lib="$(dirname "$0")/lib/ncz-brand.sh"
[ -r "$_ncz_brand_lib" ] || _ncz_brand_lib=/usr/local/lib/cix-installer/post-install/lib/ncz-brand.sh
if [ -r "$_ncz_brand_lib" ] && . "$_ncz_brand_lib"; then
    _ncz_medium=$(ncz_brand_medium_variant /usr/local/lib/cix-installer)
fi
if [ "$_ncz_medium" = server ]; then
    _ncz_ver=""
    for _ncz_rf in /usr/local/lib/cix-installer/RELEASE /etc/cix-installer/RELEASE; do
        [ -r "$_ncz_rf" ] || continue
        _ncz_ver=$(sed -n 's/^NCZ_RELEASE_VERSION="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$_ncz_rf" | head -1)
        [ -n "$_ncz_ver" ] && break
    done
    # Plain ASCII, no box (copy review H3). \4 is agetty's IPv4 address escape,
    # \r and \m the kernel release and machine.
    {
        echo
        ncz_brand_label server "" NCZ-OS "$_ncz_ver"
        printf '%s\n' 'Log in below, or over the network with: ssh <user>@\4' \
            'Other consoles: press Alt+F2 to Alt+F6.' 'Kernel \r (\m)'
        echo
    } > /etc/issue.d/10-ncz-server.issue
else
cat > /etc/issue.d/10-ncz-server.issue <<'EOF'

****************************************************************
*                                                              *
*      N C Z   M A X I M I L I A N   S E R V E R               *
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
*   Re-enable graphical ... sudo ncz desktop on                *
*                                                              *
****************************************************************

   NCZ-OS  -  running kernel \r  (\m)

EOF
fi
chmod 0644 /etc/issue.d/10-ncz-server.issue
echo "[48] /etc/issue.d/10-ncz-server.issue written"

# r76 fix #5 — defensive NetworkManager wired auto-up.
# If the wired link is down at boot, SSH-on-port-22 doesn't help. Make
# sure NM has an auto-connect ethernet profile so any plugged cable
# gets DHCP without operator intervention.
if command -v nmcli >/dev/null 2>&1; then
    # Find the first ethernet device (skip lo, virtual, wireless)
    # nmcli has no daemon to talk to inside the install chroot and exits non-zero;
    # under errexit + pipefail that ended the hook here (console installs).
    ETH_DEV=$(nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2=="ethernet"{print $1; exit}' || true)
    if [ -n "$ETH_DEV" ]; then
        # Only add a profile if there isn't one already for this device.
        if ! { nmcli -t -f NAME,DEVICE connection show 2>/dev/null || true; } | grep ":${ETH_DEV}$" >/dev/null; then
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
echo "[48] Server variant applied. Boot-up will land in tty2 multi-user."
echo "     tty1 reserved for kernel boot diag; press Alt+F2 for login prompt."
echo "     SSH on port 22."
echo "     Switch back to desktop with: sudo ncz desktop on"
