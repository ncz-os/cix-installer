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

# 2026-05-08 take19 (per Codex DNS deep dive in
# docs/R78-DNS-DEEP-DIVE-2026-05-08.md): the actual fix is to drop
# scripts into d-i's documented hook directories so they run AT the
# right moment in the install flow:
#
#   /usr/lib/base-installer.d/  — fires before base-installer's
#       chrooted apt-get update inside /target. This is the FIRST
#       chroot apt operation, so /target/etc/resolv.conf must be
#       correct here.
#   /usr/lib/pre-pkgsel.d/      — fires immediately before pkgsel
#       package selection runs apt update + install in /target.
#       Belt-and-suspenders against any intervening clobber.
#
# Each hook authoritatively REWRITES /target/etc/resolv.conf as a
# regular file (replacing systemd-resolved's stub-resolv symlink so
# it can't redirect us elsewhere), with the 3-NS chain. Router
# pulled from default-route at hook-fire time.
#
# This replaces the long-running watcher-loop sync approach that
# raced with the 1800s timeout. The hooks fire ONCE, deterministically,
# at the right d-i waypoints. Watcher still maintains sshd_config patch
# + a separate continuous resolv.conf rewrite as belt-and-suspenders.
install_ncz_dns_hooks() {
    mkdir -p /usr/lib/base-installer.d /usr/lib/pre-pkgsel.d

    write_ncz_dns_hook() {
        hook_dir="$1"
        hook_tmp="$hook_dir/.05ncz-dns.$$"
        hook_final="$hook_dir/05ncz-dns"

        rm -f "$hook_tmp"
        cat > "$hook_tmp" <<'NCZDNSHOOK'
#!/bin/sh
# 05ncz-dns — d-i hook: write /target/etc/resolv.conf with public-fallback
# chain BEFORE base-installer or pkgsel runs apt-get inside the chroot.
# Replaces any pre-existing symlink (systemd-resolved stub) with a real file.
set +e
LOG=/var/log/early_command.log
router="$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')"
[ -n "$router" ] || router=192.168.207.1

if [ -d /target/etc ]; then
    rc_tmp="/target/etc/.resolv.conf.ncz.$$"
    rm -f "$rc_tmp"
    cat > "$rc_tmp" <<EOF
search nclawzero.lan
nameserver $router
nameserver 8.8.8.8
nameserver 1.1.1.1
options timeout:2 attempts:3
EOF
    if grep -q '^options timeout:2 attempts:3$' "$rc_tmp" && mv -f "$rc_tmp" /target/etc/resolv.conf; then
        echo "[ncz-dns] wrote /target/etc/resolv.conf router=$router at $(date -u +%FT%TZ)" >> "$LOG"
    else
        rm -f "$rc_tmp"
        echo "[ncz-dns] failed to publish /target/etc/resolv.conf at $(date -u +%FT%TZ)" >> "$LOG"
    fi
else
    echo "[ncz-dns] /target/etc missing at $(date -u +%FT%TZ)" >> "$LOG"
fi
exit 0
NCZDNSHOOK
        if grep -q '^exit 0$' "$hook_tmp" && chmod 0755 "$hook_tmp" && mv -f "$hook_tmp" "$hook_final"; then
            :
        else
            rm -f "$hook_tmp"
            echo "[watcher] failed to publish $hook_final"
        fi
    }

    write_ncz_dns_hook /usr/lib/base-installer.d
    write_ncz_dns_hook /usr/lib/pre-pkgsel.d
    echo "[watcher] installed ncz DNS hooks for base-installer.d + pre-pkgsel.d"
}
install_ncz_dns_hooks

# Netinstall-bootstrap carries a small regular-deb pool on the ISO but keeps
# .disk/base_installable absent so base-installer still debootstraps from the
# HTTP mirror. This pre-pkgsel hook activates only when that non-empty regular
# Packages index exists, then makes file:///cdrom the pinned first source for
# pkgsel/include.
install_ncz_bootstrap_pool_hook() {
    hook_dir=/usr/lib/pre-pkgsel.d
    hook_tmp="$hook_dir/.20ncz-bootstrap-pool.$$"
    hook_final="$hook_dir/20ncz-bootstrap-pool"

    mkdir -p "$hook_dir"
    rm -f "$hook_tmp"
    cat > "$hook_tmp" <<'NCZBOOTSTRAPPOOL'
#!/bin/sh
# 20ncz-bootstrap-pool - prefer the ISO pkgsel bootstrap pool when present.
set +e
LOG=/var/log/early_command.log
INDEX=/cdrom/dists/resolute/main/binary-arm64/Packages

if [ -e /cdrom/.disk/base_installable ]; then
    echo "[ncz-bootstrap-pool] base-installable media already uses cdrom; skipping" >> "$LOG"
    exit 0
fi
if [ ! -s "$INDEX" ]; then
    echo "[ncz-bootstrap-pool] no non-empty cdrom Packages index; skipping" >> "$LOG"
    exit 0
fi
if [ ! -d /target/etc/apt ]; then
    echo "[ncz-bootstrap-pool] /target/etc/apt missing; skipping" >> "$LOG"
    exit 0
fi

mkdir -p /target/cdrom /target/etc/apt/sources.list.d /target/etc/apt/preferences.d
if ! grep -qs ' /target/cdrom ' /proc/mounts; then
    if mount --bind /cdrom /target/cdrom >> "$LOG" 2>&1; then
        echo "[ncz-bootstrap-pool] mounted /cdrom at /target/cdrom" >> "$LOG"
    else
        echo "[ncz-bootstrap-pool] failed to bind-mount /cdrom into /target" >> "$LOG"
        exit 0
    fi
fi

cat > /target/etc/apt/sources.list.d/cixmini-cdrom.list <<'EOF'
deb [trusted=yes] file:///cdrom resolute main
EOF
cat > /target/etc/apt/preferences.d/00cixmini-bootstrap-pool.pref <<'EOF'
Package: *
Pin: release o=nclawzero
Pin-Priority: 1001
EOF

CHROOT_BIN=""
for c in /usr/sbin/chroot /usr/bin/chroot /bin/chroot; do
    if [ -x "$c" ]; then
        CHROOT_BIN="$c"
        break
    fi
done

if [ -x /target/usr/bin/apt-get ] && [ -n "$CHROOT_BIN" ]; then
    "$CHROOT_BIN" /target /usr/bin/apt-get \
        -o Dir::Etc::sourcelist="sources.list.d/cixmini-cdrom.list" \
        -o Dir::Etc::sourceparts="-" \
        -o APT::Get::List-Cleanup="0" \
        update >> "$LOG" 2>&1 \
        || echo "[ncz-bootstrap-pool] local apt-get update failed; pkgsel may use network fallback" >> "$LOG"
fi

echo "[ncz-bootstrap-pool] file:///cdrom source and nclawzero pin installed" >> "$LOG"
exit 0
NCZBOOTSTRAPPOOL

    if grep -q '^exit 0$' "$hook_tmp" && chmod 0755 "$hook_tmp" && mv -f "$hook_tmp" "$hook_final"; then
        echo "[watcher] installed ncz bootstrap-pool hook for pre-pkgsel.d"
    else
        rm -f "$hook_tmp"
        echo "[watcher] failed to publish $hook_final"
    fi
}
install_ncz_bootstrap_pool_hook

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

# 2026-05-08 take18 (per .66 take17 install failure at 95% / pkgsel
# "Temporary failure resolving 'ports.ubuntu.com'"):
#
# Take15-take17 evolution:
#   take15 — installed custom /etc/udhcpc/default.script (3-NS chain)
#   take16 — confirmed via di-diag that approach got OVERWRITTEN by
#            netcfg's own resolv.conf writer post-DHCP. Took15-16's
#            /etc/resolv.conf ended up with single LAN-router NS only.
#   take17 — added /target/etc/resolv.conf sync from /etc/resolv.conf,
#            but since /etc/resolv.conf was ALREADY single-NS by then,
#            /target/etc/resolv.conf inherited single-NS too. Pkgsel
#            failed when LAN router DNS glitched — no public fallback.
#
# Take18: stop using udhcpc default.script as the writer. The watcher
# itself authoritatively REWRITES BOTH resolv.conf files on every poll
# tick with the full 3-nameserver chain (LAN router + 8.8.8.8 +
# 1.1.1.1). LAN router pulled dynamically from default-route; if it
# changes (e.g. DHCP renewal moves us), we re-pin on next tick.
#
# /target/etc/resolv.conf may be a symlink → ../run/systemd/resolve/
# stub-resolv.conf. cat > follows the symlink, so writing to the
# canonical path Just Works. We pre-create the target dir if missing.
RESOLV_LAST_WROTE=""

ensure_resolv_conf() {
    rc_path="$1"
    [ -d "$(dirname "$rc_path")" ] || return 0
    # If rc_path is a symlink to a missing target dir, mkdir -p the
    # target dir so cat > $rc_path can follow + write.
    if [ -L "$rc_path" ]; then
        rc_target="$(readlink -f "$rc_path" 2>/dev/null)"
        [ -n "$rc_target" ] && mkdir -p "$(dirname "$rc_target")" 2>/dev/null
    fi

    # Pull current LAN gateway from default route. Fall back to
    # 192.168.207.1 if no default route yet.
    ROUTER="$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')"
    [ -z "$ROUTER" ] && ROUTER="192.168.207.1"

    rc_tmp="/tmp/.watcher-resolv.tmp.$$"
    {
        echo "search nclawzero.lan"
        echo "nameserver $ROUTER"
        echo "nameserver 8.8.8.8"
        echo "nameserver 1.1.1.1"
        echo "options timeout:2 attempts:3"
    } > "$rc_tmp"

    if [ ! -f "$rc_path" ] || ! cmp -s "$rc_tmp" "$rc_path" 2>/dev/null; then
        # cat > follows symlink; cp would dereference and write to symlink target
        # (same behavior). Either way, we don't want to clobber a symlink with
        # a regular file, since systemd-resolved expects the symlink shape.
        cat "$rc_tmp" > "$rc_path" 2>/dev/null \
            && RESOLV_LAST_WROTE="$(date -u +%H:%M:%S)" \
            && echo "[watcher] (re)wrote $rc_path with 3-NS chain (router=$ROUTER) at $RESOLV_LAST_WROTE"
    fi
    rm -f "$rc_tmp"
}

sync_target_resolv() {
    ensure_resolv_conf /etc/resolv.conf
    [ -d /target/etc ] && ensure_resolv_conf /target/etc/resolv.conf
}

SSHD_PATCHED=0
i=0
# Take19 per Codex audit: drop the 1800s ceiling — the d-i hooks are now
# the deterministic fix, but keep the watcher running for the full install
# duration so belt-and-suspenders sync_target_resolv() never expires.
while :; do
    sync_target_resolv
    if [ "$SSHD_PATCHED" -eq 0 ] && [ -f /etc/ssh/sshd_config ] && pidof sshd >/dev/null 2>&1; then
        echo "[watcher] sshd live + sshd_config present at i=$i"

        sed -i \
            -e 's|^[[:space:]]*#*[[:space:]]*PermitRootLogin.*|PermitRootLogin yes|' \
            -e 's|^[[:space:]]*#*[[:space:]]*PubkeyAuthentication.*|PubkeyAuthentication yes|' \
            -e 's|^[[:space:]]*#*[[:space:]]*PasswordAuthentication.*|PasswordAuthentication yes|' \
            /etc/ssh/sshd_config

        grep -q '^PermitRootLogin yes' /etc/ssh/sshd_config \
            || echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
        grep -q '^PubkeyAuthentication yes' /etc/ssh/sshd_config \
            || echo 'PubkeyAuthentication yes' >> /etc/ssh/sshd_config
        grep -q '^PasswordAuthentication yes' /etc/ssh/sshd_config \
            || echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config

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
        grep -E '^(PermitRootLogin|PubkeyAuthentication|PasswordAuthentication)' /etc/ssh/sshd_config
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
