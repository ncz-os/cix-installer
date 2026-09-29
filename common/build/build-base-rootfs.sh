#!/bin/bash
# build-base-rootfs.sh — produce the RAW (un-baked) base rootfs tarball that
# build-squashfs-layers.sh's build_base() extracts as BASE_TARBALL
# (assets/rootfs/rootfs-$NCZ_BASE_CODENAME-arm64.tar.zst). build_base() then
# runs its own machine-agnostic hooks + installer-base.pkgs on top of this --
# this script's only job is the plain base, nothing NCZ-specific baked in
# (no hostname, no rescue services, no branding).
#
# BUILD HOST (operator directive, 2026-09-14): this pipeline builds Sky1
# arm64 images and runs on ULTRA (192.168.207.88, native aarch64 Fedora
# Asahi) -- NOT PROTEUS. PROTEUS is x86_64 and is reserved for a future
# amd64 variant of this pipeline. Building arm64 on PROTEUS works (podman
# + qemu-user-static/binfmt cross-arch emulation) and was used for the
# initial integration proof (this branch, commits through d9b51fb and the
# build_layer() wiring commit), but emulation is measurably slower than
# native arm64 and should not be the standing path. Run arm64 builds/
# verification on ULTRA going forward; reach for PROTEUS again only when
# the amd64 variant is the thing being built.
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
# Runs natively on aarch64 (e.g. ULTRA) with no qemu/binfmt needed, OR
# cross-arch on x86_64 (e.g. ARGOS, PROTEUS) via qemu-user-static's
# binfmt_misc registration for aarch64. The 2026-09-11 version of this
# comment claimed cross-arch was unsupported because the host's binfmt flags
# showed "POF, not FPOF" -- that claim was wrong on its own terms (POF
# already includes F; there is no additional "FPOF" form) and was never
# actually tested. VERIFIED 2026-09-14 on PROTEUS (x86_64, binfmt flags
# `POF`): podman pulls the arm64 debian:$SUITE image, binfmt transparently
# execs it ("chroot architecture arm64 is equal to the host's architecture"
# per mmdebstrap's own log), and mmdebstrap completes cleanly (exit 0,
# real tarball, usrmerge symlinks confirmed via `tar -tvf` matching forky's
# native layout). No F-flag re-registration was needed.
#
# One real prerequisite found during that verification: a fresh host can
# hit `crun: create keyring ...: Disk quota exceeded` from podman/crun --
# this is the kernel per-user keyring quota (kernel.keys.maxkeys, default
# 200), not disk space, and not specific to this script. Checked below with
# an actionable error instead of letting podman's cryptic message stand.
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
OUT="${2:-$ROOT/assets/rootfs/rootfs-$SUITE-$ARCH.tar.zst}"
COMPONENTS="${COMPONENTS:-${NCZ_BASE_COMPONENTS:-main contrib non-free non-free-firmware}}"

for t in tar zstd; do
    command -v "$t" >/dev/null 2>&1 || { echo "ERROR: missing build-host tool: $t" >&2; exit 1; }
done
command -v podman >/dev/null 2>&1 || command -v docker >/dev/null 2>&1 || \
    { echo "ERROR: need podman or docker on the build host" >&2; exit 1; }

# Per-user kernel keyring quota: podman/crun creates a session keyring per
# container. The default kernel.keys.maxkeys=200 is easy to exhaust on a
# host that has run many containers/sessions, and the failure ("crun: create
# keyring ...: Disk quota exceeded") gives no hint it's a keyring, not disk,
# limit. Caught fast here rather than mid-mmdebstrap.
if [ -r /proc/sys/kernel/keys/maxkeys ]; then
    _maxkeys=$(cat /proc/sys/kernel/keys/maxkeys)
    if [ "$_maxkeys" -lt 1000 ]; then
        echo "ERROR: kernel.keys.maxkeys=$_maxkeys is too low for podman/crun and will fail" >&2
        echo "       with a misleading 'Disk quota exceeded' error partway through the" >&2
        echo "       container run. Fix: sudo sysctl -w kernel.keys.maxkeys=1000000" >&2
        exit 1
    fi
fi

HOST_ARCH="$(uname -m)"
case "$HOST_ARCH:$ARCH" in
    aarch64:arm64) ;;
    x86_64:amd64)  ;;
    x86_64:arm64)
        echo "[base-rootfs] cross-arch $HOST_ARCH -> $ARCH via qemu-user-static/binfmt (verified 2026-09-14, see header)"
        ;;
    *)
        echo "ERROR: unsupported host/target arch combination: $HOST_ARCH -> $ARCH" >&2
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

# A pinned snapshot.debian.org mirror (release.conf's NCZ_BASE_MIRROR_SNAPSHOT)
# carries a short-lived Valid-Until; mmdebstrap's internal apt would refuse it
# as expired without this. No-op against the live deb.debian.org mirror.
APTOPT_ARGS=()
if [ -n "${NCZ_BASE_MIRROR_APT_OPTS:-}" ]; then
    APTOPT_ARGS=(--aptopt='Acquire::Check-Valid-Until=false')
fi

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
    ${APTOPT_ARGS[@]+"${APTOPT_ARGS[@]}"} \
    --customize-hook='chroot "\$1" /bin/sh -c "true > /etc/machine-id" 2>/dev/null || true' \
    --customize-hook='rm -f "\$1/etc/resolv.conf"' \
    "$SUITE" /out/$TAR_NAME "$BOOTSTRAP_MIRROR"
zstd -19 -T0 -f /out/$TAR_NAME -o /out/$OUT_BASE
rm -f /out/$TAR_NAME
CMD
)

# --arch is required for the cross-arch case (x86_64 host -> arm64 target):
# without it podman pulls/runs the host-native image and mmdebstrap's
# --arch=$ARCH would be bootstrapping a foreign arch from inside a
# same-arch-as-host container instead of a genuinely $ARCH one. This was
# the actual gap in the version of this script that pre-emptively refused
# cross-arch rather than testing it -- verified 2026-09-14 (see header).
"$CE" run --rm --network=host --arch="$ARCH" -v "$OUT_DIR":/out:Z "$CONTAINER_IMAGE" bash -c "$CONTAINER_CMD"

echo "[base-rootfs] done: $(du -h "$OUT" | cut -f1)"
