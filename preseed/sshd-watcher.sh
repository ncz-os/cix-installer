#!/bin/sh
# sshd-watcher.sh — late-arming SSH-config patch for d-i network-console.
#
# Spawned in background by preseed/early_command. The d-i environment
# does NOT have sshd up at preseed-load time — network-console installs
# the openssh-server udeb later. So we poll for sshd_config + a running
# sshd process up to 600 seconds, then patch PermitRootLogin yes +
# PubkeyAuthentication yes and HUP sshd to reload its config.
#
# Without this, root@<host> login via fleet pubkey doesn't work during
# install (only installer@<host> with the password) — operator can't
# remote-diagnose a failing install.
#
# 2026-05-07 (Codex r78 audit): kept as separate file (not heredoc'd
# into preseed early_command) because d-i's preseed parser may
# truncate multi-line values at the first non-continuation line, and
# heredoc body lines don't end in backslash. Easier to ship + maintain
# as a standalone script.
#
# Runs entirely under busybox 1.35 in d-i initrd. Uses only:
#   sh, sed, grep, pidof, ps, kill, sleep, date, echo, exec, [
# All present as busybox applets.

set +e
exec >> /var/log/early_command.log 2>&1
echo "[watcher] start $(date -u +%FT%TZ) pid=$$"

# 2026-05-07 take12: CONTINUOUSLY append fallback nameservers to d-i's
# /etc/resolv.conf, surviving DHCP renewals. The LAN router on the .66
# fleet (Island Router Pro at 192.168.207.1) is the DHCP-provided primary
# resolver, and its DNS proxy drops queries under apt batch load. Even
# with the router's UPSTREAM set to Cloudflare, the router's local
# proxy/cache is the one that dies — we need to bypass it entirely from
# the d-i client.
#
# Take11 used a 30s-bounded poll. That hit a race where DHCP completion
# arrived after the poll timed out, OR DHCP renewal at +5min clobbered
# our appended lines. Take12 runs forever (until d-i is shut down):
# every 10s, ensure 8.8.8.8 + 1.1.1.1 + options are present in
# /etc/resolv.conf. Idempotent (grep guards).
(
    while true; do
        if [ -s /etc/resolv.conf ] && grep -q '^nameserver ' /etc/resolv.conf; then
            grep -q '^nameserver 8\.8\.8\.8' /etc/resolv.conf || {
                echo 'nameserver 8.8.8.8' >> /etc/resolv.conf
                echo "[watcher] $(date -u +%FT%TZ) appended 8.8.8.8 to /etc/resolv.conf"
            }
            grep -q '^nameserver 1\.1\.1\.1' /etc/resolv.conf || {
                echo 'nameserver 1.1.1.1' >> /etc/resolv.conf
                echo "[watcher] $(date -u +%FT%TZ) appended 1.1.1.1 to /etc/resolv.conf"
            }
            grep -q '^options ' /etc/resolv.conf || {
                echo 'options timeout:2 attempts:3' >> /etc/resolv.conf
                echo "[watcher] $(date -u +%FT%TZ) appended options to /etc/resolv.conf"
            }
        fi
        sleep 10
    done
) &

i=0
while [ "$i" -lt 600 ]; do
    if [ -f /etc/ssh/sshd_config ] && pidof sshd >/dev/null 2>&1; then
        echo "[watcher] sshd live + sshd_config present at i=$i"

        sed -i \
            -e 's|^[[:space:]]*#*[[:space:]]*PermitRootLogin.*|PermitRootLogin yes|' \
            -e 's|^[[:space:]]*#*[[:space:]]*PubkeyAuthentication.*|PubkeyAuthentication yes|' \
            /etc/ssh/sshd_config

        grep -q '^PermitRootLogin yes' /etc/ssh/sshd_config \
            || echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
        grep -q '^PubkeyAuthentication yes' /etc/ssh/sshd_config \
            || echo 'PubkeyAuthentication yes' >> /etc/ssh/sshd_config

        # Primary mechanism: kill -HUP makes sshd re-read config.
        # /etc/init.d/ssh fallbacks are guarded with 2>/dev/null; if
        # network-console didn't materialize the wrapper, they fail
        # silently (busybox d-i initrd lacks /etc/init.d/ssh by default,
        # but post-udeb-unpack the wrapper may exist).
        # shellcheck disable=SC2046
        kill -HUP $(pidof sshd) 2>/dev/null
        /etc/init.d/ssh restart 2>/dev/null
        /etc/init.d/ssh reload 2>/dev/null

        echo "[watcher] post-patch sshd_config:"
        grep -E '^(PermitRootLogin|PubkeyAuthentication)' /etc/ssh/sshd_config
        echo "[watcher] post-patch sshd procs:"
        # shellcheck disable=SC2009  # busybox d-i has no pgrep
        ps | grep -E '[s]shd' | head -5
        echo "[watcher] done $(date -u +%FT%TZ)"
        exit 0
    fi
    sleep 1
    i=$((i + 1))
done

echo "[watcher] TIMEOUT after 600s — sshd never came up"
exit 1
