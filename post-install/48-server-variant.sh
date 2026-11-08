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

# Console burn-in protection (operator 2026-11-08): a server left on a console
# burns the panel in. Blank after 5 minutes, power the panel down after one
# more; any key wakes. Kernel cmdline also carries consoleblank=300 for the
# boot menu entries; this unit re-applies the same policy on every VT (the
# cmdline only covers the boot console) and re-runs when a new VT appears.
mkdir -p /etc/ncz
cat > /etc/ncz/console.conf <<'CONF'
# /etc/ncz/console.conf -- server console idle policy (ncz-console-blank).
# Sourceable by /bin/sh. NCZ_CONSOLE_BLANK=no disables everything.
NCZ_CONSOLE_BLANK=yes
NCZ_CONSOLE_IDLE_MIN=5
NCZ_CONSOLE_POWERDOWN_MIN=1
NCZ_CONSOLE_SAVER=none
CONF
chmod 0644 /etc/ncz/console.conf

cat > /usr/local/sbin/ncz-console-blank <<'SCRIPT'
#!/bin/bash
# ncz-console-blank -- apply the /etc/ncz/console.conf idle policy to every VT.
# Server consoles only; a desktop session owns DPMS itself. Idempotent: setterm
# writes the console escape sequence, so re-running on a new VT is safe.
set -u
conf=/etc/ncz/console.conf
NCZ_CONSOLE_BLANK=yes
NCZ_CONSOLE_IDLE_MIN=5
NCZ_CONSOLE_POWERDOWN_MIN=1
[ -r "$conf" ] && . "$conf"
case "${NCZ_CONSOLE_BLANK:-yes}" in
    no|0|false|disabled) exit 0 ;;
esac
idle="${NCZ_CONSOLE_IDLE_MIN:-5}"; power="${NCZ_CONSOLE_POWERDOWN_MIN:-1}"
for _t in /dev/console /dev/tty0 /dev/tty[1-9] /dev/tty1[0-9] /dev/tty2[0-9] /dev/tty3[0-9]; do
    [ -c "$_t" ] || continue
    setterm --blank "$idle" --powerdown "$power" > "$_t" 2>/dev/null || true
done
exit 0
SCRIPT
chmod 0755 /usr/local/sbin/ncz-console-blank

cat > /etc/systemd/system/ncz-console-blank.service <<'UNIT'
[Unit]
Description=NCZ console idle blanking (server burn-in protection)
After=getty.target multi-user.target
ConditionPathExists=/etc/ncz/console.conf

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/ncz-console-blank

[Install]
WantedBy=multi-user.target
UNIT
chmod 0644 /etc/systemd/system/ncz-console-blank.service

# A VT appears later (Alt+F3 on a freshly booted server): re-apply at once.
cat > /etc/udev/rules.d/90-ncz-console-blank.rules <<'RULES'
ACTION=="add", SUBSYSTEM=="vtconsole", KERNEL=="vtcon*", ATTR{name}!="*dummy device", RUN+="/usr/bin/systemctl --no-block restart ncz-console-blank.service"
RULES
chmod 0644 /etc/udev/rules.d/90-ncz-console-blank.rules
systemctl enable ncz-console-blank.service 2>&1 | sed 's/^/    /' || true
echo "[48] console idle blanking installed (ncz-console-blank, /etc/ncz/console.conf)"

# Optional tier BEFORE the blank (off by default): a tiny text saver that
# drifts the brand wordmark, dimmed, and stops on any key. No third-party
# packages (operator: no cmatrix/pipes); python3 + ANSI only. One daemon owns
# both the idle judgement and the drawing: it holds the console open, reads it
# (so "any key" is the same read that resets the idle clock), and only draws
# between 2 minutes idle and the blank deadline, then stops writing so the
# kernel can blank the panel without being woken by the saver.
cat > /usr/local/sbin/ncz-console-saver <<'SAVER'
#!/usr/bin/env python3
"""ncz-console-saver -- idle console wordmark drift; any key stops the saver.

Off by default (NCZ_CONSOLE_SAVER=wordmark enables it). Dependency-free: ANSI
escapes and a blocking read on the console device; no curses, no packages.
The daemon tracks console input itself: 2 minutes of silence starts the drift,
and it stops drawing at NCZ_CONSOLE_IDLE_MIN so the kernel can blank the panel
without the saver's output waking it. Any key clears the saver immediately.
"""
import os, select, sys, termios, time, tty

WORD = ("N C Z - O S", "M a g n e t a r   S e r v e r")
DIM, RST, CLR, HIDE, SHOW = "\x1b[2m", "\x1b[0m", "\x1b[2J\x1b[H", "\x1b[?25h", "\x1b[?25l"
SAVER_AFTER = 120.0      # seconds of console silence before the drift starts
POLL = 1.0               # select timeout, so idle is tracked at 1 Hz


def conf(path="/etc/ncz/console.conf"):
    v = {"NCZ_CONSOLE_SAVER": "none", "NCZ_CONSOLE_IDLE_MIN": "5"}
    try:
        with open(path) as fh:
            for line in fh:
                k, sep, val = line.strip().partition("=")
                if sep and k in v:
                    v[k] = val.strip().strip('"').strip("'")
    except OSError:
        pass
    return v


def open_tty():
    for p in ("/dev/tty", "/dev/tty1"):
        try:
            return os.open(p, os.O_RDWR | os.O_NOCTTY)
        except OSError:
            continue
    return None


def main():
    c = conf()
    if c["NCZ_CONSOLE_SAVER"] != "wordmark":
        return 0
    try:
        idle_min = max(1, int(c["NCZ_CONSOLE_IDLE_MIN"]))
    except ValueError:
        idle_min = 5
    blank_at = idle_min * 60.0
    fd = open_tty()
    if fd is None:
        return 0
    attrs = None
    try:
        try:
            attrs = termios.tcgetattr(fd)
            tty.setraw(fd)
        except termios.error:
            attrs = None
        os.write(fd, SHOW.encode())
        last = time.monotonic()
        drawing = False
        x = y = 4
        dx = dy = 1
        while True:
            r, _, _ = select.select([fd], [], [], POLL)
            if r:
                try:
                    os.read(fd, 4096)
                except OSError:
                    pass
                last = time.monotonic()
                if drawing:
                    os.write(fd, (RST + CLR).encode())
                    drawing = False
                continue
            idle = time.monotonic() - last
            if SAVER_AFTER <= idle < blank_at:
                if not drawing:
                    drawing = True
                os.write(fd, CLR.encode())
                for i, line in enumerate(WORD):
                    row = y + i
                    if 1 <= row <= 24:
                        os.write(fd, f"\x1b[{row};{x}H{DIM}{line}{RST}".encode())
                x += dx
                y += dy
                if x < 2 or x > 40:
                    dx = -dx
                if y < 1 or y > 18:
                    dy = -dy
            elif idle >= blank_at and drawing:
                # Stop writing: the kernel's consoleblank now owns the panel.
                os.write(fd, (RST + CLR).encode())
                drawing = False
    finally:
        try:
            os.write(fd, (RST + SHOW + CLR).encode())
        except OSError:
            pass
        if attrs is not None:
            try:
                termios.tcsetattr(fd, termios.TCSADRAIN, attrs)
            except termios.error:
                pass
        os.close(fd)


if __name__ == "__main__":
    sys.exit(main())
SAVER
chmod 0755 /usr/local/sbin/ncz-console-saver

cat > /etc/systemd/system/ncz-console-saver.service <<'UNIT'
[Unit]
Description=NCZ console wordmark saver (idle drift; optional)
Requires=ncz-console-blank.service
After=ncz-console-blank.service
ConditionPathExists=/etc/ncz/console.conf

[Service]
Type=simple
ExecStart=/usr/local/sbin/ncz-console-saver
Restart=always
RestartSec=2
StandardInput=tty
TTYPath=/dev/tty1
TTYReset=no
TTYVHangup=no

[Install]
WantedBy=multi-user.target
UNIT
chmod 0644 /etc/systemd/system/ncz-console-saver.service
systemctl enable ncz-console-saver.service 2>&1 | sed 's/^/    /' || true
echo "[48] console saver tier installed (ncz-console-saver, wordmark only; off by default)"



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
# One banner, no duplication, no codename (operator report + photo, 2026-10-28).
# WHAT WAS WRONG: the desktop-medium branch below carried a hardcoded ASCII
# block reading "N C Z   M A X I M I L I A N   S E R V E R" -- the 26.7 codename,
# frozen into a shell heredoc when the codename moved to Cygnus, and shipped on
# every console-only install from a desktop medium. /etc/issue on the same
# screen already names the release correctly, so the block was both stale and
# redundant, and it is what made a correct machine look like it was running a
# two-release-old build. The identity gate never saw it: the string lived in a
# hook's heredoc, not in a generated identity file.
#
# WHAT IT IS NOW: /etc/issue (50-brand.sh) owns the identity -- product,
# version, codename, SoC, build and IP. This file adds ONLY what /etc/issue
# cannot say: that the box is in headless mode and how to get back. No product
# line, no kernel line, no box art, no codename. The two media differ by a
# single hint line.
{
    echo
    printf '%s\n' 'This system is running in headless server mode.'
    printf '%s\n' 'Console login is available on all terminals; other consoles: Alt+F2 .. Alt+F6.'
    printf '%s\n' 'Remote access: ssh port 22.'
    # A Magnetar Server medium has no desktop to re-enable; a desktop medium
    # installed with the desktop component off does.
    if [ "$_ncz_medium" = desktop ]; then
        printf '%s\n' 'Re-enable the desktop: sudo ncz desktop on'
    fi
    echo
} > /etc/issue.d/10-ncz-server.issue
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
# A Magnetar Server medium carries no desktop layer, so there is nothing to switch back to.
[ "$_ncz_medium" = server ] || echo "     Switch back to desktop with: sudo ncz desktop on"
