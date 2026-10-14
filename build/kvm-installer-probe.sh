#!/bin/bash
# kvm-installer-probe.sh -- sample the RUNNING installer of a KVM gate guest over
# its diagnostics SSH (root / documented diag login, docs/RECOVERY-LOGINS.md)
# and judge the samples afterwards.
#
#   kvm-installer-probe.sh sample PORT OUT [INTERVAL]
#       loop until killed: every INTERVAL s (default 15) log in to
#       root@127.0.0.1:PORT and append one sample block to OUT. Runs in the
#       background of phase 1; the caller kills it by PID. It also stops on
#       its own once the process that started it is gone, so an interrupted
#       gate never leaves it running.
#   kvm-installer-probe.sh judge OUT
#       exit 0 when at least one sample was taken while main-menu ran, no
#       sample shows brltty (process, a brltty line in the installer syslog,
#       binary, udev rules, d-i hooks, the framebuffer-off hook S20brltty) and
#       tty1 is never narrower than tty2;
#       exit 1 otherwise, naming the finding.
#
# Why: the installer must never start brltty or clamp the console. brltty-udeb
# (removed from the initrd by build/iso/patch-initrd-t2-kernel.py) started brltty
# from its S37brltty startup hook whenever "brltty" appeared on the cmdline and
# from its udev rules for a set of USB ids (a USB braille display, and generic
# USB-serial chips); brltty.sh then ran `stty cols 80 < /dev/tty1` and turned the
# framebuffer frontend off. The gate attaches an emulated usb-braille (Baum,
# 0403:fe72) and usb-serial (FTDI, 0403:6001) so both udev paths are exercised.
# tty1 is compared with tty2 because only tty1 is clamped: both are created at
# the same native size, so a narrower tty1 is the clamp whatever the font or
# framebuffer resolution.
#
# The password is the documented diagnostics login (override: NCZ_GATE_DIAG_PW).
set -uo pipefail
MODE="${1:?usage: kvm-installer-probe.sh sample PORT OUT [INTERVAL] | judge OUT}"

remote_sample='
echo "uptime $(cut -d" " -f1 /proc/uptime)"
echo "main_menu $(pidof main-menu >/dev/null 2>&1 && echo yes || echo no)"
echo "brltty_pid $(pidof brltty 2>/dev/null || echo none)"
for f in /usr/bin/brltty /bin/brltty /usr/lib/udev/rules.d/brltty.rules /lib/udev/rules.d/brltty.rules \
         /usr/lib/debian-installer-startup.d/S37brltty /lib/debian-installer.d/S19brltty \
         /lib/debian-installer.d/S20brltty /var/run/brltty.pid /var/run/brltty-generic; do
    [ -e "$f" ] && echo "brltty_file $f"
done
echo "tty1 $(stty -F /dev/tty1 size 2>/dev/null || echo unknown)"
echo "tty2 $(stty -F /dev/tty2 size 2>/dev/null || echo unknown)"
echo "cmdline $(cat /proc/cmdline)"
for d in /sys/bus/usb/devices/*; do
    [ -f "$d/idVendor" ] && echo "usb $(basename "$d") $(cat "$d/idVendor"):$(cat "$d/idProduct") $(cat "$d/product" 2>/dev/null)"
done
grep -i -E "brltty|braille" /var/log/syslog 2>/dev/null | head -5 | sed "s/^/syslog /"
dmesg 2>/dev/null | grep -i -E "usb [0-9]|braille|brltty" | head -40 | sed "s/^/dmesg /"
'

case "$MODE" in
sample)
    PORT="${2:?port}"; OUT="${3:?out}"; INTERVAL="${4:-15}"
    command -v sshpass >/dev/null 2>&1 || { echo "probe: sshpass not installed" >> "$OUT"; exit 2; }
    export SSHPASS="${NCZ_GATE_DIAG_PW:-rescue}"
    parent=$PPID
    n=0
    while kill -0 "$parent" 2>/dev/null; do
        n=$((n + 1))
        if blk="$(timeout 20 sshpass -e ssh -p "$PORT" -o StrictHostKeyChecking=no \
                -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 \
                -o PubkeyAuthentication=no root@127.0.0.1 "$remote_sample" 2>/dev/null)"; then
            { echo "=== sample $n $(date -u +%H:%M:%SZ)"; printf '%s\n' "$blk"; } >> "$OUT"
        fi
        sleep "$INTERVAL"
    done
    ;;
judge)
    OUT="${2:?out}"
    [ -s "$OUT" ] || { echo "probe: no sample: the installer diagnostics SSH never answered (cannot prove brltty stayed off)"; exit 1; }
    awk '
        /^=== sample/ { s++; mm[s] = "no" }
        /^main_menu / { mm[s] = $2 }
        /^brltty_pid / && $2 != "none" { pid[s] = $2 }
        /^brltty_file / { f[s] = f[s] " " $2 }
        /^syslog .*brltty\[[0-9]+\]/ { started[s] = 1 }
        /^tty1 / { t1r[s] = $2; t1c[s] = $3 }
        /^tty2 / { t2r[s] = $2; t2c[s] = $3 }
        END {
            ok = 0; bad = 0; maxc = 0
            for (i = 1; i <= s; i++) {
                if (mm[i] != "yes") continue
                ok++
                if (pid[i] != "") { printf "probe: sample %d: brltty is running (pid %s)\n", i, pid[i]; bad = 1 }
                if (f[i] != "") { printf "probe: sample %d: brltty files present:%s\n", i, f[i]; bad = 1 }
                if (started[i]) { printf "probe: sample %d: the installer syslog shows brltty ran\n", i; bad = 1 }
                if (t1c[i] ~ /^[0-9]+$/ && t2c[i] ~ /^[0-9]+$/ && t1c[i] + 0 < t2c[i] + 0) {
                    printf "probe: sample %d: tty1 clamped to %s columns (tty2 has %s)\n", i, t1c[i], t2c[i]; bad = 1
                }
                if (t1c[i] ~ /^[0-9]+$/ && t1c[i] + 0 > maxc) maxc = t1c[i] + 0
            }
            if (ok == 0) { print "probe: no sample was taken while main-menu ran"; exit 1 }
            if (bad) exit 1
            printf "probe: %d installer sample(s): no brltty, tty1 %d columns, not clamped\n", ok, maxc
        }' "$OUT"
    ;;
*) echo "usage: kvm-installer-probe.sh sample PORT OUT [INTERVAL] | judge OUT" >&2; exit 2 ;;
esac
