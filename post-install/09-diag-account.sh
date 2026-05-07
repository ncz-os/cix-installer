#!/bin/bash
# 09-diag-account.sh — TEMPORARY diagnostic root-equivalent account.
#
# REMOVE THIS HOOK BEFORE PUBLIC DISTRIBUTION.
#
# Adds a `magnetar` user with password `Gumbo@Kona1b` and full passwordless
# sudo. Purpose: guaranteed working login during r75/r76 hardware shakedown
# even when the operator account is misconfigured (e.g. password typo during
# d-i passwd-set, missed group membership, broken SSH on the primary user).
#
# This account is parallel to whatever the d-i preseed creates for the
# operator (typically `mini` or whatever was typed at install time). It
# does NOT replace the operator account; the operator account stays the
# canonical day-to-day login.
#
# Removal at distribution-cut time:
#   1. Delete this file: rm post-install/09-diag-account.sh
#   2. Re-bake the ISO. No other cleanup needed — the user only exists on
#      installed targets, and a fresh install simply won't create them.
#
# RUNS INSIDE CHROOT (via run-all.sh).
set -euo pipefail

DIAG_USER=magnetar
DIAG_PASS='Gumbo@Kona1b'

echo "[09] (TESTING) seeding diagnostic root-equivalent account: $DIAG_USER"
echo "[09] WARNING: this hook MUST be removed before public distribution."

if id "$DIAG_USER" >/dev/null 2>&1; then
    echo "[09] $DIAG_USER already exists — refreshing password + groups"
else
    useradd --create-home --shell /bin/bash --comment "Diagnostic account (testing only)" "$DIAG_USER"
    echo "[09] $DIAG_USER created"
fi

echo "${DIAG_USER}:${DIAG_PASS}" | chpasswd
echo "[09] password set"

# Pile on every group that touches device access so diagnostics work
# regardless of which subsystem is being chased (gpu/audio/serial/usb/etc).
for grp in sudo adm dialout plugdev video audio render input netdev systemd-journal; do
    if getent group "$grp" >/dev/null 2>&1; then
        usermod -aG "$grp" "$DIAG_USER"
    fi
done
echo "[09] $DIAG_USER added to: sudo adm dialout plugdev video audio render input netdev systemd-journal (where present)"

# Passwordless sudo via dedicated drop-in (so removal is one-line).
SUDOERS=/etc/sudoers.d/09-diag-magnetar
cat > "$SUDOERS" <<EOF
# TEMPORARY — testing-only diagnostic account. Remove before distribution.
# See post-install/09-diag-account.sh for context.
${DIAG_USER} ALL=(ALL) NOPASSWD:ALL
EOF
chmod 0440 "$SUDOERS"
echo "[09] $SUDOERS written (NOPASSWD)"

# Mirror fleet authorized_keys onto the diag account so SSH works without
# password too. Same key set 35-ssh.sh uses.
read -r -d '' DIAG_KEYS <<'EOF' || true
# === nclawzero fleet-default authorized_keys (DIAG account — testing only) ===
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBJ3z+8UX2oPt3cmN1X9XU8RWrgp7VvdHPd0vW+m/AoR jperlow@work-laptop
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHKCDT5Busd1J+j4kpzkZ/jT/GtUQylaZCUCTftY2sYk argos-backup
EOF

DIAG_HOME=$(getent passwd "$DIAG_USER" | cut -d: -f6)
DIAG_GROUP=$(id -gn "$DIAG_USER")
install -d -m 0700 -o "$DIAG_USER" -g "$DIAG_GROUP" "$DIAG_HOME/.ssh"
echo "$DIAG_KEYS" > "$DIAG_HOME/.ssh/authorized_keys"
chmod 0600 "$DIAG_HOME/.ssh/authorized_keys"
chown "$DIAG_USER:$DIAG_GROUP" "$DIAG_HOME/.ssh/authorized_keys"
echo "[09] $DIAG_HOME/.ssh/authorized_keys seeded"

# Drop a marker file so it's obvious in /etc what this account is.
cat > /etc/cix-diag-account.txt <<EOF
TEMPORARY DIAGNOSTIC ACCOUNT — testing only.

User:     $DIAG_USER
Password: <see post-install/09-diag-account.sh>
Sudo:     NOPASSWD (full root-equivalent)

This account exists ONLY for r75/r76 hardware shakedown. It MUST be
removed before any public distribution. To remove on a running system:

  sudo userdel -r $DIAG_USER
  sudo rm /etc/sudoers.d/09-diag-magnetar
  sudo rm /etc/cix-diag-account.txt

To remove from future builds: delete post-install/09-diag-account.sh
and re-bake the ISO.
EOF
chmod 0644 /etc/cix-diag-account.txt

echo
echo "[09] Diagnostic account ready:"
echo "     login: $DIAG_USER / <preset password>"
echo "     sudo:  NOPASSWD"
echo "     ssh:   pubkey + password both work"
echo "     marker: /etc/cix-diag-account.txt"
