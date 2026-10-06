#!/bin/bash
# NCZ-MIXED-HOOK: Sky1 DRM/linlondp detector; unit enable is arm64-only but xorg/udev drop-ins are written on every arch; TODO make sky1-only body (docs/platform-inventory.tsv; runs on every platform, listed in both hooks.list files)
# 22-display-fix.sh — Sky1 DRM card numbering shifts between boots due to
# driver-init race. Detector runs at every boot AFTER udev-settle, with a
# 30-second retry loop because Sky1 linlondp probes asynchronously.
# CRITICAL: never wipes existing Xorg config when no display is detected
# (otherwise a transient detection failure bricks the next boot).
set -euo pipefail

echo "[22] installing dynamic primary-display detector + Xorg config"

VARIANT=desktop
if [ -f /usr/local/lib/cix-installer/BUILD_VARIANT ]; then
    VARIANT=$(tr -d ' \t\r\n' < /usr/local/lib/cix-installer/BUILD_VARIANT)
fi
case "$VARIANT" in
    server|headless)
        echo "[22] BUILD_VARIANT=server - Server headless SKU; skipping Xorg display detector"
        exit 0
        ;;
esac

install -d /usr/local/lib/cix-installer
cat > /usr/local/lib/cix-installer/detect-primary-display.sh <<'DET'
#!/bin/sh
LOG=/var/log/ncz-display-detect.log
exec >>"$LOG" 2>&1
echo "=== $(date -u) ==="

CONN_CARD=""; CONN_OUTPUT=""
# Sky1 DRM probe is asynchronous. Keep the 30-second safety bound, but poll
# frequently: the former five-second interval was on greetd's critical path
# and added up to 4.99 seconds after the connector had already appeared.
try=0
while [ "$try" -lt 120 ]; do
    for c in /sys/class/drm/card*-eDP-* /sys/class/drm/card*-DP-* /sys/class/drm/card*-HDMI-*; do
        [ -e "$c/status" ] || continue
        if [ "$(cat $c/status 2>/dev/null)" = "connected" ]; then
            CONN_CARD=$(echo "$c" | sed -nE "s|^/sys/class/drm/(card[0-9]+)-.*|\\1|p")
            CONN_OUTPUT=$(basename "$c" | sed -nE "s|^card[0-9]+-(.*)|\\1|p")
            break 2
        fi
    done
    try=$((try + 1))
    sleep 0.25
done

if [ -z "$CONN_CARD" ]; then
    # NEVER wipe existing Xorg config — a transient detect-fail must not brick the next boot.
    echo "  no connected display this boot — keeping existing config"
    exit 0
fi

echo "  connected: $CONN_CARD ($CONN_OUTPUT)"

# Sky1 only from here on (2026-10-06). The unit is disabled on amd64, but greetd's drop-in
# (55-greeter.sh) Wants= it, so it still ran there every boot and pinned the Sky1 layout on PC
# hardware: MEASURED on CHIMERA (MacBookPro16,1, i915 card0 + amdgpu card1) and PEGASUS (ASUS
# GU502, i915 card0 + NVIDIA) -- both had /etc/udev/rules.d/73-cixmini-primary-display.rules
# stripping master-of-seat from every other card (on PEGASUS that is the NVIDIA GPU, which drives
# the HDMI port) plus an Xorg kmsdev pin. The rule is written after coldplug, so it applies at the
# NEXT boot to whatever card numbering that boot gets. On PC hardware keep only the bounded wait
# above: greetd's ExecCondition (ncz-has-drm-output) checks once, and amdgpu on CHIMERA publishes
# its eDP connector ~7 s into userspace, so this wait is what keeps the greeter from being skipped.
case "$(uname -m)" in
    aarch64|arm64) ;;
    *) echo "  $(uname -m): connected-output wait only; no Sky1 card pin written"; exit 0 ;;
esac

mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/10-cixmini-primary-display.conf <<XCONF
Section "ServerLayout"
    Identifier "Cixmini"
    Screen "PrimaryScreen"
EndSection
Section "Device"
    Identifier "PrimaryDevice"
    Driver "modesetting"
    Option "kmsdev" "/dev/dri/$CONN_CARD"
EndSection
Section "Screen"
    Identifier "PrimaryScreen"
    Device "PrimaryDevice"
    Monitor "PrimaryMonitor"
    DefaultDepth 24
    SubSection "Display"
        Depth 24
    EndSubSection
EndSection
Section "Monitor"
    Identifier "PrimaryMonitor"
    Option "DPMS" "false"
EndSection
Section "ServerFlags"
    Option "BlankTime"   "0"
    Option "StandbyTime" "0"
    Option "SuspendTime" "0"
    Option "OffTime"     "0"
    Option "AutoAddGPU"  "false"
    Option "DefaultServerLayout" "Cixmini"
EndSection
XCONF

{
  echo "# Auto-generated $(date -u) — keep master-of-seat ONLY on $CONN_CARD"
  for n in 0 1 2 3 4 5 6 7; do
      [ "card$n" = "$CONN_CARD" ] && continue
      echo "ACTION==\"add|change\", SUBSYSTEM==\"drm\", KERNEL==\"card$n\", TAG-=\"master-of-seat\", TAG-=\"seat\""
      echo "ACTION==\"add|change\", SUBSYSTEM==\"drm\", KERNEL==\"card$n-*\", TAG-=\"master-of-seat\", TAG-=\"seat\""
  done
} > /etc/udev/rules.d/73-cixmini-primary-display.rules
udevadm control --reload-rules 2>/dev/null
echo "  -> /dev/dri/$CONN_CARD pinned"
DET
chmod 0755 /usr/local/lib/cix-installer/detect-primary-display.sh

cat > /etc/systemd/system/cix-detect-display.service <<UNIT
[Unit]
Description=NCZ Sky1 connected-display autodetect
DefaultDependencies=no
After=systemd-udev-settle.service
# Do not hold basic.target: USB recovery is on greetd's critical path and can
# run while the asynchronous DRM connector probe is resolving.  greetd itself
# has an explicit After= dependency on this service (installed by 55-greeter),
# so the compositor can never start before the connected DRM card is known.
Before=display-manager.service lightdm.service
RequiresMountsFor=/var/log

[Service]
Type=oneshot
ExecStart=/usr/local/lib/cix-installer/detect-primary-display.sh
RemainAfterExit=true
TimeoutStartSec=60

[Install]
WantedBy=sysinit.target
UNIT
# ARCH GATE (2026-09-29). This unit is "NCZ Sky1 connected-display
# autodetect" and exists for Sky1's ASYNCHRONOUS linlondp probe (see this
# hook's own header). Nothing gated it, so it also ran on amd64, where DRM
# probing is synchronous and there is nothing to wait for.
#
# MEASURED on MEDUSA (MacBookPro16,1) 2026-09-29, systemd-analyze blame:
#     7.428s cix-detect-display.service
# -- the second-largest unit on the boot, ~19% of a 39.7s userspace boot, on
# a machine the service cannot help. It was also visible doing nothing useful
# on CHIMERA's 7.3-rc5 debug boot.
_ncz_arch="${NCZ_TARGET_ARCH:-}"
[ -n "$_ncz_arch" ] || _ncz_arch=$(cat /usr/local/lib/cix-installer/BUILD_ARCH 2>/dev/null | tr -d '[:space:]')
[ -n "$_ncz_arch" ] || _ncz_arch=$(dpkg --print-architecture 2>/dev/null || true)
if [ "$_ncz_arch" = "arm64" ]; then
    systemctl enable cix-detect-display.service 2>&1 | tail -1
else
    systemctl disable cix-detect-display.service >/dev/null 2>&1 || true
    echo "[22] arch=$_ncz_arch -- cix-detect-display NOT enabled (Sky1 linlondp async probe only)"
fi

# Mask the CIX factory display watchdog. cix-debian-misc ships
# cix-check-display.service -> /usr/bin/restart-display, hardcoded to
# GNOME/gdm3; on our lightdm+XFCE stack it fails every boot with
# "Unit gdm3.service not found" (operator-reported 2026-06-25 on r131).
# Our cix-detect-display.service above handles display bring-up. Mask via a
# /etc symlink to /dev/null so it wins even though cix-debian-misc installs
# later (25-cix-proprietary.sh).
ln -sf /dev/null /etc/systemd/system/cix-check-display.service
echo "[22] masked vendor cix-check-display.service (GNOME-only; we use lightdm+XFCE)"

# Run once during install -- Sky1 only. On amd64 the install-time run saw the INSTALLER's DRM
# devices through the bind-mounted /sys and wrote a card pin for the installed system.
if [ "$_ncz_arch" = "arm64" ]; then
    /usr/local/lib/cix-installer/detect-primary-display.sh
fi

echo "[22] dynamic primary-display detector installed (retry loop + safe-on-fail)"
