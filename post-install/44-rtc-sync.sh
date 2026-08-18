#!/bin/bash
# 44-rtc-sync.sh — make the RTC hold real time across a flash.
#
# THE PROBLEM (measured on O6N, 2026-08-17, reproduced on every flash):
#
#   RTC time: Fri 2024-08-30 03:36:48      <- firmware default, ~2 years stale
#   Local time: Mon 2026-08-17 23:43:10    <- correct, NTP had fixed it
#   RTC in local TZ: yes                   <- wrong for a UEFI/Linux box
#   $ hwclock
#   sudo: hwclock: command not found
#
# and in dmesg, every boot:
#   rtc-efi rtc-efi.0: setting system clock to 2024-08-30T00:17:32 UTC
#
# So each fresh install boots believing it is 2024, because the kernel seeds
# the system clock from an RTC nobody ever wrote. NTP later corrects the
# SYSTEM clock, but nothing propagates that back to the RTC, so the next boot
# starts in 2024 again -- and until timesyncd wins the race, anything that
# validates a TLS certificate (apt, curl, git) fails against a clock two years
# in the past. That is the recurring "RTC issue after flashing".
#
# WHY IT WAS NEVER WRITTEN — two independent causes, both fixed here:
#
#   1. hwclock is NOT shipped. Debian moved it out of util-linux into
#      util-linux-extra, which is in neither the desktop nor the server
#      manifest, so the standard system->RTC path did not exist on the target.
#
#   2. The RTC was configured in LOCAL time. systemd treats a local-time RTC
#      as a legacy dual-boot concession and warns against it; on a UEFI-only
#      board there is no reason for it.
#
# The RTC itself is NOT read-only, which was the obvious suspicion given ARM
# UEFI firmwares that stub out the SetTime runtime service. Tested directly on
# O6N: `hwclock -w` succeeded and the RTC read back correct immediately. The
# hardware was always fine; the software simply never asked.
set -uo pipefail

echo "[44] RTC: make the hardware clock hold real time across reboots"

# ---------------------------------------------------------------------------
# 1. hwclock, via util-linux-extra.
# ---------------------------------------------------------------------------
if ! command -v hwclock >/dev/null 2>&1; then
    # Simulated first per standing rule: never let a convenience install
    # amputate packages.
    _remv=$(apt-get install -y -s util-linux-extra 2>/dev/null | grep -c '^Remv' || true)
    if [ "${_remv:-1}" = "0" ]; then
        if apt-get install -y util-linux-extra >/dev/null 2>&1; then
            echo "[44]   installed util-linux-extra (provides hwclock)"
        else
            echo "[44]   WARN: could not install util-linux-extra — falling back to systemd only"
        fi
    else
        echo "[44]   WARN: skipping util-linux-extra — apt wanted to REMOVE $_remv package(s)"
    fi
fi

# ---------------------------------------------------------------------------
# 2. RTC keeps UTC, not local time.
# ---------------------------------------------------------------------------
if command -v timedatectl >/dev/null 2>&1; then
    if timedatectl set-local-rtc 0 >/dev/null 2>&1; then
        echo "[44]   RTC set to UTC (was local time)"
    else
        echo "[44]   note: timedatectl set-local-rtc failed (no dbus in chroot?) — writing adjtime directly"
        printf '0.0 0 0.0\n0\nUTC\n' > /etc/adjtime
    fi
else
    printf '0.0 0 0.0\n0\nUTC\n' > /etc/adjtime
    echo "[44]   RTC set to UTC via /etc/adjtime"
fi

# ---------------------------------------------------------------------------
# 3. Seed the RTC now, but ONLY from a system clock worth trusting.
#
# Writing an unsynced clock would just persist a different wrong time. In the
# installer chroot there is usually no NTP yet, so this is deliberately
# conservative: write only if the clock is already sane. The boot-time unit
# below is what actually fixes it on the installed system.
# ---------------------------------------------------------------------------
_now_year=$(date -u +%Y 2>/dev/null || echo 1970)
if [ "$_now_year" -ge 2026 ] 2>/dev/null; then
    if command -v hwclock >/dev/null 2>&1 && hwclock --systohc --utc >/dev/null 2>&1; then
        echo "[44]   seeded RTC from system clock ($(date -u '+%Y-%m-%d %H:%M UTC'))"
    fi
else
    echo "[44]   system clock reads $_now_year — not seeding RTC from an untrusted clock"
fi

# ---------------------------------------------------------------------------
# 4. Persist it: write the RTC once NTP has actually synchronised.
#
# systemd's 11-minute-mode does update the RTC once an NTP client marks the
# clock synchronised, but that is exactly what was NOT happening here, and a
# board that is powered off before the first sync keeps the stale RTC. This
# unit closes that gap explicitly and cheaply: it runs after
# time-sync.target, so by then the clock is trustworthy.
# ---------------------------------------------------------------------------
cat > /etc/systemd/system/ncz-rtc-sync.service <<'UNIT'
[Unit]
Description=Write the synchronised system clock back to the RTC
Documentation=man:hwclock(8)
# WAIT FOR AN ACTUAL SYNC, NOT JUST FOR THE TARGET.
#
# time-sync.target is reached when the time subsystem is UP, which is NOT the
# same as the clock having been corrected. MEASURED on a v12 install (O6N,
# 2026-08-18): this unit ran at boot, found NTPSynchronized=no, skipped, and
# exited 0 -- and because it is a oneshot it never ran again. NTP synced
# seconds later, so the system clock was right while the RTC stayed at the
# 2024 firmware default, which is the exact bug this hook exists to fix. The
# journal shows it plainly: the unit's own log lines are stamped
# "Jul 23 18:31:58" -- i.e. it ran while the clock was still wrong.
#
# systemd-time-wait-sync.service BLOCKS until the clock is actually
# synchronised, so ordering after it means the check below can succeed.
After=systemd-time-wait-sync.service time-sync.target systemd-timesyncd.service
Wants=systemd-time-wait-sync.service time-sync.target
ConditionPathExists=/dev/rtc0

[Service]
Type=oneshot
RemainAfterExit=no
# Only write when the clock is actually synchronised; otherwise this would
# faithfully persist the wrong time. Retry rather than give up: on a board
# whose RTC is years out, the first boot is exactly when this matters, and a
# single missed attempt leaves the stale RTC in place until someone notices.
ExecStart=/bin/sh -c 'for i in 1 2 3 4 5 6 7 8 9 10 11 12; do \
    if [ "$(timedatectl show -p NTPSynchronized --value)" = "yes" ]; then \
        hwclock --systohc --utc && echo "RTC written: $(hwclock -r 2>/dev/null)" && exit 0; \
    fi; \
    sleep 10; \
done; \
echo "NTP never synchronised within 120s — RTC left unchanged" >&2; exit 0'

[Install]
WantedBy=multi-user.target
UNIT

systemctl enable ncz-rtc-sync.service >/dev/null 2>&1 \
    && echo "[44]   enabled ncz-rtc-sync.service (writes RTC after each NTP sync)" \
    || echo "[44]   WARN: could not enable ncz-rtc-sync.service"

echo "[44]   RTC now: $(hwclock -r 2>/dev/null || echo 'unreadable')"
exit 0
