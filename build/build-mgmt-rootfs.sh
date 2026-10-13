#!/bin/bash
# build-mgmt-rootfs.sh - build the Server nspawn recovery/management rootfs.
#
# Produces assets/mgmt/ncz-mgmt-rootfs.tar.zst: a minimal Debian forky
# rootfs (arm64 or amd64) that boots under systemd-nspawn (Boot=yes) with its OWN complete
# userland (glibc/NSS/PAM/openssh). This is the MIDDLE recovery tier on Server
# edge boxes, between the day-to-day host sshd:22 and the crash-proof static
# busybox telnet :2323 (post-install/37-failsafe-access.sh):
#
#   - It survives total host /usr/lib damage (the 2026-06-25 test-board incident) the
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
# Runs on a Linux build host of the target arch (an arm64 host for arm64, an amd64 host for amd64), native debootstrap - no qemu.
# Usage:  sudo bash build/build-mgmt-rootfs.sh [chroot_dir] [out_tarball] [suite] [arch] [mirror]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Follow the active release profile so the recovery container matches the image
# it ships inside. There is NO Ubuntu fallback any more: the script refuses to
# run unless the suite is Debian forky and the mirror is a Debian archive.
if [ -r "$ROOT/release.conf" ]; then
    # shellcheck source=../release.conf
    . "$ROOT/release.conf"
fi
# shellcheck source=lib/mirror-apt-opts.sh
. "$ROOT/build/lib/mirror-apt-opts.sh"

# Derive the recovery-container banner from the active release identity instead
# of pinning a codename (this said "MAXIMILIAN" through 26.7).
NCZ_MGMT_BANNER_LABEL="${NCZ_PRODUCT_NAME:-NCZ-OS}${NCZ_RELEASE_VERSION:+ ${NCZ_RELEASE_VERSION}}${NCZ_RELEASE_CODENAME:+ ${NCZ_RELEASE_CODENAME}}"

CHROOT="${1:-$ROOT/build/mgmt-rootfs}"
OUT="${2:-$ROOT/assets/mgmt/ncz-mgmt-rootfs.tar.zst}"
SUITE="${3:-${NCZ_BASE_CODENAME:-forky}}"
ARCH="${4:-arm64}"
MIRROR="${5:-${NCZ_BASE_MIRROR:-https://deb.debian.org/debian}}"

ncz_require_debian_forky "$SUITE" "$MIRROR" "${NCZ_BASE_NAME:-}" || exit 1
COMPONENTS="${NCZ_BASE_COMPONENTS:-main contrib non-free non-free-firmware}"
# debootstrap must verify the Release signature.  Prefer the host keyring; on
# a non-Debian build host (e.g. an Ubuntu host) it is absent, so fall back to
# the repo's COMMITTED Debian archive keyring (manifests/keys/, the same one the
# provenance gate gpgv-checks against) rather than building unverified.
DEBOOTSTRAP_KEYRING="${NCZ_DEBOOTSTRAP_KEYRING:-/usr/share/keyrings/debian-archive-keyring.gpg}"
if [ ! -f "$DEBOOTSTRAP_KEYRING" ] && [ -f "$ROOT/manifests/keys/debian-archive-keyring.gpg" ]; then
    DEBOOTSTRAP_KEYRING="$ROOT/manifests/keys/debian-archive-keyring.gpg"
fi
[ -f "$DEBOOTSTRAP_KEYRING" ] || { echo "FATAL: no debootstrap keyring (set NCZ_DEBOOTSTRAP_KEYRING)" >&2; exit 1; }

PKG_MANIFEST="$ROOT/manifests/mgmt.pkgs"

# Recovery container credentials. LAN-only (private subnet, no public route)
# per fleet doctrine. Password is random per build; override by exporting
# NCZ_MGMT_PASS. Day-to-day access is key-based (the post-install
# hook injects fleet authorized_keys into the container's /root/.ssh).
# NCZ_MGMT_PASS=<pass> to pin one, =random for a unique per-build password.
if [ -n "${NCZ_MGMT_PASS:-}" ] && [ "${NCZ_MGMT_PASS}" != "random" ]; then
    MGMT_ROOT_PW="$NCZ_MGMT_PASS"
elif [ "${NCZ_MGMT_PASS:-}" = "random" ]; then
    _raw=$(tr -dc 'a-z0-9' < /dev/urandom | head -c 20)
    [ "${#_raw}" -eq 20 ] || { echo "FATAL: no entropy for container root password" >&2; exit 1; }
    MGMT_ROOT_PW="${_raw:0:5}-${_raw:5:5}-${_raw:10:5}-${_raw:15:5}"
    echo "== ncz-recovery root password (generated): $MGMT_ROOT_PW"
    echo "   record it now; it is not recoverable from the image."
else
    # Distributed default, documented in docs/REMOTE-ACCESS.md.
    MGMT_ROOT_PW="recovery"
fi
MGMT_HOSTNAME="ncz-recovery"

for t in debootstrap chroot zstd tar awk sed grep mountpoint; do
    command -v "$t" >/dev/null 2>&1 || { echo "ERROR: missing build-host tool: $t" >&2; exit 1; }
done
[ -f "$PKG_MANIFEST" ] || { echo "ERROR: manifest not found: $PKG_MANIFEST" >&2; exit 1; }

# grep . under pipefail exits 1 on an empty manifest and kills the script
# with no message. ncz_pkgs_from_manifest reports that case explicitly.
PKGS=$(ncz_pkgs_from_manifest "$PKG_MANIFEST")
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
DEBOOTSTRAP_ARGS=(--arch="$ARCH" --variant=minbase --include=ca-certificates,apt-utils)
DEBOOTSTRAP_ARGS+=(--keyring "$DEBOOTSTRAP_KEYRING")
debootstrap "${DEBOOTSTRAP_ARGS[@]}" "$SUITE" "$CHROOT" "$MIRROR"

# debootstrap writes its own sources.list with no deb options. A pinned
# snapshot Release is expired once Valid-Until passes, so rewrite every line
# with NCZ_BASE_MIRROR_APT_OPTS (empty when unpinned: a live mirror keeps
# normal expiry checks). ONLY the forky suite itself is written (operator
# 2026-10-08: "only Debian versions from forky"): no forky-updates, no
# forky-security, so the rootfs matches the pinned snapshot exactly.
ncz_mirror_sources_list "$MIRROR" "$SUITE" "$COMPONENTS" "" "" "" \
    > "$CHROOT/etc/apt/sources.list"

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

# Surface apt-get update failures (E:/W: lines) instead of letting a later
# install hide an expired snapshot Release behind a bare non-zero exit.
MGMT_APT_UPDATE_LOG="$CHROOT/tmp/ncz-apt-update.log"
mkdir -p "$CHROOT/tmp"
ncz_apt_update_or_die "$MGMT_APT_UPDATE_LOG" "management chroot" \
    chroot "$CHROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive DPKG_ROOT=/ TMPDIR=/tmp apt-get update
if ! chroot "$CHROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive DPKG_ROOT=/ TMPDIR=/tmp bash -eu <<CHROOT_APT
apt-get install -y --no-install-recommends $PKGS
apt-get clean
CHROOT_APT
then
    mountpoint -q "$CHROOT/proc" || mount -t proc proc "$CHROOT/proc"
    chroot "$CHROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive DPKG_ROOT=/ TMPDIR=/tmp dpkg --configure -a
    chroot "$CHROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive DPKG_ROOT=/ TMPDIR=/tmp apt-get install -f -y
    chroot "$CHROOT" apt-get clean
fi

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
# NCZ Server recovery container - LAN-only break-glass. Primary access is
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
# clobber (the 2026-06-25 test-board lockout). Defaults to /host.
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

  $NCZ_MGMT_BANNER_LABEL SERVER RECOVERY CONTAINER (systemd-nspawn)
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
