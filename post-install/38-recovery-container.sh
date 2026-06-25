#!/bin/bash
# 38-recovery-container.sh - Magnetar nspawn recovery/management container.
#
# Installs a systemd-nspawn container ("ncz-recovery") that is the MIDDLE
# recovery tier on the Magnetar edge SKU, between the day-to-day host sshd:22
# (35-ssh.sh) and the crash-proof static busybox telnet :2323
# (37-failsafe-access.sh):
#
#   - It ships its OWN complete userland (glibc/NSS/PAM/openssh), so a wedged
#     host /usr/lib (the 2026-06-25 .66 lockout) cannot break it -- a
#     private-libdir sshd would NOT survive, since glibc still dlopens
#     libnss_*/PAM from the broken host /usr/lib.
#   - Unlike the static telnet failsafe, it speaks ssh + SFTP/scp.
#   - It gets its OWN macvlan LAN IP (reachable from other fleet hosts) and a
#     READ-WRITE bind of the host root at /host so an operator can repair the
#     host in place (helpers: ncz-fixlib, ncz-host-chroot inside the container).
#
# DESKTOP (Reinhardt) SKU: no-op. Server/Magnetar/headless only.
#
# RUNS INSIDE CHROOT (via run-all.sh), Phase 2 optional hook.
set -euo pipefail

VARIANT="desktop"
VARIANT_FILE=/usr/local/lib/cix-installer/BUILD_VARIANT
[ -f "$VARIANT_FILE" ] && VARIANT=$(tr -d ' \t\r\n' < "$VARIANT_FILE")

case "$VARIANT" in
    server|magnetar|headless) ;;
    *)
        echo "[38] BUILD_VARIANT=$VARIANT - Reinhardt SKU; skipping nspawn recovery container"
        exit 0
        ;;
esac

echo "[38] Magnetar nspawn recovery/management container (ncz-recovery)"

MACHINE=ncz-recovery
MACHINE_ROOT=/var/lib/machines/$MACHINE
ROOTFS_TARBALL=/usr/local/lib/cix-installer/assets/mgmt/ncz-mgmt-rootfs.tar.zst

# ---- 1. host nspawn runtime (offline from embedded server-mirror) ----
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    systemd-container

# ---- 2. extract the container rootfs ----
if [ ! -f "$ROOTFS_TARBALL" ]; then
    echo "[38] ERROR: $ROOTFS_TARBALL missing (build/build-mgmt-rootfs.sh not run before ISO build)"
    exit 1
fi
echo "[38] extracting container rootfs -> $MACHINE_ROOT"
rm -rf "$MACHINE_ROOT"
mkdir -p "$MACHINE_ROOT"
zstd -dc "$ROOTFS_TARBALL" | tar --numeric-owner -xpf - -C "$MACHINE_ROOT"

# ---- 3. nspawn config: boot it, own macvlan IP, RW host bind at /host ----
# MACVLAN= is a placeholder; ncz-recovery-netparent.service rewrites it to the
# host's real uplink NIC at boot (the name varies per box, e.g. enp1s0).
install -d -m 0755 /etc/systemd/nspawn
cat > /etc/systemd/nspawn/$MACHINE.nspawn <<'EOF'
# NCZ Magnetar recovery/management container.
# MACVLAN= is rewritten at boot by ncz-recovery-netparent.service to the host's
# real uplink NIC. Bind=/:/host gives the container READ-WRITE access to the
# host root for in-place repair (LAN-only doctrine; key-gated + password).
#
# PrivateUsers=no is REQUIRED: the stock systemd-nspawn@.service template runs
# with -U (private user namespace), which maps container root to a high host
# UID, so host files appear nobody:nogroup and the RW /host bind is read-only to
# the operator. The template passes --settings=override, so this file value
# overrides -U and restores container-root == host-root (uid 0) for real repair.
[Exec]
Boot=yes
PrivateUsers=no

[Network]
MACVLAN=enp1s0

[Files]
Bind=/:/host
EOF

# macvlan is not auto-loaded by systemd-nspawn; without it the container fails to
# start ("Failed to add new macvlan interfaces: Operation not supported"). Load
# it at boot (the netparent oneshot also modprobes it before the container).
echo macvlan > /etc/modules-load.d/ncz-recovery.conf

# ---- 4. fleet authorized_keys into the container's root account ----
# Reuse the fleet-canonical keys from 35-ssh.sh so the recovery container is
# reachable from this Mac + ARGOS on first boot (key-first; password fallback).
install -d -m 0700 "$MACHINE_ROOT/root/.ssh"
cat > "$MACHINE_ROOT/root/.ssh/authorized_keys" <<'EOF'
# === nclawzero fleet-default authorized_keys (ncz-recovery container) ===
# jperlow-mlt (this Mac, primary operator workstation)
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBJ3z+8UX2oPt3cmN1X9XU8RWrgp7VvdHPd0vW+m/AoR jperlow@work-laptop
# ARGOS (192.168.207.22, fleet build host - used for live diagnostics)
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHKCDT5Busd1J+j4kpzkZ/jT/GtUQylaZCUCTftY2sYk argos-backup
EOF
chmod 0600 "$MACHINE_ROOT/root/.ssh/authorized_keys"
# Container is not user-ns mapped by default, so uid 0 == host root; ownership
# is already root:root from the chroot context.

# ---- 5. per-box macvlan parent NIC resolver (name varies per box) ----
cat > /usr/local/sbin/ncz-recovery-netparent <<'EOF'
#!/bin/sh
# Set the ncz-recovery .nspawn MACVLAN= parent to the host's real uplink NIC,
# and ensure the macvlan module is loaded before the container starts.
set -eu
modprobe macvlan 2>/dev/null || true
NSPAWN=/etc/systemd/nspawn/ncz-recovery.nspawn
[ -f "$NSPAWN" ] || exit 0
parent=$(ip -o route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
if [ -z "$parent" ]; then
    for i in $(ls /sys/class/net 2>/dev/null); do
        case "$i" in en*|eth*) parent="$i"; break;; esac
    done
fi
[ -n "$parent" ] || { echo "ncz-recovery-netparent: no uplink NIC found"; exit 0; }
sed -i "s/^MACVLAN=.*/MACVLAN=$parent/" "$NSPAWN"
echo "ncz-recovery-netparent: MACVLAN=$parent"
EOF
chmod 0755 /usr/local/sbin/ncz-recovery-netparent

cat > /etc/systemd/system/ncz-recovery-netparent.service <<'EOF'
[Unit]
Description=Resolve macvlan parent NIC for the ncz-recovery container
After=network-pre.target systemd-udevd.service
Before=systemd-nspawn@ncz-recovery.service
Wants=network-pre.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/ncz-recovery-netparent
[Install]
WantedBy=multi-user.target
EOF

# ---- 6. enable container + resolver at boot ----
# `systemctl enable systemd-nspawn@X` puts the instance in machines.target.wants,
# but machines.target has no [Install] of its own and is not always reached, so
# we ALSO pull the instance directly into multi-user.target.wants. Doing both is
# harmless (started once) and guarantees boot start regardless of machines.target.
systemctl enable ncz-recovery-netparent.service
systemctl enable systemd-nspawn@$MACHINE.service || true
install -d -m 0755 /etc/systemd/system/multi-user.target.wants
ln -sf /usr/lib/systemd/system/systemd-nspawn@.service \
    /etc/systemd/system/multi-user.target.wants/systemd-nspawn@$MACHINE.service 2>/dev/null || true

echo "[38] ncz-recovery container staged ($(du -sh "$MACHINE_ROOT" 2>/dev/null | cut -f1)); enabled on boot with its own macvlan IP + RW /host bind."
