#!/bin/bash
# 49-riskyeats-rescue.sh — RiskyEats pipeline rescue capability for cixmini.
#
# Configures cixmini (.66 / hostname `mini`) to participate as a full-pipeline
# rescue host for the RiskyEats sharded metro pipeline. The pipeline runs across
# ARGOS (192.168.207.22) / TYPHON (.61) / PROTEUS (.25) twice daily; if all
# three primary shard hosts miss their sentinel deadlines, the ARGOS aggregator
# SSHes into cixmini and dispatches a rescue shard run for any unfinished
# metros.
#
# This installer hook does NOT do the slow setup synchronously at install time
# (NFS server may not be reachable from the chroot, repo clone needs gitlab
# auth, uv install needs network). Instead it:
#   1. Adds NFS line to /etc/fstab for /mnt/argonas
#   2. Creates /mnt/argonas mountpoint
#   3. Drops /usr/local/sbin/riskyeats-rescue-setup — one-shot first-boot setup
#   4. Installs riskyeats-rescue-setup.service — runs once on first network-online
#
# On reflash, this hook re-runs at install time and the systemd oneshot re-runs
# on first boot, restoring rescue capability without operator intervention.

set -euo pipefail

echo "[49] RiskyEats rescue capability"

RESCUE_USER="mini"
RESCUE_HOME="/home/${RESCUE_USER}"
NFS_HOST="192.168.207.101"
NFS_SRC="${NFS_HOST}:/mnt"
NFS_MNT="/mnt/argonas"
RISKYEATS_NFS_PATH="${NFS_MNT}/datapool/projects/riskyeats"
VENV_DIR="${RESCUE_HOME}/.riskyeats-venv-mini"

# --- 1. fstab entry for NFS share ---
mkdir -p "${NFS_MNT}"
if ! grep -Eq "^[^#].*${NFS_HOST}.*${NFS_MNT}" /etc/fstab 2>/dev/null; then
    printf "%s  %s  nfs  _netdev,x-systemd.automount,nofail,timeo=14,soft  0  0\n" \
        "${NFS_SRC}" "${NFS_MNT}" >> /etc/fstab
    echo "  added NFS fstab entry: ${NFS_SRC} -> ${NFS_MNT}"
else
    echo "  NFS fstab entry already present"
fi

# --- 2. first-boot setup script ---
install -d -m 0755 /usr/local/sbin
cat > /usr/local/sbin/riskyeats-rescue-setup <<'SCRIPT'
#!/bin/bash
# riskyeats-rescue-setup — finalize rescue config once network is up.
set -euo pipefail
exec >> /var/log/riskyeats-rescue-setup.log 2>&1
echo ""
echo "================================================"
echo "RESCUE SETUP $(date -Iseconds)"
echo "================================================"

RESCUE_USER="mini"
RESCUE_HOME="/home/${RESCUE_USER}"
NFS_MNT="/mnt/argonas"
RISKYEATS_NFS_PATH="${NFS_MNT}/datapool/projects/riskyeats"
VENV_DIR="${RESCUE_HOME}/.riskyeats-venv-mini"
ARGOS_PUBKEY_NFS="${NFS_MNT}/datapool/projects/fleet-secrets/argos-rescue.pub"

# Wait for NFS reachable (automount will mount on first access; force a stat)
for i in $(seq 1 30); do
    if stat "${RISKYEATS_NFS_PATH}/pyproject.toml" >/dev/null 2>&1; then
        echo "  NFS reachable on attempt $i"
        break
    fi
    echo "  waiting for NFS ($i/30)"
    sleep 4
done
if ! [ -f "${RISKYEATS_NFS_PATH}/pyproject.toml" ]; then
    echo "  ERROR: NFS still unreachable; will retry next boot via systemd"
    exit 1
fi

# uv installer (idempotent — skips if already present)
if ! sudo -u "${RESCUE_USER}" test -x "${RESCUE_HOME}/.local/bin/uv"; then
    echo "  installing uv for ${RESCUE_USER}"
    sudo -u "${RESCUE_USER}" bash -lc 'curl -LsSf https://astral.sh/uv/install.sh | sh' || {
        echo "  WARN: uv install failed (no network?); will retry next boot"
        exit 1
    }
fi

# Pull gitlab credentials from ARGOS (only on LAN; pubkey-only auth)
if [ ! -s "${RESCUE_HOME}/.git-credentials" ]; then
    echo "  pulling gitlab creds from ARGOS"
    if sudo -u "${RESCUE_USER}" ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
         jasonperlow@192.168.207.22 'cat ~/.git-credentials' > "${RESCUE_HOME}/.git-credentials" 2>/dev/null; then
        chown "${RESCUE_USER}:${RESCUE_USER}" "${RESCUE_HOME}/.git-credentials"
        chmod 0600 "${RESCUE_HOME}/.git-credentials"
        sudo -u "${RESCUE_USER}" git config --global credential.helper store
        echo "  git creds installed"
    else
        echo "  WARN: could not pull gitlab creds (no SSH key to ARGOS yet?)"
    fi
fi

# Authorize ARGOS to SSH in for rescue dispatch (best-effort)
mkdir -p "${RESCUE_HOME}/.ssh"
chmod 0700 "${RESCUE_HOME}/.ssh"
touch "${RESCUE_HOME}/.ssh/authorized_keys"
chmod 0600 "${RESCUE_HOME}/.ssh/authorized_keys"
chown -R "${RESCUE_USER}:${RESCUE_USER}" "${RESCUE_HOME}/.ssh"
if [ -f "${ARGOS_PUBKEY_NFS}" ]; then
    fp="$(ssh-keygen -lf "${ARGOS_PUBKEY_NFS}" 2>/dev/null | awk '{print $2}')"
    if [ -n "$fp" ] && ! ssh-keygen -lf "${RESCUE_HOME}/.ssh/authorized_keys" 2>/dev/null | grep -qF "$fp"; then
        cat "${ARGOS_PUBKEY_NFS}" >> "${RESCUE_HOME}/.ssh/authorized_keys"
        echo "  ARGOS pubkey authorized from NFS"
    fi
else
    echo "  WARN: ARGOS rescue pubkey not found at ${ARGOS_PUBKEY_NFS}"
fi

# Build venv once (~45s); subsequent runs short-circuit via stamp
if [ ! -x "${VENV_DIR}/bin/python" ]; then
    echo "  uv sync for riskyeats venv (one-time, ~45s)"
    sudo -u "${RESCUE_USER}" bash -lc "
        cd '${RISKYEATS_NFS_PATH}'
        export UV_PROJECT_ENVIRONMENT='${VENV_DIR}'
        export UV_LINK_MODE=copy
        export PATH=\"\$HOME/.local/bin:\$PATH\"
        uv sync
    " || {
        echo "  WARN: uv sync failed; will retry next boot"
        exit 1
    }
fi

# Smoke-test
if sudo -u "${RESCUE_USER}" "${VENV_DIR}/bin/python3" -c 'import polars, riskyeats' 2>/dev/null; then
    echo "  rescue venv smoke OK"
    touch /var/lib/riskyeats-rescue.ready
else
    echo "  WARN: smoke failed"
    exit 1
fi

echo "RESCUE SETUP COMPLETE $(date -Iseconds)"
SCRIPT
chmod 0755 /usr/local/sbin/riskyeats-rescue-setup

# --- 3. systemd oneshot, runs on every boot until ready marker exists ---
cat > /etc/systemd/system/riskyeats-rescue-setup.service <<'UNIT'
[Unit]
Description=RiskyEats rescue host first-boot setup
After=network-online.target
Wants=network-online.target
ConditionPathExists=!/var/lib/riskyeats-rescue.ready

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/riskyeats-rescue-setup
TimeoutStartSec=600
StandardOutput=journal
StandardError=journal
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload || true
systemctl enable riskyeats-rescue-setup.service >/dev/null 2>&1 || true

echo "  riskyeats-rescue-setup.service enabled (runs on next boot until /var/lib/riskyeats-rescue.ready exists)"
echo "[49] done"
