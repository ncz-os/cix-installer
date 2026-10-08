#!/bin/bash
# NCZ-MIXED-HOOK: telnet/journald generic; serial-getty ttyAMA0 enable gated on arm64 (lines ~198-210); TODO split UART part (docs/platform-inventory.tsv; runs on every platform, listed in both hooks.list files)
# 36-telemetry.sh — maximum-telemetry + lockout-prevention console.
#
# Operator requirement (2026-06-01): "telnetd enabled by default with
# loghost to .22, I want all possible telemetry for debug."
#
# This hook makes a freshly-installed cixmini observable + recoverable
# from day zero, on BOTH the Desktop and Server SKUs — telemetry is
# variant-agnostic, so there is no variant gate.
#
# It sets up four things:
#   1. telnetd on TCP 23 (CLAUDE.md directive 9 — LAN-only lockout
#      prevention; backup console when sshd hangs / has bad config).
#   2. Persistent journald (Storage=persistent) so logs survive the
#      reboot and can be read from rescue.target afterwards. Forwarding
#      to a remote syslog host is OPT-IN via the /etc/ncz-loghost marker;
#      when the marker is set we install rsyslog as the receiver and
#      configure journald's ForwardToSyslog=yes (off by default — see
#      step 2 for details). Without the marker, the installed system is
#      journald-only: no rsyslog package, no /var/log/syslog file.
#   3. Serial getty on ttyAMA0 @115200 — a real login over the on-board
#      UART (ttyAMA2 does not enumerate on disk-boot; see step 3 below).
#
# NOTE: the file numbering below is 1=telnetd, 2=rsyslog opt-in, 3=journald
# drop-in, 4=serial getty. The header "four things" intentionally lists only
# the three persistent-state changes (telnet, journald, getty); the rsyslog
# opt-in is a conditional fifth, only relevant when /etc/ncz-loghost is set.
#
# Failure-tolerant: this is a Phase 2 optional hook. Each step is
# wrapped so a single missing package can't abort the install. Runs in
# the chroot against the freshly-installed rootfs (Ubuntu questing /
# Debian bookworm), so `apt-get` + `systemctl enable` are available.
# Idempotent: re-runnable on a live system; matches the logging style
# used across the rest of the post-install tree.
set +e

echo "[36] telemetry + lockout-prevention console"

LOGHOST="192.168.207.22"   # ARGOS — fleet loghost (stays up while a target wedges)

# ----------------------------------------------------------------------
# 1. telnetd on :23  (directive 9 — LAN-only backup console)
# ----------------------------------------------------------------------
# Preferred: inetutils-telnetd behind openbsd-inetd. Fallback: a
# busybox-telnetd systemd socket unit (busybox is in every base rootfs).
echo "[36] installing telnetd (backup console on :23)"
# timeout-wrapped: a hung/slow mirror must not stall the whole install.
# set +e is active, so a timeout just skips this optional step (Codex nit).
timeout 300 env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    inetutils-telnetd openbsd-inetd 2>&1 | tail -3

# The inetd line must name the telnetd binary that EXISTS. It used to hardcode
# /usr/sbin/in.telnetd, but forky's inetutils-telnetd ships /usr/sbin/telnetd
# only: :23 accepted and inetd logged "execv /usr/sbin/in.telnetd: No such file
# or directory" (r201, every reflashed machine). lib/telnet-inetd.sh detects the
# real binary, disables stale/tcpd-wrapped lines and writes one direct line (no
# tcpd: inetutils-telnetd does not pull tcp-wrappers). Runs as root so the
# daemon can exec /bin/login.
_ncz_telnet_lib="$(dirname "$0")/lib/telnet-inetd.sh"
[ -r "$_ncz_telnet_lib" ] || _ncz_telnet_lib=/usr/local/lib/cix-installer/post-install/lib/telnet-inetd.sh
_ncz_telnet_ok=0
if dpkg -s openbsd-inetd >/dev/null 2>&1 && dpkg -s inetutils-telnetd >/dev/null 2>&1 \
   && [ -r "$_ncz_telnet_lib" ] && . "$_ncz_telnet_lib" && ncz_telnet_inetd_fix ""; then
    _ncz_telnet_ok=1
fi
if [ "$_ncz_telnet_ok" = 1 ]; then
    systemctl enable inetd 2>&1 | tail -1
    systemctl enable openbsd-inetd 2>&1 | tail -1
    echo "[36] telnetd via openbsd-inetd enabled: $(grep -E '^telnet[[:space:]]' /etc/inetd.conf | head -1)"
else
    echo "[36] WARN: inetutils-telnetd/openbsd-inetd unavailable — falling back to busybox telnetd socket"
    BB=$(command -v busybox || echo /bin/busybox)
    cat > /etc/systemd/system/telnetd.socket <<EOF
[Unit]
Description=Telnet backup console (busybox) — LAN lockout prevention
[Socket]
ListenStream=23
Accept=yes
[Install]
WantedBy=sockets.target
EOF
    cat > /etc/systemd/system/telnetd@.service <<EOF
[Unit]
Description=Telnet per-connection (busybox) — LAN lockout prevention
[Service]
ExecStart=-$BB telnetd -i -l /bin/login
StandardInput=socket
EOF
    systemctl enable telnetd.socket 2>&1 | tail -1
    echo "[36] busybox telnetd socket enabled on :23"
fi

# Allow root login over telnet pts as a TRUE lockout fallback. LAN-only,
# no internet route (directive 9: plain-text auth acceptable on LAN, and
# lockout recovery beats theoretical plain-text concerns). The diag
# account (09-diag-account.sh: magnetar) is the normal telnet login;
# this just keeps root reachable if that account is gone.
if [ -f /etc/securetty ]; then
    for d in ttyAMA0 pts/0 pts/1 pts/2 pts/3 pts/4 pts/5 pts/6 pts/7 pts/8 pts/9; do
        grep -qxF "$d" /etc/securetty || echo "$d" >> /etc/securetty
    done
    echo "[36] /etc/securetty: ttyAMA0 + pts/0..9 permitted (root console/telnet fallback)"
fi

# ----------------------------------------------------------------------
# 2. journald -> loghost (OPT-IN — off by default on a shipped image)
# ----------------------------------------------------------------------
# The installed system is JOURNALD-ONLY: rsyslog is apt-purged in
# 58-boot-hygiene.sh because we have nothing that needs its legacy
# /var/log/{syslog,messages} files. When the operator wants to ship logs
# off-box (doctrine: forward to ARGOS @ 192.168.207.22 for the fleet),
# they drop /etc/ncz-loghost with the loghost IP (or "default"); this
# hook then installs rsyslog, sets journald ForwardToSyslog=yes so
# journald feeds the legacy unix socket, and writes the omfwd action.
# No marker => no forward => no spam, no rsyslog install, no /var/log
# growth (the 200M journald cap below bounds journald instead).
#
# rsyslog is only pulled in here, only on demand. The Debian forky
# default install brings it in via tasksel; 58-boot-hygiene apt-purges
# it so journald is the single syslog sink on a stock-shipped image.
echo "[36] journald is the only syslog sink (rsyslog installed ONLY when /etc/ncz-loghost is set)"
rm -f /etc/rsyslog.d/90-loghost.conf
# Never ship the old always-on forward; remove any stale copy from a prior image.
FWD_HOST=""
if [ -r /etc/ncz-loghost ]; then
    FWD_HOST=$(tr -d ' \t\r\n' < /etc/ncz-loghost)
    [ "$FWD_HOST" = "default" ] && FWD_HOST="$LOGHOST"
fi
if [ -n "$FWD_HOST" ]; then
    # BEGIN rsyslog-status
    # set +e and no pipefail here: `... | tail || echo WARN` tested tail, so the WARN could never fire.
    timeout 300 env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends rsyslog 2>&1 | tail -3
    _rsys_rc=${PIPESTATUS[0]}
    [ "$_rsys_rc" -eq 0 ] || echo "[36] WARN: rsyslog install failed (rc=$_rsys_rc); journald-only loghost path disabled" >&2
    # END rsyslog-status
    if dpkg -s rsyslog >/dev/null 2>&1; then
        mkdir -p /etc/rsyslog.d
        cat > /etc/rsyslog.d/90-loghost.conf <<EOF
# NCZ telemetry — forward ALL messages to loghost (opt-in via /etc/ncz-loghost).
# reportSuspension off so a brief unreachable-loghost window does not spam the
# local log with "Network is unreachable".
\$ActionQueueType LinkedList
\$ActionQueueFileName loghost_fwd
\$ActionResumeRetryCount -1
\$ActionQueueSaveOnShutdown on
*.* action(type="omfwd" target="${FWD_HOST}" port="514" protocol="udp"
          action.resumeRetryCount="-1" action.reportSuspension="off"
          action.reportSuspensionContinuation="off"
          queue.type="LinkedList" queue.filename="loghost_fwd" queue.saveOnShutdown="on")
EOF
        systemctl enable rsyslog 2>&1 | tail -1 || true
        echo "[36] rsyslog forwarding *.* to ${FWD_HOST}:514 (opt-in, suspension reporting off)"
    else
        echo "[36] /etc/ncz-loghost set but rsyslog unavailable — journald-only, no remote forward"
    fi
else
    echo "[36] rsyslog remote forward NOT configured (no /etc/ncz-loghost marker) — journald persistent covers logs"
fi

# ----------------------------------------------------------------------
# 3. Persistent journald (survive reboot for post-mortem)
# ----------------------------------------------------------------------
mkdir -p /etc/systemd/journald.conf.d
# Cap at 200M: this is flash-backed storage (btrfs root on NVMe) so an
# unbounded journal fills the root subvolume and slowly wedges the system
# on long uptimes. 200M is ~3-5 days of full-noise journal on a typical
# CIX Sky1 install; raise it (or set SystemKeepFree) when adding new
# verbose subsystems. ForwardToSyslog is keyed off the opt-in marker
# above so a stock-shipped image does not pull in rsyslog.
if [ -n "$FWD_HOST" ] && dpkg -s rsyslog >/dev/null 2>&1; then
    FWD_SYSLOG=yes
else
    FWD_SYSLOG=no
fi
cat > /etc/systemd/journald.conf.d/10-persistent.conf <<EOF
[Journal]
Storage=persistent
# Forward to rsyslog's legacy unix socket only when rsyslog is actually
# installed (opt-in via /etc/ncz-loghost). Default is journald-only.
ForwardToSyslog=${FWD_SYSLOG}
# Cap the on-disk ring so a runaway subsystem cannot fill btrfs@rootfs.
SystemMaxUse=200M
SystemKeepFree=100M
EOF
mkdir -p /var/log/journal
echo "[36] journald set persistent (Storage=persistent, ForwardToSyslog=${FWD_SYSLOG}, SystemMaxUse=200M)"

# ----------------------------------------------------------------------
# 4. Serial getty on ttyAMA0 @115200 (the REAL on-board UART)
# r123 fix: was serial-getty@ttyAMA2 — but /dev/ttyAMA2 does NOT enumerate on
# the MS-R1 booting from disk (only the debug harness exposes it). An enabled
# serial-getty@ttyAMA2 BindsTo dev-ttyAMA2.device, which then blocks getty.target
# (and thus graphical.target) for the full 90s device timeout on every boot.
# ttyAMA0 (ARMH0011) is the UART that actually enumerates, so the getty binds
# instantly and a serial login is still available for debugging.
# ----------------------------------------------------------------------
# ARCH GATE (2026-09-28). ttyAMA* is the ARM PL011 UART and does not exist on
# x86. Measured on CHIMERA (MacBookPro16,1, amd64): this hook enabled
# serial-getty@ttyAMA0, whose BindsTo dev-ttyAMA0.device never resolves, so
# `systemctl list-jobs` showed dev-ttyAMA0.device start running with
# getty.target -> multi-user.target -> graphical.target all queued behind it and
# `systemd-analyze` reporting FinishTimestampMonotonic=0. That is exactly the
# failure the r123 note above records for ttyAMA2 on Sky1, re-created on the
# other architecture because nothing gated it. Telnet (:23, directive 8) and
# tty1 remain the console fallback on x86; no serial getty is enabled there
# speculatively, because enabling a getty for a device that may not enumerate
# is the bug itself.
_ncz_arch="${NCZ_TARGET_ARCH:-}"
[ -n "$_ncz_arch" ] || _ncz_arch=$(cat /usr/local/lib/cix-installer/BUILD_ARCH 2>/dev/null | tr -d '[:space:]')
[ -n "$_ncz_arch" ] || _ncz_arch=$(dpkg --print-architecture 2>/dev/null || true)
# Belt-and-braces: ensure a stale ttyAMA2 getty can never be pulled in.
systemctl disable serial-getty@ttyAMA2.service 2>/dev/null || true
systemctl mask serial-getty@ttyAMA2.service 2>/dev/null || true
if [ "$_ncz_arch" = "arm64" ]; then
    systemctl enable serial-getty@ttyAMA0.service 2>&1 | tail -1
    echo "[36] serial-getty@ttyAMA0 enabled (115200); ttyAMA2 getty masked"
else
    systemctl disable serial-getty@ttyAMA0.service 2>/dev/null || true
    systemctl mask serial-getty@ttyAMA0.service 2>/dev/null || true
    echo "[36] arch=$_ncz_arch -- ttyAMA0/ttyAMA2 gettys masked (ARM-only UART)"
fi

echo "[36] DONE — telnet:23 + persistent journald (rsyslog→${LOGHOST} opt-in) + serial console"
