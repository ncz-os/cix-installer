#!/bin/bash
# build-role-delta-mkosi.sh — build one role delta (e.g. desktop, server) as an
# overlayfs upperdir via mkosi, against a base rootfs tree.
#
# STATUS: mkosi phase 2, standalone producer. Verified end-to-end on PROTEUS
# (2026-09-14) against a real mmdebstrap base + a real package set (curl and
# its 10 dependencies) -- see docs/superpowers/specs/2026-09-14-mkosi-phase2-design.md
# for the full verification trail, including the dpkg-status hazard the hooks
# below exist to close and the containerization hazard the podman wrapping
# below exists to close.
#
# NOT YET WIRED into build-squashfs-layers.sh's build_layer(). This produces
# the delta as a directory (mkosi Format=directory); it does NOT yet do the
# metacopy-materialization / overlay-manifest-generation / mksquashfs steps
# build_layer() does after producing its upperdir by hand -- those steps are
# unchanged by this replacement (they operate on the upperdir's CONTENT, not
# on how the overlay mount was created) and should be reused from
# build_layer(), not duplicated here. See "Integration" at the bottom.
#
# WHY CONTAINERIZED (2026-09-14): the first version of this script ran
# `sudo mkosi --force build` directly on the bare host. mkosi's Overlay=yes
# needs a real overlayfs mount(), so that reintroduced exactly the class of
# host-level-mount risk build-base-rootfs.sh's podman-wrapped mmdebstrap was
# redesigned to eliminate (see that script's header: a bind-mounted EFI
# System Partition was destroyed by `rm -rf` under a chroot that failed to
# clean up a stale mount). Wrapping this build in a throwaway podman
# container closes that: if mkosi dies mid-build, the mount lives and dies
# with the container, never touching the host's real filesystem tree.
#
# WHY --cap-add=SYS_ADMIN INSTEAD OF --privileged: tested both on PROTEUS.
# --privileged is not required; SYS_ADMIN (for mount()) plus disabling
# apparmor/SELinux label confinement for this one container is sufficient
# and is the smaller privilege grant.
#
# WHY THE WORKSPACE MUST BE A HOST BIND MOUNT, NOT THE CONTAINER'S OWN ROOTFS
# (this doubles as the tmpfs-exhaustion guard build-squashfs-layers.sh
# already carries for the same reason -- see its own header comment, ported
# here): podman's default storage driver backs a container's own rootfs with
# overlayfs. mkosi's BaseTrees=+Overlay=yes needs to mount ANOTHER overlayfs
# for its workspace/staging area. The kernel refuses to layer an overlayfs
# mount on top of a lowerdir/upperdir that is itself already on an overlayfs
# ("overlay on overlay") -- confirmed empirically on PROTEUS 2026-09-14:
#
#     OSError: [Errno 22] Invalid argument: '/var/tmp/mkosi-workspace-.../root'
#
# with --privileged and every capability granted; the container's own
# overlay-backed root was the actual problem, not a missing capability.
# Fix: bind-mount a REAL host directory (never tmpfs, per the same
# ENOSPC-disguised-as-corruption incident build-squashfs-layers.sh already
# documents) over /var/tmp inside the container, so mkosi's nested overlay
# mount lands on ext4/xfs/whatever the host scratch disk actually is, not on
# another overlayfs. Verified: with this bind mount in place, the exact same
# build that failed under --privileged with no bind mount succeeds cleanly.
#
# Usage: build-role-delta-mkosi.sh <role> <manifest-path> <base-dir> <out-dir> [arch]
set -euo pipefail

ROLE="${1:?usage: $0 <role> <manifest-path> <base-dir> <out-dir> [arch]}"
MANIFEST="${2:?manifest path required}"
BASE_DIR="${3:?base directory required (a plain extracted rootfs tree, not a tarball)}"
OUT_DIR="${4:?output directory required}"
ARCH="${5:-arm64}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ -r "$ROOT/release.conf" ]; then
    # shellcheck source=../release.conf
    . "$ROOT/release.conf"
else
    echo "ERROR: $ROOT/release.conf not readable -- refusing to guess the base distro" >&2
    exit 1
fi
: "${NCZ_BASE_CODENAME:?release.conf did not define NCZ_BASE_CODENAME}"

# Pinned exact mkosi package version, per GRAEAE consult hardening ask
# (2026-09-14, winning synthesis openai/gpt-5.6-sol): a floating "latest"
# mkosi is a live drift surface -- the container image's own apt snapshot
# already pins the distro suite, but mkosi as a package inside it does not
# unless we say so explicitly. Confirmed available in debian:forky as of
# 2026-09-14 (`apt-cache policy mkosi` -> Candidate: 27-1). Bump deliberately,
# re-verify the overlay/dpkg-status behavior above when you do -- mkosi's
# own overlay dedup semantics are exactly the kind of thing a minor version
# could change silently.
MKOSI_PKG_VERSION="${MKOSI_PKG_VERSION:-27-1}"

command -v podman >/dev/null 2>&1 || { echo "ERROR: podman required (containerized mkosi build)" >&2; exit 1; }

[ -d "$BASE_DIR" ] || { echo "ERROR: base dir not found: $BASE_DIR" >&2; exit 1; }
[ -f "$BASE_DIR/var/lib/dpkg/status" ] || {
    echo "ERROR: $BASE_DIR has no var/lib/dpkg/status -- not a real base tree" >&2
    echo "       (CleanPackageMetadata=no must have been used to build it)" >&2
    exit 1
}
[ -f "$MANIFEST" ] || { echo "ERROR: manifest not found: $MANIFEST" >&2; exit 1; }

# --- tmpfs guard -------------------------------------------------------------
# Same logic and same reason as build-squashfs-layers.sh's WORK relocation
# (see that script's header: a multi-GB layer's decompress+verify pass
# exceeding a RAM-backed /tmp was once silently misdiagnosed as squashfs
# corruption). Applies doubly here: this directory is ALSO what gets bind-
# mounted over the container's /var/tmp as the mkosi workspace (see header),
# so tmpfs here would reintroduce both hazards -- OOM/ENOSPC AND the overlay-
# on-overlay EINVAL if podman's own tmpfs backing happens to be overlay-
# adjacent. Only relocate when the caller has not chosen WORK explicitly.
WORK="${WORK:-/var/tmp/ncz-mkosi-delta-$ROLE}"
if [ -z "${WORK_EXPLICIT:-}" ] && [ "$(stat -f -c %T "$(dirname "$WORK")" 2>/dev/null || true)" = "tmpfs" ]; then
    _alt="$ROOT/build/.mkosi-delta-work"
    echo "[$ROLE] WORK ($WORK) is on tmpfs -- relocating to $_alt (mkosi's overlay workspace will not fit in RAM, and cannot nest on tmpfs safely either)"
    WORK="$_alt"
fi
rm -rf "$WORK"
mkdir -p "$WORK/conf" "$WORK/vartmp"
trap 'rm -rf "$WORK"' EXIT

_avail_gb=$(df -P --block-size=1G "$WORK" 2>/dev/null | awk 'NR==2{print $4+0}') || true
_avail_gb="${_avail_gb:-0}"
if [ "$_avail_gb" -lt 20 ]; then
    echo "[$ROLE] WARNING: only ${_avail_gb}G free on $(dirname "$WORK") -- a role delta plus its mkosi workspace can need well over that." >&2
fi

# Package list: one per line in the manifest, '#'-comments and blanks
# ignored -- same format build-squashfs-layers.sh's manifest_pkgs() reads.
PKG_LIST="$WORK/conf/packages.txt"
grep -vE '^\s*(#|$)' "$MANIFEST" > "$PKG_LIST"
[ -s "$PKG_LIST" ] || { echo "ERROR: manifest $MANIFEST has no packages after filtering" >&2; exit 1; }

# --- the dpkg-status preservation hooks (REQUIRED, see design doc) ---------
# mkosi's Overlay=yes dedup pass unconditionally strips /var/lib/dpkg/status
# (and status-old) from the delta output as a "duplicate path", even when the
# content differs from base (confirmed empirically -- it is not a content
# check, package-manager runtime state is treated the same as lock files and
# ld.so.cache). Stash to a path with no base counterpart before the dedup
# pass runs, restore it into the finalized output after. Re-verified working
# inside the containerized build 2026-09-14 (same mechanism, same paths --
# BUILDROOT/OUTPUTDIR are mkosi's own env vars for its hook scripts, set
# identically whether mkosi runs bare or inside a container).
cat > "$WORK/conf/save-dpkg-status.sh" <<'SAVE'
#!/bin/bash
set -e
mkdir -p "$BUILDROOT/var/tmp"
cp "$BUILDROOT/var/lib/dpkg/status" "$BUILDROOT/var/tmp/.saved-dpkg-status"
[ -f "$BUILDROOT/var/lib/dpkg/status-old" ] && \
    cp "$BUILDROOT/var/lib/dpkg/status-old" "$BUILDROOT/var/tmp/.saved-dpkg-status-old"
exit 0
SAVE
chmod +x "$WORK/conf/save-dpkg-status.sh"

cat > "$WORK/conf/restore-dpkg-status.sh" <<'RESTORE'
#!/bin/bash
set -e
[ -f "$OUTPUTDIR/image/var/tmp/.saved-dpkg-status" ] && \
    mv "$OUTPUTDIR/image/var/tmp/.saved-dpkg-status" "$OUTPUTDIR/image/var/lib/dpkg/status"
[ -f "$OUTPUTDIR/image/var/tmp/.saved-dpkg-status-old" ] && \
    mv "$OUTPUTDIR/image/var/tmp/.saved-dpkg-status-old" "$OUTPUTDIR/image/var/lib/dpkg/status-old"
exit 0
RESTORE
chmod +x "$WORK/conf/restore-dpkg-status.sh"

# --- mkosi config -----------------------------------------------------------
# OutputDirectory is /out INSIDE the container (bind-mounted from $OUT_DIR on
# the host); BaseTrees is /base INSIDE the container (bind-mounted read-only
# from $BASE_DIR) -- these are container-internal paths, not host paths.
PKG_YAML_LIST="$(sed 's/^/    /' "$PKG_LIST")"
cat > "$WORK/conf/mkosi.conf" <<EOF
[Distribution]
Distribution=debian
Release=$NCZ_BASE_CODENAME
Architecture=$ARCH

[Output]
Format=directory
OutputDirectory=/out

[Content]
Bootable=no
BaseTrees=/base
Overlay=yes
CleanPackageMetadata=no
PostInstallationScripts=save-dpkg-status.sh
PostOutputScripts=restore-dpkg-status.sh
Packages=
$PKG_YAML_LIST
EOF

echo "[$ROLE] mkosi delta build (containerized): base=$BASE_DIR manifest=$MANIFEST arch=$ARCH mkosi=$MKOSI_PKG_VERSION"
mkdir -p "$OUT_DIR"

# --cap-add=SYS_ADMIN (not --privileged): tested both on PROTEUS 2026-09-14,
# SYS_ADMIN plus the two security-opt below (mount() needs the capability;
# apparmor/SELinux label confinement otherwise blocks the nested mount even
# with the capability granted) is sufficient and is the smaller grant.
# --rm: this container is pure scratch space, nothing inside it should
# outlive the build -- $OUT_DIR (bind-mounted) is the only durable output.
sudo podman run --rm \
    --cap-add=SYS_ADMIN \
    --security-opt apparmor=unconfined \
    --security-opt label=disable \
    -v "$WORK/conf":/work:Z \
    -v "$BASE_DIR":/base:ro,Z \
    -v "$OUT_DIR":/out:Z \
    -v "$WORK/vartmp":/var/tmp:Z \
    "debian:$NCZ_BASE_CODENAME" bash -c "
        set -e
        apt-get update -qq
        apt-get install -y -qq mkosi=$MKOSI_PKG_VERSION
        cd /work && mkosi --force build
    "

[ -f "$OUT_DIR/image/var/lib/dpkg/status" ] || {
    echo "ERROR: $ROLE delta produced no var/lib/dpkg/status -- the save/restore" >&2
    echo "       hooks did not run or failed silently. Do not ship this delta." >&2
    exit 1
}
echo "[$ROLE] DONE: $(du -sh "$OUT_DIR/image" | cut -f1) at $OUT_DIR/image"

# --- Integration (not yet done) ---------------------------------------------
# build_layer() in build-squashfs-layers.sh currently produces its upperdir
# via: unsquash base -> mount -t overlay -> apt-get install into the mount ->
# metacopy materialization -> overlay-manifest generation -> mksquashfs.
# This script replaces ONLY the first two steps (mount + install). To wire
# it in, build_layer() would call this script instead of its own
# mount/apt-install block, then run ITS EXISTING metacopy-materialization,
# overlay-manifest-generation, and mksquashfs steps against
# $OUT_DIR/image (this script's output) instead of its own hand-mounted
# upperdir ($U). Those later steps are unchanged -- they operate on
# directory content, not on how the overlay was assembled -- and should stay
# in build_layer() rather than being duplicated here.
