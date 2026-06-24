#!/bin/bash
# 33-network.sh — wire NetworkManager as the active netplan renderer.
#
# 2026-05-08 take23 (per .66 take22 install): resolute defaults to
# systemd-networkd OR nothing if neither netplan config is present.
# The XFCE dep chain on resolute does not pull network-manager the way
# questing's did, so the previous build relied on an implicit pull
# that no longer happens.
#
# This hook (a) confirms network-manager is installed (preseed
# pkgsel/include adds it; verify here in case operator/dpkg state
# diverged), (b) writes a netplan YAML that uses NetworkManager
# renderer + matches every en* / wl* interface for DHCP, (c)
# disables systemd-networkd if it was somehow active so it doesn't
# fight NM, (d) enables NM at boot.
#
# Idempotent: re-runnable; sed-guards prevent duplicate writes.

set -euo pipefail

echo "[33-network] verifying NetworkManager + writing netplan"

# (a) Hard-fail if NM is not installed. preseed pkgsel/include puts it
# there; if it is missing, the netinstall apt fetch failed silently and
# the operator-visible symptom (no network) is exactly what we are
# trying to prevent.
if ! command -v nmcli >/dev/null 2>&1 || ! dpkg-query -W -f='${Status}\n' network-manager 2>/dev/null | grep -q "install ok installed"; then
    echo "[33-network] ERROR: network-manager not installed; aborting" >&2
    echo "[33-network] preseed/preseed-ubuntu.cfg pkgsel/include must list network-manager" >&2
    exit 1
fi

# (b) netplan with NetworkManager as renderer + match every wired/wireless
# interface for DHCP. Wildcards survive interface-rename churn between
# kernel boots (enp1s0 vs enp2s0 etc.).
NETPLAN_DIR=/etc/netplan
install -d -m 0755 "$NETPLAN_DIR"

NETPLAN_FILE="$NETPLAN_DIR/01-ncz-networkmanager.yaml"
cat > "$NETPLAN_FILE" <<'YAML'
# Written by ncz-installer post-install/33-network.sh
# All wired + wireless interfaces are managed by NetworkManager.
# DHCP is the default; operator can override via nm-applet or nmcli.
network:
  version: 2
  renderer: NetworkManager
  ethernets:
    # r130.5 (Codex review): explicit wired DHCP profiles. Two reasons:
    #   1. guarantees NM has an auto-connect profile for the wired NIC on
    #      first boot (don't rely solely on NM's implicit auto-default).
    #   2. optional:true keeps NetworkManager-wait-online.service (which
    #      33-network unmasks+enables below) from BLOCKING network-online
    #      at boot when the wired link has no carrier/lease — that stall,
    #      behind the boot splash, looked like a hang on the .66 install.
    # Wildcard match survives enp1s0<->enp49s0 rename churn across boots.
    ncz-wired-en:
      match:
        name: "en*"
      dhcp4: true
      dhcp6: true
      optional: true
    ncz-wired-eth:
      match:
        name: "eth*"
      dhcp4: true
      dhcp6: true
      optional: true
YAML
chmod 0600 "$NETPLAN_FILE"

# Remove cloud-init's generated 50-cloud-init.yaml and any other
# competing netplan configs that would re-render to systemd-networkd.
for stale in 50-cloud-init.yaml 99_cloud-init.yaml 00-installer-config.yaml; do
    if [ -f "$NETPLAN_DIR/$stale" ]; then
        echo "[33-network] removing stale $stale (would compete with NM renderer)"
        rm -f "$NETPLAN_DIR/$stale"
    fi
done

# (b2) r130.5 (CRITICAL — .27/.66 install: wired NIC never got DHCP):
# d-i's netcfg writes /etc/network/interfaces with the INSTALL-TIME wired NIC
# as `allow-hotplug <if>` + `iface <if> inet dhcp`, and the stock
# /etc/NetworkManager/NetworkManager.conf ships `[ifupdown] managed=false`.
# Together that makes NM HAND OFF any interface named in
# /etc/network/interfaces to ifupdown (nmcli shows STATE=unmanaged, reason 76
# "unmanaged by user decision via settings plugin"). On the XFCE/NM desktop
# ifupdown is not actively raising the link, so the wired port never gets DHCP
# while wifi (absent from the file) works — exactly the "DHCP broke, wired
# unmanaged" symptom. Fix BOTH halves so NM owns every real NIC:
#   1. flip [ifupdown] managed=false -> true (NM manages even listed devices)
#   2. reset /etc/network/interfaces to loopback-only (drop the d-i dhcp stanza)
NM_CONF=/etc/NetworkManager/NetworkManager.conf
install -d -m 0755 "$(dirname "$NM_CONF")"
if [ -f "$NM_CONF" ] && grep -qE '^[[:space:]]*managed=false' "$NM_CONF"; then
    sed -i -E 's/^[[:space:]]*managed=false/managed=true/' "$NM_CONF"
    echo "[33-network] flipped [ifupdown] managed=false -> true in $NM_CONF"
elif [ -f "$NM_CONF" ] && grep -qE '^\[ifupdown\]' "$NM_CONF" && ! grep -qE '^[[:space:]]*managed=' "$NM_CONF"; then
    sed -i '/^\[ifupdown\]/a managed=true' "$NM_CONF"
    echo "[33-network] added managed=true under existing [ifupdown] in $NM_CONF"
elif [ ! -f "$NM_CONF" ] || ! grep -qE '^\[ifupdown\]' "$NM_CONF"; then
    printf '\n[ifupdown]\nmanaged=true\n' >> "$NM_CONF"
    echo "[33-network] appended [ifupdown] managed=true to $NM_CONF"
fi

ENI=/etc/network/interfaces
if [ -f "$ENI" ] && grep -qE '^[[:space:]]*(allow-hotplug|auto)[[:space:]]+(en|eth|wl)' "$ENI"; then
    echo "[33-network] resetting $ENI to loopback-only (d-i had pinned the install NIC to inet dhcp)"
fi
cat > "$ENI" <<'ENICONF'
# Reset by ncz-installer post-install/33-network.sh.
# All real NICs are owned by NetworkManager (see
# /etc/netplan/01-ncz-networkmanager.yaml). d-i's netcfg had written the
# install-time wired NIC here as `iface <if> inet dhcp`, which NM hands off to
# ifupdown ([ifupdown] managed=false) -> the wired port never got DHCP. Keeping
# this loopback-only leaves NM in sole control of all wired + wireless links.
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback
ENICONF

# (c) Disable systemd-networkd so it does not race NM for the link.
# `mask` is stronger than `disable` because it survives package
# upgrades that re-enable units.
systemctl disable --now systemd-networkd.socket 2>/dev/null || true
systemctl disable --now systemd-networkd 2>/dev/null || true
systemctl mask systemd-networkd 2>/dev/null || true

# (d) NetworkManager enabled at boot.
systemctl enable NetworkManager 2>&1 | tail -3 || true

# (d2) Restore real network-online semantics. The base rootfs ships
# NetworkManager-wait-online.service masked (a boot-speed default),
# which silently neutralises every "After=network-online.target"
# ordering: timer/oneshot units (e.g. nclawzero-load-agent-images)
# then fire before DHCP/link is up and fail at boot. Unmask + enable
# so network-online.target actually waits for NM. This is bounded by
# NM_ONLINE_TIMEOUT (~30s) and never blocks login/ssh, which are gated
# on network.target (link present), not network-online.target.
systemctl unmask NetworkManager-wait-online.service 2>/dev/null || true
systemctl enable NetworkManager-wait-online.service 2>&1 | tail -2 || true
# Don't try to start NM in the chroot — the host has no live network
# stack to manage. First boot will pick it up via the enable.

# Apply netplan to regenerate /run/NetworkManager/conf.d/*. This does
# NOT bring up interfaces in the chroot (no live stack); it just
# updates the rendered config that NM will read on first boot.
netplan generate 2>&1 | tail -3 || \
    echo "[33-network] WARN: netplan generate failed (likely chroot — first-boot will retry)"

echo "[33-network] netplan written; NM enabled; systemd-networkd masked"
