#!/bin/bash
# build-base-rootfs.sh — produce the RAW (un-baked) base rootfs tarball that
# build-squashfs-layers.sh's build_base() extracts as BASE_TARBALL
# (assets/rootfs/rootfs-$NCZ_BASE_CODENAME-arm64.tar.zst). build_base() then
# runs its own machine-agnostic hooks + installer-base.pkgs on top of this --
# this script's only job is the plain base, nothing NCZ-specific baked in
# (no hostname, no rescue services, no branding).
#
# METHOD
#   Uses `podman` + `mmdebstrap --mode=unshare` inside a debian:<codename>
#   container. mmdebstrap is a single Perl script (debian-installer style)
#   that bootstraps an apt-installable Debian rootfs inside its own
#   user/mount namespaces, so NO host chroot and NO host bind mounts are
#   ever created -- which eliminates a whole class of leftover-mount bugs
#   this codebase has been bitten by (a bind-mounted ESP under $CHROOT
#   being destroyed by `rm -rf` once wiped a build host's EFI System
#   Partition; the unmount-safety helpers in build-rescue-rootfs.sh exist
#   precisely because of that history).
#
#   Why podman and not native mmdebstrap on Fedora?
#   Fedora does not package mmdebstrap; manual install drags in a long Perl
#   dependency chain (`File::Copy::Recursive`, `Lintian`, libtest-pkg-perl,
#   `apt`, etc.) that we would need to vendor and keep current.  The same
#   repo already standardizes on `podman` for cross-distro work
#   (build/build-singularity-podman.sh), and `debian:forky` is already
#   pulled on ULTRA. The container itself is throwaway; the only artefact
#   that ships is the boot-strapped tarball.
#
#   Why `--mode=unshare`?
#   mmdebstrap's other modes (`--mode=sudo`, `--mode=root`) need host-root
#   and rely on chroot(2). `--mode=unshare` runs entirely in a user+
#   mount namespace owned by the running mmdebstrap process, so its
#   mount/unmount activity only affects the namespace, never the host
#   filesystem. A crash, an OOM kill, or any other failure cannot leak
#   mounts into `$CHROOT` because no host mounts exist there to begin
#   with.
#
# Runs on any native aarch64 host with `podman` (e.g. ULTRA, Fedora Asahi
# Remix aarch64), targeting an arm64 Debian/Forky base. No qemu, no binfmt;
# the container's own arch matches the host's, and the guest matches too.
#
# Usage: bash build/build-base-rootfs.sh [chroot_dir] [out_tarball] [suite] [arch] [mirror]
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

# Tool check: we don't need debootstrap on the host anymore. mmdebstrap is
# inside the container; we just need host-side tar+podman+zstd to seal.
for t in podman tar zstd; do
    command -v "$t" >/dev/null 2>&1 || { echo "ERROR: missing build-host tool: $t" >&2; exit 1; }
done

HOST_ARCH="$(uname -m)"
case "$HOST_ARCH:$ARCH" in
    aarch64:arm64) NEEDS_QEMU=0 ;;
    x86_64:amd64)  NEEDS_QEMU=0 ;;
    *)             NEEDS_QEMU=1 ;;
esac
if [ "$NEEDS_QEMU" = 1 ]; then
    echo "ERROR: cross-arch ($HOST_ARCH -> $ARCH) is not supported via podman+mmdebstrap here." >&2
    echo "       The same repo's other scripts rely on qemu-aarch64-static for cross-arch" >&2
    echo "       debootstrap; extending that into the container path is out of scope." >&2
    exit 1
fi

# Mirror sanity: refuse the historical "plain http" footgun. mmdebstrap
# fetches packages from $MIRROR over HTTPS, so the mirror must be https.
case "$MIRROR" in
    https://*) ;;
    *) echo "ERROR: MIRROR must be https for mmdebstrap's apt fetches: $MIRROR" >&2; exit 1 ;;
esac

CONTAINER_IMAGE="${NCZ_BASE_CONTAINER_IMAGE:-debian:$SUITE}"
CE="$(command -v podman || command -v docker || true)"
[ -n "$CE" ] || { echo "ERROR: need podman or docker on the build host" >&2; exit 1; }

echo "[base-rootfs] chroot:   $CHROOT   (host-side workspace only -- never chrooted)"
echo "[base-rootfs] out:      $OUT"
echo "[base-rootfs] suite:    $SUITE   arch: $ARCH   host: $HOST_ARCH (native=$([ "$NEEDS_QEMU" = 0 ] && echo yes || echo no))"
echo "[base-rootfs] mirror:   $MIRROR"
echo "[base-rootfs] image:    $CONTAINER_IMAGE   ($CE)"

# Host-side workdir -- where mmdebstrap's tarball lands and from which we
# re-compress. This is NOT a chroot and NO mounts happen under it on the
# host. Plain `rm -rf` at any point is always safe.
mkdir -p "$(dirname "$OUT")"
rm -rf "$CHROOT"
mkdir -p "$CHROOT"

# ----------------------------------------------------------------------
# Build script that runs INSIDE the container.
#
# Quote discipline: this whole block is passed as a single string argument
# to podman; the values substituted in are all restricted to $SUITE, $ARCH,
# $COMPONENTS, $MIRROR -- each of which we have bound to a value we know is
# safe (no embedded quotes, no whitespace beyond [A-Za-z0-9 _./:]). Every
# variable substitution here is therefore equivalent to a literal.
# ----------------------------------------------------------------------
read -r -d '' BUILD_SCRIPT <<BUILDSCRIPT || true
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# CA bundle first so the in-namespace apt that mmdebstrap spawns can verify
# the mirror's TLS chain.
apt-get install -y --no-install-recommends ca-certificates mmdebstrap
mkdir -p /work
# --customize-hook fires inside the chroot after extract+install and before
# the tarball is sealed, writing the exact sources.list line the old
# debootstrap path produced, so build_base()'s "no offline mirror -> use
# base sources" fallback continues to behave the same.
HOOK='sh -c "set -e; mkdir -p /etc/apt; printf 'deb ${MIRROR} ${SUITE} ${COMPONENTS}\\n' > /etc/apt/sources.list"'
mmdebstrap --mode=unshare --variant=minbase \\
    --include=ca-certificates,apt-utils \\
    --architectures=${ARCH} \\
    --components=${COMPONENTS} \\
    --skip=sign/tripwire \\
    --customize-hook="\${HOOK}" \\
    ${SUITE} /work/rootfs.tar ${MIRROR}
BUILDSCRIPT

INNER_LOG="$CHROOT/mmdebstrap.log"
echo "[base-rootfs] bootstrapping in $CONTAINER_IMAGE (unshare mode)..."
"$CE" run --rm --privileged --network=host \
    -v "$CHROOT":/work:Z \
    "$CONTAINER_IMAGE" bash -euo pipefail -c "$BUILD_SCRIPT" \
    >"$INNER_LOG" 2>&1

[ -f "$CHROOT/rootfs.tar" ] || {
    echo "ERROR: mmdebstrap produced no $CHROOT/rootfs.tar -- log tail:" >&2
    tail -40 "$INNER_LOG" >&2 || true
    exit 1
}

echo "[base-rootfs] container log tail:"
tail -8 "$INNER_LOG" | sed 's/^/[base-rootfs]   /'

# ----------------------------------------------------------------------
# Stage 3 -- post-process on the host.
#
# mmdebstrap already strips apt cache, package lists, machine-id, and
# resolv.conf the same way debootstrap's tar output does; we do the same
# final pass here defensively -- a future mmdebstrap option change
# (e.g. --keep-cache) would otherwise leak state, and the only consumer
# test that catches leaks is the end-to-end build_base(), which is much
# more expensive than a 4-line rm.
# ----------------------------------------------------------------------
echo "[base-rootfs] post-processing + compressing with zstd..."
EXTRACT="$CHROOT/_finalize"
mkdir -p "$EXTRACT"
tar -xf "$CHROOT/rootfs.tar" -C "$EXTRACT"
rm -rf "$EXTRACT/var/lib/apt/lists/"* "$EXTRACT/var/cache/apt/archives/"*.deb 2>/dev/null || true
: > "$EXTRACT/etc/machine-id"
rm -f "$EXTRACT/etc/resolv.conf"

echo "[base-rootfs] writing $OUT"
tar -C "$EXTRACT" --numeric-owner -cpf - . | zstd -19 -T0 -o "$OUT" -f
echo "[base-rootfs] done: $(du -h "$OUT" | cut -f1)"

# Final cleanup. No mounts were ever created under $CHROOT on the host,
# so plain rm -rf is safe -- this is the line we kept tripping over with
# the debootstrap path when a prior bind mount leaked into $CHROOT.
rm -rf "$CHROOT"
