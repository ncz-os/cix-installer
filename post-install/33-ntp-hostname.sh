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
set +e
# r63 (codex review): don't `set -e + pipefail` here — chroot-time
# `systemctl enable --now` calls are expected to fail when systemd is
# not PID 1, and `ls | head` summary pipes can SIGPIPE-fail under pipefail.

# r63: only override hostname if it's blank or default (debian/ubuntu).
# Operator may have set their own hostname during preseed — preserve it.
DEFAULT_HOSTNAME=mini
EXISTING=$(cat /etc/hostname 2>/dev/null | tr -d ' \t\r\n')
case "$EXISTING" in
    ""|debian|ubuntu|localhost|raspbian|"(none)")
        TARGET_HOSTNAME="$DEFAULT_HOSTNAME"
        echo "[33] hostname '$EXISTING' is default — overriding to $TARGET_HOSTNAME"
        ;;
    *)
        TARGET_HOSTNAME="$EXISTING"
        echo "[33] preserving operator hostname: $TARGET_HOSTNAME"
        ;;
esac

echo "[33] hostname + /etc/hosts + chrony"

# ----- hostname --------------------------------------------------------
echo "$TARGET_HOSTNAME" > /etc/hostname

# /etc/hosts: keep 127.0.0.1 localhost, ensure 127.0.1.1 → $TARGET_HOSTNAME.
if grep -q "^127\.0\.1\.1" /etc/hosts; then
    sed -i "s|^127\.0\.1\.1.*|127.0.1.1\t${TARGET_HOSTNAME}|" /etc/hosts
else
    echo -e "127.0.1.1\t${TARGET_HOSTNAME}" >> /etc/hosts
fi

# ----- chrony for NTP --------------------------------------------------
# 2026-05-04 (r41): use systemd-timesyncd from the pre-baked rootfs instead of
# apt-installing chrony — offline mirror does not have chrony, and the cloudimg
# rootfs already ships systemd-timesyncd. systemd-timesyncd handles step+drift
# correctly for Sky1 (verified against MS-R1's no-RTC quirk).
systemctl enable systemd-timesyncd 2>/dev/null || true
# r63: NEVER use --now in chroot context (codex finding); first boot starts it

# ----- summary ---------------------------------------------------------
echo ""
echo "Final state:"
echo "  hostname:  $(cat /etc/hostname)"
echo "  /etc/hosts:"
grep -E "^127\." /etc/hosts | sed 's/^/    /'
echo "  systemd-timesyncd: $(systemctl is-enabled systemd-timesyncd) / $(systemctl is-active systemd-timesyncd)"
