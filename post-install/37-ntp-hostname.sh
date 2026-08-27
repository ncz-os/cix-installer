#!/bin/bash
# 33-ntp-hostname.sh - hostname + /etc/hosts + systemd-timesyncd.
#
# Discovered 2026-05-03 during r8 bringup:
# 1. preseed didn't set the hostname -> installed system was "debian"
#    instead of "cixmini". Sudo throws warnings on every invocation:
#       sudo: unable to resolve host cixmini: Name or service not known
# 2. MS-R1 has no working RTC battery (RTC time = n/a). Without NTP,
#    system clock starts at whatever Linux's default is (typically the
#    build-time epoch of e2fsprogs / 1970), which broke timestamps in
#    journal + made cert validation fail.
#
# This hook sets the hostname and enables systemd-timesyncd. chrony was avoided
# because the offline mirror did not carry it, and timesyncd is sufficient for
# first-boot step correction on Sky1 systems without a reliable RTC.
set -uo pipefail
# r63 (codex review): don't use `systemctl enable --now` here - chroot-time
# starts are expected to fail when systemd is not PID 1. Plain enable should
# still work in the target root; if it does not, first boot will have no time
# sync, so fail the hook loudly.

# r75 P2: hostname fallback strategy. r74 used a fleet-wide 'mini'
# default which is bad debug UX (every NCZ box on a LAN is named the
# same). r75 generates ncz-<MAC8hex> from the first ethernet MAC for
# machines that arrived here with a blank/default hostname. Operators
# who set their own hostname during preseed always win.
#
# Why MAC-based: deterministic across reboots (MAC is hardware-bound),
# unique across NCZ boxes on the same LAN, easy to type from a sticker
# on the chassis.
#
# Origin: Jeff Hunter's r74 wireless-only install bug - 'Invalid
# hostname ""' from netcfg blank, then downstream scripts crashed.
ncz_default_hostname() {
    # r75 Codex LOW fix - uniqueness + collision space.
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

EXISTING=$(tr -d ' \t\r\n' < /etc/hostname 2>/dev/null || true)
case "$EXISTING" in
    ""|debian|ubuntu|localhost|raspbian|"(none)"|mini)
        TARGET_HOSTNAME=$(ncz_default_hostname)
        echo "[33] hostname '$EXISTING' is default/blank - generated $TARGET_HOSTNAME (MAC-derived)"
        ;;
    *)
        TARGET_HOSTNAME="$EXISTING"
        echo "[33] preserving operator hostname: $TARGET_HOSTNAME"
        ;;
esac

echo "[33] hostname + /etc/hosts + systemd-timesyncd"

# ----- hostname --------------------------------------------------------
echo "$TARGET_HOSTNAME" > /etc/hostname

# /etc/hosts: keep 127.0.0.1 localhost, ensure 127.0.1.1 -> $TARGET_HOSTNAME.
if grep -q "^127\.0\.1\.1" /etc/hosts; then
    sed -i "s|^127\.0\.1\.1.*|127.0.1.1\t${TARGET_HOSTNAME}|" /etc/hosts
else
    echo -e "127.0.1.1\t${TARGET_HOSTNAME}" >> /etc/hosts
fi

# ----- systemd-timesyncd for NTP ---------------------------------------
# 2026-05-04 (r41): use systemd-timesyncd from the pre-baked rootfs instead of
# apt-installing chrony - offline mirror does not have chrony, and the cloudimg
# rootfs already ships systemd-timesyncd. systemd-timesyncd handles step+drift
# correctly for Sky1 (verified against MS-R1's no-RTC quirk).
install -d -m 0755 /etc/systemd/timesyncd.conf.d
cat > /etc/systemd/timesyncd.conf.d/10-nclawzero.conf <<'EOF'
[Time]
NTP=time.cloudflare.com time.google.com
FallbackNTP=0.pool.ntp.org 1.pool.ntp.org 2.pool.ntp.org 3.pool.ntp.org
EOF

# 2026-08-02 (Debian forky): systemd-timesyncd is NOT part of systemd on Debian
# — it is split into its own package (Ubuntu bundles it, which is why this hook
# worked for two years and then silently stopped). Confirmed on O6N: this line
# failed with "Failed to enable unit: systemd-timesyncd.service does not exist",
# so the board had NO time source at all: no /dev/rtc, timesyncd/chronyd/ntpsec
# all inactive, and the clock re-seeding from the image build epoch on every
# boot (which breaks TLS certificate validation and every log timestamp).
# systemd-timesyncd is now seeded in manifests/{desktop,server}.pkgs; install it
# here if the unit is still missing, and fall back to chrony before giving up.
#
# Order matters: check for an ALREADY-PRESENT daemon before installing anything.
# The server profile seeds chrony, and chrony and systemd-timesyncd both
# Provide/Conflict `time-daemon` — blindly apt-installing timesyncd there is
# unresolvable, which is exactly how the first rc6 server layer build failed
# ("systemd-timesyncd Conflicts time-daemon [selected chrony]").
NCZ_TIME_UNIT=""
for u in systemd-timesyncd chrony chronyd ntpsec; do
    if systemctl cat "$u.service" >/dev/null 2>&1; then
        NCZ_TIME_UNIT="$u"
        break
    fi
done
if [ -n "$NCZ_TIME_UNIT" ]; then
    echo "[33] time daemon already present: $NCZ_TIME_UNIT"
else
    echo "[33] systemd-timesyncd.service absent (Debian splits it out of systemd) — installing"
    if DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends systemd-timesyncd >/dev/null 2>&1 \
       && systemctl cat systemd-timesyncd.service >/dev/null 2>&1; then
        NCZ_TIME_UNIT=systemd-timesyncd
    elif DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends chrony >/dev/null 2>&1 \
       && systemctl cat chrony.service >/dev/null 2>&1; then
        NCZ_TIME_UNIT=chrony
        echo "[33] systemd-timesyncd unavailable — using chrony instead"
    fi
fi

if [ -n "$NCZ_TIME_UNIT" ]; then
    systemctl enable "$NCZ_TIME_UNIT"
    # r63: NEVER use --now in chroot context (codex finding); first boot starts it
else
    echo "[33] ERROR: no NTP implementation available (systemd-timesyncd and chrony both" \
         "uninstallable). Sky1 boards have no usable RTC, so this system will boot with a" \
         "stale clock and TLS validation will fail. Seed systemd-timesyncd in the layer manifest." >&2
fi

# ----- timezone --------------------------------------------------------
# The CIX vendor rootfs ships TZ=Asia/Shanghai. Nothing in our pipeline ever
# reset it, so every installed board silently ran on Shanghai local time
# (confirmed on O6N 2026-08-02). Honour an operator/preseed choice if one was
# made; otherwise correct the vendor default to UTC, which is the only sane
# default for a fleet that spans timezones and logs to a shared bus.
NCZ_TZ_DEFAULT="${NCZ_TIMEZONE:-UTC}"
CURRENT_TZ=$(readlink -f /etc/localtime 2>/dev/null | sed 's|^.*/zoneinfo/||')
case "$CURRENT_TZ" in
    ""|Asia/Shanghai|Etc/UTC|UTC)
        if [ -f "/usr/share/zoneinfo/$NCZ_TZ_DEFAULT" ]; then
            ln -sf "/usr/share/zoneinfo/$NCZ_TZ_DEFAULT" /etc/localtime
            echo "$NCZ_TZ_DEFAULT" > /etc/timezone
            echo "[33] timezone: '${CURRENT_TZ:-unset}' (CIX vendor default) -> $NCZ_TZ_DEFAULT"
        else
            echo "[33] WARN: /usr/share/zoneinfo/$NCZ_TZ_DEFAULT missing (tzdata not installed?) — timezone left as '${CURRENT_TZ:-unset}'"
        fi
        ;;
    *)
        echo "[33] preserving operator timezone: $CURRENT_TZ"
        ;;
esac

# ----- summary ---------------------------------------------------------
echo ""
echo "Final state:"
echo "  hostname:  $(cat /etc/hostname)"
echo "  /etc/hosts:"
grep -E "^127\." /etc/hosts | sed 's/^/    /' || true
echo "  timezone:  $(readlink -f /etc/localtime 2>/dev/null | sed 's|^.*/zoneinfo/||')"
if [ -n "$NCZ_TIME_UNIT" ]; then
    echo "  time sync: $NCZ_TIME_UNIT — $(systemctl is-enabled "$NCZ_TIME_UNIT" 2>&1 || true) / $(systemctl is-active "$NCZ_TIME_UNIT" 2>&1 || true)"
else
    echo "  time sync: NONE (see error above)"
fi
