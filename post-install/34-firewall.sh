#!/bin/bash
# 34-firewall.sh — install a ready-to-enable nftables firewall.
#
# NCZ-OS targets power users who commonly have perimeter protection or their
# own host-network policy, so the firewall is deliberately DISABLED by default.
# The ruleset is nevertheless a complete workstation baseline: permit loopback,
# established traffic, essential ICMP/ICMPv6 and DHCP replies; deny unsolicited
# input and all forwarding; permit output.  No mDNS exception is included because
# Avahi/libnss-mdns is not part of the NCZ-OS package manifests.
#
# Runs after apt sources (23/24) and network setup (33).  It is idempotent.
set -euo pipefail

echo "[34] firewall: installing nftables with a disabled-by-default workstation policy"

if ! dpkg-query -W -f='${Status}\n' nftables 2>/dev/null | grep -q '^install ok installed$'; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nftables
fi

cat > /etc/nftables.conf <<'RULESET'
#!/usr/sbin/nft -f

# NCZ-OS default host firewall. Installed and ready, but disabled by default.
# Enable with: sudo systemctl enable --now nftables
flush ruleset

table inet filter {
    chain input {
        type filter hook input priority filter; policy drop;

        ct state invalid drop
        ct state established,related accept
        iifname "lo" accept

        # ICMP is required for diagnostics, IPv4 path-MTU discovery, and
        # essential IPv6 functions including neighbour discovery and SLAAC.
        ip protocol icmp accept
        meta l4proto icmpv6 accept

        # Permit replies while acquiring an address before conntrack has a
        # complete flow. These are server-to-client DHCP ports only.
        udp sport 67 udp dport 68 accept
        udp sport 547 udp dport 546 accept
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
RULESET
chmod 0644 /etc/nftables.conf

# Validate before leaving a policy behind. `nft --check` parses and validates
# without committing the ruleset to the running installer's network namespace.
nft --check --file /etc/nftables.conf

# Debian may enable units from package postinst/preset policy. Force the final
# image off, including any service that happened to start in a live build root.
systemctl stop nftables.service 2>/dev/null || true
systemctl disable nftables.service 2>/dev/null || true

# Terminal signpost: this is evaluated at login, so it disappears after the
# operator enables the service rather than becoming stale documentation.
install -d -m 0755 /etc/update-motd.d
cat > /etc/update-motd.d/40-ncz-firewall <<'MOTD'
#!/bin/sh
if ! systemctl is-active --quiet nftables.service 2>/dev/null; then
    printf '\n  FIREWALL: nftables is installed but OFF (NCZ-OS default).\n'
    printf '  Enable protection: sudo systemctl enable --now nftables\n\n'
fi
MOTD
chmod 0755 /etc/update-motd.d/40-ncz-firewall

# Desktop signpost follows the existing NCZ XDG notification pattern. It is
# intentionally shown on each login while protection remains off. The
# Singularity shell starts a system autostart entry only when OnlyShowIn names
# Singularity (build/test-xdg-autostart.sh).
install -d -m 0755 /usr/local/bin /etc/xdg/autostart
cat > /usr/local/bin/ncz-firewall-notify <<'NOTIFY'
#!/bin/sh
command -v notify-send >/dev/null 2>&1 || exit 0
systemctl is-active --quiet nftables.service 2>/dev/null && exit 0
sleep 10
notify-send -a "NCZ Security" -u normal -t 30000 -i security-low \
    "Firewall installed but off" \
    "NCZ-OS leaves nftables disabled by default. Enable protection with:\nsudo systemctl enable --now nftables"
NOTIFY
chmod 0755 /usr/local/bin/ncz-firewall-notify

cat > /etc/xdg/autostart/ncz-firewall-notice.desktop <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=NCZ Firewall Notice
Comment=Show firewall status and activation command
Exec=/usr/local/bin/ncz-firewall-notify
Icon=security-low
Terminal=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
OnlyShowIn=Singularity;
DESKTOP
chmod 0644 /etc/xdg/autostart/ncz-firewall-notice.desktop

echo "[34] DONE — nftables rules validated; service stopped and disabled"
echo "[34] enable later with: systemctl enable --now nftables"
