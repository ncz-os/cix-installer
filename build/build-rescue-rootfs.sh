#!/bin/bash
# build-rescue-rootfs.sh — build the r130 dedicated RESCUE PARTITION rootfs.
#
# Produces assets/rescue/rescue-rootfs.tar.zst: a minimal Ubuntu (resolute)
# arm64 rootfs carrying the full rescue toolset from manifests/rescue.pkgs,
# pre-configured for headless LAN recovery (serial + telnet + dropbear + sshd
# + static-IP fallback) with the /lib-usrmerge repair helper baked in.
#
# This rootfs is KERNEL-FREE on purpose: post-install/72-rescue-partition.sh
# drops the LTS 6.18 kernel Image + modules into it at install time (a clean,
# quiet recovery kernel — NOT the edge payload — and the rescue
# rEFInd "RESCUE PARTITION" menuentry written by 70-bootloader.sh boots it via root=PARTUUID.
#
# Runs on the Linux arm64 build host (ARGOS), native debootstrap — no qemu.
# Usage:  sudo bash build/build-rescue-rootfs.sh [chroot_dir] [out_tarball] [suite] [arch] [mirror]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

CHROOT="${1:-$ROOT/build/rescue-rootfs}"
OUT="${2:-$ROOT/assets/rescue/rescue-rootfs.tar.zst}"
SUITE="${3:-resolute}"
ARCH="${4:-arm64}"
MIRROR="${5:-http://ports.ubuntu.com/ubuntu-ports}"

PKG_MANIFEST="$ROOT/manifests/rescue.pkgs"
AGENTS_SRC="$ROOT/assets/rescue/AGENTS.md"

# Rescue console credentials (documented in assets/rescue/AGENTS.md). LAN-only.
RESCUE_ROOT_PW="${RESCUE_ROOT_PW:-rescue}"
RESCUE_HOSTNAME="ncz-rescue"
RESCUE_STATIC_IP="192.168.207.66/24"
RESCUE_STATIC_GW="192.168.207.1"

for t in debootstrap chroot zstd tar awk sed grep mountpoint; do
    command -v "$t" >/dev/null 2>&1 || { echo "ERROR: missing build-host tool: $t" >&2; exit 1; }
done
[ -f "$PKG_MANIFEST" ] || { echo "ERROR: manifest not found: $PKG_MANIFEST" >&2; exit 1; }

# Resolve the package list: strip comments + inline '# ...' notes, dedupe.
PKGS=$(grep -vE '^\s*(#|$)' "$PKG_MANIFEST" | sed 's/#.*//' | awk '{print $1}' | grep . | sort -u | tr '\n' ' ')
echo "[rescue-rootfs] chroot:   $CHROOT"
echo "[rescue-rootfs] out:      $OUT"
echo "[rescue-rootfs] suite:    $SUITE   arch: $ARCH"
echo "[rescue-rootfs] mirror:   $MIRROR"
echo "[rescue-rootfs] packages: $(echo "$PKGS" | wc -w | tr -d ' ') from manifest"

# ----------------------------------------------------------------------
# Clean any prior chroot (best-effort unmount first).
# ----------------------------------------------------------------------
for d in dev/pts dev proc sys; do
    mountpoint -q "$CHROOT/$d" && umount -lf "$CHROOT/$d" || true
done
rm -rf "$CHROOT"
mkdir -p "$CHROOT" "$(dirname "$OUT")"

# ----------------------------------------------------------------------
# Stage 1 — debootstrap minimal base (native arm64, no foreign/qemu).
# minbase keeps it lean; rescue.pkgs pulls everything we actually need.
# ----------------------------------------------------------------------
echo "[rescue-rootfs] debootstrap $SUITE..."
debootstrap --arch="$ARCH" --variant=minbase \
    --include=ca-certificates,apt-utils "$SUITE" "$CHROOT" "$MIRROR"

cat > "$CHROOT/etc/apt/sources.list" <<EOF
deb $MIRROR $SUITE main universe restricted multiverse
deb $MIRROR $SUITE-updates main universe restricted multiverse
deb $MIRROR $SUITE-security main universe restricted multiverse
EOF

# ----------------------------------------------------------------------
# Stage 2 — bind mounts + apt install of the rescue toolset.
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
# Stage 3 — rescue configuration (baked into the rootfs).
# ----------------------------------------------------------------------
echo "[rescue-rootfs] applying rescue configuration"

# hostname
echo "$RESCUE_HOSTNAME" > "$CHROOT/etc/hostname"
printf '127.0.0.1\tlocalhost\n127.0.1.1\t%s\n' "$RESCUE_HOSTNAME" > "$CHROOT/etc/hosts"

# root password (LAN-only rescue console)
chroot "$CHROOT" /bin/sh -c "echo 'root:$RESCUE_ROOT_PW' | chpasswd"

# Serial console on ttyAMA2 @115200 (matches console=ttyAMA2,115200 cmdline).
chroot "$CHROOT" systemctl enable serial-getty@ttyAMA2.service 2>/dev/null || true
chroot "$CHROOT" systemctl enable getty@tty1.service 2>/dev/null || true

# Allow root login on serial + pts (telnet/console) — mirrors 36-telemetry.sh.
{
    echo "console"
    echo "ttyAMA0"
    echo "ttyAMA2"
    for n in 0 1 2 3 4 5 6 7 8 9; do echo "pts/$n"; done
} >> "$CHROOT/etc/securetty"

# --- telnetd on :23 via openbsd-inetd (busybox fallback) ---
if [ -e "$CHROOT/usr/sbin/in.telnetd" ]; then
    if ! grep -qE '^telnet[[:space:]]' "$CHROOT/etc/inetd.conf" 2>/dev/null; then
        echo 'telnet stream tcp nowait root /usr/sbin/in.telnetd in.telnetd' >> "$CHROOT/etc/inetd.conf"
    fi
    chroot "$CHROOT" systemctl enable openbsd-inetd.service 2>/dev/null || true
else
    # busybox-static fallback telnetd socket
    cat > "$CHROOT/etc/systemd/system/telnetd.socket" <<'EOF'
[Unit]
Description=Telnet rescue console (busybox) — LAN-only lockout prevention
[Socket]
ListenStream=23
Accept=yes
[Install]
WantedBy=sockets.target
EOF
    cat > "$CHROOT/etc/systemd/system/telnetd@.service" <<'EOF'
[Unit]
Description=Telnet per-connection (busybox)
[Service]
ExecStart=-/bin/busybox telnetd -i -l /bin/login
StandardInput=socket
EOF
    chroot "$CHROOT" systemctl enable telnetd.socket 2>/dev/null || true
fi

# --- dropbear lightweight SSH on :2222 (openssh keeps :22) ---
if [ -e "$CHROOT/usr/sbin/dropbear" ]; then
    mkdir -p "$CHROOT/etc/dropbear"
    cat > "$CHROOT/etc/systemd/system/dropbear-rescue.service" <<'EOF'
[Unit]
Description=Dropbear SSH (rescue, port 2222)
After=network.target
[Service]
ExecStart=/usr/sbin/dropbear -F -E -p 2222 -R
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
    chroot "$CHROOT" systemctl enable dropbear-rescue.service 2>/dev/null || true
fi

# --- sshd: permit root + password auth (rescue context only) ---
mkdir -p "$CHROOT/etc/ssh/sshd_config.d"
cat > "$CHROOT/etc/ssh/sshd_config.d/99-rescue.conf" <<'EOF'
# r130 rescue environment — LAN-only recovery. Permissive by design.
PermitRootLogin yes
PasswordAuthentication yes
PermitEmptyPasswords no
EOF
chroot "$CHROOT" systemctl enable ssh.service 2>/dev/null || \
    chroot "$CHROOT" systemctl enable sshd.service 2>/dev/null || true

# --- network bring-up: DHCP all NICs, static fallback 192.168.207.66/24 ---
cat > "$CHROOT/usr/local/sbin/ncz-rescue-net" <<EOF
#!/bin/sh
# Bring every wired NIC up, try DHCP (busybox udhcpc), static fallback.
set +e
for i in \$(ls /sys/class/net 2>/dev/null | grep -v '^lo\$'); do
    ip link set "\$i" up 2>/dev/null
    busybox udhcpc -i "\$i" -q -n -t 5 2>/dev/null
done
if ! ip -4 addr show 2>/dev/null | grep -q 'inet '; then
    iface=\$(ls /sys/class/net 2>/dev/null | grep -v '^lo\$' | head -1)
    [ -n "\$iface" ] && ip addr add $RESCUE_STATIC_IP dev "\$iface" 2>/dev/null
    [ -n "\$iface" ] && ip route add default via $RESCUE_STATIC_GW 2>/dev/null
fi
exit 0
EOF
chmod 0755 "$CHROOT/usr/local/sbin/ncz-rescue-net"
cat > "$CHROOT/etc/systemd/system/ncz-rescue-net.service" <<'EOF'
[Unit]
Description=NCZ rescue network bring-up (DHCP + static fallback)
After=systemd-udevd.service
Wants=network.target
Before=network.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ncz-rescue-net
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
chroot "$CHROOT" systemctl enable ncz-rescue-net.service 2>/dev/null || true

# --- /lib usrmerge repair + boot-default fix helper (from R80 rescue) ---
cat > "$CHROOT/usr/local/sbin/ncz-rescue-fixlib" <<'EOF'
#!/bin/sh
# ncz-rescue-fixlib <mountpoint-of-broken-root>
# Repairs the usrmerge /lib symlink that a bad `tar -C /` of a modules tarball
# can clobber (replaces /lib symlink with a real dir, orphaning ld-linux ->
# every dynamically linked binary fails to exec). See AGENTS.md.
set -eu
ROOT="${1:?usage: ncz-rescue-fixlib <root-mountpoint>}"
[ -d "$ROOT/usr/lib" ] || { echo "ERROR: $ROOT/usr/lib missing — not a usrmerge root"; exit 1; }
if [ -L "$ROOT/lib" ]; then
    echo "[fixlib] $ROOT/lib is already a symlink -> $(readlink "$ROOT/lib"); nothing to do"
    exit 0
fi
if [ -d "$ROOT/lib" ]; then
    ts=$(date +%Y%m%d-%H%M%S)
    echo "[fixlib] $ROOT/lib is a REAL dir — moving to lib.broken.$ts and restoring symlink"
    cp -a "$ROOT/lib/." "$ROOT/usr/lib/" 2>/dev/null || true
    mv "$ROOT/lib" "$ROOT/lib.broken.$ts"
    ln -s usr/lib "$ROOT/lib"
    echo "[fixlib] done: $ROOT/lib -> usr/lib (old dir preserved at lib.broken.$ts)"
else
    echo "[fixlib] $ROOT/lib does not exist — creating symlink -> usr/lib"
    ln -s usr/lib "$ROOT/lib"
fi
EOF
chmod 0755 "$CHROOT/usr/local/sbin/ncz-rescue-fixlib"

# --- chroot-into-broken-root helper ---
cat > "$CHROOT/usr/local/sbin/ncz-rescue-chroot" <<'EOF'
#!/bin/sh
# ncz-rescue-chroot <device>   e.g. ncz-rescue-chroot /dev/nvme0n1p3
# Mounts a target ext4/btrfs root + bind mounts and drops into a chroot shell.
set -eu
DEV="${1:?usage: ncz-rescue-chroot <root-device>}"
MNT=/mnt/target
mkdir -p "$MNT"
mount "$DEV" "$MNT" 2>/dev/null || mount -t btrfs -o subvol=@ "$DEV" "$MNT"
for d in dev dev/pts proc sys run; do mkdir -p "$MNT/$d"; done
mount --bind /dev "$MNT/dev"; mount --bind /dev/pts "$MNT/dev/pts"
mount -t proc proc "$MNT/proc"; mount -t sysfs sys "$MNT/sys"
echo "[chroot] entering $DEV at $MNT — type 'exit' to leave + auto-unmount"
chroot "$MNT" /bin/bash || true
for d in sys proc dev/pts dev; do umount -lf "$MNT/$d" 2>/dev/null || true; done
umount -lf "$MNT" 2>/dev/null || true
EOF
chmod 0755 "$CHROOT/usr/local/sbin/ncz-rescue-chroot"

# MOTD pointing operators at AGENTS.md
cat > "$CHROOT/etc/motd" <<EOF

  NCZ-OS RESCUE ENVIRONMENT (LTS 6.18 kernel, full toolset)
  -----------------------------------------------------
  Read /AGENTS.md for system facts, drivers, boot model, and recovery steps.
  Helpers:  ncz-rescue-fixlib <root>   ncz-rescue-chroot <dev>
  Access:   telnet :23   ssh root@host   dropbear :2222   serial ttyAMA2@115200
  Net fallback: $RESCUE_STATIC_IP (gw $RESCUE_STATIC_GW) if DHCP fails.

EOF

# AGENTS.md (authored in assets/rescue/AGENTS.md; copied if present)
if [ -f "$AGENTS_SRC" ]; then
    install -m 0644 "$AGENTS_SRC" "$CHROOT/AGENTS.md"
    install -D -m 0644 "$AGENTS_SRC" "$CHROOT/root/AGENTS.md"
    echo "[rescue-rootfs] AGENTS.md installed into rootfs"
else
    echo "[rescue-rootfs] WARN: $AGENTS_SRC missing — rootfs will ship without AGENTS.md"
fi

# Drop apt lists to shrink the tarball.
rm -rf "$CHROOT/var/lib/apt/lists/"* "$CHROOT/var/cache/apt/archives/"*.deb 2>/dev/null || true

# ----------------------------------------------------------------------
# Stage 4 — pack the tarball (unmount binds first).
# ----------------------------------------------------------------------
cleanup
trap - EXIT

echo "[rescue-rootfs] packing $OUT"
tar -C "$CHROOT" --numeric-owner -cpf - . | zstd -19 -T0 -o "$OUT" -f
echo "[rescue-rootfs] done: $(du -h "$OUT" | cut -f1)"
