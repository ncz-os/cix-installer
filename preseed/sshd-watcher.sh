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

# 2026-05-08 take15: install a custom /etc/udhcpc/default.script that
# unconditionally writes /etc/resolv.conf with our 3-nameserver chain
# (8.8.8.8 + 1.1.1.1 + DHCP-provided). udhcpc on bookworm d-i runs
# this script on every DHCP bound|renew|deconfig event. By replacing
# the script BEFORE DHCP runs (early_command fires before netcfg),
# our resolv.conf survives every renewal natively — no backgrounded
# subshell that could die when parent exits, no race with the DHCP
# clobberer.
#
# Take11/take12 used a backgrounded `( while true ) &` watcher.
# Operator-confirmed evidence on .66 (resolv.conf had only the LAN
# router IP after several minutes) suggests the subshell didn't
# survive parent exit on busybox 1.35 ash. The udhcpc script approach
# avoids the daemonization problem entirely.
mkdir -p /etc/udhcpc
cat > /etc/udhcpc/default.script <<'UDHCPCDEFAULT'
#!/bin/sh
# nclawzero d-i custom udhcpc script — installs resolv.conf with
# fallback nameservers (8.8.8.8 + 1.1.1.1) ALWAYS present, regardless
# of what DHCP serves. The LAN router DNS may or may not be reliable;
# the public anycast resolvers always are.
#
# Called by udhcpc with $1 in {deconfig, leasefail, nak, bound, renew}
# and DHCP options exposed as env vars (interface, ip, subnet, router,
# dns, domain, ...).

case "$1" in
    bound|renew)
        # Configure the IP + default route from DHCP
        ip addr flush dev "$interface" 2>/dev/null
        ip addr add "$ip/$(echo "$subnet" | awk -F. '{c=0; for(i=1;i<=4;i++){n=$i; while(n){c+=n%2; n=int(n/2)}}; print c}')" dev "$interface" 2>/dev/null \
            || ifconfig "$interface" "$ip" netmask "$subnet" 2>/dev/null
        if [ -n "$router" ]; then
            for r in $router; do
                ip route add default via "$r" 2>/dev/null \
                    || route add default gw "$r" 2>/dev/null
                break
            done
        fi
        # Build resolv.conf with fallback chain
        {
            [ -n "$domain" ] && echo "search $domain"
            for ns in $dns; do
                echo "nameserver $ns"
            done
            echo "nameserver 8.8.8.8"
            echo "nameserver 1.1.1.1"
            echo "options timeout:2 attempts:3"
        } > /etc/resolv.conf
        ;;
    deconfig)
        ip addr flush dev "$interface" 2>/dev/null
        ;;
esac
exit 0
UDHCPCDEFAULT
chmod +x /etc/udhcpc/default.script
echo "[watcher] installed custom /etc/udhcpc/default.script for resolv.conf fallback chain"

# Belt-and-suspenders: write /etc/resolv.conf NOW with fallback nameservers
# in case any d-i step uses DNS BEFORE DHCP populates it. udhcpc will
# overwrite this with the full chain (LAN router + 8.8.8.8 + 1.1.1.1)
# on first bound event.
{
    echo "search nclawzero.lan"
    echo "nameserver 8.8.8.8"
    echo "nameserver 1.1.1.1"
    echo "options timeout:2 attempts:3"
} > /etc/resolv.conf
echo "[watcher] pre-DHCP /etc/resolv.conf seeded with public fallbacks"

# 2026-05-08 take17 (per .66 take16 install failure at 95% / pkgsel
# "Temporary failure resolving 'ports.ubuntu.com'"): the udhcpc
# default.script keeps the d-i RAMDISK /etc/resolv.conf populated
# with our 3-nameserver chain (8.8.8.8 + 1.1.1.1 + LAN router), but
# pkgsel runs in-target chroot and reads /target/etc/resolv.conf,
# which d-i base-installer seeds from netcfg with DHCP-only DNS
# (192.168.207.1 LAN router) — and that clobbers when the router
# DNS goes flaky. Result: 18 of ~30 pkgsel packages fail at once
# with "Temporary failure resolving" inside the chroot.
#
# Fix: continuously sync /etc/resolv.conf → /target/etc/resolv.conf
# every poll tick, so the moment base-installer mounts /target and
# debootstrap creates /target/etc, our 3-nameserver chain is there
# and stays there through every chroot reentry (apt-setup, pkgsel,
# late_command).
TARGET_LAST_SYNC=""
sync_target_resolv() {
    [ -d /target/etc ] || return 0
    if [ ! -f /target/etc/resolv.conf ] \
       || ! cmp -s /etc/resolv.conf /target/etc/resolv.conf 2>/dev/null; then
        cp /etc/resolv.conf /target/etc/resolv.conf 2>/dev/null \
            && TARGET_LAST_SYNC="$(date -u +%H:%M:%S)" \
            && echo "[watcher] synced /target/etc/resolv.conf at $TARGET_LAST_SYNC"
    fi
}

SSHD_PATCHED=0
i=0
while [ "$i" -lt 1800 ]; do
    sync_target_resolv
    if [ "$SSHD_PATCHED" -eq 0 ] && [ -f /etc/ssh/sshd_config ] && pidof sshd >/dev/null 2>&1; then
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
        echo "[watcher] sshd patch DONE $(date -u +%FT%TZ) — continuing /target resolv.conf sync"
        SSHD_PATCHED=1
        # Do NOT exit — keep looping to maintain /target/etc/resolv.conf
        # against pkgsel/apt-setup chroot DNS clobber.
    fi
    sleep 1
    i=$((i + 1))
done

if [ "$SSHD_PATCHED" -eq 0 ]; then
    echo "[watcher] TIMEOUT after 1800s — sshd never came up"
    exit 1
fi
echo "[watcher] TIMEOUT after 1800s with sshd patched — install presumed complete"
exit 0
