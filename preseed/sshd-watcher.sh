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

# 2026-05-07 take11: append fallback nameservers to d-i's /etc/resolv.conf
# once DHCP has populated it. The LAN router (192.168.207.1) is the
# DHCP-provided primary on the .66 fleet; if its DNS service is flaky
# (observed dropping queries during pkgsel + grub-installer batch
# fetches), apt-get errors with "Temporary failure resolving" and the
# whole download batch aborts. With 8.8.8.8 + 1.1.1.1 appended,
# resolver auto-fails-over within ~6s instead of giving up.
#
# Polls 30s for resolv.conf to be non-empty (DHCP completion), then
# appends fallbacks if not already present. Idempotent.
(
    j=0
    while [ "$j" -lt 30 ]; do
        if [ -s /etc/resolv.conf ] && grep -q '^nameserver ' /etc/resolv.conf; then
            grep -q '^nameserver 8\.8\.8\.8' /etc/resolv.conf || \
                echo 'nameserver 8.8.8.8' >> /etc/resolv.conf
            grep -q '^nameserver 1\.1\.1\.1' /etc/resolv.conf || \
                echo 'nameserver 1.1.1.1' >> /etc/resolv.conf
            grep -q '^options ' /etc/resolv.conf || \
                echo 'options timeout:2 attempts:3' >> /etc/resolv.conf
            echo "[watcher] /etc/resolv.conf fallbacks appended at j=$j:"
            cat /etc/resolv.conf | sed 's/^/    /'
            break
        fi
        sleep 1
        j=$((j + 1))
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
