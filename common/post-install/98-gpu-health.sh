#!/bin/bash
# 98-gpu-health.sh -- the never-software-render health check (operator policy, 2026-09-29).
#
# If a machine has a GPU it must not render in software. This hook installs:
#   /usr/local/bin/ncz-gpu-hw-present      is there a hardware GPU? (shared answer for every fallback)
#   /usr/bin/ncz-gpu-status                `ncz-gpu-status --require-hardware` runs the EGL/Vulkan probes in the session
#                                          AND a bare environment and fails on llvmpipe/softpipe/swrast/lavapipe
#   ncz-gpu-health.service                 runs that check once per boot; writes /var/log/ncz-gpu-health.log,
#                                          /etc/issue.d/50-ncz-gpu-health.issue (console banner) and FAILS the unit
# A machine with no hardware GPU (a KVM guest) passes with "no GPU: software allowed", so the install gates pass.
# Runs inside the target chroot; common to both architectures.
set -uo pipefail
echo "[98] installing the GPU health check (never software-render)"
SRC=/usr/local/lib/cix-installer/assets/gpu
[ -d "$SRC" ] || SRC=/cdrom/ncz-payload/assets/gpu
if [ ! -f "$SRC/ncz-gpu-hw-present" ] || [ ! -f "$SRC/ncz-gpu-status" ]; then
    echo "[98] ERROR: assets/gpu/ncz-gpu-hw-present or ncz-gpu-status missing under $SRC" >&2
    exit 1
fi
install -d -m0755 /usr/local/bin /etc/issue.d
install -m0755 "$SRC/ncz-gpu-hw-present" /usr/local/bin/ncz-gpu-hw-present
install -m0755 "$SRC/ncz-gpu-status" /usr/bin/ncz-gpu-status
cat > /etc/systemd/system/ncz-gpu-health.service <<'UNIT'
[Unit]
Description=NCZ GPU health: a machine with a GPU must not render in software
# after the GPU stack switcher (Sky1) has bound its driver; harmless where that unit does not exist
After=ncz-gpu-switcher.service systemd-udev-settle.service
Wants=ncz-gpu-switcher.service

[Service]
Type=oneshot
ExecStart=/usr/bin/ncz-gpu-status --require-hardware --quiet
# a hardware GPU with software rendering is a real fault: leave the unit FAILED so `systemctl --failed`, the
# first-boot report and the install gates all show it
StandardError=journal+console

[Install]
WantedBy=multi-user.target
UNIT
install -d -m0755 /etc/systemd/system/multi-user.target.wants
ln -sf /etc/systemd/system/ncz-gpu-health.service /etc/systemd/system/multi-user.target.wants/ncz-gpu-health.service
echo "[98] ncz-gpu-health.service enabled"
exit 0
