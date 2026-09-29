#!/bin/bash
# 97-firstboot-report.sh -- record which systemd units failed on the installed system's FIRST boot.
#
# Installs a oneshot unit that, 30 s after multi-user.target, writes `systemctl --failed` to
# /var/log/ncz-first-boot-failed.txt once. The KVM gate reads that file from the installed disk
# (build/kvm-install-gate-gpt.sh) so a unit that fails only on first boot (ldconfig.service on
# 18e8a14: "Renaming of /etc/ld.so.cache~ ... failed") is caught before an image ships.
# Runs inside the target chroot; arch-neutral.
set -uo pipefail
echo "[97] installing the first-boot failed-unit report"
install -d -m0755 /etc/systemd/system/multi-user.target.wants
cat > /etc/systemd/system/ncz-firstboot-report.service <<'UNIT'
[Unit]
Description=Record failed units after the first boot (NCZ gate evidence)
After=multi-user.target network-online.target
ConditionPathExists=!/var/log/ncz-first-boot-failed.txt

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'sleep 30; { date -u +"# first boot report %FT%TZ"; systemctl --failed --no-legend --plain --no-pager; echo "# end"; } > /var/log/ncz-first-boot-failed.txt 2>&1; sync'
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
UNIT
ln -sf /etc/systemd/system/ncz-firstboot-report.service /etc/systemd/system/multi-user.target.wants/ncz-firstboot-report.service
echo "[97] ncz-firstboot-report.service enabled"
