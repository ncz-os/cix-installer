#!/bin/bash
# build-mgmt-rootfs.sh - build the Magnetar nspawn recovery/management rootfs.
#
# Produces assets/mgmt/ncz-mgmt-rootfs.tar.zst: a minimal Ubuntu (resolute)
# arm64 rootfs that boots under systemd-nspawn (Boot=yes) with its OWN complete
# userland (glibc/NSS/PAM/openssh). This is the MIDDLE recovery tier on Magnetar
# edge boxes, between the day-to-day host sshd:22 and the crash-proof static
# busybox telnet :2323 (post-install/37-failsafe-access.sh):
#
#   - It survives total host /usr/lib damage (the 2026-06-25 .66 incident) the
#     same way the static failsafe does, because it shares NOTHING with the host
#     userland -- a private-libdir sshd would NOT, since glibc still dlopens
#     libnss_*/PAM from the broken host /usr/lib.
#   - Unlike the static telnet failsafe it speaks ssh + SFTP/scp, so an operator
#     can pull/push files while repairing.
#   - post-install/38-recovery-container.sh gives it its own macvlan LAN IP and
#     a READ-WRITE bind of the host root at /host so it can repair in place.
#
# KERNEL-FREE on purpose: nspawn shares the host kernel.
#
# Runs on the Linux arm64 build host (ARGOS), native debootstrap - no qemu.
# Usage:  sudo bash build/build-mgmt-rootfs.sh [chroot_dir] [out_tarball] [suite] [arch] [mirror]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

CHROOT="${1:-$ROOT/build/mgmt-rootfs}"
OUT="${2:-$ROOT/assets/mgmt/ncz-mgmt-rootfs.tar.zst}"
SUITE="${3:-resolute}"
ARCH="${4:-arm64}"
MIRROR="${5:-http://ports.ubuntu.com/ubuntu-ports}"

PKG_MANIFEST="$ROOT/manifests/mgmt.pkgs"

# Recovery container credentials. LAN-only (192.168.207.0/24, no public route)
# per fleet doctrine. Fleet break-glass secret by default; override at bake time
# by exporting NCZ_MGMT_PASS. Day-to-day access is key-based (the post-install
# hook injects fleet authorized_keys into the container's /root/.ssh).
MGMT_ROOT_PW="${NCZ_MGMT_PASS:-Gumbo@Kona1b}"
MGMT_HOSTNAME="ncz-recovery"

for t in debootstrap chroot zstd tar awk sed grep mountpoint; do
    command -v "$t" >/dev/null 2>&1 || { echo "ERROR: missing build-host tool: $t" >&2; exit 1; }
done
[ -f "$PKG_MANIFEST" ] || { echo "ERROR: manifest not found: $PKG_MANIFEST" >&2; exit 1; }

PKGS=$(grep -vE '^\s*(#|$)' "$PKG_MANIFEST" | sed 's/#.*//' | awk '{print $1}' | grep . | sort -u | tr '\n' ' ')
echo "[mgmt-rootfs] chroot:   $CHROOT"
echo "[mgmt-rootfs] out:      $OUT"
echo "[mgmt-rootfs] suite:    $SUITE   arch: $ARCH"
echo "[mgmt-rootfs] mirror:   $MIRROR"
echo "[mgmt-rootfs] packages: $(echo "$PKGS" | wc -w | tr -d ' ') from manifest"

# ----------------------------------------------------------------------
# Clean any prior chroot (best-effort unmount first).
# ----------------------------------------------------------------------
for d in dev/pts dev proc sys; do
    mountpoint -q "$CHROOT/$d" && umount -lf "$CHROOT/$d" || true
done
rm -rf "$CHROOT"
mkdir -p "$CHROOT" "$(dirname "$OUT")"

# ----------------------------------------------------------------------
# Stage 1 - debootstrap minimal base (native arm64, no foreign/qemu).
# ----------------------------------------------------------------------
echo "[mgmt-rootfs] debootstrap $SUITE..."
debootstrap --arch="$ARCH" --variant=minbase \
    --include=ca-certificates,apt-utils "$SUITE" "$CHROOT" "$MIRROR"

cat > "$CHROOT/etc/apt/sources.list" <<EOF
deb $MIRROR $SUITE main universe restricted multiverse
deb $MIRROR $SUITE-updates main universe restricted multiverse
deb $MIRROR $SUITE-security main universe restricted multiverse
EOF

# ----------------------------------------------------------------------
# Stage 2 - bind mounts + apt install of the management toolset.
# ----------------------------------------------------------------------
mount --bind /dev     "$CHROOT/dev"
mount --bind /dev/pts "$CHROOT/dev/pts"
mount -t proc proc    "$CHROOT/proc"
mount -t sysfs sys    "$CHROOT/sys"
cleanup() {
    for d in dev/pts dev proc sys; do
        mountpoint -q "$CHROOT/$d" && umount -lf "$CHROOT/$d" || true
    done
}
trap cleanup EXIT

chroot "$CHROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive bash -eu <<CHROOT_APT
apt-get update
apt-get install -y --no-install-recommends $PKGS
apt-get clean
CHROOT_APT

# ----------------------------------------------------------------------
# Stage 3 - container configuration (baked into the rootfs).
# ----------------------------------------------------------------------
echo "[mgmt-rootfs] applying recovery-container configuration"

# hostname
echo "$MGMT_HOSTNAME" > "$CHROOT/etc/hostname"
printf '127.0.0.1\tlocalhost\n127.0.1.1\t%s\n' "$MGMT_HOSTNAME" > "$CHROOT/etc/hosts"

# root password (LAN-only recovery; primary access is key-based).
chroot "$CHROOT" /bin/sh -c "echo 'root:$MGMT_ROOT_PW' | chpasswd"

# RW host-bind mountpoint (post-install hook binds host / here).
mkdir -p "$CHROOT/host"

# --- networking: own macvlan IP via systemd-networkd + DNS via resolved ---
# nspawn MACVLAN= moves a macvlan iface named mv-<hostnic> into the container.
# Match mv-* (macvlan), host0 (veth fallback), and en* so DHCP comes up
# regardless of the host NIC name resolved at install time.
mkdir -p "$CHROOT/etc/systemd/network"
cat > "$CHROOT/etc/systemd/network/80-recovery.network" <<'EOF'
[Match]
Name=mv-* host0 en*

[Network]
DHCP=yes

[DHCPv4]
UseHostname=no
EOF
chroot "$CHROOT" systemctl enable systemd-networkd.service 2>/dev/null || true
chroot "$CHROOT" systemctl enable systemd-resolved.service 2>/dev/null || true
# resolved manages /etc/resolv.conf via the stub symlink.
ln -sf /run/systemd/resolve/stub-resolv.conf "$CHROOT/etc/resolv.conf" 2>/dev/null || true

# --- sshd: ssh + SFTP, key-first with password break-glass (LAN-only) ---
mkdir -p "$CHROOT/etc/ssh/sshd_config.d"
cat > "$CHROOT/etc/ssh/sshd_config.d/99-recovery.conf" <<'EOF'
# NCZ Magnetar recovery container - LAN-only break-glass. Primary access is
# fleet key-based (authorized_keys injected by post-install/38); password is a
# fallback. The SFTP subsystem is what this tier adds over the :2323 telnet
# failsafe.
PermitRootLogin yes
PasswordAuthentication yes
PermitEmptyPasswords no
Subsystem sftp /usr/lib/openssh/sftp-server
EOF
chroot "$CHROOT" systemctl enable ssh.service 2>/dev/null || \
    chroot "$CHROOT" systemctl enable sshd.service 2>/dev/null || true

# --- host-repair helpers (operate on the RW /host bind) ---
# Repair the usrmerge /lib symlink a bad `tar -C /` of a modules tarball can
# clobber (the 2026-06-25 .66 lockout). Defaults to /host.
cat > "$CHROOT/usr/local/sbin/ncz-fixlib" <<'EOF'
#!/bin/sh
# ncz-fixlib [root]   (default: /host) - restore the usrmerge /lib -> usr/lib
# symlink so dynamically linked host binaries can exec again.
set -eu
ROOT="${1:-/host}"
[ -d "$ROOT/usr/lib" ] || { echo "ERROR: $ROOT/usr/lib missing - not a usrmerge root"; exit 1; }
if [ -L "$ROOT/lib" ]; then
    echo "[fixlib] $ROOT/lib already a symlink -> $(readlink "$ROOT/lib"); nothing to do"
    exit 0
fi
if [ -d "$ROOT/lib" ]; then
    ts=$(date +%Y%m%d-%H%M%S)
    echo "[fixlib] $ROOT/lib is a REAL dir - merging into usr/lib and restoring symlink"
    cp -a "$ROOT/lib/." "$ROOT/usr/lib/" 2>/dev/null || true
    mv "$ROOT/lib" "$ROOT/lib.broken.$ts"
    ln -s usr/lib "$ROOT/lib"
    echo "[fixlib] done: $ROOT/lib -> usr/lib (old dir at lib.broken.$ts)"
else
    echo "[fixlib] $ROOT/lib missing - creating symlink -> usr/lib"
    ln -s usr/lib "$ROOT/lib"
fi
EOF
chmod 0755 "$CHROOT/usr/local/sbin/ncz-fixlib"

# Drop into a chroot on the bound host root (with dev/proc/sys from /host).
cat > "$CHROOT/usr/local/sbin/ncz-host-chroot" <<'EOF'
#!/bin/sh
# ncz-host-chroot - chroot into the RW-bound host root (/host) for in-place repair.
set -eu
ROOT="${1:-/host}"
[ -x "$ROOT/bin/bash" ] || [ -x "$ROOT/usr/bin/bash" ] || echo "[chroot] warn: $ROOT/bin/bash not executable (host may be wedged; run ncz-fixlib $ROOT first)"
echo "[chroot] entering $ROOT - type 'exit' to leave"
chroot "$ROOT" /bin/bash || chroot "$ROOT" /bin/sh || true
EOF
chmod 0755 "$CHROOT/usr/local/sbin/ncz-host-chroot"

# MOTD
cat > "$CHROOT/etc/motd" <<EOF

  NCZ-OS MAGNETAR RECOVERY CONTAINER (systemd-nspawn)
  ---------------------------------------------------
  This is the middle recovery tier. It has its OWN userland, so it stays
  reachable even if the host /usr/lib is wedged. The host root is bound
  READ-WRITE at /host.
  Helpers:  ncz-fixlib [/host]      ncz-host-chroot [/host]
  Transfer: scp/sftp to this container's own LAN IP (see: machinectl status ncz-recovery on the host)

EOF

# Drop apt lists/cache to shrink the tarball.
rm -rf "$CHROOT/var/lib/apt/lists/"* "$CHROOT/var/cache/apt/archives/"*.deb 2>/dev/null || true
# Empty machine-id so nspawn provisions a fresh one per host.
: > "$CHROOT/etc/machine-id" 2>/dev/null || true

# ----------------------------------------------------------------------
# Stage 4 - pack the tarball (unmount binds first).
# ----------------------------------------------------------------------
cleanup
trap - EXIT

echo "[mgmt-rootfs] packing $OUT"
tar -C "$CHROOT" --numeric-owner -cpf - . | zstd -19 -T0 -o "$OUT" -f
echo "[mgmt-rootfs] done: $(du -h "$OUT" | cut -f1)"
