#!/bin/bash
# NCZ-MIXED-HOOK: netplan/NetworkManager wiring is generic; also installs udev/NM rules unmanaging the Apple T2 iBridge NIC; TODO move T2 rules to an amd64 t2 hook (docs/platform-inventory.tsv; runs on every platform, listed in both hooks.list files)
# 33-network.sh — wire NetworkManager as the active netplan renderer.
#
# 2026-05-08 take23 (per MS-R1 test-board take22 install): resolute defaults to
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

# Exclude the Apple T2 "iBridge" virtual USB ethernet-gadget interface from
# network management. It enumerates as a normal cdc_ncm ethernet device
# (idVendor=05ac idProduct=8233 -- fixed across every T2 Mac model, not
# board-specific) but is the T2 coprocessor's internal USB bridge, never a
# real LAN uplink; it never has anything on the other end and will never get
# a DHCP lease.
#
# Root cause, measured live on T2 Mac B (T2 MacBook, 2026-09-20): the netplan
# wildcard `en*` match legitimately applies to BOTH this virtual interface
# and the real dock/Thunderbolt ethernet NIC. NetworkManager's policy engine
# auto-activated the phantom iBridge interface first, which timed out its
# DHCP attempt every ~45s and immediately retried -- a genuine infinite
# retry loop (confirmed via `journalctl -u NetworkManager`: repeating
# "activation: beginning transaction (timeout in 45 seconds)" /
# "ip-config-unavailable" cycles) -- while the REAL ethernet interface sat
# with carrier detected but no activation attempt logged for 4m43s, until
# the operator forced one manually. The phantom interface was starving the
# real one's automatic DHCP. This udev rule stops NM from ever touching the
# phantom interface, so the wildcard match's activation attempts go to real
# NICs only -- fixes it for ANY hotplugged USB/Thunderbolt ethernet
# interface on ANY T2 Mac, not just this one board.
install -d -m 0755 /etc/udev/rules.d
# NOTE ordering: netplan generates /run/udev/rules.d/90-netplan.rules, which
# (for our `en*` wildcard match) EXPLICITLY sets ENV{NM_UNMANAGED}="0" to
# force-manage anything matching the glob -- confirmed live on T2 Mac B via
# `udevadm test`, this clobbered an earlier attempt at this fix numbered
# 71-*. Our rule must sort AFTER 90-netplan.rules (udev applies rule files
# in filename order, later assignments win) to actually take effect -- 93-
# does that while staying before 95-99 range reserved by other ncz rules.
cat > /etc/udev/rules.d/93-ncz-unmanage-t2-ibridge.rules <<'UDEVRULES'
# NCZ-OS: the Apple T2 "iBridge" coprocessor exposes a virtual USB ethernet
# (cdc_ncm, idVendor=05ac idProduct=8233) that is never a real network link.
# Tag it unmanaged so NetworkManager never attempts DHCP on it -- otherwise
# its endless 45s-timeout retry loop starves autoconnect on the real wired
# NIC that shares the same wildcard `en*` connection match. Must sort after
# netplan's generated 90-netplan.rules -- see 33-network.sh comment.
ACTION=="add|change", SUBSYSTEM=="net", ATTRS{idVendor}=="05ac", ATTRS{idProduct}=="8233", ENV{NM_UNMANAGED}="1"
UDEVRULES
chmod 0644 /etc/udev/rules.d/93-ncz-unmanage-t2-ibridge.rules
echo "[33-network] installed udev rule to unmanage the Apple T2 iBridge virtual ethernet"

# BELT AND BRACES (2026-09-29). The udev rule above is NECESSARY BUT NOT
# SUFFICIENT. It has to out-sort 90-netplan.rules, which sets
# ENV{ID_NET_NAME}=="en*" NM_UNMANAGED="0" -- and that file is GENERATED INTO
# /run/udev/rules.d DURING BOOT. At the moment the T2 NIC is first enumerated
# the netplan rule may not exist yet, so the ordering a later `udevadm test`
# reproduces is not the ordering that actually ran.
#
# MEASURED on T2 Mac A 2026-09-29 (installed from 2026.09.29-0d04e75):
#     udevadm test /sys/class/net/enxacde48001122   -> NM_UNMANAGED=1   (rule wins)
#     udevadm info  /sys/class/net/enxacde48001122   -> NM_UNMANAGED=0   (live value)
# NetworkManager therefore bound the wildcard `en*` netplan profile to the
# T2 virtual NIC and sat in "connecting (getting IP configuration)" forever
# on an interface attached to nothing, while the real 2.5G adapter
# (enx00e04c684081) stayed "disconnected" with no profile at all. Knock-on:
# NetworkManager-wait-online FAILED after 60s and systemd-time-wait-sync then
# burned 3min36s, taking boot from 38s to 3min41s.
#
# A NetworkManager [device] section is evaluated by NM itself from its own
# config, so it does not race udev rule-file generation at all. Match on the
# MAC: ac:de:48:00:11:22 is a FIXED Apple placeholder, byte-identical on every
# T2 Mac (verified on both MacBookPro16,1 test units), not a per-unit address.
install -d /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/95-ncz-unmanage-t2-ibridge.conf <<'NMCONF'
# The Apple T2 iBridge virtual ethernet is never a real link. Keep
# NetworkManager off it entirely; see post-install/33-network.sh for why the
# udev rule alone is not enough.
[device-ncz-t2-ibridge]
match-device=mac:ac:de:48:00:11:22
managed=0
NMCONF
chmod 0644 /etc/NetworkManager/conf.d/95-ncz-unmanage-t2-ibridge.conf
echo "[33-network] NetworkManager [device] rule: T2 iBridge NIC (mac ac:de:48:00:11:22) managed=0"

# r8152 (Realtek USB 2.5G/1G ethernet, the chip inside most USB-C/Thunderbolt
# docks -- confirmed on a Kensington dock on T2 Mac B, 2026-09-21) drops off the
# USB bus under Linux's default USB autosuspend policy and never resumes: it
# enumerates fine right after boot, works for as long as there's continuous
# traffic (autosuspend only fires on IDLE), then vanishes entirely from
# `nmcli`/`lsusb` after a period of no traffic -- confirmed live: the
# physical ethernet link stays up the whole time (switch-side LEDs active,
# and other USB devices on the SAME dock like keyboard/mouse keep working),
# so it is specifically this chip's suspend/resume handling that fails, not
# the cable, the dock's USB hub, or the driver failing to load. Only a full
# reboot re-probes the bus and brings it back -- exactly the "only
# enumerates on reboot" symptom that made this look like a boot-time
# hardware problem instead of a runtime power-management one.
# Match by USB driver name (r8152) rather than a specific vendor:product ID
# so this covers any dock/adapter using this common chip, not just the one
# board this was found on.
cat > /etc/udev/rules.d/94-ncz-r8152-no-autosuspend.rules <<'UDEVRULES'
# NCZ-OS: Realtek r8152 USB ethernet (common in USB-C/Thunderbolt docks)
# drops off the bus under USB autosuspend and never resumes on its own.
# Pin power/control=on for any device bound to this driver.
ACTION=="add|bind", SUBSYSTEM=="usb", DRIVER=="r8152", TEST=="power/control", ATTR{power/control}="on"
UDEVRULES
chmod 0644 /etc/udev/rules.d/94-ncz-r8152-no-autosuspend.rules
echo "[33-network] installed udev rule disabling USB autosuspend for r8152 ethernet adapters"

# (a) Hard-fail if NM is not installed. preseed pkgsel/include puts it
# there; if it is missing, the netinstall apt fetch failed silently and
# the operator-visible symptom (no network) is exactly what we are
# trying to prevent.
# SELF-SKIP ON THE SINGULARITY SKU.
#
# This hook predates Singularity: its header is about the XFCE dep chain on
# resolute. NCZ-OS 26.7 does not use NetworkManager when sinty-nm is staged:
# 19-sinty-nm.sh installs sinty-nmd and explicitly PURGES network-manager,
# network-manager-gnome, network-manager-applet and nm-connection-editor, and
# network-manager is not in manifests/desktop.pkgs.
#
# So on this image "network-manager is missing" is the CORRECT state, not a
# failed apt fetch. Exiting 1 here aborted every v11 install at finish-install
# ("33-network.sh FAILED rc=1 -- install aborts", measured on O6N 2026-08-18).
# Skip cleanly when sinty-nmd owns the network stack. If neither sinty-nmd nor
# NetworkManager is present, install a minimal systemd-networkd DHCP config for
# the base/console SKU rather than leaving the first boot with no active
# renderer.
if [ -x /usr/bin/sinty-nmd ] || [ -x /usr/local/bin/sinty-nmd ]; then
    echo "[33-network] sinty-nmd owns the network stack on this SKU — skipping NetworkManager/netplan wiring"
    exit 0
fi

if ! command -v nmcli >/dev/null 2>&1 || ! dpkg-query -W -f='${Status}\n' network-manager 2>/dev/null | grep -q "install ok installed"; then
    echo "[33-network] network-manager absent and no sinty-nmd — configuring systemd-networkd DHCP fallback"
    install -d -m 0755 /etc/systemd/network
    cat > /etc/systemd/network/10-ncz-dhcp.network <<'NETWORKD'
# Written by ncz-installer post-install/33-network.sh
# Base/console installs do not run the Singularity desktop sinty-nm path.
[Match]
Name=en* eth*

[Network]
DHCP=yes
IPv6AcceptRA=yes

[DHCPv4]
RouteMetric=100

[DHCPv6]
RouteMetric=100
NETWORKD
    chmod 0644 /etc/systemd/network/10-ncz-dhcp.network

    if [ -f /etc/network/interfaces ]; then
        cat > /etc/network/interfaces <<'ENICONF'
# Reset by ncz-installer post-install/33-network.sh.
# Real NICs are owned by systemd-networkd on the base/console SKU.
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback
ENICONF
    fi

    systemctl unmask systemd-networkd.service systemd-networkd.socket \
        systemd-networkd-wait-online.service 2>/dev/null || true
    systemctl enable systemd-networkd.service systemd-networkd.socket 2>&1 | tail -3 || true
    systemctl enable systemd-networkd-wait-online.service 2>&1 | tail -2 || true
    echo "[33-network] systemd-networkd DHCP fallback enabled"
    exit 0
fi

# (a2) Real upstream NetworkManager needs a WiFi authentication backend to
# manage wireless devices at all -- without one, WiFi PHYs sit stuck at
# NM_DEVICE_STATE_UNAVAILABLE (state 20) forever, with no scan, no
# connect, and no error surfaced anywhere obvious. 19-sinty-nm.sh already
# installs `iwd` unconditionally (as sinty-nmd's own WiFi backend, "part
# of the daemon's complete contract"), but upstream NetworkManager
# does NOT use iwd unless explicitly told to -- it defaults to
# wpa_supplicant, which is NOT in any package manifest and is genuinely
# absent from this image. This branch only runs when sinty-nmd is absent
# and real NetworkManager is taking over (see the exit 0 above), so fix
# it exactly here rather than touching 19-sinty-nm.sh's sinty-nmd/iwd
# path, which this hook must not touch.
#
# Metal-confirmed on T2 Mac B (T2 MacBook, AMD Navi14, no sinty-nmd staged):
# wlan0 existed with a real driver-assigned MAC and real firmware loaded
# (see post-install/55-t2-firmware.sh's Apple firmware fetch, a separate
# fix), but NetworkManager logged
# "Couldn't initialize supplicant interface: Failed to D-Bus activate
# wpa_supplicant service" in a five-retry loop before giving up
# ("supplicant interface keeps failing, giving up"), leaving the device
# permanently unavailable. Installing wpasupplicant and restarting
# NetworkManager fixed it immediately -- confirmed via a real
# `nmcli device wifi list` scan returning real nearby access points.
if ! dpkg-query -W -f='${Status}\n' wpasupplicant 2>/dev/null | grep -q "install ok installed"; then
    echo "[33-network] installing wpasupplicant (NetworkManager's WiFi backend on the non-sinty-nmd fallback path)"
    DEBIAN_FRONTEND=noninteractive apt-get install -y wpasupplicant 2>&1 | tail -10 || \
        echo "[33-network] WARN: wpasupplicant install failed -- WiFi devices will stay unavailable under NetworkManager"
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
    # r130.5 (review): explicit wired DHCP profiles. Two reasons:
    #   1. guarantees NM has an auto-connect profile for the wired NIC on
    #      first boot (don't rely solely on NM's implicit auto-default).
    #   2. optional:true keeps NetworkManager-wait-online.service (which
    #      33-network unmasks+enables below) from BLOCKING network-online
    #      at boot when the wired link has no carrier/lease — that stall,
    #      behind the boot splash, looked like a hang on the MS-R1 test-board install.
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

# PIN THE NIC THE INSTALLER ACTUALLY USED (2026-09-29).
#
# The profile above matches `en*`, which is a wildcard race on any machine
# with more than one candidate. d-i already solved this problem minutes
# earlier -- ethdetect/netcfg picked a working interface and pulled a DHCP
# lease on it -- and then the installed system threw that answer away and
# re-raced from scratch. Carry the answer forward instead.
#
# MEASURED 2026-09-29, three machines on the same image (2026.09.29-0d04e75):
#   GU502LV  (ASUSTeK, no T2)        -> wildcard landed correctly
#   T2 Mac A (T2, adapter on a dock) -> NM bound enxacde48001122 (the T2
#                                       iBridge decoy), real NIC left
#                                       "disconnected", no lease
#   T2 Mac B (T2, SAME adapter model, direct-attached, no dock)
#                                    -> same failure, machine unreachable
# The installer got it right on all three. Only the installed system lost.
# Same adapter model on both MacBookPro16,1 test units with different USB topology gave
# different outcomes, which is the signature of a race, not a config error.
#
# Pinning is by MAC, in a higher-numbered netplan file so it wins the merge
# without editing the wildcard profile (which stays as the fallback for a
# machine whose NIC is later swapped).
_ncz_pin_if=$(ip route show default 2>/dev/null | awk '/^default/ {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
if [ -n "$_ncz_pin_if" ] && [ -r "/sys/class/net/$_ncz_pin_if/address" ]; then
    _ncz_pin_mac=$(cat "/sys/class/net/$_ncz_pin_if/address")
    case "$_ncz_pin_mac" in
        ac:de:48:00:11:22)
            # The T2 iBridge decoy must never be pinned even if something
            # upstream managed to route over it.
            echo "[33-network] refusing to pin $_ncz_pin_if -- that is the T2 iBridge decoy"
            _ncz_pin_mac="" ;;
    esac
    if [ -n "$_ncz_pin_mac" ]; then
        cat > "$NETPLAN_DIR/02-ncz-installer-nic.yaml" <<PINYAML
# Pinned by post-install/33-network.sh: this is the interface the INSTALLER
# used and obtained a DHCP lease on ($_ncz_pin_if, $_ncz_pin_mac). Matching
# by MAC removes the en* wildcard race on machines with several candidates
# -- notably Apple T2, whose iBridge virtual NIC also matches en*.
network:
  version: 2
  renderer: NetworkManager
  ethernets:
    ncz-wired-primary:
      match:
        macaddress: $_ncz_pin_mac
      dhcp4: true
      dhcp6: true
      optional: true
PINYAML
        chmod 0600 "$NETPLAN_DIR/02-ncz-installer-nic.yaml"
        echo "[33-network] pinned installer NIC $_ncz_pin_if ($_ncz_pin_mac) as ncz-wired-primary"
    fi
else
    echo "[33-network] no default route in the installer env -- cannot pin a NIC; en* wildcard remains"
fi

# Remove cloud-init's generated 50-cloud-init.yaml and any other
# competing netplan configs that would re-render to systemd-networkd.
for stale in 50-cloud-init.yaml 99_cloud-init.yaml 00-installer-config.yaml; do
    if [ -f "$NETPLAN_DIR/$stale" ]; then
        echo "[33-network] removing stale $stale (would compete with NM renderer)"
        rm -f "$NETPLAN_DIR/$stale"
    fi
done

# (b2) r130.5 (CRITICAL — two test-board installs: wired NIC never got DHCP):
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
# so network-online.target actually waits for NM. It never blocks
# login/ssh, which are gated on network.target (link present), not
# network-online.target.
systemctl unmask NetworkManager-wait-online.service 2>/dev/null || true
systemctl enable NetworkManager-wait-online.service 2>&1 | tail -2 || true

# (d3) Bound it at 15 s (2026-10-06). The stock unit sets
# NM_ONLINE_TIMEOUT=60 (the comment above used to claim ~30 s), and
# `nm-online -s` waits for NetworkManager's "startup complete", which also
# waits for cable-less NICs and the first Wi-Fi scan. MEASURED (systemd
# blame): 8.08 s on T2 Mac A, 5.55 s on the GU502LV laptop, both on a healthy DHCP LAN;
# T2 Mac A had its lease at 8.33 s and "startup complete" only at 16.04 s.
# graphical.target waits for it through multi-user.target -> inetd.service
# (After=network-online.target). The greeter does not, so this changes when
# boot is "finished", not when the login screen appears. With no DHCP server
# the wait was up to 60 s; 15 s is ~2x the measured healthy case. Units that
# need the network for real keep their own ordering and retries
# (ncz-cuda-setup.timer fires 2 min after boot; ncz-issue-refresh polls).
install -d -m0755 /etc/systemd/system/NetworkManager-wait-online.service.d
cat > /etc/systemd/system/NetworkManager-wait-online.service.d/10-ncz-bounded.conf <<'NMWAIT'
[Service]
# NCZ-OS: cap network-online at 15 s (post-install/33-network.sh, build/test-boot-sequence.sh).
Environment=NM_ONLINE_TIMEOUT=15
NMWAIT
chmod 0644 /etc/systemd/system/NetworkManager-wait-online.service.d/10-ncz-bounded.conf
echo "[33-network] NetworkManager-wait-online bounded at NM_ONLINE_TIMEOUT=15"
# Don't try to start NM in the chroot — the host has no live network
# stack to manage. First boot will pick it up via the enable.

# Apply netplan to regenerate /run/NetworkManager/conf.d/*. This does
# NOT bring up interfaces in the chroot (no live stack); it just
# updates the rendered config that NM will read on first boot.
netplan generate 2>&1 | tail -3 || \
    echo "[33-network] WARN: netplan generate failed (likely chroot — first-boot will retry)"

echo "[33-network] netplan written; NM enabled; systemd-networkd masked"
