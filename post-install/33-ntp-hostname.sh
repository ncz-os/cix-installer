#!/bin/bash
# 33-ntp-hostname.sh — hostname + /etc/hosts + NTP/chrony.
#
# Discovered 2026-05-03 during r8 bringup:
# 1. preseed didn't set the hostname → installed system was "debian"
#    instead of "cixmini". Sudo throws warnings on every invocation:
#       sudo: unable to resolve host cixmini: Name or service not known
# 2. MS-R1 has no working RTC battery (RTC time = n/a). Without NTP,
#    system clock starts at whatever Linux's default is (typically the
#    build-time epoch of e2fsprogs / 1970), which broke timestamps in
#    journal + made cert validation fail.
#
# This hook sets hostname=cixmini AND installs chrony (better than
# systemd-timesyncd for our case — chrony handles large step + drift
# correction more robustly when RTC is unreliable).
set -euo pipefail

TARGET_HOSTNAME=cixmini

echo "[33] hostname + /etc/hosts + chrony"

# ----- hostname --------------------------------------------------------
# Both /etc/hostname and /etc/hosts get the canonical name.
echo "$TARGET_HOSTNAME" > /etc/hostname

# /etc/hosts: keep 127.0.0.1 localhost, ensure 127.0.1.1 → $TARGET_HOSTNAME.
# If the file has a stale `127.0.1.1 debian` line, replace it.
if grep -q "^127\.0\.1\.1" /etc/hosts; then
    sed -i "s|^127\.0\.1\.1.*|127.0.1.1\t${TARGET_HOSTNAME}|" /etc/hosts
else
    echo -e "127.0.1.1\t${TARGET_HOSTNAME}" >> /etc/hosts
fi

# ----- chrony for NTP --------------------------------------------------
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends chrony

# Default Debian config polls Debian NTP pool — fine for our use.
systemctl enable --now chrony

# ----- summary ---------------------------------------------------------
echo ""
echo "Final state:"
echo "  hostname:  $(cat /etc/hostname)"
echo "  /etc/hosts:"
grep -E "^127\." /etc/hosts | sed 's/^/    /'
echo "  chrony:    $(systemctl is-enabled chrony) / $(systemctl is-active chrony)"
