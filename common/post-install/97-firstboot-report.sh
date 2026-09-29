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
install -d -m0755 /usr/local/sbin
cat > /usr/local/sbin/ncz-firstboot-report <<'REPORT'
#!/bin/sh
# Evidence for the KVM gate, written once ~30 s after the first multi-user boot:
#   - systemctl --failed
#   - a smoke run of the Bing wallpaper helper (`fetch --if-stale` must exit 0, or 75 when offline)
sleep 30
{
    date -u +"# first boot report %FT%TZ"
    systemctl --failed --no-legend --plain --no-pager
    if [ -x /usr/local/bin/ncz-wallpaper-bing ]; then
        timeout 90 /usr/local/bin/ncz-wallpaper-bing fetch --if-stale > /var/log/ncz-wallpaper-smoke.log 2>&1
        echo "# wallpaper-bing-rc=$?"
    fi
    echo "# end"
} > /var/log/ncz-first-boot-failed.txt 2>&1
sync
REPORT
chmod 0755 /usr/local/sbin/ncz-firstboot-report
cat > /etc/systemd/system/ncz-firstboot-report.service <<'UNIT'
[Unit]
Description=Record failed units after the first boot (NCZ gate evidence)
ConditionPathExists=!/var/log/ncz-first-boot-failed.txt

# Type=simple on purpose: a oneshot in multi-user.target's wants would hold the target (and the
# display manager behind it) for the 30 s sleep, and After=multi-user.target on a unit wanted by
# multi-user.target is an ordering cycle that systemd resolves by dropping the job -- the first
# version of this unit never ran for exactly that reason.
[Service]
Type=simple
ExecStart=/usr/local/sbin/ncz-firstboot-report

[Install]
WantedBy=multi-user.target
UNIT
ln -sf /etc/systemd/system/ncz-firstboot-report.service /etc/systemd/system/multi-user.target.wants/ncz-firstboot-report.service
echo "[97] ncz-firstboot-report.service enabled"
