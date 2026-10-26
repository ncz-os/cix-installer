#!/bin/bash
# 97-firstboot-report.sh -- record which systemd units failed on the installed system's FIRST boot.
#
# Installs a oneshot unit that, 30 s after multi-user.target, writes `systemctl --failed` to
# /var/log/ncz-first-boot-report.txt once (named ncz-first-boot-failed.txt before 2026-10-26; it is
# a report of the first boot, written whether or not anything failed). The KVM gate reads that file from the installed disk
# (build/kvm-install-gate-gpt.sh) so a unit that fails only on first boot (ldconfig.service on
# 18e8a14: "Renaming of /etc/ld.so.cache~ ... failed") is caught before an image ships.
# Runs inside the target chroot; arch-neutral.
set -uo pipefail
_pm="$(dirname "$0")/lib/progress-msg.sh"; [ -r "$_pm" ] || _pm=/usr/local/lib/cix-installer/post-install/lib/progress-msg.sh
[ -r "$_pm" ] && . "$_pm"
command -v ncz_msg >/dev/null 2>&1 && ncz_msg "First boot: staging the failed-unit report and GPU health check (a few seconds)"
echo "[97] installing the first-boot failed-unit report"
install -d -m0755 /etc/systemd/system/multi-user.target.wants
install -d -m0755 /usr/local/sbin
cat > /usr/local/sbin/ncz-firstboot-report <<'REPORT'
#!/bin/sh
# Evidence for the KVM gate, written once ~30 s after the first multi-user boot:
#   - systemctl --failed
#   - a smoke run of the Bing wallpaper helper (`fetch --if-stale --preferred-only`
#     must exit 0, or 75 when offline). --preferred-only bounds the run to the
#     preferred market's first batch: a full multi-market backfill legitimately
#     runs for minutes and would be killed by the 90 s cap, surfacing as exit
#     124 (which the gate does not accept) on any host whose guest network is
#     merely slow, not broken.
sleep 30
{
    date -u +"# first boot report %FT%TZ"
    systemctl --failed --no-legend --plain --no-pager
    # What the machine boots into: the gate checks these against the install
    # options (graphical + greeter with the desktop, multi-user without it).
    echo "# default-target=$(systemctl get-default 2>/dev/null)"
    echo "# greetd=$(systemctl is-active greetd.service 2>/dev/null)"
    echo "# getty-tty1=$(systemctl is-active getty@tty1.service 2>/dev/null)"
    if [ -x /usr/local/bin/ncz-wallpaper-bing ]; then
        timeout 90 /usr/local/bin/ncz-wallpaper-bing fetch --if-stale --preferred-only > /var/log/ncz-wallpaper-smoke.log 2>&1
        echo "# wallpaper-bing-rc=$?"
    fi
    echo "# end"
} > /var/log/ncz-first-boot-report.txt 2>&1
sync
REPORT
chmod 0755 /usr/local/sbin/ncz-firstboot-report
cat > /etc/systemd/system/ncz-firstboot-report.service <<'UNIT'
[Unit]
Description=Record failed units after the first boot (NCZ gate evidence)
ConditionPathExists=!/var/log/ncz-first-boot-report.txt

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
