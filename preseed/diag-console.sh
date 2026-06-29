#!/bin/sh
# diag-console.sh — NCZ installer remote-diagnostics module (single, removable).
#
# ONE self-contained module that gives a remote operator full access *while the
# d-i installer is booted*, so an install can never wedge us out:
#
#   * telnet :23   -> rich busybox shell (full applet farm: vi/awk/sed/tar/...)
#   * ssh          -> PASSWORD auth as root (network-console + sshd-watcher);
#                     root password is set here so password login actually works
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
echo "[diag] start $(date -u +%FT%TZ) pid=$$"

# ---- parse kernel cmdline ---------------------------------------------------
CMDLINE=$(cat /proc/cmdline 2>/dev/null)
kv() { for t in $CMDLINE; do case "$t" in "$1"=*) echo "${t#*=}"; return;; esac; done; }

DIAG=$(kv ncz_diag);     DIAG=${DIAG:-1}
case "$DIAG" in
    0|off|no|false|disable|disabled)
        echo "[diag] disabled via ncz_diag=$DIAG — exiting (no daemons started)"; exit 0;;
esac
PW=$(kv ncz_diag_pw);    PW=${PW:-diags}
LOGDST=$(kv ncz_diag_log); LOGDST=${LOGDST:-192.168.207.22:5514}
case "$LOGDST" in *:*) LOGHOST=${LOGDST%:*}; LOGPORT=${LOGDST##*:};; *) LOGHOST=$LOGDST; LOGPORT=5514;; esac
echo "[diag] cfg: pw=*** log=$LOGHOST:$LOGPORT"

BB=/tmp/bbdiag
BIN=/tmp/diagbin
RUN=/tmp/diag
mkdir -p "$RUN"
TELNET_PORT=23
HTTP_PORT=8080

# ---- stage the static busybox + applet farm ---------------------------------
if [ ! -x "$BB" ]; then
    # robust: scan every mount for the install medium (USB or CD)
    for src in /cdrom/cixmini/busybox-arm64 /hd-media/cixmini/busybox-arm64 \
               /media/cdrom/cixmini/busybox-arm64 /run/live/medium/cixmini/busybox-arm64; do
        [ -f "$src" ] && { cp "$src" "$BB" && chmod 0755 "$BB" && echo "[diag] staged busybox from $src" && break; }
    done
    if [ ! -x "$BB" ]; then
        while read _d _mp _r; do
            [ -f "$_mp/cixmini/busybox-arm64" ] && { cp "$_mp/cixmini/busybox-arm64" "$BB" && chmod 0755 "$BB" && echo "[diag] staged busybox from $_mp/cixmini (mount-scan)" && break; }
        done < /proc/mounts
    fi
fi
[ -x "$BB" ] || { echo "[diag] FATAL: static busybox not found on medium"; exit 1; }
mkdir -p "$BIN"; "$BB" --install -s "$BIN" 2>/dev/null
echo "[diag] applet farm: $(ls "$BIN" 2>/dev/null | wc -l) applets in $BIN"

# Rich diagnostic shell: full applet PATH ahead of the stripped d-i busybox.
cat > "$RUN/diagsh" <<SH
#!/bin/sh
export PATH=$BIN:/usr/bin:/bin:/usr/sbin:/sbin
export TERM=\${TERM:-vt100} HOME=/root PS1='ncz-diag:\w# '
exec $BIN/sh
SH
chmod 0755 "$RUN/diagsh"

# ---- root password so SSH password-auth + telnet login work -----------------
# (sshd-watcher.sh forces PasswordAuthentication yes + PermitRootLogin yes; d-i
#  root is otherwise locked, so set a known simple password here.)
printf 'root:%s\n' "$PW" | "$BB" chpasswd 2>/dev/null \
    && echo "[diag] root password set (ssh/telnet password auth enabled)"

# ---- daemon helpers (idempotent via pidfiles) -------------------------------
alive() { p=$(cat "$1" 2>/dev/null); [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }

start_syslogd() {
    alive "$RUN/syslogd.pid" && return 0
    # Replace d-i's syslogd with ours so we keep /var/log/syslog AND forward to
    # the collector. -n = foreground (we background it), -R host:port = remote.
    ( "$BB" tail -F /var/log/syslog 2>/dev/null | while IFS= read -r _L; do printf "%s\n" "$_L" | "$BB" nc -w1 "$LOGHOST" "$LOGPORT" 2>/dev/null; done ) &
    echo $! > "$RUN/syslogd.pid"
    "$BB" klogd -n & echo $! > "$RUN/klogd.pid"
    echo "[diag] syslogd forwarding -> $LOGHOST:$LOGPORT (+ klogd)"
}
start_telnetd() {
    alive "$RUN/telnetd.pid" && return 0
    "$BB" telnetd -F -l "$RUN/diagsh" -p "$TELNET_PORT" & echo $! > "$RUN/telnetd.pid"
    echo "[diag] telnetd up :$TELNET_PORT (rich shell)"
}
start_httpd() {
    alive "$RUN/httpd.pid" && return 0
    "$BB" httpd -f -p "$HTTP_PORT" -h / & echo $! > "$RUN/httpd.pid"
    echo "[diag] httpd up :$HTTP_PORT serving / (GET-only)"
}

start_syslogd
start_telnetd
start_httpd

# ---- banner (after best-effort network wait, for a real IP) -----------------
current_ip() { ip -4 -o addr 2>/dev/null | grep -oE 'inet [0-9.]+' | grep -v 'inet 127' | head -1 | cut -d' ' -f2; }
i=0; while [ -z "$(current_ip)" ] && [ "$i" -lt 120 ]; do sleep 1; i=$((i+1)); done
IP="$(current_ip)"
echo "[diag] ==================================================================="
echo "[diag] NCZ installer diagnostics READY  (ncz_diag=$DIAG)  IP=${IP:-<none>}"
echo "[diag]   ssh:    ssh root@${IP:-<host>}            (password: $PW)"
echo "[diag]   telnet: telnet ${IP:-<host>} ${TELNET_PORT}             (rich shell)"
echo "[diag]   pull:   wget http://${IP:-<host>}:${HTTP_PORT}/var/log/syslog"
echo "[diag]   logs ->  $LOGHOST:$LOGPORT (remote syslog)"
echo "[diag] ==================================================================="

# ---- idempotent respawn for the life of the install -------------------------
while :; do
    start_syslogd
    start_telnetd
    start_httpd
    sleep 10
done
