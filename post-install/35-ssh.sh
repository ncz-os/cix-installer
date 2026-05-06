#!/bin/bash
# 35-ssh.sh — openssh-server + fleet-canonical authorized_keys.
#
# Goal: a freshly-installed cixmini is reachable on port 22 from any
# fleet host on day zero, without having to physically touch it. Both
# root and the ncz operator account get the same authorized_keys so
# operators can ssh in directly + use sudo, while diagnostics from
# this Mac (jperlow-mlt) and ARGOS work as root over the network.
#
# Runs after 30-agents (which already enabled podman.socket etc.) so
# sshd's startup ordering doesn't fight quadlet generation.
set -euo pipefail

echo "[35] openssh-server + fleet authorized_keys"

DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    openssh-server sudo

# Ensure the daemon comes up on boot. d-i tends to leave services
# disabled until first manual enable; explicit enable + ssh.socket make
# this idempotent if either path is in use.
systemctl enable ssh || true
systemctl enable ssh.socket || true

# Make sshd ALSO start in rescue.target — so cixmini-rescue.conf boots
# get a remote shell for diagnostics. By default rescue.target only
# runs emergency-grade services (no sshd). Drop-in pulls sshd in via
# WantedBy=rescue.target alongside multi-user.target. Critical when
# normal boot wedges and the only way to inspect /var/log/cix-install/
# is via SSH.
mkdir -p /etc/systemd/system/ssh.service.d
cat > /etc/systemd/system/ssh.service.d/run-in-rescue.conf <<'EOF'
[Install]
WantedBy=rescue.target
EOF
# sshd ALSO needs networking active in rescue.target. By default
# rescue.target doesn't pull NetworkManager (it's pulled by
# multi-user.target). Add a drop-in to NetworkManager so it joins
# rescue.target — without this, sshd is up but has no IP, so SSH
# from another fleet host can't reach the box (discovered 2026-05-03
# when cixmini wedged into rescue and we couldn't ssh in to inspect
# /var/log/cix-install/).
mkdir -p /etc/systemd/system/NetworkManager.service.d
cat > /etc/systemd/system/NetworkManager.service.d/run-in-rescue.conf <<'EOF'
[Install]
WantedBy=rescue.target
EOF
# Re-trigger preset so the drop-in WantedBy gets symlink-installed
systemctl reenable ssh || true
systemctl reenable NetworkManager 2>/dev/null || true

# ---- authorized_keys -------------------------------------------------
# Fleet-canonical keys baked here so the device is reachable immediately
# after first boot. Operators can rotate via sync-fleet-keys.sh later.
read -r -d '' KEYS <<'EOF' || true
# === nclawzero fleet-default authorized_keys (cixmini factory image) ===
# jperlow-mlt (this Mac, primary operator workstation)
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBJ3z+8UX2oPt3cmN1X9XU8RWrgp7VvdHPd0vW+m/AoR jperlow@work-laptop
# ARGOS (192.168.207.22, fleet build host — used for live diagnostics)
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHKCDT5Busd1J+j4kpzkZ/jT/GtUQylaZCUCTftY2sYk argos-backup
EOF

# Root account — only seed if absent (codex review: don't clobber operator-rotated keys)
install -d -m 0700 -o root -g root /root/.ssh
if [ ! -s /root/.ssh/authorized_keys ]; then
    echo "$KEYS" > /root/.ssh/authorized_keys
    chmod 0600 /root/.ssh/authorized_keys
    chown root:root /root/.ssh/authorized_keys
    echo "  /root/.ssh/authorized_keys seeded (was empty)"
else
    echo "  /root/.ssh/authorized_keys exists ($(wc -l < /root/.ssh/authorized_keys) lines) — preserving"
fi

# Operator account — preseed creates 'ncz' by default but be defensive: detect
# the first UID >= 1000 < 65000 user dynamically so this still works if the
# preseed prompts the user for a different name (or no longer auto-creates ncz).
OPERATOR_USER=$(awk -F: '$3 >= 1000 && $3 < 65000 {print $1; exit}' /etc/passwd)
if [ -z "$OPERATOR_USER" ] && id ncz >/dev/null 2>&1; then
    OPERATOR_USER=ncz  # explicit fallback
fi
if [ -n "$OPERATOR_USER" ] && id "$OPERATOR_USER" >/dev/null 2>&1; then
    OPERATOR_HOME=$(getent passwd "$OPERATOR_USER" | cut -d: -f6)
    OPERATOR_GROUP=$(id -gn "$OPERATOR_USER")
    install -d -m 0700 -o "$OPERATOR_USER" -g "$OPERATOR_GROUP" "$OPERATOR_HOME/.ssh"
    # r63 (codex review): only seed if absent — don't clobber operator-rotated keys
    if [ ! -s "$OPERATOR_HOME/.ssh/authorized_keys" ]; then
        echo "$KEYS" > "$OPERATOR_HOME/.ssh/authorized_keys"
        chmod 0600 "$OPERATOR_HOME/.ssh/authorized_keys"
        chown "$OPERATOR_USER:$OPERATOR_GROUP" "$OPERATOR_HOME/.ssh/authorized_keys"
        echo "  $OPERATOR_HOME/.ssh/authorized_keys seeded (was empty)"
    else
        echo "  $OPERATOR_HOME/.ssh/authorized_keys exists — preserving"
    fi
fi

# ---- sshd_config tweaks ---------------------------------------------
# Permit root login by key only (factory image needs root reachability
# for fleet-auth bootstrap; operators harden post-rotate). Keep
# password-auth on for emergency console login with the seeded
# fleet-default password.
SSHD_DROPIN=/etc/ssh/sshd_config.d/10-nclawzero.conf
install -d -m 0755 /etc/ssh/sshd_config.d
cat > "$SSHD_DROPIN" <<'EOF'
# nclawzero factory defaults — see /etc/motd for rotation guidance.
PermitRootLogin prohibit-password
PasswordAuthentication yes
PubkeyAuthentication yes
EOF
chmod 0644 "$SSHD_DROPIN"

echo ""
echo "Installed authorized_keys (count, files):"
wc -l /root/.ssh/authorized_keys "${OPERATOR_HOME:-/home/ncz}/.ssh/authorized_keys" 2>&1 || true

echo ""
echo "ssh service state:"
systemctl is-enabled ssh 2>&1 || true
systemctl is-enabled ssh.socket 2>&1 || true
