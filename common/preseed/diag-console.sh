#!/bin/sh
# diag-console.sh — NCZ installer remote-diagnostics module (single, removable).
#
# ONE self-contained module that gives a remote operator full access *while the
# d-i installer is booted*, so an install can never wedge us out:
#
#   * telnet :23   -> rich busybox shell (full applet farm: vi/awk/sed/tar/...)
#   * ssh          -> PASSWORD auth as root; this script installs/starts the
#                     installer OpenSSH udeb directly so the normal local d-i UI
#                     does not have to be handed to network-console.
#   * http :8080   -> GET-only file pull of the whole installer FS (logs etc.)
#   * remote syslog-> every installer log line shipped to a collector host:port
#                     (so we get the failure even if we never log in)
#   * DEBCONF_DEBUG=5 verbose d-i logging (set on the kernel cmdline by the build)
#
# TOGGLE / REMOVAL (two independent switches):
#   1. Build switch  : `DIAG_ENABLE=0 build/build-iso-di.sh ...` -> this module
#      is NOT staged and `ncz_diag=1` is NOT added to the cmdline => ship-clean.
#   2. Boot variable : `ncz_diag=0|off` on the kernel cmdline disables it even if
#      staged; `ncz_diag=1` enables. Operators can flip it at the GRUB menu.
#   Tunables (kernel cmdline): ncz_diag_pw=<pw>  ncz_diag_log=<host[:port]>
#   Remote syslog is OPT-IN ONLY -- no default loghost is baked in (operator
#   2026-09-17: a shipped installer must never phone home to an internal
#   fleet address by default). Without ncz_diag_log, the forwarder simply
#   never starts; the console banner tells the operator how to turn it on.
#
# Idempotent: safe to run repeatedly; daemons are tracked by pidfiles and only
# (re)started when missing. Spawned in background by preseed/early_command.
#
# Runs under the d-i busybox 1.35 ash; uses a shipped static arm64 busybox
# (assets/diag/busybox-arm64) for the applets d-i lacks (telnetd/httpd/syslogd/
# chpasswd/--install) and for the richer diagnostic shell.

set +e
LOG=/var/log/diag-console.log
exec >> "$LOG" 2>&1
say() {
    echo "[diag] $*"
    # VT3 only: on a serial-console install the newt UI owns ttyAMA0/ttyS0 and any write there lands on the dialog
    for _v in /dev/tty3; do
        echo "[diag] $*" > "$_v" 2>/dev/null || true
    done
}
say "start $(date -u +%FT%TZ) pid=$$"

# ---- parse kernel cmdline ---------------------------------------------------
CMDLINE=$(cat /proc/cmdline 2>/dev/null)
kv() { for t in $CMDLINE; do case "$t" in "$1"=*) echo "${t#*=}"; return;; esac; done; }

DIAG=$(kv ncz_diag);     DIAG=${DIAG:-1}
case "$DIAG" in
    0|off|no|false|disable|disabled)
        say "disabled via ncz_diag=$DIAG — exiting (no daemons started)"; exit 0;;
esac
PW=$(kv ncz_diag_pw);    PW_EXPLICIT=0; [ -n "$PW" ] && PW_EXPLICIT=1; PW=${PW:-diags}
# No default loghost — a real, shipped installer must never phone home to an
# internal fleet address by default. Remote syslog forwarding is OPT-IN ONLY
# via ncz_diag_log=<host[:port]> on the boot cmdline; unset means no forward
# daemon is even started (see start_syslogd). This used to default to
# 192.168.207.22:5514 (ARGOS), which meant every real-hardware install's
# console banner printed our internal fleet IP whether or not anyone wanted
# remote logging — operator directive 2026-09-17: never ship that.
LOGDST=$(kv ncz_diag_log)
if [ -n "$LOGDST" ]; then
    case "$LOGDST" in *:*) LOGHOST=${LOGDST%:*}; LOGPORT=${LOGDST##*:};; *) LOGHOST=$LOGDST; LOGPORT=5514;; esac
    say "cfg: pw=*** log=$LOGHOST:$LOGPORT"
else
    LOGHOST=""; LOGPORT=""
    say "cfg: pw=*** log=disabled (set ncz_diag_log=<host[:port]> on the boot cmdline to enable)"
fi

BB=/tmp/nczdiag/busybox
BIN=/tmp/diagbin
RUN=/run/nczdiag
"$BB" mkdir -p "$RUN" || { say "FATAL: cannot create runtime directory $RUN"; exit 1; }
[ -d "$RUN" ] && [ -w "$RUN" ] \
    || { say "FATAL: runtime path is not a writable directory: $RUN"; exit 1; }
TELNET_PORT=23
HTTP_PORT=8080
SSH_PORT=22

# ---- stage the static busybox + applet farm ---------------------------------
# Self-describing at runtime via uname -m, not a build-time constant: the
# medium may carry either arch's diag module (arm64 Sky1 vs amd64/T2), and
# the binary must match the RUNNING kernel, not whichever was baked at
# build time. Maps uname -m -> our asset-naming convention (busybox-arm64 /
# busybox-amd64), matching NCZ_TARGET_ARCH on the build side.
BB_UNAME_M=$(/tmp/nczdiag/busybox uname -m 2>/dev/null)
case "$BB_UNAME_M" in
    aarch64) BB_ARCH=arm64 ;;
    x86_64)  BB_ARCH=amd64 ;;
    *) say "FATAL: unsupported uname -m for diag busybox: $BB_UNAME_M"; exit 1 ;;
esac
if [ ! -x "$BB" ]; then
    mkdir -p "$(dirname "$BB")" 2>/dev/null || true
    # robust: scan every mount for the install medium (USB or CD)
    for src in /cdrom/ncz-payload/busybox-$BB_ARCH /hd-media/ncz-payload/busybox-$BB_ARCH \
               /media/cdrom/ncz-payload/busybox-$BB_ARCH /run/live/medium/ncz-payload/busybox-$BB_ARCH; do
            [ -f "$src" ] && { cp "$src" "$BB" && chmod 0755 "$BB" && say "staged busybox from $src" && break; }
    done
    if [ ! -x "$BB" ]; then
        while read _d _mp _r; do
            [ -f "$_mp/ncz-payload/busybox-$BB_ARCH" ] && { cp "$_mp/ncz-payload/busybox-$BB_ARCH" "$BB" && chmod 0755 "$BB" && say "staged busybox from $_mp/ncz-payload (mount-scan)" && break; }
        done < /proc/mounts
    fi
fi
[ -x "$BB" ] || { say "FATAL: static busybox not found on medium"; exit 1; }
if ! "$BB" true >/tmp/bbdiag.exec-test.log 2>&1; then
    say "FATAL: static busybox exists at $BB but cannot execute"
    say "bbdiag ls: $(ls -l "$BB" 2>/dev/null || true)"
    _bb_err=$(sed -n '1,3p' /tmp/bbdiag.exec-test.log 2>/dev/null | tr '\n' ' ')
    [ -n "$_bb_err" ] && say "bbdiag exec error: $_bb_err"
    file "$BB" 2>/dev/null || true
    mount 2>/dev/null | sed -n '1,40p' || true
    exit 1
fi
"$BB" mkdir -p "$BIN"; "$BB" --install "$BIN" 2>/dev/null
# Some d-i tmpfs builds accept BusyBox --install but create no links. Build
# the applet farm explicitly in that case so diagnostics do not die silently.
if [ ! -x "$BIN/chpasswd" ]; then
    for _applet in chpasswd httpd ifconfig klogd login nc netstat route sh tail telnetd udhcpc; do
        "$BB" ln -sf "$BB" "$BIN/$_applet" 2>/dev/null || true
    done
fi
say "applet farm: $("$BB" ls "$BIN" 2>/dev/null | "$BB" wc -l) applets in $BIN"
export PATH=$BIN:/usr/bin:/bin:/usr/sbin:/sbin
for _applet in chpasswd httpd ifconfig klogd login nc netstat route sh tail telnetd udhcpc; do
    if [ ! -x "$BIN/$_applet" ]; then
        say "FATAL: busybox applet $_applet missing from $BIN"
        exit 1
    fi
done

# Rich diagnostic shell: full applet PATH ahead of the stripped d-i busybox.
cat > "$RUN/diagsh" <<SH
#!/bin/sh
export PATH=$BIN:/usr/bin:/bin:/usr/sbin:/sbin
export TERM=\${TERM:-vt100} HOME=/root PS1='ncz-diag:\w# '
exec $BIN/sh -i
SH
chmod 0755 "$RUN/diagsh"
export PATH=$BIN:/usr/bin:/bin:/usr/sbin:/sbin
export TERM="${TERM:-vt100}" HOME=/root PS1='ncz-diag:\w# '

# BusyBox telnetd allocates a PTY for the login shell. Some d-i paths reach
# early_command before devpts can be mounted. Do not publish a listener in
# that state: it accepts TCP and then immediately closes every session. This
# helper is also called by every retry, so a transient early mount failure is
# repaired as soon as devpts becomes available.
ensure_devpts() {
    mkdir -p /dev/pts
    if ! grep -q '[[:space:]]/dev/pts[[:space:]]devpts[[:space:]]' /proc/mounts 2>/dev/null; then
        mount -t devpts devpts /dev/pts 2>/dev/null || {
            say "telnet deferred: devpts is not mounted yet (will retry)"
            return 1
        }
        say "devpts mounted for telnet diagnostics"
    fi
    [ -e /dev/ptmx ] || ln -s pts/ptmx /dev/ptmx 2>/dev/null || true
    [ -e /dev/ptmx ] || {
        say "telnet deferred: /dev/ptmx is unavailable (will retry)"
        return 1
    }
    return 0
}

# ---- root password so SSH password-auth + telnet login work -----------------
# d-i root is otherwise locked, so set a known simple password here.
printf 'root:%s\n' "$PW" | "$BB" chpasswd 2>/dev/null \
    && say "root password set (ssh/telnet password auth enabled)" \
    || say "ERROR: failed to set root password; SSH password login will fail"

# ---- bring the network up OURSELVES -----------------------------------------
# ROOT CAUSE of the 2026-08-23 "telnet listens but never answers" arc: this
# module used to WAIT for an IP that only d-i's netcfg would assign — but
# netcfg runs long after early_command, and not at all when d-i wedges at an
# early dialog. That is EXACTLY the scenario this module exists for. Measured
# in QEMU DIAG boots (build/diag-net, 2026-08-24): d-i sitting at the language
# dialog, "telnetd verified listening on :23", banner IP=<none>, and the
# host-forwarded telnet connect closed with no data because the guest had no
# address for slirp to deliver to. Every telnetd/login/pty tweak before this
# was aimed at the wrong layer: the login path was never even reached.
#
# So: raise every NIC, then one-shot DHCP (udhcpc -n -q) each NIC with
# carrier using the static busybox. One-shot means the client exits after
# binding, so it can never fight netcfg's own DHCP client later in a normal
# install. Retried from the respawn loop until an address exists (RTL8125B
# autoneg can take ~9-13s, so first pass may legitimately find no carrier).
current_ip() {
    "$BB" ifconfig 2>/dev/null | grep -oE 'inet (addr:)?[0-9.]+' \
        | grep -oE '[0-9]+\.[0-9.]+' | grep -v '^127\.' | head -1
}
cat > "$RUN/udhcpc.script" <<'US'
#!/bin/sh
BIN=/tmp/diagbin
case "$1" in
    bound|renew)
        "$BIN/ifconfig" "$interface" "$ip" netmask "${subnet:-255.255.255.0}"
        for r in $router; do
            "$BIN/route" add default gw "$r" dev "$interface" 2>/dev/null
            break
        done
        ;;
    deconfig)
        "$BIN/ifconfig" "$interface" 0.0.0.0 2>/dev/null
        ;;
esac
exit 0
US
chmod 0755 "$RUN/udhcpc.script"
# r-net1: a default route is part of "network up". netcfg can leave an
# interface addressed but routeless (observed on O6N 2026-09-26: IP
# 192.168.207.3/24 on-link, no default, netcfg/confirm_static=true with an
# empty netcfg/get_gateway). d-i's own udebs are fetched from the live
# archive by anna, so a routeless install dies later at "Bad archive mirror"
# with no hint that routing is the real problem. Treating an IP alone as
# success made this respawn loop skip the very repair it already knows how
# to do -- the udhcpc script below installs $router as the default route.
has_default_route() { "$BB" route -n 2>/dev/null | grep -qE "^0\.0\.0\.0"; }
diag_net_up() {
    [ -n "$(current_ip)" ] && has_default_route && return 0
    for _ifp in /sys/class/net/*; do
        _ifn=$(basename "$_ifp")
        [ "$_ifn" = "lo" ] && continue
        "$BB" ifconfig "$_ifn" up 2>/dev/null || true
    done
    for _ifp in /sys/class/net/*; do
        _ifn=$(basename "$_ifp")
        [ "$_ifn" = "lo" ] && continue
        [ "$(cat "$_ifp/carrier" 2>/dev/null)" = "1" ] || continue
        "$BB" udhcpc -f -n -q -t 3 -T 3 -i "$_ifn" -s "$RUN/udhcpc.script" \
            >/tmp/diag-udhcpc-"$_ifn".log 2>&1
        _got=$(current_ip)
        if [ -n "$_got" ]; then
            say "network up: $_ifn $_got default_route=$(has_default_route && echo yes || echo NO) (diag-owned one-shot DHCP)"
            return 0
        fi
    done
    return 1
}
diag_net_up || say "no DHCP lease yet (no carrier or no server); will keep retrying"

# ---- daemon helpers (idempotent via pidfiles) -------------------------------
alive() { p=$(cat "$1" 2>/dev/null); [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
listening() {
    _port="$1"
    "$BB" netstat -ltn 2>/dev/null | grep -E "[.:]${_port}[[:space:]]" >/dev/null 2>&1
}
verify_pid() {
    _name="$1"; _pidfile="$2"
    if alive "$_pidfile"; then
        say "$_name running pid=$(cat "$_pidfile" 2>/dev/null)"
        return 0
    fi
    say "ERROR: $_name failed to stay running (pidfile=$_pidfile pid=$(cat "$_pidfile" 2>/dev/null))"
    ps 2>/dev/null | grep -E "($_name|telnetd|httpd|klogd|tail|nc)" | grep -v grep || true
    return 1
}
verify_listener() {
    _name="$1"; _pidfile="$2"; _port="$3"
    sleep 1
    verify_pid "$_name" "$_pidfile" || return 1
    if listening "$_port"; then
        say "$_name verified listening on :$_port"
        return 0
    fi
    say "ERROR: $_name pid is alive but :$_port is not listening"
    "$BB" netstat -ltn 2>/dev/null || true
    return 1
}
install_udeb_from_media() {
    _pkg="$1"
    _udeb=""
    # The raw-GPT pipeline bakes these into the initrd because early_command
    # runs before partition 2 is necessarily mounted. Legacy ISO paths remain
    # as fallbacks for the older assembler.
    for _base in /ncz/ssh-udebs /cdrom /hd-media /media/cdrom /run/live/medium; do
        [ -d "$_base" ] || continue
        _udeb=$(find "$_base" -name "${_pkg}_*.udeb" 2>/dev/null | head -1)
        [ -n "$_udeb" ] && break
    done
    if [ -z "$_udeb" ]; then
        while read _d _mp _r; do
            [ -d "$_mp" ] || continue
            _udeb=$(find "$_mp" -name "${_pkg}_*.udeb" 2>/dev/null | head -1)
            [ -n "$_udeb" ] && break
        done < /proc/mounts
    fi
    [ -n "$_udeb" ] || { say "ERROR: could not find ${_pkg}_*.udeb on installer media"; return 1; }
    say "installing $_pkg from $_udeb"
    udpkg -i "$_udeb" >/tmp/diag-udpkg-${_pkg}.log 2>&1 || {
        _udpkg_err=$(sed -n '1,8p' "/tmp/diag-udpkg-${_pkg}.log" 2>/dev/null | tr '\n' ' ')
        say "ERROR: udpkg install failed for $_pkg: $_udpkg_err"
        return 1
    }
}
install_sshd_udebs() {
    # early_command deliberately launches this module with fd 3 closed so it
    # cannot retain cdebconf's protocol pipe. anna-install sources
    # /usr/share/debconf/confmodule, whose _db_cmd writes to fd 3; invoking it
    # here therefore always fails with "dup2(3,1): Bad file descriptor" and
    # can never be a valid path. Direct udpkg neither needs fd 3 nor contends
    # with main-menu's single cdebconf frontend.
    say "installing diagnostic SSH udebs directly (cdebconf fd 3 is intentionally closed)"
    for _dep in libc6-udeb zlib1g-udeb libcrypt1-udeb libcrypto3-udeb openssh-client-udeb; do
        install_udeb_from_media "$_dep" || say "WARNING: sshd dependency $_dep not installed from media; will try sshd anyway"
    done
    install_udeb_from_media openssh-server-udeb || return 1
}

installer_component_loader_busy() {
    # Only TRANSIENT package-loader processes defer us. main-menu must NOT be
    # in this list: it runs for the whole life of d-i, so matching it deferred
    # the SSH udeb install FOREVER — measured 2026-08-24 in a QEMU DIAG boot
    # ("installer component loader busy" every 10s for the entire session,
    # sshd never installed) in precisely the wedged-installer scenario this
    # module exists for.
    ps 2>/dev/null \
        | grep -E '([[:space:]]|/)(anna|anna-install|udpkg)([[:space:]]|$)' \
        | grep -v grep >/dev/null 2>&1
}

start_syslogd() {
    if [ -z "$LOGHOST" ]; then
        # No forwarder to guard re-entry with (there's no forward pidfile in
        # this branch), so guard on klogd itself instead.
        alive "$RUN/klogd.pid" && return 0
        "$BB" klogd -n & echo $! > "$RUN/klogd.pid"
        say "syslog forwarding disabled (no ncz_diag_log) — local /var/log/syslog + klogd only"
        verify_pid "klogd" "$RUN/klogd.pid" || true
        return 0
    fi
    alive "$RUN/syslogd.pid" && return 0
    "$BB" klogd -n & echo $! > "$RUN/klogd.pid"
    # Replace d-i's syslogd with ours so we keep /var/log/syslog AND forward to
    # the collector. -n = foreground (we background it), -R host:port = remote.
    ( "$BB" tail -F /var/log/syslog 2>/dev/null | while IFS= read -r _L; do printf "%s\n" "$_L" | "$BB" nc -w1 "$LOGHOST" "$LOGPORT" 2>/dev/null; done ) &
    echo $! > "$RUN/syslogd.pid"
    say "syslog forwarding -> $LOGHOST:$LOGPORT (+ klogd)"
    verify_pid "syslog-forwarder" "$RUN/syslogd.pid" || true
    verify_pid "klogd" "$RUN/klogd.pid" || true
}
start_telnetd() {
    alive "$RUN/telnetd.pid" && return 0
    ensure_devpts || return 1
    "$BB" telnetd -F -l "$BIN/login" -p "$TELNET_PORT" & echo $! > "$RUN/telnetd.pid"
    verify_listener "telnetd" "$RUN/telnetd.pid" "$TELNET_PORT" || true
}
start_httpd() {
    alive "$RUN/httpd.pid" && return 0
    "$BB" httpd -f -p "$HTTP_PORT" -h / & echo $! > "$RUN/httpd.pid"
    verify_listener "httpd" "$RUN/httpd.pid" "$HTTP_PORT" || true
}
start_sshd() {
    if [ ! -x /usr/sbin/sshd ]; then
        if installer_component_loader_busy; then
            # Logged once on the FIRST deferral, then silently re-checked every
            # respawn-loop tick (10s) until the loader frees up -- was logging
            # this identical line every single tick, which on a long apt/dpkg
            # run (late.sh/run-all.sh) produced dozens of duplicate lines and
            # buried genuinely useful diagnostic output. The retry ITSELF is
            # correct and unchanged; only the noisy logging is fixed.
            if [ "${_sshd_defer_logged:-0}" != "1" ]; then
                say "installer component loader busy; deferring SSH udeb install (will keep retrying silently)"
                _sshd_defer_logged=1
            fi
            return 1
        fi
        _sshd_defer_logged=0
        install_sshd_udebs || {
            say "ERROR: could not install openssh-server-udeb; SSH unavailable for now"
            return 1
        }
    fi
    [ -x /usr/sbin/sshd ] || { say "ERROR: /usr/sbin/sshd still missing after install attempt"; return 1; }
    mkdir -p /etc/ssh /run/sshd /root/.ssh
    chmod 0755 /run/sshd 2>/dev/null || true
    chmod 0700 /root/.ssh 2>/dev/null || true
    grep -qs '^nogroup:' /etc/group || echo "nogroup:*:65534:" >> /etc/group
    grep -qs '^sshd:' /etc/passwd || echo "sshd:*:100:65534::/run/sshd:/bin/false" >> /etc/passwd
    if [ ! -s /etc/ssh/ssh_host_ed25519_key ]; then
        if command -v ssh-keygen >/dev/null 2>&1; then
            ssh-keygen -t ed25519 -N '' -f /etc/ssh/ssh_host_ed25519_key -q \
                || say "ERROR: ssh-keygen failed; SSH may not start"
        else
            say "ERROR: ssh-keygen missing; SSH host key cannot be generated"
        fi
    fi
    cat > /etc/ssh/sshd_config <<EOF
Port $SSH_PORT
ListenAddress 0.0.0.0
HostKey /etc/ssh/ssh_host_ed25519_key
PermitRootLogin yes
PubkeyAuthentication yes
PasswordAuthentication yes
PermitEmptyPasswords no
UsePAM no
AuthorizedKeysFile .ssh/authorized_keys
PidFile $RUN/sshd.pid
EOF
    if alive "$RUN/sshd.pid" && listening "$SSH_PORT"; then
        return 0
    fi
    if alive "$RUN/sshd.pid"; then
        kill "$(cat "$RUN/sshd.pid" 2>/dev/null)" 2>/dev/null || true
        sleep 1
    fi
    /usr/sbin/sshd -f /etc/ssh/sshd_config -E /var/log/diag-sshd.log \
        || { say "ERROR: sshd start command failed"; sed -n '1,80p' /var/log/diag-sshd.log 2>/dev/null || true; return 1; }
    verify_listener "sshd" "$RUN/sshd.pid" "$SSH_PORT" || {
        sed -n '1,80p' /var/log/diag-sshd.log 2>/dev/null || true
        return 1
    }
}

start_syslogd
start_telnetd
start_httpd
start_sshd

# ---- banner (after best-effort network wait, for a real IP) -----------------
# current_ip() defined above (busybox ifconfig — d-i's own `ip` is not
# guaranteed). diag_net_up() actively DHCPs, so this loop normally exits on
# its first few iterations rather than timing out at 120s with IP=<none>.
i=0; while [ -z "$(current_ip)" ] && [ "$i" -lt 120 ]; do diag_net_up >/dev/null 2>&1; sleep 1; i=$((i+1)); done
IP="$(current_ip)"
say "==================================================================="
say "NCZ installer diagnostics READY  (ncz_diag=$DIAG)  IP=${IP:-<none>}"
if [ "$PW_EXPLICIT" = 1 ]; then
    say "  ssh:    ssh root@${IP:-<host>}            (password: set by ncz_diag_pw on the boot line)"
else
    say "  ssh:    ssh root@${IP:-<host>}            (default diagnostics password, see docs/DIAG.md)"
fi
say "  telnet: telnet ${IP:-<host>} ${TELNET_PORT}             (rich shell)"
say "  pull:   wget http://${IP:-<host>}:${HTTP_PORT}/var/log/syslog"
if [ -n "$LOGHOST" ]; then
    say "  logs ->  $LOGHOST:$LOGPORT (remote syslog)"
else
    say "  logs:   remote syslog DISABLED -- add ncz_diag_log=<host[:port]> to the"
    say "          boot cmdline (e.g. at the rEFInd/GRUB menu) to enable it"
fi
say "==================================================================="

# ---- idempotent respawn for the life of the install -------------------------
while :; do
    diag_net_up >/dev/null 2>&1
    start_syslogd
    start_telnetd
    start_httpd
    start_sshd
    sleep 10
done
