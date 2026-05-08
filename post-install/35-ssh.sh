#!/bin/bash
# 35-ssh.sh - openssh-server + fleet-canonical authorized_keys.
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
#
# r76: dropped `|| true` - silent failure here on r75 Magnetar smoke
# left .66 unreachable on port 22. Fail loud so run-all.sh records the
# hook failure in $LOGDIR and the operator sees it. Magnetar without
# SSH is broken-by-definition; better to flag at install than to ship
# headless boxes without remote access.
systemctl enable ssh
# ssh.socket is generator-pulled on some systemd configs; tolerate
# a "static" non-zero from `enable` here, but record it.
if ! systemctl enable ssh.socket; then
    echo "  WARN: 'systemctl enable ssh.socket' returned non-zero (likely static-unit config - safe to ignore if ssh.service is enabled)"
fi

# Make sshd ALSO start in rescue.target - so cixmini-rescue.conf boots
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
# rescue.target - without this, sshd is up but has no IP, so SSH
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
# ARGOS (192.168.207.22, fleet build host - used for live diagnostics)
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHKCDT5Busd1J+j4kpzkZ/jT/GtUQylaZCUCTftY2sYk argos-backup
EOF

# Root account - only seed if absent (codex review: don't clobber
# operator-rotated keys).
install_authorized_keys() {
    local user=$1
    local home=$2
    local group=$3
    local keyfile="$home/.ssh/authorized_keys"

    install -d -m 0700 -o "$user" -g "$group" "$home/.ssh"
    if [ ! -s "$keyfile" ]; then
        echo "$KEYS" > "$keyfile"
        chmod 0600 "$keyfile"
        chown "$user:$group" "$keyfile"
        echo "  $keyfile seeded (was empty)"
    else
        echo "  $keyfile exists ($(wc -l < "$keyfile") lines) - preserving"
    fi
}

install_authorized_keys root /root root

# Operator accounts - seed every normal local user, plus explicit fallbacks for
# historical names. This covers the preseed-created operator and the temporary
# magnetar diagnostic account without guessing which UID was created first.
SEEDED_USERS=""
seed_user_if_present() {
    local user=$1
    local home group

    case " $SEEDED_USERS " in
        *" $user "*) return 0 ;;
    esac

    if ! id "$user" >/dev/null 2>&1; then
        return 0
    fi

    home=$(getent passwd "$user" | cut -d: -f6)
    group=$(id -gn "$user")
    if [ -z "$home" ] || [ "$home" = "/" ]; then
        echo "  WARN: skipping $user authorized_keys; invalid home '$home'"
        return 0
    fi

    install_authorized_keys "$user" "$home" "$group"
    SEEDED_USERS="$SEEDED_USERS $user"
}

for user in $(awk -F: '$3 >= 1000 && $3 < 65000 {print $1}' /etc/passwd); do
    seed_user_if_present "$user"
done
for user in ncz magnetar; do
    seed_user_if_present "$user"
done

# ---- sshd_config tweaks ---------------------------------------------
# Permit root login by key only (factory image needs root reachability for
# fleet-auth bootstrap). Password logins stay disabled for SSH; the diagnostic
# and operator accounts still have console passwords, but network access is
# fleet-key only.
SSHD_DROPIN=/etc/ssh/sshd_config.d/10-nclawzero.conf
install -d -m 0755 /etc/ssh/sshd_config.d
cat > "$SSHD_DROPIN" <<'EOF'
# nclawzero factory defaults - see /etc/motd for rotation guidance.
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
EOF
chmod 0644 "$SSHD_DROPIN"

echo ""
echo "Installed authorized_keys (count, files):"
wc -l /root/.ssh/authorized_keys 2>&1 || true
for user in $SEEDED_USERS; do
    home=$(getent passwd "$user" | cut -d: -f6)
    wc -l "$home/.ssh/authorized_keys" 2>&1 || true
done

echo ""
echo "ssh service state:"
systemctl is-enabled ssh 2>&1 || true
systemctl is-enabled ssh.socket 2>&1 || true
