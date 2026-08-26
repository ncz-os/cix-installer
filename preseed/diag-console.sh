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
    for _v in /dev/console /dev/tty3 /dev/ttyAMA0; do
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
PW=$(kv ncz_diag_pw);    PW=${PW:-diags}
LOGDST=$(kv ncz_diag_log); LOGDST=${LOGDST:-192.168.207.22:5514}
case "$LOGDST" in *:*) LOGHOST=${LOGDST%:*}; LOGPORT=${LOGDST##*:};; *) LOGHOST=$LOGDST; LOGPORT=5514;; esac
say "cfg: pw=*** log=$LOGHOST:$LOGPORT"

BB=/tmp/nczdiag/busybox
BIN=/tmp/diagbin
RUN=/tmp/diag
mkdir -p "$RUN"
TELNET_PORT=23
HTTP_PORT=8080
SSH_PORT=22

# ---- stage the static busybox + applet farm ---------------------------------
if [ ! -x "$BB" ]; then
    mkdir -p "$(dirname "$BB")" 2>/dev/null || true
    # robust: scan every mount for the install medium (USB or CD)
    for src in /cdrom/cixmini/busybox-arm64 /hd-media/cixmini/busybox-arm64 \
               /media/cdrom/cixmini/busybox-arm64 /run/live/medium/cixmini/busybox-arm64; do
            [ -f "$src" ] && { cp "$src" "$BB" && chmod 0755 "$BB" && say "staged busybox from $src" && break; }
    done
    if [ ! -x "$BB" ]; then
        while read _d _mp _r; do
            [ -f "$_mp/cixmini/busybox-arm64" ] && { cp "$_mp/cixmini/busybox-arm64" "$BB" && chmod 0755 "$BB" && say "staged busybox from $_mp/cixmini (mount-scan)" && break; }
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
mkdir -p "$BIN"; "$BB" --install -s "$BIN" 2>/dev/null
say "applet farm: $(ls "$BIN" 2>/dev/null | wc -l) applets in $BIN"
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

# BusyBox telnetd allocates a PTY for the login shell.  Some d-i paths reach
# early_command before devpts is mounted, which leaves telnet reachable but
# causes sessions to close immediately instead of getting a shell.
mkdir -p /dev/pts
if ! mount | grep -q ' on /dev/pts '; then
    mount -t devpts devpts /dev/pts 2>/dev/null \
        && say "devpts mounted for telnet diagnostics" \
        || say "WARNING: could not mount devpts; telnet shell may fail"
fi
[ -e /dev/ptmx ] || ln -s pts/ptmx /dev/ptmx 2>/dev/null || true

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
diag_net_up() {
    [ -n "$(current_ip)" ] && return 0
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
            say "network up: $_ifn $_got (diag-owned one-shot DHCP)"
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
    for _base in /cdrom /hd-media /media/cdrom /run/live/medium; do
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
    # anna-install talks to the single cdebconf instance; doing that while
    # main-menu has a live dialog up can corrupt/hang the installer UI. In the
    # wedged-installer scenario (main-menu waiting on a question forever) go
    # straight to direct udpkg, which does not touch the debconf frontend.
    if ps 2>/dev/null | grep -E '([[:space:]]|/)main-menu([[:space:]]|$)' | grep -v grep >/dev/null 2>&1; then
        say "main-menu active; using direct udpkg for openssh-server-udeb (skipping anna-install)"
    elif command -v anna-install >/dev/null 2>&1; then
        say "sshd not present; installing openssh-server-udeb for diagnostics"
        anna-install openssh-server-udeb >/tmp/diag-anna-sshd.log 2>&1 && return 0
        say "ERROR: anna-install openssh-server-udeb failed; falling back to direct udpkg"
        _anna_err=$(sed -n '1,8p' /tmp/diag-anna-sshd.log 2>/dev/null | tr '\n' ' ')
        [ -n "$_anna_err" ] && say "anna-install error: $_anna_err"
    else
        say "anna-install unavailable; falling back to direct udpkg for openssh-server-udeb"
    fi
    for _dep in libc6-udeb libcrypt1-udeb libcrypto3-udeb zlib1g-udeb; do
        install_udeb_from_media "$_dep" || say "WARNING: optional sshd dependency $_dep not installed from media; will try sshd anyway"
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
    alive "$RUN/syslogd.pid" && return 0
    # Replace d-i's syslogd with ours so we keep /var/log/syslog AND forward to
    # the collector. -n = foreground (we background it), -R host:port = remote.
    ( "$BB" tail -F /var/log/syslog 2>/dev/null | while IFS= read -r _L; do printf "%s\n" "$_L" | "$BB" nc -w1 "$LOGHOST" "$LOGPORT" 2>/dev/null; done ) &
    echo $! > "$RUN/syslogd.pid"
    "$BB" klogd -n & echo $! > "$RUN/klogd.pid"
    say "syslog forwarding -> $LOGHOST:$LOGPORT (+ klogd)"
    verify_pid "syslog-forwarder" "$RUN/syslogd.pid" || true
    verify_pid "klogd" "$RUN/klogd.pid" || true
}
start_telnetd() {
    alive "$RUN/telnetd.pid" && return 0
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
say "  ssh:    ssh root@${IP:-<host>}            (password: $PW)"
say "  telnet: telnet ${IP:-<host>} ${TELNET_PORT}             (rich shell)"
say "  pull:   wget http://${IP:-<host>}:${HTTP_PORT}/var/log/syslog"
say "  logs ->  $LOGHOST:$LOGPORT (remote syslog)"
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
