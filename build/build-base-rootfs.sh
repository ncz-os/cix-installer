#!/bin/bash
# build-base-rootfs.sh — debootstrap the RAW (un-baked) base rootfs tarball
# that build-squashfs-layers.sh's build_base() extracts as BASE_TARBALL
# (assets/rootfs/rootfs-$NCZ_BASE_CODENAME-arm64.tar.zst). build_base() then
# runs its own machine-agnostic hooks + installer-base.pkgs on top of this --
# this script's only job is the plain debootstrap, nothing NCZ-specific baked
# in (no hostname, no rescue services, no branding).
#
# Runs on any NATIVE arm64 Linux build host with debootstrap installed (e.g.
# ULTRA, Fedora Asahi Remix aarch64) -- no qemu-aarch64-static/binfmt required
# when the host's own arch already matches the target. This mirrors
# build-rescue-rootfs.sh and build-mgmt-rootfs.sh, which already run this way;
# this script fills the one remaining gap -- there was no producer at all for
# the PLAIN base tarball, only for the rescue and mgmt variants.
#
# Usage: sudo bash build/build-base-rootfs.sh [chroot_dir] [out_tarball] [suite] [arch] [mirror]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

CHROOT="${1:-$ROOT/build/base-rootfs}"
if [ -r "$ROOT/release.conf" ]; then
    # shellcheck source=../release.conf
    . "$ROOT/release.conf"
else
    echo "ERROR: $ROOT/release.conf not readable -- refusing to guess the base distro" >&2
    exit 1
fi
: "${NCZ_BASE_CODENAME:?release.conf did not define NCZ_BASE_CODENAME}"
SUITE="${3:-$NCZ_BASE_CODENAME}"
ARCH="${4:-arm64}"
MIRROR="${5:-${NCZ_BASE_MIRROR:-https://deb.debian.org/debian}}"
OUT="${2:-$ROOT/assets/rootfs/rootfs-$SUITE-arm64.tar.zst}"
COMPONENTS="${COMPONENTS:-${NCZ_BASE_COMPONENTS:-main contrib non-free non-free-firmware}}"

for t in debootstrap chroot zstd tar; do
    command -v "$t" >/dev/null 2>&1 || { echo "ERROR: missing build-host tool: $t" >&2; exit 1; }
done

HOST_ARCH="$(uname -m)"
case "$HOST_ARCH:$ARCH" in
    aarch64:arm64) NEEDS_QEMU=0 ;;
    x86_64:amd64)  NEEDS_QEMU=0 ;;
    *)             NEEDS_QEMU=1 ;;
esac
if [ "$NEEDS_QEMU" = 1 ]; then
    command -v qemu-"$ARCH"-static >/dev/null 2>&1 || \
        [ -x /usr/bin/qemu-aarch64-static ] || \
        { echo "ERROR: cross-arch debootstrap needs qemu-$ARCH-static on this host ($HOST_ARCH)" >&2; exit 1; }
fi

echo "[base-rootfs] chroot:   $CHROOT"
echo "[base-rootfs] out:      $OUT"
echo "[base-rootfs] suite:    $SUITE   arch: $ARCH   host: $HOST_ARCH (native=$([ "$NEEDS_QEMU" = 0 ] && echo yes || echo no))"
echo "[base-rootfs] mirror:   $MIRROR"

# ----------------------------------------------------------------------
# Mount-safety helpers -- identical pattern to build-rescue-rootfs.sh.
# A leftover mount under $CHROOT (e.g. a bind-mounted host ESP from a prior
# build-iso run) would be DESTROYED by `rm -rf` below if not detected first --
# this exact class of bug wiped a build host's EFI System Partition once.
# ----------------------------------------------------------------------
mounts_under() {
    findmnt -rno TARGET 2>/dev/null | while IFS= read -r mp; do
        case "$mp" in "$1"|"$1"/*) printf '%s\n' "$mp";; esac
    done
}
unmount_all_under() {
    mounts_under "$1" | awk '{print length, $0}' | sort -rn | cut -d' ' -f2- | \
    while IFS= read -r mp; do umount -lf "$mp" 2>/dev/null || true; done
}

unmount_all_under "$CHROOT"
if [ -n "$(mounts_under "$CHROOT")" ]; then
    echo "ERROR: mounts still present under $CHROOT after unmount -- refusing 'rm -rf'" >&2
    mounts_under "$CHROOT" >&2
    exit 1
fi
rm -rf "$CHROOT"
mkdir -p "$CHROOT" "$(dirname "$OUT")"

# ----------------------------------------------------------------------
# Stage 1 -- debootstrap. minbase + apt-utils/ca-certificates, same include
# set as build-rescue-rootfs.sh; build_base() layers its own package set and
# hooks on top, so this stays a plain, generic base.
# ----------------------------------------------------------------------
echo "[base-rootfs] debootstrap $SUITE..."
if [ "$NEEDS_QEMU" = 1 ]; then
    debootstrap --arch="$ARCH" --variant=minbase --foreign \
        --include=ca-certificates,apt-utils "$SUITE" "$CHROOT" "$MIRROR"
    QEMU_BIN="$(command -v qemu-"$ARCH"-static || echo /usr/bin/qemu-aarch64-static)"
    cp "$QEMU_BIN" "$CHROOT/usr/bin/"
    chroot "$CHROOT" /debootstrap/debootstrap --second-stage
else
    debootstrap --arch="$ARCH" --variant=minbase \
        --include=ca-certificates,apt-utils "$SUITE" "$CHROOT" "$MIRROR"
fi

cat > "$CHROOT/etc/apt/sources.list" <<EOF
deb $MIRROR $SUITE $COMPONENTS
EOF

# ----------------------------------------------------------------------
# Stage 2 -- bind mounts, apt-get update only (no package install here --
# build_base() does that from installer-base.pkgs against its own mirror).
# ----------------------------------------------------------------------
mount --bind /dev     "$CHROOT/dev"
mount --bind /dev/pts "$CHROOT/dev/pts"
mount -t proc proc    "$CHROOT/proc"
mount -t sysfs sys    "$CHROOT/sys"
trap 'unmount_all_under "$CHROOT"' EXIT

chroot "$CHROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get update

unmount_all_under "$CHROOT"
trap - EXIT

# ----------------------------------------------------------------------
# Stage 3 -- strip build-host-specific bits, finalize the tarball.
# ----------------------------------------------------------------------
[ "$NEEDS_QEMU" = 1 ] && rm -f "$CHROOT/usr/bin/qemu-$ARCH-static"
rm -rf "$CHROOT/var/lib/apt/lists/"* "$CHROOT/var/cache/apt/archives/"*.deb 2>/dev/null || true
: > "$CHROOT/etc/machine-id"
rm -f "$CHROOT/etc/resolv.conf"

echo "[base-rootfs] writing $OUT"
tar -C "$CHROOT" --numeric-owner -cpf - . | zstd -19 -T0 -o "$OUT" -f
echo "[base-rootfs] done: $(du -h "$OUT" | cut -f1)"
