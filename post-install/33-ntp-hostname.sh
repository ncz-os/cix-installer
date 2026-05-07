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
    # r75 Codex LOW fix — uniqueness + collision space.
    # Strategy ladder:
    #   1. First wired-ethernet MAC, last 8 hex chars (32-bit space, ~4 B)
    #   2. First wireless MAC if no wired (still 8 hex; wireless rand is per
    #      association so the burned-in MAC under /sys is stable)
    #   3. systemd machine-id sha256 prefix (8 hex) if no networking at all
    # All paths produce a hostname like ncz-<8-hex>. /sys/class/net/*/address
    # is the most-portable Linux source.
    local mac iface ifpath
    # Pass 1: wired
    for ifpath in /sys/class/net/*; do
        [ -e "$ifpath" ] || continue   # nullglob fallback if /sys empty
        iface=${ifpath##*/}
        case "$iface" in lo|virbr*|docker*|veth*|br-*|tun*|tap*) continue ;; esac
        if [ -d "$ifpath/wireless" ] || [ -d "$ifpath/phy80211" ]; then continue; fi
        if [ -r "$ifpath/address" ]; then
            mac=$(tr -d ":" < "$ifpath/address" | tr "[:upper:]" "[:lower:]")
            if [ -n "$mac" ] && [ "$mac" != "000000000000" ]; then
                printf "ncz-%s" "${mac: -8}"
                return 0
            fi
        fi
    done
    # Pass 2: wireless (still better than a constant). Per-association MAC
    # randomization happens at the supplicant layer; the burned-in MAC under
    # /sys/class/net/<wif>/address is the persistent identifier.
    for ifpath in /sys/class/net/*; do
        [ -e "$ifpath" ] || continue
        iface=${ifpath##*/}
        case "$iface" in lo|virbr*|docker*|veth*|br-*|tun*|tap*) continue ;; esac
        if [ -d "$ifpath/wireless" ] || [ -d "$ifpath/phy80211" ]; then
            if [ -r "$ifpath/address" ]; then
                mac=$(tr -d ":" < "$ifpath/address" | tr "[:upper:]" "[:lower:]")
                if [ -n "$mac" ] && [ "$mac" != "000000000000" ]; then
                    printf "ncz-%s" "${mac: -8}"
                    return 0
                fi
            fi
        fi
    done
    # Pass 3: machine-id hash. systemd populates /etc/machine-id at first
    # boot to a 128-bit random; sha256-prefix gives a stable identifier
    # for diskless / DUT-without-NIC edge cases. This is preferable to a
    # collision-prone "ncz-noeth" constant.
    if [ -r /etc/machine-id ]; then
        local mid
        mid=$(cat /etc/machine-id | tr -d "\r\n")
        if [ -n "$mid" ]; then
            local h
            h=$(printf "%s" "$mid" | sha256sum | cut -c1-8)
            printf "ncz-%s" "$h"
            return 0
        fi
    fi
    # Last resort. Should never be hit on a Linux system that has booted
    # systemd at least once (machine-id is generated then). If we DO get
    # here, downstream needs a non-empty hostname; "ncz-unset" makes the
    # state visible to operators.
    echo "ncz-unset"
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
