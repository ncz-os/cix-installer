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
#   2. rsyslog forwarding ALL messages to loghost 192.168.207.22 (ARGOS)
#      over UDP/514 — so a box that wedges mid-boot still streams its
#      kernel + service logs to a host that stays up.
#   3. Persistent journald (Storage=persistent) so logs survive the
#      reboot and can be read from rescue.target afterwards.
#   4. Serial getty on ttyAMA2 @115200 — a real login over the serial
#      console that matches the console=ttyAMA2,115200 boot cmdline.
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
    for d in ttyAMA2 pts/0 pts/1 pts/2 pts/3 pts/4 pts/5 pts/6 pts/7 pts/8 pts/9; do
        grep -qxF "$d" /etc/securetty || echo "$d" >> /etc/securetty
    done
    echo "[36] /etc/securetty: ttyAMA2 + pts/0..9 permitted (root console/telnet fallback)"
fi

# ----------------------------------------------------------------------
# 2. rsyslog → loghost .22  (forward EVERYTHING, best-effort UDP)
# ----------------------------------------------------------------------
echo "[36] installing rsyslog + remote forwarding to $LOGHOST"
timeout 300 env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends rsyslog 2>&1 | tail -3

if dpkg -s rsyslog >/dev/null 2>&1; then
    mkdir -p /etc/rsyslog.d
    cat > /etc/rsyslog.d/90-loghost.conf <<EOF
# NCZ telemetry — forward ALL messages to fleet loghost (ARGOS .22).
# UDP @ = fire-and-forget (best effort, survives a wedging box better
# than a blocking TCP queue). Disk-queue so a brief loghost outage
# doesn't drop local logging.
\$ActionQueueType LinkedList
\$ActionQueueFileName loghost_fwd
\$ActionResumeRetryCount -1
\$ActionQueueSaveOnShutdown on
*.*  @${LOGHOST}:514
EOF
    # Pull kernel + journal into rsyslog so the forward includes them.
    systemctl enable rsyslog 2>&1 | tail -1
    echo "[36] rsyslog forwarding *.* to @${LOGHOST}:514 (UDP)"
else
    echo "[36] WARN: rsyslog unavailable — relying on journald forward only"
    # journald can forward to a remote via systemd-journal-upload, but
    # that needs a journal-remote receiver on .22. rsyslog UDP is the
    # simpler, more universally-received path; log the gap and continue.
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
# 4. Serial getty on ttyAMA2 @115200 (matches console= cmdline)
# ----------------------------------------------------------------------
systemctl enable serial-getty@ttyAMA2.service 2>&1 | tail -1
echo "[36] serial-getty@ttyAMA2 enabled (115200)"

echo "[36] DONE — telnet:23 + rsyslog→${LOGHOST} + persistent journal + serial console"
