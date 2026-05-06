#!/bin/bash
# 35-fstrim-fix.sh — exclude vfat (/boot/efi) from systemd fstrim.
# Cix Sky1 EFI partition returns I/O error on FITRIM ioctl; weekly
# fstrim.timer otherwise marks fstrim.service failed forever.
set +e
mkdir -p /etc/systemd/system/fstrim.service.d
cat > /etc/systemd/system/fstrim.service.d/no-vfat.conf << 'EOF'
[Service]
ExecStart=
ExecStart=/usr/sbin/fstrim --listed-in /etc/fstab:/proc/self/mountinfo --types ext4,btrfs,xfs,f2fs,zfs --verbose --quiet-unsupported
EOF
systemctl daemon-reload 2>&1 | tail -1
echo "[35] fstrim drop-in: skips vfat /boot/efi (FITRIM unsupported on Cix Sky1 ESP)"
