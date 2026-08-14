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

# Never runtime-suspend the interactive USB chain. On O6N the VIA hub is the
# keyboard/mouse path; a wake from runtime suspend can add hundreds of ms to
# HID delivery even when CPU idle is pinned off.
install -d /etc/udev/rules.d
cat > /etc/udev/rules.d/70-ncz-usb-interactive.rules <<'UDEV'
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="24f0", ATTR{idProduct}=="0140", TEST=="power/control", ATTR{power/control}="on", ATTR{power/autosuspend_delay_ms}="-1"
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="413c", ATTR{idProduct}=="3012", TEST=="power/control", ATTR{power/control}="on", ATTR{power/autosuspend_delay_ms}="-1"
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="2109", ATTR{idProduct}=="2812", TEST=="power/control", ATTR{power/control}="on", ATTR{power/autosuspend_delay_ms}="-1"
UDEV
udevadm control --reload 2>/dev/null || true

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

# On a healthy O6 boot, the USB hub and keyboard can arrive late. Give it a
# short opportunity to do so, then recover rather than holding the entire
# graphical path for eight seconds. The post-rebind probe below is important:
# greetd must not start until libinput can see the keyboard.
keyboard_present() {
  for name in /sys/class/input/input*/name; do
    [ -r "$name" ] || continue
    if grep -qi "keyboard" "$name"; then
      return 0
    fi
  done
  return 1
}

# Pre-rebind grace: 1s, NOT 3s. This unit is ordered After=systemd-udev-settle,
# so if the keyboard were going to enumerate on its own it would already be
# present -- a longer wait cannot make an affected controller work, it only
# delays the rebind that does. Measured on O6N with r239:
#
#   ncz-usb2-rescan: keyboard absent after 3s; rebinding xhci-hcd.3.auto only
#   ncz-usb2-rescan: keyboard present after rebind; recovery complete
#
# i.e. the full grace elapsed with nothing, then the device appeared ~1.7s
# after the rebind. The 3s was pure dead time on every boot of affected
# hardware, and it is NOT free: greetd.service is ordered After= this unit, so
# it sits directly in the path to the login screen. systemd-analyze
# critical-chain on that boot:
#
#   graphical.target @8.843s
#   └─greetd.service @7.738s +184ms
#     └─ncz-usb2-rescan.service @2.031s +5.704s
#
# The boot splash is downstream of the same delay -- it ran 6.864s wall for
# only 1.571s CPU because it waits to hand off to greetd, and finished within
# a second of greetd coming up. So this one wait inflates both.
#
# The early-exit path is unchanged: hardware that enumerates normally still
# exits immediately without a rebind.
for try in 1 2 3 4; do
  if keyboard_present; then
    logger -t ncz-usb2-rescan "keyboard present; recovery not needed"
    exit 0
  fi
  sleep 0.25
done

# O6N USB-A hub/HID chain: ACPI controller CIXH2030:06/CIXH2031:06.
# Rebinding every Sky1 xHCI controller was counterproductive: it delayed input
# by ~16 seconds and needlessly disturbed unrelated USB roots. Resolve the
# controller dynamically because its xhci-hcd.* index is not stable.
DRV=/sys/bus/platform/drivers/xhci-hcd
keyboard_ctrl=
for node in "$DRV"/xhci-hcd.*.auto; do
  [ -e "$node" ] || continue
  case "$(readlink -f "$node")" in
    */CIXH2030:06/CIXH2031:06/*) keyboard_ctrl=$(basename "$node"); break ;;
  esac
done

if [ -z "$keyboard_ctrl" ]; then
  logger -t ncz-usb2-rescan "keyboard absent; O6 USB-A controller not found, no recovery attempted"
  exit 0
fi

# Never reset a controller that owns removable storage. Match its USB roots
# directly; following the controller symlink can recurse through all of sysfs.
has_storage=0
for usb_root in /sys/bus/usb/devices/usb*; do
  [ -e "$usb_root/speed" ] || continue
  ctrl=$(basename "$(readlink -f "$usb_root/..")")
  [ "$ctrl" = "$keyboard_ctrl" ] || continue
  if find "$usb_root" -maxdepth 8 -type d -name block -print -quit 2>/dev/null | grep -q .; then
    has_storage=1
    break
  fi
done
if [ "$has_storage" -eq 1 ]; then
  logger -t ncz-usb2-rescan "skip $keyboard_ctrl (has USB storage downstream)"
  exit 0
fi

logger -t ncz-usb2-rescan "keyboard absent after 1s grace; rebinding $keyboard_ctrl only"
echo "$keyboard_ctrl" > "$DRV/unbind" 2>/dev/null
sleep 1
echo "$keyboard_ctrl" > "$DRV/bind" 2>/dev/null
for try in 1 2 3 4 5 6 7 8 9 10 11 12; do
  if keyboard_present; then
    logger -t ncz-usb2-rescan "keyboard present after rebind; recovery complete"
    exit 0
  fi
  sleep 0.25
done
logger -t ncz-usb2-rescan "keyboard still absent 3s after rebind; continuing without input"
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
