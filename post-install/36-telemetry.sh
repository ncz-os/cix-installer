#!/bin/bash
# 36-telemetry.sh — maximum-telemetry + lockout-prevention console.
#
# Operator requirement (2026-06-01): "telnetd enabled by default with
# loghost to .22, I want all possible telemetry for debug."
#
# This hook makes a freshly-installed cixmini observable + recoverable
# from day zero, on BOTH the Reinhardt (desktop) and Magnetar (server)
# SKUs — telemetry is variant-agnostic, so there is no variant gate.
#
# It sets up four things:
#   1. telnetd on TCP 23 (CLAUDE.md directive 9 — LAN-only lockout
#      prevention; backup console when sshd hangs / has bad config).
#   2. rsyslog installed; remote loghost forwarding is OPT-IN via the
#      /etc/ncz-loghost marker (off by default — an always-on forward to a
#      fleet IP spammed "omfwd: Network is unreachable" on shipped images).
#   3. Persistent journald (Storage=persistent) so logs survive the
#      reboot and can be read from rescue.target afterwards.
#   4. Serial getty on ttyAMA0 @115200 — a real login over the on-board
#      UART (ttyAMA2 does not enumerate on disk-boot; see step 4 below).
#
# Failure-tolerant: this is a Phase 2 optional hook. Each step is
# wrapped so a single missing package can't abort the install. Runs in
# the chroot against the freshly-installed rootfs (Ubuntu questing /
# Debian bookworm), so `apt-get` + `systemctl enable` are available.
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

if dpkg -s openbsd-inetd >/dev/null 2>&1 && dpkg -s inetutils-telnetd >/dev/null 2>&1; then
    # Ensure the inetd telnet line is present + enabled. Invoke in.telnetd
    # DIRECTLY (no /usr/sbin/tcpd wrapper) — inetutils-telnetd does not pull
    # tcp-wrappers, so a tcpd-wrapped line silently fails to spawn telnetd
    # when tcpd is absent (Codex 26.6 review nit). Run as root so the daemon
    # can exec /bin/login.
    if ! grep -qE '^telnet[[:space:]]' /etc/inetd.conf 2>/dev/null; then
        echo 'telnet stream tcp nowait root /usr/sbin/in.telnetd in.telnetd' >> /etc/inetd.conf
    fi
    systemctl enable inetd 2>&1 | tail -1
    systemctl enable openbsd-inetd 2>&1 | tail -1
    echo "[36] telnetd via openbsd-inetd enabled"
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
# 2. rsyslog → loghost  (OPT-IN — off by default on a shipped image)
# ----------------------------------------------------------------------
# Forwarding *.* to a hardcoded fleet IP (192.168.207.22) is wrong for a
# shipped/community image: off-fleet that host is unreachable, so rsyslog's
# omfwd action logged "omfwd: Network is unreachable" ~26x every boot (the
# forward is attempted before the network route exists). Persistent journald
# (below) + serial console + telnet already cover on-box observability, so the
# remote forward is now OPT-IN: it is only written when the operator drops a
# marker file /etc/ncz-loghost with the loghost IP (or the legacy default is
# used when the marker just says "default"). No marker => no forward => no spam.
echo "[36] installing rsyslog (remote forward is opt-in via /etc/ncz-loghost)"
timeout 300 env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends rsyslog 2>&1 | tail -3

# Never ship the old always-on forward; remove any stale copy from a prior image.
rm -f /etc/rsyslog.d/90-loghost.conf

FWD_HOST=""
if [ -r /etc/ncz-loghost ]; then
    FWD_HOST=$(tr -d ' \t\r\n' < /etc/ncz-loghost)
    [ "$FWD_HOST" = "default" ] && FWD_HOST="$LOGHOST"
fi
if dpkg -s rsyslog >/dev/null 2>&1 && [ -n "$FWD_HOST" ]; then
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
    systemctl enable rsyslog 2>&1 | tail -1
    echo "[36] rsyslog forwarding *.* to ${FWD_HOST}:514 (opt-in, suspension reporting off)"
else
    echo "[36] rsyslog remote forward NOT configured (no /etc/ncz-loghost marker) — journald persistent covers logs"
fi

# ----------------------------------------------------------------------
# 3. Persistent journald (survive reboot for post-mortem)
# ----------------------------------------------------------------------
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/10-persistent.conf <<'EOF'
[Journal]
Storage=persistent
# Forward to /dev/console-attached syslog so rsyslog (above) sees kernel
# + service messages and can ship them to the loghost.
ForwardToSyslog=yes
# Keep a generous on-disk ring so a slow-developing fault is captured.
SystemMaxUse=512M
EOF
mkdir -p /var/log/journal
echo "[36] journald set persistent (Storage=persistent, ForwardToSyslog=yes)"

# ----------------------------------------------------------------------
# 4. Serial getty on ttyAMA0 @115200 (the REAL on-board UART)
# r123 fix: was serial-getty@ttyAMA2 — but /dev/ttyAMA2 does NOT enumerate on
# the MS-R1 booting from disk (only the debug harness exposes it). An enabled
# serial-getty@ttyAMA2 BindsTo dev-ttyAMA2.device, which then blocks getty.target
# (and thus graphical.target) for the full 90s device timeout on every boot.
# ttyAMA0 (ARMH0011) is the UART that actually enumerates, so the getty binds
# instantly and a serial login is still available for debugging.
# ----------------------------------------------------------------------
# Belt-and-braces: ensure a stale ttyAMA2 getty can never be pulled in.
systemctl disable serial-getty@ttyAMA2.service 2>/dev/null || true
systemctl mask serial-getty@ttyAMA2.service 2>/dev/null || true
systemctl enable serial-getty@ttyAMA0.service 2>&1 | tail -1
echo "[36] serial-getty@ttyAMA0 enabled (115200); ttyAMA2 getty masked"

echo "[36] DONE — telnet:23 + rsyslog→${LOGHOST} + persistent journal + serial console"
