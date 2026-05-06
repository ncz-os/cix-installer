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

# r75 P2: hostname fallback strategy. r74 used a fleet-wide 'mini'
# default which is bad debug UX (every NCZ box on a LAN is named the
# same). r75 generates ncz-<MAC4hex> from the first ethernet MAC for
# machines that arrived here with a blank/default hostname. Operators
# who set their own hostname during preseed always win.
#
# Why MAC-based: deterministic across reboots (MAC is hardware-bound),
# unique across NCZ boxes on the same LAN, easy to type from a sticker
# on the chassis.
#
# Origin: Jeff Hunter's r74 wireless-only install bug — 'Invalid
# hostname ""' from netcfg blank, then downstream scripts crashed.
ncz_default_hostname() {
    # First non-loopback ethernet MAC, last 4 hex chars, lowercase.
    # /sys/class/net/*/address is the most-portable source on Linux.
    local mac iface
    for iface in $(ls /sys/class/net 2>/dev/null); do
        case "$iface" in
            lo|virbr*|docker*|veth*|br-*|tun*|tap*) continue ;;
        esac
        # Skip wireless interfaces — we want the persistent identity, and
        # wireless MACs can be randomized per-association on some configs.
        if [ -d "/sys/class/net/$iface/wireless" ] || [ -d "/sys/class/net/$iface/phy80211" ]; then
            continue
        fi
        if [ -r "/sys/class/net/$iface/address" ]; then
            mac=$(cat "/sys/class/net/$iface/address" | tr -d ":" | tr "[:upper:]" "[:lower:]")
            if [ -n "$mac" ] && [ "$mac" != "000000000000" ]; then
                printf "ncz-%s" "${mac: -4}"
                return 0
            fi
        fi
    done
    # No non-virtual ethernet — fall back to a static identifier to keep
    # downstream scripts that depend on a non-empty hostname working.
    echo "ncz-noeth"
}

EXISTING=$(cat /etc/hostname 2>/dev/null | tr -d ' \t\r\n')
case "$EXISTING" in
    ""|debian|ubuntu|localhost|raspbian|"(none)"|mini)
        TARGET_HOSTNAME=$(ncz_default_hostname)
        echo "[33] hostname '$EXISTING' is default/blank — generated $TARGET_HOSTNAME (MAC-derived)"
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
