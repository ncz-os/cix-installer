#!/bin/bash
# 19-sinty-nm.sh - install the native NCZ network owner for every variant.
#
# sinty-nm is foundational NCZ networking, not a desktop feature. It owns the
# org.freedesktop.NetworkManager D-Bus name directly and provides wired DHCP,
# WiFi through iwd, and WireGuard VPN support. Desktop/Singularity builds on top
# of this base service; console-only installs use the same daemon.
#
# If the gitignored sinty-nmd build blob is absent, leave NetworkManager/netplan
# intact so 33-network.sh can configure the fallback path.

set -euo pipefail

echo "[19-sinty-nm] native network owner: sinty-nm"

ncz_ports_fallback() {
    echo "[19-sinty-nm] WARN: package missing from current apt source - retrying after apt-get update"
    apt-get update -o Acquire::http::Timeout=8 -o Acquire::https::Timeout=8 \
        -o Acquire::Retries=0 -o Acquire::ForceIPv4=true -q || true
}

# Backends: iwd (WiFi) + wireguard-tools (VPN). Ethernet and DHCP are handled by
# sinty-nmd itself, but these packages are part of the daemon's complete fleet
# contract and belong in the base package set.
if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends iwd wireguard-tools; then
    ncz_ports_fallback
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends iwd wireguard-tools || \
        echo "[19-sinty-nm] WARN: iwd/wireguard-tools install failed (WiFi/VPN backends)"
fi

SINTY_NMD=""
for c in /usr/local/lib/cix-installer/assets/sinty-nm/sinty-nmd \
         /cdrom/assets/sinty-nm/sinty-nmd \
         /run/cixmini/assets/sinty-nm/sinty-nmd; do
    [ -f "$c" ] && { SINTY_NMD="$c"; break; }
done

if [ -z "$SINTY_NMD" ]; then
    echo "[19-sinty-nm] WARN: assets/sinty-nm/sinty-nmd not staged - falling back to NetworkManager" >&2
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends network-manager netplan.io 2>&1 | tail -2 || true
    systemctl enable NetworkManager 2>/dev/null || true
    exit 0
fi

_AD="$(dirname "$SINTY_NMD")"
install -m0755 "$SINTY_NMD" /usr/bin/sinty-nmd
install -D -m0644 "$_AD/sinty-nm.service" /usr/lib/systemd/system/sinty-nm.service

# Purge NetworkManager + GUI helpers if present. Two daemons cannot own
# org.freedesktop.NetworkManager. Never use --auto-remove here.
_nm_present=""
for p in network-manager network-manager-gnome network-manager-applet nm-connection-editor; do
    dpkg -l "$p" 2>/dev/null | grep -q '^ii' && _nm_present="$_nm_present $p"
done
if [ -n "$_nm_present" ]; then
    echo "[19-sinty-nm] purging NetworkManager (sinty-nm owns the name now):$_nm_present"
    _nm_purge_log="$(mktemp /tmp/ncz-nm-purge.XXXXXX)"
    if ! DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Use-Pty=0 \
            purge -y $_nm_present \
            >"$_nm_purge_log" 2>&1; then
        tail -20 "$_nm_purge_log"
        rm -f "$_nm_purge_log"
        echo "[19-sinty-nm] FATAL: NetworkManager purge failed"
        exit 1
    fi
    tail -3 "$_nm_purge_log"
    rm -f "$_nm_purge_log"
fi

# Install the replacement policy only after purging NetworkManager, because the
# NetworkManager package owns this exact policy path and purge would remove it.
install -D -m0644 "$_AD/org.freedesktop.NetworkManager.conf" \
    /usr/share/dbus-1/system.d/org.freedesktop.NetworkManager.conf

systemctl disable NetworkManager.service NetworkManager-wait-online.service \
    NetworkManager-dispatcher.service 2>/dev/null || true
systemctl mask NetworkManager.service NetworkManager-wait-online.service 2>/dev/null || true

# sinty-nm owns wired L2/L3 and DHCP itself. Do not leave networkd enabled with
# no .network files; it races sinty and can stall network-online users.
systemctl disable systemd-networkd.service systemd-networkd.socket \
    systemd-networkd-wait-online.service \
    systemd-networkd-resolve-hook.socket \
    systemd-networkd-varlink.socket 2>/dev/null || true
systemctl mask systemd-networkd.service systemd-networkd.socket \
    systemd-networkd-wait-online.service \
    systemd-networkd-resolve-hook.socket \
    systemd-networkd-varlink.socket 2>/dev/null || true

# sinty-nm writes /etc/resolv.conf directly.
if [ -L /etc/resolv.conf ] || [ ! -e /etc/resolv.conf ]; then
    rm -f /etc/resolv.conf
    : > /etc/resolv.conf
    chmod 0644 /etc/resolv.conf
fi

# iwd is useful only when a wireless PHY exists. Without this, wired-only boards
# and KVM leave a misleading failed iwd.service despite working wired networking.
install -d -m0755 /etc/systemd/system/iwd.service.d
cat > /etc/systemd/system/iwd.service.d/10-ncz-wireless-hardware.conf <<'IWDUNIT'
[Unit]
ConditionDirectoryNotEmpty=/sys/class/ieee80211
IWDUNIT

systemctl enable iwd.service 2>/dev/null || true
systemctl enable sinty-nm.service 2>/dev/null || true
echo "[19-sinty-nm] sinty-nm installed + enabled (iwd WiFi backend, WireGuard VPN); NetworkManager purged/masked"
