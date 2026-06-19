#!/bin/bash
# 09-diag-account.sh — installer-only diagnostic root-equivalent account.
#
# r110 (operator decision): this account is an install-time / first-boot
# RESCUE + telemetry affordance only. It MUST NOT persist on a normally
# running installed system. A first-boot systemd oneshot
# (nclawzero-diag-selfdestruct, installed at the end of this hook) deletes the
# account + every artifact (sudoers drop-in, AccountsService entry, marker,
# ssh keys via -r) and then removes itself — so the delivered appliance ships
# with no diagnostic credentials.
#
# Adds a `magnetar` user with password `diags` and full passwordless
# sudo. Purpose: guaranteed working login during hardware shakedown / a
# botched install, even when the operator account is misconfigured (e.g.
# password typo during d-i passwd-set, missed group membership, broken SSH).
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
DIAG_PASS='diags'

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
install -d -m 0755 /etc/sudoers.d
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

This account is an installer / first-boot rescue affordance only. It is
AUTOMATICALLY removed on the first successful boot by
nclawzero-diag-selfdestruct.service. If you are reading this on a running
system, the self-destruct has not run yet; remove it manually with:

  sudo /usr/local/sbin/nclawzero-diag-selfdestruct

To remove from future builds entirely: delete post-install/09-diag-account.sh
and re-bake the ISO.
EOF
chmod 0644 /etc/cix-diag-account.txt

# Hide the diagnostic account from the LightDM/GDM greeter user list so it is
# not shown (and not the default selected user) at the login screen. The
# account stays fully functional for SSH + manual login (type the username).
# AccountsService SystemAccount=true is honoured by lightdm-gtk-greeter and gdm.
install -d -m 0755 /var/lib/AccountsService/users
cat > /var/lib/AccountsService/users/${DIAG_USER} <<ASVC
[User]
SystemAccount=true
ASVC
chmod 0644 /var/lib/AccountsService/users/${DIAG_USER}
echo "[09] ${DIAG_USER} hidden from greeter (AccountsService SystemAccount=true)"

# --- r110: first-boot self-destruct -----------------------------------------
# The diag account must not exist on a normally running installed system. This
# oneshot runs on the FIRST boot, removes the account + all artifacts, then
# deletes itself. If the first boot fails before it runs, the account is still
# available for rescue; once the system boots cleanly it is gone.
cat > /usr/local/sbin/nclawzero-diag-selfdestruct <<'SELFDESTRUCT'
#!/bin/sh
# Remove the installer-only diagnostic account on first successful boot.
U=magnetar
logger -t nclawzero-diag-selfdestruct "removing transient diagnostic account $U" 2>/dev/null || true
pkill -KILL -u "$U" 2>/dev/null || true
userdel -r "$U" 2>/dev/null || true
rm -f /etc/sudoers.d/09-diag-magnetar
rm -f /var/lib/AccountsService/users/"$U"
rm -f /etc/cix-diag-account.txt
systemctl disable nclawzero-diag-selfdestruct.service 2>/dev/null || true
rm -f /etc/systemd/system/nclawzero-diag-selfdestruct.service
rm -f /etc/systemd/system/multi-user.target.wants/nclawzero-diag-selfdestruct.service
rm -f /usr/local/sbin/nclawzero-diag-selfdestruct
SELFDESTRUCT
chmod 0755 /usr/local/sbin/nclawzero-diag-selfdestruct

cat > /etc/systemd/system/nclawzero-diag-selfdestruct.service <<'UNIT'
[Unit]
Description=Remove installer-only diagnostic account on first boot (NCZ)
After=multi-user.target
ConditionPathExists=/usr/local/sbin/nclawzero-diag-selfdestruct

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nclawzero-diag-selfdestruct

[Install]
WantedBy=multi-user.target
UNIT
systemctl enable nclawzero-diag-selfdestruct.service 2>&1 | tail -1 || true
echo "[09] first-boot self-destruct armed (nclawzero-diag-selfdestruct.service)"

echo
echo "[09] Diagnostic account ready (installer/first-boot rescue only — self-destructs):"
echo "     login: $DIAG_USER / <preset password>"
echo "     sudo:  NOPASSWD"
echo "     ssh:   pubkey + password both work"
echo "     marker: /etc/cix-diag-account.txt"
