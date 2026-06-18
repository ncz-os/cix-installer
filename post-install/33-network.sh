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
