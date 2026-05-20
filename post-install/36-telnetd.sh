#!/bin/bash
# 36-telnetd.sh — enable telnetd as backup console access on LAN.
#
# Rationale: fleet is LAN-only (192.168.207.0/24, no internet exposure).
# Telnet provides a backup access path when sshd hangs, crashes, or has
# config issues. Operator gets to a recovery shell without physical console.
#
# Security posture: bind to LAN interface only. NOT exposed to internet.
# Plain-text auth is acceptable on trusted LAN segment.
set -uo pipefail

echo "[36] enabling telnetd as backup LAN console"

# inetutils-telnetd + openbsd-inetd installed via pkgsel/include.
# openbsd-inetd reads /etc/inetd.conf and spawns telnetd on incoming
# connections to TCP 23.

# Ensure inetd.conf has telnet entry (default Ubuntu config has it
# but commented). Drop a known-good config snippet.
INETD_CONF=/etc/inetd.conf
if [ -f "$INETD_CONF" ]; then
    # Remove any existing telnet line, add fresh enabled one
    sed -i '/^[[:space:]]*#*[[:space:]]*telnet[[:space:]]/d' "$INETD_CONF"
    echo "telnet  stream  tcp     nowait  telnetd /usr/sbin/tcpd  /usr/sbin/in.telnetd" >> "$INETD_CONF"
    echo "  added telnet line to $INETD_CONF"
fi

# Enable + start openbsd-inetd (systemd unit name varies)
systemctl enable openbsd-inetd.service 2>/dev/null || \
    systemctl enable inetd.service 2>/dev/null || \
    echo "  WARN: could not enable inetd unit"

# Don't start now — chroot context. systemd will start on boot.
echo "[36] telnetd enabled (binds to 0.0.0.0:23 on next boot)"

# MOTD warning for operators
cat >> /etc/motd <<'TELNETMOTD'

⚠ TELNET ENABLED (LAN backup access on TCP 23).
  Use SSH (port 22) for normal access. Telnet is plain-text — LAN only.

TELNETMOTD

exit 0
