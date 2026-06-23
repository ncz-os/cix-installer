#!/bin/bash
# 99-diagnostics.sh — final state dump for post-install forensics.
#
# Runs LAST (after 70-bootloader's EXIT trap has finalized the
# loader entries). Captures install-time state to /var/log/cix-install/
# so that:
#   - rescue.target boot can ssh in (35-ssh.sh drops sshd into rescue
#     too) and read these
#   - SAFE-rescue from USB can mount NVMe and read these
#   - normal-boot from a working kernel can show "what happened during
#     install" via cat /var/log/cix-install/*
#
# Failure-tolerant: this hook NEVER aborts run-all.sh. If something
# can't be captured (binary missing, file unreadable), log "MISSING"
# and continue.
set +e

OUT=/var/log/cix-install
mkdir -p "$OUT"

stamp() { echo "=== $1 (collected at $(date -u +%FT%TZ)) ==="; }

{
    stamp "uname -a"
    uname -a 2>&1
    echo ""
    stamp "uptime"
    uptime 2>&1
    echo ""
    stamp "free -m"
    free -m 2>&1
    echo ""
    stamp "lsblk"
    lsblk 2>&1
    echo ""
    stamp "blkid"
    blkid 2>&1
    echo ""
    stamp "mount"
    mount 2>&1
    echo ""
    stamp "df -h"
    df -h 2>&1
    echo ""
    stamp "fdisk -l (NVMe + SATA)"
    fdisk -l /dev/nvme* /dev/sd* 2>/dev/null
} > "$OUT/disk-state.log" 2>&1

{
    stamp "bootctl status"
    bootctl status 2>&1 || echo "MISSING bootctl"
    echo ""
    stamp "bootctl list"
    bootctl list 2>&1 || true
    echo ""
    stamp "efibootmgr -v"
    efibootmgr -v 2>&1 || echo "MISSING efibootmgr or no efivarfs"
    echo ""
    stamp "/boot/efi tree"
    find /boot/efi -maxdepth 4 -ls 2>&1 | head -200
    echo ""
    stamp "/boot/efi/loader/loader.conf"
    cat /boot/efi/loader/loader.conf 2>&1
    echo ""
    stamp "/boot/efi/loader/entries/*.conf"
    for f in /boot/efi/loader/entries/*.conf; do
        echo "--- $f ---"
        cat "$f" 2>&1
        echo ""
    done
    echo ""
    stamp "/boot directory"
    ls -la /boot/ 2>&1
} > "$OUT/bootloader-state.log" 2>&1

{
    stamp "dmesg (last 500 lines, install-time)"
    dmesg -T 2>&1 | tail -500
} > "$OUT/dmesg-install.log" 2>&1

{
    stamp "loaded kernel modules"
    lsmod 2>&1 | head -100
    echo ""
    stamp "/lib/modules/ trees"
    ls -la /lib/modules/ 2>&1
} > "$OUT/modules-state.log" 2>&1

{
    stamp "systemctl --failed"
    systemctl --failed 2>&1 || true
    echo ""
    stamp "systemctl is-enabled key services"
    for svc in ssh ssh.socket systemd-networkd NetworkManager; do
        echo "--- $svc ---"
        systemctl is-enabled "$svc" 2>&1
        systemctl is-active "$svc" 2>&1
    done
} > "$OUT/services-state.log" 2>&1

{
    stamp "ip addr"
    ip addr 2>&1
    echo ""
    stamp "ip route"
    ip route 2>&1
    echo ""
    stamp "/etc/resolv.conf"
    cat /etc/resolv.conf 2>&1
} > "$OUT/network-state.log" 2>&1

{
    stamp "/etc/cix-installer/ contents"
    ls -la /etc/cix-installer/ 2>&1
    echo ""
    for f in BUILD_VERSION BUILD_DATE BUILD_HOST KVER_LTS KVER_NEXT; do
        echo "--- /etc/cix-installer/$f ---"
        cat "/etc/cix-installer/$f" 2>&1 || echo "(missing)"
        echo ""
    done
} > "$OUT/cix-installer-meta.log" 2>&1

# ---- INDEX file --------------------------------------------------------
# Top-level summary pointing at every diagnostic. Read this first if
# you're in rescue mode trying to figure out what went wrong.
cat > /etc/cix-installer/DIAGNOSTICS.md <<'INDEX'
# Post-install diagnostics — nclawzero cixmini

If the system wedges during boot, mount this filesystem from rescue
mode (USB SAFE rescue OR cixmini-rescue.conf systemd-boot entry) and
read the per-stage logs below.

## Per-hook install logs

`/var/log/cix-install/<hook>.log` — one log per post-install hook,
collected by run-all.sh as each hook ran.

| Log | What it captures |
|---|---|
| 10-our-kernel.log | kernel image install + modules extraction |
| 12-sky1-firmware.log | firmware blob copy to /lib/firmware |
| 20-desktop.log | XFCE / GNOME install |
| 25-cix-proprietary.log | Cix vendor debs (filtered for vermagic) |
| 30-agents.log | agent stack quadlets |
| 32-quadlet-shim.log | systemd quadlet shim |
| 35-ssh.log | openssh-server + authorized_keys |
| 40-claude-code.log | Claude Code install |
| 50-brand.log | branding assets |
| 60-plymouth.log | Plymouth splash |
| 70-bootloader.log | systemd-boot install + loader entries |
| 99-diagnostics.log | this hook (its own output) |

## Captured runtime state

| Log | What |
|---|---|
| disk-state.log | lsblk, blkid, mount, fdisk -l |
| bootloader-state.log | bootctl status, efibootmgr, loader entries, /boot tree |
| dmesg-install.log | last 500 lines of dmesg at install end |
| modules-state.log | lsmod + /lib/modules/ trees |
| services-state.log | systemctl --failed + service enable state |
| network-state.log | ip addr, ip route, resolv.conf |
| cix-installer-meta.log | BUILD_VERSION + KVER sidecars |

## Build identification

| File | Contains |
|---|---|
| /etc/cix-installer/BUILD_VERSION | e.g. "2026.05.03-r8" |
| /etc/cix-installer/BUILD_DATE | UTC build timestamp |
| /etc/cix-installer/BUILD_HOST | host that built the ISO |
| /etc/cix-installer/KVER_LTS | LTS kernel uname -r |
| /etc/cix-installer/KVER_NEXT | NEXT (BETA) kernel uname -r |

## How to read these from rescue mode

### Option 1 — boot SAFE rescue (cixmini-rescue.conf)
sshd starts in rescue.target via /etc/systemd/system/ssh.service.d/run-in-rescue.conf.
Once at the rescue prompt or after ssh root@<ip>:

  ls /var/log/cix-install/
  cat /var/log/cix-install/70-bootloader.log
  cat /etc/cix-installer/DIAGNOSTICS.md

### Option 2 — USB SAFE rescue (d-i rescue mode)
At rescue menu, mount root partition (/dev/nvme0n1p2 typically) as /mnt:

  mount /dev/nvme0n1p2 /mnt
  ls /mnt/var/log/cix-install/

### Option 3 — normal boot worked, just want diagnostics
Just `cat /var/log/cix-install/*` as root. /etc/cix-installer/DIAGNOSTICS.md
is the index.

## d-i upstream logs (also on disk)

`/var/log/installer/` — Debian-installer's own logs (syslog, partman,
hardware-summary, status, etc.). Copied here by d-i's finish-install
step. Useful if a hook ran but d-i framework had an issue.
INDEX

echo "[99] diagnostic dump complete:"
ls -la "$OUT"/ 2>&1 | head -20
echo ""
echo "[99] index file: /etc/cix-installer/DIAGNOSTICS.md"
echo "[99] DONE"
