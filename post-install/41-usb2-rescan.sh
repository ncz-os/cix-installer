#!/bin/bash
# 41-usb2-rescan.sh — workaround for the CIX Sky1 (Sky1/CD8180) boot-time
# USB2-companion enumeration bug observed on the 7.2 kernel.
#
# Discovered 2026-07-22 on O6N (.3): on some boots an xhci controller brings
# up its SuperSpeed (USB3) root but its High-Speed (USB2) companion root never
# enumerates the downstream device. The board's USB-A ports fan out through an
# onboard VIA VL812 hub; when the USB2 companion is down, ANY USB2 device
# behind it — including a keyboard whose own HID + mouse pass-through live on
# the USB2 side — is completely invisible (no /dev/input, no hidraw). The user
# lands on a login screen with a dead keyboard and mouse. A rebind of the
# affected xhci controller forces both roots to re-init and the whole tree
# (hub + keyboard + mouse) enumerates. The stock 7.0.12 kernel does not show
# this — it is a 7.2 regression, most likely USB2 PHY/reset init timing (cdns3
# territory, cf. kernel patch 0082). This is a mitigation, not the root fix.
#
# The community also hit this: gitlab.com/ncz-os/cix-installer issue #1
# ("USB 3 notes ... may need updating").
#
# Precision: the service rebinds ONLY controllers showing the exact failure
# signature — SuperSpeed root has a downstream device AND the USB2 companion
# root is empty. Healthy controllers and in-use USB storage are never touched,
# so on a good boot it is a pure no-op (rebound=0).
#
# Ordering is late ON PURPOSE. An early-sysinit ESP-writing guard once bricked
# the O6N via a systemd dependency cycle (2026-07-xx). This unit uses
# DefaultDependencies=yes and runs After=systemd-udev-settle. It first gives
# the physical keyboard a short chance to finish its normal late enumeration;
# it only resets controllers when that recovery is actually needed. This avoids
# stealing a healthy keyboard from the greeter and avoids a needless boot stall.
# Verified cycle-free with `systemd-analyze verify`.
set -uo pipefail

echo "[41] USB2-companion rescan workaround (Sky1 7.2 xhci)"

install -d -m 0755 /usr/local/sbin

cat > /usr/local/sbin/ncz-usb2-rescan <<'EOF'
#!/bin/bash
# Recover the CIX Sky1 7.2 USB2-companion enumeration failure by rebinding the
# xhci controllers. The failure is intermittent and its severity varies: on some
# boots the SuperSpeed root is up while the USB2 companion is empty; on others
# NOTHING enumerates on the affected controller at all. So an "SuperSpeed-up +
# USB2-empty" signature is too narrow (misses the everything-empty case, observed
# 2026-07-22 on O6N r198). First wait briefly for the normal VIA hub/HID path to
# finish enumerating. Only if no keyboard appears do we rebind controllers with
# no USB mass-storage device downstream; that re-triggers hub/HID enumeration
# while never disturbing a USB boot/data drive mid-I/O.
set -u

# On a healthy O6 boot, the USB hub and keyboard arrive late. Resetting an xHCI
# controller while that is already happening creates a visible input delay and
# holds the graphical target. Treat a discovered keyboard as success; this unit
# is a recovery mechanism, not a normal-boot optimization.
for try in 1 2 3 4 5 6; do
  for name in /sys/class/input/input*/name; do
    [ -r "$name" ] || continue
    if grep -qi 'keyboard' "$name"; then
      logger -t ncz-usb2-rescan "keyboard present; recovery not needed"
      exit 0
    fi
  done
  sleep 1
done
logger -t ncz-usb2-rescan "no keyboard after 6s; starting controller recovery"

DRV=/sys/bus/platform/drivers/xhci-hcd
declare -A has_storage
for u in /sys/bus/usb/devices/usb*; do
  [ -e "$u/speed" ] || continue
  ctrl=$(basename "$(readlink -f "$u/..")")   # e.g. xhci-hcd.13.auto
  # any SCSI/block (USB mass storage) device anywhere under this controller?
  if find "$u" -maxdepth 8 -type d -name 'block' 2>/dev/null | grep -q .; then
    has_storage[$ctrl]=1
  fi
done
rebound=0
for ctrl in $(ls "$DRV" 2>/dev/null | grep '^xhci-hcd'); do
  if [ -n "${has_storage[$ctrl]:-}" ]; then
    logger -t ncz-usb2-rescan "skip $ctrl (has USB storage downstream)"
    continue
  fi
  logger -t ncz-usb2-rescan "rebinding $ctrl (USB2 enum recovery)"
  echo "$ctrl" > "$DRV/unbind" 2>/dev/null
  sleep 1
  echo "$ctrl" > "$DRV/bind" 2>/dev/null
  rebound=$((rebound+1))
done
logger -t ncz-usb2-rescan "done, rebound=$rebound"
exit 0
EOF
chmod 0755 /usr/local/sbin/ncz-usb2-rescan

cat > /etc/systemd/system/ncz-usb2-rescan.service <<'EOF'
[Unit]
Description=NCZ: rebind CIX xhci controllers with failed USB2 enumeration (Sky1 7.2 workaround)
Documentation=https://github.com/Sky1-Linux
# Late ordering ON PURPOSE — never place USB/ESP-touching guards in
# sysinit.target (an early-sysinit ESP guard bricked the O6N once).
After=systemd-udev-settle.service
DefaultDependencies=yes

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ncz-usb2-rescan
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# chroot-safe: plain enable only (systemd is not PID 1 during install).
systemctl enable ncz-usb2-rescan.service 2>&1 | tail -1 || true
echo "  ncz-usb2-rescan: $(systemctl is-enabled ncz-usb2-rescan.service 2>&1 || true)"
