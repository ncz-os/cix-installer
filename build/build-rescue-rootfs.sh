#!/bin/bash
# build-rescue-rootfs.sh — build the r130 dedicated RESCUE PARTITION rootfs.
#
# Produces assets/rescue/rescue-rootfs.tar.zst: a minimal Debian (forky) arm64
# rootfs carrying the full rescue toolset from manifests/rescue.pkgs,
# pre-configured for headless LAN recovery (serial + telnet + dropbear + sshd
# + static-IP fallback) with the /lib-usrmerge repair helper baked in.
#
# WAS UBUNTU (resolute) UNTIL 2026-08-11. That was wrong twice over: the
# operator retired Ubuntu entirely, and a recovery environment built from a
# different distribution than the system it recovers cannot share the shipping
# kernel's modules. Measured on O6N: the installed rescue partition was
# "Ubuntu 26.04 LTS" carrying only 7.0.12 modules, so retiring the 7.0.12
# kernel would have left it unbootable.
#
# This rootfs is KERNEL-FREE on purpose: post-install/72-rescue-partition.sh
# drops the shipping kernel Image + modules into it at install time (and the rescue
# rEFInd "RESCUE PARTITION" menuentry written by 70-bootloader.sh boots it via root=PARTUUID.
#
# Runs on the Linux arm64 build host (ARGOS), native debootstrap — no qemu.
# Usage:  sudo bash build/build-rescue-rootfs.sh [chroot_dir] [out_tarball] [suite] [arch] [mirror]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

CHROOT="${1:-$ROOT/build/rescue-rootfs}"
OUT="${2:-$ROOT/assets/rescue/rescue-rootfs.tar.zst}"
# Defaults come from release.conf so the rescue environment can never drift to a
# different distribution than the release it is recovering.
if [ -r "$ROOT/release.conf" ]; then
    # shellcheck source=../release.conf
    . "$ROOT/release.conf"
fi
SUITE="${3:-${NCZ_BASE_CODENAME:-forky}}"
ARCH="${4:-arm64}"
MIRROR="${5:-${NCZ_BASE_MIRROR:-https://deb.debian.org/debian}}"

# Components come from the release profile. The list used to be Ubuntu's
# (main universe restricted multiverse) with -updates and -security suites
# appended, which on Debian produces "Skipping acquire of configured file
# 'restricted/...'" for every component and then a hard failure:
#   E: The repository '.../forky-security Release' does not have a Release file.
# Debian testing has no -security pocket of that name and no universe/multiverse
# at all, so a single suite line with the profile's own components is correct.
COMPONENTS="${COMPONENTS:-${NCZ_BASE_COMPONENTS:-main contrib non-free non-free-firmware}}"
PKG_MANIFEST="$ROOT/manifests/rescue.pkgs"
AGENTS_SRC="$ROOT/assets/rescue/AGENTS.md"

# Rescue console credentials (documented in assets/rescue/AGENTS.md). LAN-only.
RESCUE_ROOT_PW="${RESCUE_ROOT_PW:-rescue}"
RESCUE_HOSTNAME="ncz-rescue"
RESCUE_STATIC_IP="192.168.207.199/24"  # dedicated rescue fallback — NOT any production host (was .66/cixmini builder — collision fixed 2026-07-20)
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
# Mount-safety helpers. CRITICAL: a leftover mount under $CHROOT (e.g. the
# host's ESP, bind-mounted by a prior build-iso / grub-install run) would be
# DESTROYED by the rm -rf below — this exact bug wiped the build host's EFI
# System Partition on 2026-06-26. Never rm -rf a tree that has live mounts.
# ----------------------------------------------------------------------
mounts_under() {   # print every mountpoint at or under $1
    findmnt -rno TARGET 2>/dev/null | while IFS= read -r mp; do
        case "$mp" in "$1"|"$1"/*) printf '%s\n' "$mp";; esac
    done
}
unmount_all_under() {   # unmount everything under $1, deepest path first
    mounts_under "$1" | awk '{print length, $0}' | sort -rn | cut -d' ' -f2- | \
    while IFS= read -r mp; do umount -lf "$mp" 2>/dev/null || true; done
}

# ----------------------------------------------------------------------
# Clean any prior chroot (unmount EVERYTHING under it first, then verify).
# ----------------------------------------------------------------------
unmount_all_under "$CHROOT"
if [ -n "$(mounts_under "$CHROOT")" ]; then
    echo "ERROR: mounts still present under $CHROOT after unmount — refusing 'rm -rf' to avoid destroying a mounted filesystem:" >&2
    mounts_under "$CHROOT" >&2
    exit 1
fi
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
deb $MIRROR $SUITE $COMPONENTS
EOF

# ----------------------------------------------------------------------
# Stage 2 — bind mounts + apt install of the rescue toolset.
# ----------------------------------------------------------------------
mount --bind /dev     "$CHROOT/dev"
mount --bind /dev/pts "$CHROOT/dev/pts"
mount -t proc proc    "$CHROOT/proc"
mount -t sysfs sys    "$CHROOT/sys"
cleanup() {
    unmount_all_under "$CHROOT"
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

# Carry the Realtek NIC firmware into the standalone rescue partition.  The
# rescue kernel is intentionally independent of the main rootfs; without
# this copy r8169 can enumerate but cannot bring the onboard NIC up.
RTL_FIRMWARE_SRC="$ROOT/assets/firmware/rtl_nic"
if [ -d "$RTL_FIRMWARE_SRC" ]; then
    install -d -m 0755 "$CHROOT/lib/firmware/rtl_nic"
    cp -a "$RTL_FIRMWARE_SRC"/. "$CHROOT/lib/firmware/rtl_nic/"
    echo "[rescue-rootfs] installed Realtek NIC firmware ($(find "$CHROOT/lib/firmware/rtl_nic" -type f | wc -l | tr -d ' ') files)"
else
    echo "[rescue-rootfs] WARN: Realtek NIC firmware absent at $RTL_FIRMWARE_SRC" >&2
fi

# hostname
echo "$RESCUE_HOSTNAME" > "$CHROOT/etc/hostname"
printf '127.0.0.1\tlocalhost\n127.0.1.1\t%s\n' "$RESCUE_HOSTNAME" > "$CHROOT/etc/hosts"
printf 'LANG=C.UTF-8\n' > "$CHROOT/etc/default/locale"

# root password (LAN-only rescue console)
chroot "$CHROOT" /bin/sh -c "echo 'root:$RESCUE_ROOT_PW' | chpasswd"

# Serial consoles are device-driven. Enabling both template instances directly
# makes boot wait forever for whichever UART is absent (ttyAMA0 on some metal,
# ttyAMA2 under QEMU). The kernel-console generator covers the configured
# console, while this udev rule starts a getty for either UART when it exists.
install -d -m 0755 "$CHROOT/etc/udev/rules.d"
cat > "$CHROOT/etc/udev/rules.d/70-ncz-serial-getty.rules" <<'EOF'
SUBSYSTEM=="tty", KERNEL=="ttyAMA[02]", TAG+="systemd", ENV{SYSTEMD_WANTS}+="serial-getty@%k.service"
EOF
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

# --- network bring-up: DHCP (carriers-only) + DECOUPLED static fallback ---
# Two independent units, by hard-won design:
#   1. ncz-rescue-net          -> try DHCP (dhcpcd first, busybox udhcpc
#                                 fallback) on carrier NICs only, in parallel,
#                                 time-capped so a dead port can't hang boot.
#   2. ncz-rescue-net-fallback -> if NOTHING got a v4 lease, assign the documented
#                                 static rescue IP. This is a SEPARATE unit ordered
#                                 After= the DHCP unit (NOT Requires=), so it still
#                                 runs even when the DHCP unit hangs and systemd
#                                 kills it on TimeoutStartSec. The old single-oneshot
#                                 design trapped the static fallback behind a killable
#                                 DHCP step -> a stuck port meant NO IP at all
#                                 (operator-burned 2026-06-26: rescue partition came
#                                 up with no address and no DHCP client to recover).
cat > "$CHROOT/usr/local/sbin/ncz-rescue-net" <<EOF
#!/bin/sh
# DHCP bring-up only. Link-up all NICs, settle, then DHCP carriers in parallel
# with short hard timeouts. dhcpcd is preferred; busybox udhcpc is fallback.
# Static IP is intentionally handled by ncz-rescue-net-fallback (separate unit).
set +e
NICS=\$(ls /sys/class/net 2>/dev/null | grep -v '^lo\$')
for i in \$NICS; do ip link set "\$i" up 2>/dev/null; done
sleep 2   # let carrier/auto-neg settle before reading link state
for i in \$NICS; do
    [ "\$(cat /sys/class/net/\$i/carrier 2>/dev/null)" = "1" ] || continue
    if command -v dhcpcd >/dev/null 2>&1; then
        # dhcpcd is Debian Testing's supported DHCP client.  Its foreground
        # one-shot mode stays bounded so a dead carrier cannot delay rescue.
        ( timeout 12 dhcpcd -4 -w -t 10 "\$i" 2>/dev/null ) &
    else
        ( busybox udhcpc -i "\$i" -q -n -t 3 -T 2 2>/dev/null ) &
    fi
done
wait
exit 0
EOF
chmod 0755 "$CHROOT/usr/local/sbin/ncz-rescue-net"

cat > "$CHROOT/usr/local/sbin/ncz-rescue-net-fallback" <<EOF
#!/bin/sh
# Deterministic static-IP fallback. Runs AFTER the DHCP unit and even if that
# unit was killed for hanging. If no global IPv4 address exists, assign the
# documented rescue address ($RESCUE_STATIC_IP) so the box is ALWAYS reachable.
# Idempotent.
set +e
if ip -4 -o addr show scope global 2>/dev/null | grep -q 'inet '; then
    exit 0   # DHCP (or a prior run) already gave us an address
fi
NICS=\$(ls /sys/class/net 2>/dev/null | grep -v '^lo\$')
iface=\$(for i in \$NICS; do [ "\$(cat /sys/class/net/\$i/carrier 2>/dev/null)" = "1" ] && { echo "\$i"; break; }; done)
[ -z "\$iface" ] && iface=\$(echo "\$NICS" | head -1)
[ -z "\$iface" ] && exit 0
ip link set "\$iface" up 2>/dev/null
ip -4 -o addr show dev "\$iface" 2>/dev/null | grep -q "$RESCUE_STATIC_IP" || \\
    ip addr add $RESCUE_STATIC_IP dev "\$iface" 2>/dev/null
ip route show default 2>/dev/null | grep -q default || \\
    ip route add default via $RESCUE_STATIC_GW 2>/dev/null
# dhclient normally writes resolver state. A static fallback must do so itself
# or "networking works" only for literal IP addresses.
if ! grep -q '^[[:space:]]*nameserver[[:space:]]' /etc/resolv.conf 2>/dev/null; then
    printf 'nameserver %s\\nnameserver 1.1.1.1\\n' '$RESCUE_STATIC_GW' > /etc/resolv.conf
fi
exit 0
EOF
chmod 0755 "$CHROOT/usr/local/sbin/ncz-rescue-net-fallback"

cat > "$CHROOT/etc/systemd/system/ncz-rescue-net.service" <<'EOF'
[Unit]
Description=NCZ rescue network DHCP bring-up (carriers-only, parallel, time-capped)
After=systemd-udevd.service
Wants=network.target
Before=network.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ncz-rescue-net
# Hard cap so a stuck link can never hang boot waiting on network.target.
TimeoutStartSec=25
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF

cat > "$CHROOT/etc/systemd/system/ncz-rescue-net-fallback.service" <<'EOF'
[Unit]
Description=NCZ rescue static-IP fallback (guaranteed LAN address, independent of DHCP)
# Ordered after the DHCP attempt but NOT bound to it (no Requires=): must run
# even if ncz-rescue-net.service failed or was killed on TimeoutStartSec.
After=ncz-rescue-net.service
Wants=network.target
Before=network.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ncz-rescue-net-fallback
TimeoutStartSec=15
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF

chroot "$CHROOT" systemctl enable ncz-rescue-net.service 2>/dev/null || true
chroot "$CHROOT" systemctl enable ncz-rescue-net-fallback.service 2>/dev/null || true
# dhclient owns resolver updates in the rescue image. Keep this a regular,
# writable file; a debootstrap systemd-resolved stub symlink is dead because
# resolved is intentionally not part of the minimal rescue closure.
rm -f "$CHROOT/etc/resolv.conf"
: > "$CHROOT/etc/resolv.conf"
chmod 0644 "$CHROOT/etc/resolv.conf"

# Rescue is intentionally console/headless. A graphical default adds no
# recovery capability, while multipathd fails noisily on kernels without
# dm_multipath even though the userspace tools remain useful on demand.
chroot "$CHROOT" systemctl set-default multi-user.target 2>/dev/null || true
chroot "$CHROOT" systemctl enable systemd-timesyncd.service 2>/dev/null || true
chroot "$CHROOT" systemctl disable multipathd.service multipathd.socket 2>/dev/null || true
chroot "$CHROOT" systemctl mask multipathd.service multipathd.socket 2>/dev/null || true

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

  NCZ-OS RESCUE ENVIRONMENT (stable kernel, full toolset)
  -----------------------------------------------------
  Read /AGENTS.md for system facts, drivers, boot model, and recovery steps.
  Helpers:  ncz-rescue-fixlib <root>   ncz-rescue-chroot <dev>
  Access:   telnet :23   ssh root@host   dropbear :2222   serial ttyAMA0/ttyAMA2@115200
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

# Golden rescue image identity: never bake one machine-id or one set of SSH
# private host keys into every installed rescue partition. The installer hook
# creates fresh values after extracting this archive onto the target device.
rm -f "$CHROOT"/etc/ssh/ssh_host_* "$CHROOT/var/lib/dbus/machine-id"
: > "$CHROOT/etc/machine-id"

# Ship gate: this is a bootable partition image, not merely a useful chroot.
# Resolute minbase can install systemd without systemd-sysv, leaving no
# /sbin/init; that produced a kernel-mounted rescue root with no PID 1, console,
# or networking. Validate the exact boot and remote-recovery contract before
# packing so an unusable rescue image cannot enter an ISO.
for required in \
    /sbin/init \
    /bin/sh \
    /usr/local/sbin/ncz-rescue-net \
    /usr/local/sbin/ncz-rescue-net-fallback \
    /usr/lib/systemd/system/systemd-timesyncd.service \
    /usr/lib/systemd/system/ssh.service; do
    if [ ! -x "$CHROOT$required" ] && [ ! -f "$CHROOT$required" ]; then
        echo "[rescue-rootfs] ERROR: required rescue boot/runtime file missing: $required" >&2
        exit 1
    fi
done
if [ -s "$CHROOT/etc/machine-id" ] || \
   find "$CHROOT/etc/ssh" -maxdepth 1 -type f -name 'ssh_host_*_key' | grep -q .; then
    echo "[rescue-rootfs] ERROR: golden rescue image contains persistent identity or SSH private keys" >&2
    exit 1
fi
for enabled in \
    /etc/systemd/system/multi-user.target.wants/ncz-rescue-net.service \
    /etc/systemd/system/multi-user.target.wants/ncz-rescue-net-fallback.service; do
    if [ ! -L "$CHROOT$enabled" ]; then
        echo "[rescue-rootfs] ERROR: required rescue unit is not enabled: $enabled" >&2
        exit 1
    fi
done
for uart in ttyAMA0 ttyAMA2; do
    if [ -L "$CHROOT/etc/systemd/system/getty.target.wants/serial-getty@$uart.service" ]; then
        echo "[rescue-rootfs] ERROR: static $uart getty enablement can block boot when the UART is absent" >&2
        exit 1
    fi
done
if ! grep -Fq 'KERNEL=="ttyAMA[02]"' "$CHROOT/etc/udev/rules.d/70-ncz-serial-getty.rules"; then
    echo "[rescue-rootfs] ERROR: device-driven serial getty rule is missing" >&2
    exit 1
fi
echo "[rescue-rootfs] verified: PID 1, device-driven serial consoles, DHCP/fallback, ssh runtime, and identity reset"

# ----------------------------------------------------------------------
# Stage 4 — pack the tarball (unmount binds first).
# ----------------------------------------------------------------------
cleanup
trap - EXIT

echo "[rescue-rootfs] packing $OUT"
tar -C "$CHROOT" --numeric-owner -cpf - . | zstd -19 -T0 -o "$OUT" -f
echo "[rescue-rootfs] done: $(du -h "$OUT" | cut -f1)"
