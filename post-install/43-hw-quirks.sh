#!/bin/bash
# NCZ-MIXED-HOOK: rtl_btusb blacklist is Sky1 only; r8169/atlantic EEE-off and multipathd mask are generic; TODO split (docs/platform-inventory.tsv; runs on every platform, listed in both hooks.list files)
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
#  (2) r8169 / RTL8125 AND atlantic / AQC113 EEE-off — the 2.5G NIC (enp1s0) negotiates
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

echo "[43] hw quirks: rtl_btusb blacklist + r8169/atlantic EEE-off + multipathd mask"

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

# Aquantia/Marvell AQC113 (atlantic) shows the SAME 2.5G flap signature.
# Measured on T2 Mac B (MacBookPro16,1) 2026-09-28, AQC113 [1d6a:04c0] rev 03
# in a Thunderbolt enclosure, firmware ATL2FW 105002a:
#     [16.763] atlantic 0000:0c:00.0 enp12s0: atlantic: link change old 0 new 2500
#     [55.675] atlantic 0000:0c:00.0 enp12s0: atlantic: link change old 2500 new 0
#     [55.906] atlantic 0000:0c:00.0 enp12s0: PTP RX filter restore failed in link change
# Link negotiated 2.5G, held 39s, dropped to 0 and never renegotiated. No
# pcieport/D3 event accompanied the drop and ACPI had already disabled ASPM
# ("ACPI FADT declares the system doesn't support PCIe ASPM, so disable it"),
# so this is the PHY/EEE flap, not a PCIe power transition. ethtool also
# reported "Link partner advertised auto-negotiation: No", which makes the
# 2.5G negotiation more fragile. Upstream has the same report against this
# part: https://github.com/Aquantia/AQtion/issues/74 (AQC113 link drops from
# 2500Mb/s to 0 on Linux, stable on Windows).
cat > /etc/udev/rules.d/70-atlantic-eee-off.rules <<'UDEOF'
ACTION=="add", SUBSYSTEM=="net", DRIVERS=="atlantic", RUN+="/usr/local/sbin/ncz-nic-eee-off %k"
UDEOF

# apply immediately to any already-present r8169 interface
if command -v ethtool >/dev/null 2>&1; then
    for i in /sys/class/net/*; do
        [ -e "$i/device/driver" ] || continue
        case "$(readlink -f "$i/device/driver" 2>/dev/null)" in
            *r8169*|*atlantic*)
                     _drv=$(basename "$(readlink -f "$i/device/driver")")
                     /usr/local/sbin/ncz-nic-eee-off "$(basename "$i")"
                     echo "  [43] EEE disabled on $(basename "$i") ($_drv)";;
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
# pointed /dev/video-cixdec0 at the ENCODER. Measured on a Sky1 test board 2026-08-16:
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

# --- DMA-BUF heaps must be reachable by the compositor user ----------------
# The Mali vendor GBM (libgbm.so.1 from cix-gpu-umd) allocates through
# /dev/dma_heap/*. The kernel creates those nodes 0600 root:root, so a
# compositor running unprivileged -- greetd's _greetd, or any desktop
# session -- gets EACCES. wlroots then reports only
#     [render/egl.c:595] Failed to create GBM device
# which names neither dma_heap nor a permission problem, so this is
# expensive to rediscover.
#
# Measured on O6N 2026-09-28: an identical labwc invocation SUCCEEDED as root
# and FAILED as _greetd with identical library resolution. _greetd could
# already read and write /dev/dri/card0, /dev/dri/renderD128 and /dev/mali0,
# so the DRM and GPU nodes were never the issue -- only the heaps were.
#
# render is the right group: _greetd and desktop users are already members
# for /dev/dri/renderD128. 0660 not 0666 -- these hand out DMA buffers and
# should not be world-writable.
install -d /etc/udev/rules.d
cat > /etc/udev/rules.d/71-ncz-dma-heap.rules <<'DMAEOF'
SUBSYSTEM=="dma_heap", GROUP="render", MODE="0660"
DMAEOF
echo "[43] dma_heap udev rule installed (render:0660)"

# --- Sky1 media/audio stability: restored fixes (2026-10-11) ---------------
# These three were verified live on O6N in 2026-09 but never merged to main, so
# the 26.10 / 6351e0b3 image shipped without them and audio underruns returned
# under streaming load: pw-top showed the ALSA sink ERR counter climbing (79 in
# one session) at quantum 1024, and PipeWire's data-loop.0 running SCHED_OTHER
# (prio 0) instead of realtime.
#
# (4) RT scheduling: CONFIG_RT_GROUP_SCHED + cgroups-v2 delegation leaves the
#     cpu controller enabled in user slices, so rtkit-daemon cannot obtain RT
#     runtime and PipeWire's data loop runs at SCHED_OTHER. Disabling the cpu
#     controller for the top-level user slice restores RT to the root cgroup.
install -d /etc/systemd/system/-.slice.d
cat > /etc/systemd/system/-.slice.d/10-ncz-rt-sched.conf <<'SLICEEOF'
# Keep the cpu controller out of delegated user slices so rtkit/PipeWire can
# get realtime scheduling (fixes Sky1 audio XRUNs). See post-install/43-hw-quirks.sh.
[Slice]
DisableControllers=cpu
SLICEEOF
echo "[43] RT-scheduling slice drop-in installed (DisableControllers=cpu)"

# (5) PipeWire quantum floor: the default min-quantum (32) lets the quantum
#     collapse under decode load; raise the floor so the ALSA sink has headroom.
install -d /etc/pipewire/pipewire.conf.d
cat > /etc/pipewire/pipewire.conf.d/99-ncz-audio-headroom.conf <<'PWEOF'
# Sky1 audio underrun headroom (see post-install/43-hw-quirks.sh).
context.properties = {
    default.clock.min-quantum = 2048
}
PWEOF
echo "[43] PipeWire min-quantum=2048 installed"

# (6) VPU (amvx/MVX) devfreq governor: simple_ondemand parks the decoder clock
#     at 72-216 MHz at the start of AV1/VP9 decode and the decoder's first
#     frames underrun (cold-clock startup stutter). Pin it to performance.
#     Sky1 only (CIXH3010:00 = amvx_dev).
#
#     Deliberately NOT a udev RUN+=/sleep loop: udev processes RUN synchronously
#     within the event's timeout, so a retry-with-sleep there blocks the udev
#     worker and can stall unrelated device events at boot (review
#     2026-10-11). Pin it from a boot-time oneshot instead -- the pattern this
#     tree already uses for devfreq/power policy (see 85-power-perf-mode.sh and
#     the chroot-safe enable in 83-panthor-gpu.sh).
#
#     NOTE the hazard recorded in 85-power-perf-mode.sh: writing a non-default
#     governor to a CIX devfreq node is the same clk_round_rate NULL-deref class
#     that panic-looped the board when aimed at CIXH4000 (NPU). CIXH3010 (VPU)
#     is a different driver, and a `performance` write to it was applied live on
#     O6N and held 1000 MHz with no fault, so it is enabled here -- but only
#     from a single boot oneshot, never a hotplug loop, so a fault would be a
#     one-shot boot event rather than a per-event crash.
#
#     Gate on the TARGET ARCH, not on /sys (the devfreq node does not exist in
#     the build chroot, so a node test here would silently never install the
#     unit on the target -- review 2026-10-11). Same arm64 idiom as
#     81-vpu.sh. The helper repeats the node check at boot and no-ops elsewhere.
if [ "$(dpkg --print-architecture 2>/dev/null)" = "arm64" ]; then
    cat > /usr/local/sbin/ncz-vpu-governor-performance <<'VPUEOF'
#!/bin/sh
# Pin the Sky1 VPU (amvx/mvx) devfreq governor to performance. Started by
# ncz-vpu-governor.service at boot; no polling loop here (review
# 2026-10-11 -- systemd/udev handle the wait). No-ops and exits 0 if the node is
# absent (e.g. non-Sky1 hardware).
set -u
G=/sys/class/devfreq/CIXH3010:00/governor
[ -w "$G" ] && echo performance > "$G" 2>/dev/null || true
exit 0
VPUEOF
    chmod 0755 /usr/local/sbin/ncz-vpu-governor-performance
    cat > /etc/systemd/system/ncz-vpu-governor.service <<'VPUS'
[Unit]
Description=Pin Sky1 VPU devfreq governor to performance (avoids decode startup stutter)
After=systemd-udev-settle.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ncz-vpu-governor-performance
RemainAfterExit=yes
[Install]
WantedBy=graphical.target
VPUS
    # Non-blocking udev -> systemd bridge: tag the VPU platform device and let
    # systemd start the oneshot when it appears. No RUN+= program, so udev never
    # blocks (review 2026-10-11). This also covers amvx being modprobed
    # after coldplug (the node may not exist at systemd-udev-settle).
    cat > /etc/udev/rules.d/71-ncz-vpu-governor.rules <<'VPUR'
# Sky1 VPU devfreq -> performance. Non-blocking: tag the device, let systemd
# start ncz-vpu-governor.service. See post-install/43-hw-quirks.sh.
ACTION=="add", SUBSYSTEM=="platform", KERNEL=="CIXH3010:00", TAG+="systemd", ENV{SYSTEMD_WANTS}+="ncz-vpu-governor.service"
VPUR
    # Enable by hand rather than via systemctl: this hook runs in a chroot with
    # no running systemd, where `systemctl enable` can fail on the D-Bus probe
    # (same reason as 83-panthor-gpu.sh).
    install -d -m 0755 /etc/systemd/system/graphical.target.wants
    ln -sf ../ncz-vpu-governor.service \
        /etc/systemd/system/graphical.target.wants/ncz-vpu-governor.service
    echo "[43] VPU governor -> performance (ncz-vpu-governor.service + udev tag)"
else
    echo "[43] not arm64 (Sky1 VPU only); VPU governor step skipped"
fi

# (4) laptop backlight first-boot default ------------------------------------
# DELL Inspiron 5521 (Intel HD 4000), 2026-10-27: the panel's backlight
# persisted at 342/4882 (7 % of max), masking a partial scanout success as a
# black screen and making a healthy greeter look dead. Laptops do not ship
# with a usable default here, so the FIRST boot raises the brightness to
# >= 40 % of max, once. The marker in /var/lib makes this first-run only:
# a value the user sets afterwards is never clobbered.
cat > /usr/local/sbin/ncz-backlight-default <<'BLDEF'
#!/bin/sh
# ncz-backlight-default -- first-boot laptop brightness default. Run by
# ncz-backlight-default.service (After= multi-user, Before= greetd). See
# post-install/43-hw-quirks.sh for the rationale.
set -u
MARK=/var/lib/ncz/backlight-default-applied
is_laptop() {
    # SMBIOS chassis types that are actually portable: 8 Portable, 9 Laptop,
    # 10 Notebook, 11 Hand Held, 14 Sub Notebook, 30 Tablet, 31 Convertible,
    # 32 Detachable. 8 was missing, and the DELL Inspiron 5521 reports 8 -- so
    # the reference weak host skipped this default entirely and booted at 7 %
    # brightness (measured 2026-10-28: chassis_type=8, brightness 342/4882, no
    # /var/lib/ncz marker because the script exited here).
    for t in "$(tr -d '\000' < /sys/class/dmi/id/chassis_type 2>/dev/null)" \
             "$(tr -d '\000' < /sys/devices/virtual/dmi/id/chassis_type 2>/dev/null)"; do
        case "$t" in
            8 | 9 | 10 | 11 | 14 | 30 | 31 | 32) return 0 ;;
        esac
    done
    # A machine with a battery and a panel backlight is portable whatever the
    # DMI table claims; some firmware reports a desktop chassis code (3/35) on a
    # laptop, or omits chassis_type entirely.
    for b in /sys/class/power_supply/BAT*; do
        [ -e "$b" ] || continue
        for bl in /sys/class/backlight/*; do
            [ -r "$bl/max_brightness" ] && return 0
        done
    done
    return 1
}
# (1) laptop check: no DMI chassis_type (VM / unknown) or a desktop form
# factor -> nothing to do, and no marker (re-check on a future boot where DMI
# is readable, if such a machine exists).
is_laptop || exit 0
# (2) first-run only: a user-set value from a later boot is never clobbered.
[ -e "$MARK" ] && exit 0
# (3) find the panel device: a real panel has max_brightness >= 16 (GPU
# backlights); USB/ACPI dummies are smaller or absent.
dev=""
for b in /sys/class/backlight/*; do
    [ -r "$b/max_brightness" ] && [ -w "$b/brightness" ] || continue
    mx=$(cat "$b/max_brightness" 2>/dev/null) || continue
    case "$mx" in '' | *[!0-9]*) continue ;; esac
    [ "$mx" -ge 16 ] && { dev="$b"; break; }
done
[ -n "$dev" ] || exit 0
target=$(( $(cat "$dev/max_brightness") * 40 / 100 ))
[ "$target" -ge 1 ] || exit 0
if [ "$(cat "$dev/brightness" 2>/dev/null)" -lt "$target" ] 2>/dev/null; then
    echo "$target" > "$dev/brightness" 2>/dev/null || true
    logger -t ncz-backlight-default "first boot on a laptop: brightness raised to $target ($(cat "$dev/max_brightness"))" 2>/dev/null || true
fi
install -d -m 0755 /var/lib/ncz
touch "$MARK"
BLDEF
chmod 0755 /usr/local/sbin/ncz-backlight-default
cat > /etc/systemd/system/ncz-backlight-default.service <<'BLUNIT'
[Unit]
Description=First-boot laptop backlight default (>= 40 % of max, once)
After=multi-user.target
# Before the greeter so the first painted frame is at a readable brightness;
# After the splash's ordering anchor is unnecessary (it does not own
# brightness).
Before=greetd.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ncz-backlight-default
RemainAfterExit=yes

[Install]
WantedBy=graphical.target
BLUNIT
systemctl enable ncz-backlight-default.service 2>/dev/null || \
    ln -sf /etc/systemd/system/ncz-backlight-default.service \
        /etc/systemd/system/graphical.target.wants/ncz-backlight-default.service
echo "[43] first-boot laptop backlight default installed (>= 40 % of max, once)"

echo "[43] hw quirks done"
exit 0
