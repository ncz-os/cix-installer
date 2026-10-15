#!/bin/bash
# 35-ssh.sh - openssh-server, enabled on boot and in rescue.target.
#
# Goal: a freshly-installed machine is reachable on port 22 on day zero,
# without having to physically touch it, using the account passwords set
# at install time. No vendor or project SSH public key is installed: the
# image must not trust any key the machine's owner did not add themselves.
#
# Runs in the optional post-install phase after base services are present, so
# sshd's startup ordering doesn't fight quadlet generation.
set -euo pipefail

echo "[35] openssh-server (no vendor SSH keys)"

DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    openssh-server sudo

# Ensure the daemon comes up on boot. d-i tends to leave services
# disabled until first manual enable; explicit enable + ssh.socket make
# this idempotent if either path is in use.
#
# r76: dropped `|| true` - silent failure here on r75 Magnetar smoke
# left the MS-R1 test board unreachable on port 22. Fail loud so run-all.sh records the
# hook failure in $LOGDIR and the operator sees it. Magnetar without
# SSH is broken-by-definition; better to flag at install than to ship
# headless boxes without remote access.
systemctl enable ssh
# ssh.socket is generator-pulled on some systemd configs; tolerate
# a "static" non-zero from `enable` here, but record it.
if ! systemctl enable ssh.socket; then
    echo "  WARN: 'systemctl enable ssh.socket' returned non-zero (likely static-unit config - safe to ignore if ssh.service is enabled)"
fi

# Make sshd ALSO start in rescue.target - so rescue.target boots
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
# from another host can't reach the box (discovered 2026-05-03
# when a Sky1 test board wedged into rescue and we couldn't ssh in to inspect
# /var/log/cix-install/).
mkdir -p /etc/systemd/system/NetworkManager.service.d
cat > /etc/systemd/system/NetworkManager.service.d/run-in-rescue.conf <<'EOF'
[Install]
WantedBy=rescue.target
EOF
mkdir -p /etc/systemd/system/systemd-networkd.service.d
cat > /etc/systemd/system/systemd-networkd.service.d/run-in-rescue.conf <<'EOF'
[Install]
WantedBy=rescue.target
EOF

# ---- native Sinty network manager rescue activation ------------------
# On Sinty SKUs the actual network owner is /usr/bin/sinty-nmd (or a
# local build under /usr/local/bin/sinty-nmd), shipped as a native unit
# (e.g. sinty-nm.service) whose [Install] is WantedBy=multi-user.target
# only. 19-sinty-nm purges/masks NetworkManager and systemd-networkd on
# those SKUs, so the NM/networkd rescue drop-ins above are inert there:
# rescue.target would come up with sshd but no network owner, and the
# box would be unreachable. Detect the native owner and add a rescue
# drop-in for its unit. Preserve the normal multi-user enablement (do
# not touch the unit's own [Install]); only add WantedBy=rescue.target.
#
# If the native daemon is absent (non-Sinty SKU), skip silently and let
# the NM/networkd fallback above do its job. Never unmask an inactive
# fallback manager on a native SKU.
SINTY_NM_UNIT=""
if [ -x /usr/bin/sinty-nmd ] || [ -x /usr/local/bin/sinty-nmd ]; then
    # Canonical unit filename is sinty-nm.service. Probe the standard
    # unit search paths directly instead of piping list-unit-files
    # through awk|grep -q, which under `set -o pipefail` can SIGPIPE
    # the producer and silently mask the real owner.
    for cand in sinty-nm.service; do
        for d in /usr/lib/systemd/system /lib/systemd/system /etc/systemd/system; do
            if [ -f "$d/$cand" ]; then
                SINTY_NM_UNIT="$cand"
                break 2
            fi
        done
    done
    if [ -z "$SINTY_NM_UNIT" ]; then
        echo "ERROR: native Sinty daemon present but canonical unit sinty-nm.service not found in /usr/lib/systemd/system, /lib/systemd/system, or /etc/systemd/system" >&2
        exit 1
    fi
fi

if [ -n "$SINTY_NM_UNIT" ]; then
    echo "  native Sinty network manager detected: $SINTY_NM_UNIT"
    mkdir -p "/etc/systemd/system/${SINTY_NM_UNIT}.d"
    cat > "/etc/systemd/system/${SINTY_NM_UNIT}.d/run-in-rescue.conf" <<'EOF'
[Install]
WantedBy=rescue.target
EOF
    # Fail loud: if the native owner cannot be enabled for rescue, the
    # rescue boot will be unreachable. Do not silently continue.
    if ! systemctl reenable "$SINTY_NM_UNIT"; then
        echo "ERROR: failed to reenable $SINTY_NM_UNIT for rescue.target" >&2
        exit 1
    fi
fi

# Re-trigger preset so the drop-in WantedBy gets symlink-installed
systemctl reenable ssh || true
systemctl reenable NetworkManager 2>/dev/null || true
systemctl reenable systemd-networkd 2>/dev/null || true

# ---- authorized_keys -------------------------------------------------
# Deliberately NONE. Earlier images seeded root and every local user with
# project-owned public keys, which let those keys log in to any machine
# installed from a public image. Owners add their own keys with
# ssh-copy-id; existing authorized_keys files are left untouched.

# ---- sshd_config tweaks ---------------------------------------------
# Root login and password authentication stay enabled (documented default
# access model, see docs/REMOTE-ACCESS.md); key login works for any key the
# owner installs.
SSHD_DROPIN=/etc/ssh/sshd_config.d/10-nclawzero.conf
install -d -m 0755 /etc/ssh/sshd_config.d
cat > "$SSHD_DROPIN" <<'EOF'
# nclawzero factory defaults - see /etc/motd for rotation guidance.
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
ChallengeResponseAuthentication no
PubkeyAuthentication yes
EOF
chmod 0644 "$SSHD_DROPIN"

echo ""
echo "ssh service state:"
systemctl is-enabled ssh 2>&1 || true
systemctl is-enabled ssh.socket 2>&1 || true
