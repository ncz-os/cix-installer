#!/bin/bash
# 43-hw-quirks.sh — post-install hardware quirk fixes for Sky1 / O6N, found on
# real O6N metal (v5 install, 2026-07-29 serial capture). All three are
# hardware/kernel-level and apply to BOTH desktop and server SKUs, so this hook
# is unconditional (no BUILD_VARIANT gate).
#
#  (1) rtl_btusb blacklist — a STALE out-of-tree Realtek BT module built for
#      6.6.10-cix-build-generic ships in the CIX vendor rootfs and fails to load
#      on this kernel:
#        rtl_btusb: version magic '6.6.10-cix-build-generic ... modversions'
#                   should be '<KVER>-sky1-ncz ...'
#      The in-tree btusb + btrtl modules (shipped in the kernel modules set,
#      correct vermagic) provide Realtek Bluetooth properly, so the out-of-tree
#      one is redundant AND broken -> blacklist it.
#
#  (2) r8169 / RTL8125 EEE-off — the 2.5G NIC (enp1s0) negotiates
#      2.5Gbps/Full then cycles Link Up<->Down. Energy-Efficient Ethernet on
#      RTL8125 is a well-known cause of exactly this 2.5G link flap; disable EEE
#      via ethtool when an r8169 NIC appears (r8169 is built into the kernel, so
#      this is a runtime tunable, not a module param).
#      NOTE: EEE is the leading suspect from the flap signature; if a flap
#      persists after this, re-check ASPM (pcie_aspm=off) and the cable/switch.
#
#  (3) multipathd mask — single-disk appliance; DM-multipath is never used and
#      multipathd.service fails at every boot. Mask it.
set -uo pipefail

echo "[43] hw quirks: rtl_btusb blacklist + r8169 EEE-off + multipathd mask"

# (1) stale out-of-tree Realtek BT module -----------------------------------
install -d /etc/modprobe.d
cat > /etc/modprobe.d/blacklist-rtl_btusb.conf <<'MODEOF'
# Stale out-of-tree Realtek BT module (built for 6.6.10-cix-build-generic),
# vermagic-incompatible with the shipped Sky1 kernel -> never load it. In-tree
# btusb + btrtl (correct vermagic, shipped in the kernel modules set) handle
# Realtek Bluetooth on this kernel.
blacklist rtl_btusb
install rtl_btusb /bin/true
MODEOF
echo "  [43] rtl_btusb blacklisted (in-tree btusb+btrtl cover Realtek BT)"

# (2) RTL8125 2.5G EEE flap --------------------------------------------------
install -d /usr/local/sbin
cat > /usr/local/sbin/ncz-nic-eee-off <<'EEOF'
#!/bin/sh
# Disable Energy-Efficient Ethernet on a NIC (RTL8125 2.5G link-flap fix).
IF="${1:?}"
command -v ethtool >/dev/null 2>&1 || exit 0
ethtool --set-eee "$IF" eee off 2>/dev/null || true
EEOF
chmod 0755 /usr/local/sbin/ncz-nic-eee-off

install -d /etc/udev/rules.d
cat > /etc/udev/rules.d/70-r8169-eee-off.rules <<'UDEOF'
# RTL8125 2.5G link flaps Up<->Down with EEE enabled; disable EEE when an
# r8169-driven NIC appears.
ACTION=="add", SUBSYSTEM=="net", DRIVERS=="r8169", RUN+="/usr/local/sbin/ncz-nic-eee-off %k"
UDEOF

# apply immediately to any already-present r8169 interface
if command -v ethtool >/dev/null 2>&1; then
    for i in /sys/class/net/*; do
        [ -e "$i/device/driver" ] || continue
        case "$(readlink -f "$i/device/driver" 2>/dev/null)" in
            *r8169*) /usr/local/sbin/ncz-nic-eee-off "$(basename "$i")"
                     echo "  [43] EEE disabled on $(basename "$i") (r8169)";;
        esac
    done
else
    echo "  [43] ethtool not present — EEE-off deferred to first-boot udev rule"
fi

# (3) multipathd not used on single-disk appliance --------------------------
systemctl disable multipathd.service 2>/dev/null || true
systemctl mask    multipathd.service 2>/dev/null || true
echo "  [43] multipathd masked (single-disk appliance, no DM-multipath)"

# Replace the vendor loader, which hard-coded a retired 6.6 kernel tree and
# manually insmod-ed GPU/VPU modules before the current kernel was ready.
# Those stale insmods produced boot warning screens and raced seatd/DRM.
cat > /usr/bin/load-modules.sh <<'LOADER'
#!/bin/sh
set +e
# Only generic helpers belong here; GPU/NPU/VPU drivers are selected and
# loaded by their kernel cmdline/systemd paths for the running kernel.
for module in cfg80211 uhid btusb x_tables ip_tables iptable_nat nf_defrag_ipv4 nf_defrag_ipv6 libcrc32c nf_conntrack nf_nat xt_MASQUERADE; do
    modprobe "$module" 2>/dev/null || true
done
modprobe ice 2>/dev/null || true
ln -sf /dev/dma_heap/reserved /dev/dma_heap/linux,cma 2>/dev/null || true
if [ ! -s /etc/machine-id ]; then
    dbus-uuidgen > /var/lib/dbus/machine-id 2>/dev/null || true
    ln -sf /var/lib/dbus/machine-id /etc/machine-id 2>/dev/null || true
fi
# Select the VPU nodes by DRIVER NAME, never by enumeration order.
# The old code took the LAST /dev/video* after a version sort. On Sky1 the
# nodes are video0=mvxdec (decoder) and video1=mvxenc (encoder), so "last"
# pointed /dev/video-cixdec0 at the ENCODER. Measured on cixmini 2026-08-16:
# h264_v4l2m2m encode failed with "VIDIOC_STREAMON failed on capture context"
# / ENODEV, and mpeg4_v4l2m2m decode returned frame=0. Numbering is not
# guaranteed, so match on /sys/class/video4linux/*/name instead.
for _v in /sys/class/video4linux/video*; do
    [ -r "$_v/name" ] || continue
    _n=$(cat "$_v/name" 2>/dev/null)
    _d=/dev/$(basename "$_v")
    [ -e "$_d" ] || continue
    case "$_n" in
        mvxdec*) ln -sf "$_d" /dev/video-cixdec0 ;;
        mvxenc*) ln -sf "$_d" /dev/video-cixenc0 ;;
    esac
done
# Fall back to the single-node case only when nothing was named.
if [ ! -e /dev/video-cixdec0 ]; then
    set -- $(ls /dev/video* 2>/dev/null | sort -V)
    [ $# -eq 1 ] && ln -sf "$1" /dev/video-cixdec0
fi
exit 0
LOADER
chmod 0755 /usr/bin/load-modules.sh

echo "[43] hw quirks done"
exit 0
