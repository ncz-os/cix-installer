#!/bin/bash
# build-base-rootfs.sh — produce the RAW (un-baked) base rootfs tarball that
# build-squashfs-layers.sh's build_base() extracts as BASE_TARBALL
# (assets/rootfs/rootfs-$NCZ_BASE_CODENAME-arm64.tar.zst). build_base() then
# runs its own machine-agnostic hooks + installer-base.pkgs on top of this --
# this script's only job is the plain base, nothing NCZ-specific baked in
# (no hostname, no rescue services, no branding).
#
# METHOD
#   Uses `podman` + `mmdebstrap --mode=root` inside a debian:<codename>
#   container. mmdebstrap is a single Perl script that bootstraps an
#   apt-installable Debian rootfs; running it as root inside a throwaway
#   container means no HOST chroot and no HOST bind mounts are ever
#   created -- eliminating a whole class of leftover-mount bugs this
#   codebase has been bitten by (a bind-mounted ESP under a chroot dir
#   being destroyed by `rm -rf` once wiped a build host's EFI System
#   Partition; the unmount-safety helpers in build-rescue-rootfs.sh exist
#   precisely because of that history). `--mode=unshare` was tried first
#   and looked more elegant on paper (no host root needed at all) but a
#   nested-quoting bug in an unrelated customize-hook masked whether it
#   even worked; --mode=root is simpler and was the version actually
#   verified end-to-end (fixed 2026-09-11, see build-squashfs-layers.sh's
#   verified consumer test in the same session).
#
#   Why podman and not native mmdebstrap on Fedora?
#   Fedora does not package mmdebstrap; manual install drags in a long Perl
#   dependency chain we would need to vendor and keep current. The same
#   repo already standardizes on `podman` for cross-distro work
#   (build/build-singularity-podman.sh).
#
#   Why no customize-hook for /etc/apt/sources.list?
#   build_base() (build-squashfs-layers.sh) calls apt_offline(), which
#   deletes/disables every pre-existing apt source before installing
#   anything -- so whatever sources.list mmdebstrap writes here is
#   discarded before it's ever read. Writing one was dead complexity, and
#   the nested-quoting inside that hook (a single-quoted string containing
#   an unescaped inner single quote) was the actual cause of this script
#   silently exiting 127 with zero output when it made it into a commit
#   without being re-verified against the committed content.
#
# Runs on a NATIVE host matching the target arch (e.g. ULTRA, aarch64,
# building an arm64 rootfs) -- no qemu/binfmt needed. Cross-arch (e.g.
# ARGOS x86_64 building an arm64 rootfs) is NOT yet supported: it needs
# qemu-user-static's binfmt_misc registration to carry the `F` (fix-binary)
# flag so a container without its own qemu-aarch64 binary can still exec
# foreign-arch code; ARGOS's current registration lacks it (checked
# 2026-09-11: flags show `POF`, not `FPOF`) -- re-registering with F would
# be the next step, not attempted here. See docs/BUILD-HOSTS.md.
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

for t in tar zstd; do
    command -v "$t" >/dev/null 2>&1 || { echo "ERROR: missing build-host tool: $t" >&2; exit 1; }
done
command -v podman >/dev/null 2>&1 || command -v docker >/dev/null 2>&1 || \
    { echo "ERROR: need podman or docker on the build host" >&2; exit 1; }

HOST_ARCH="$(uname -m)"
case "$HOST_ARCH:$ARCH" in
    aarch64:arm64) ;;
    x86_64:amd64)  ;;
    *)
        echo "ERROR: cross-arch ($HOST_ARCH -> $ARCH) is not supported here yet." >&2
        echo "       Needs qemu-user-static binfmt_misc registered with the F flag" >&2
        echo "       so a container without its own interpreter binary can still" >&2
        echo "       exec foreign-arch code. See docs/BUILD-HOSTS.md." >&2
        exit 1
        ;;
esac

CONTAINER_IMAGE="${NCZ_BASE_CONTAINER_IMAGE:-debian:$SUITE}"
CE="$(command -v podman || command -v docker || true)"
[ -n "$CE" ] || { echo "ERROR: need podman or docker on the build host" >&2; exit 1; }

OUT_DIR="$(cd "$(dirname "$OUT")" 2>/dev/null && pwd || { mkdir -p "$(dirname "$OUT")" && cd "$(dirname "$OUT")" && pwd; })"
OUT_BASE="$(basename "$OUT")"
TAR_NAME="${OUT_BASE%.tar.zst}.tar"
MM_COMPONENTS="$(echo "$COMPONENTS" | tr -s ' ' ',')"
# mmdebstrap's OWN internal apt-get update runs inside the tree it is still
# building, before ca-certificates is installed there -- the classic
# bootstrap chicken-and-egg. https fails with a cert-verify error at that
# point regardless of the host's own trust store. Use http for the
# bootstrap mirror specifically; build_base() overwrites the rootfs's own
# apt sources anyway (see the header comment above), so this has no effect
# on what package sources the final image actually uses.
BOOTSTRAP_MIRROR="${MIRROR/https:/http:}"

echo "[base-rootfs] engine:  $CE"
echo "[base-rootfs] out:     $OUT"
echo "[base-rootfs] suite:   $SUITE   arch: $ARCH   host: $HOST_ARCH"
echo "[base-rootfs] mirror:  $MIRROR"

CONTAINER_CMD=$(cat <<CMD
set -e
apt-get update -qq
apt-get install -y -qq --no-install-recommends mmdebstrap zstd >/dev/null
mmdebstrap --arch=$ARCH --mode=root --format=tar \
    --variant=minbase \
    --include=ca-certificates,apt-utils \
    --components="$MM_COMPONENTS" \
    --customize-hook='chroot "\$1" /bin/sh -c "true > /etc/machine-id" 2>/dev/null || true' \
    --customize-hook='rm -f "\$1/etc/resolv.conf"' \
    "$SUITE" /out/$TAR_NAME "$BOOTSTRAP_MIRROR"
zstd -19 -T0 -f /out/$TAR_NAME -o /out/$OUT_BASE
rm -f /out/$TAR_NAME
CMD
)

"$CE" run --rm --network=host -v "$OUT_DIR":/out:Z "$CONTAINER_IMAGE" bash -c "$CONTAINER_CMD"

echo "[base-rootfs] done: $(du -h "$OUT" | cut -f1)"
