#!/bin/bash
# build-role-delta-mkosi.sh — build one role delta (e.g. desktop, server) as an
# overlayfs upperdir via mkosi, against a base rootfs tree.
#
# STATUS: WIRED INTO PRODUCTION (2026-09-14) via build_layer() in
# build-squashfs-layers.sh, replacing the hand-rolled mount+apt-install block
# (unsquash base -> mount -t overlay -> apt-get install). build_layer() still
# owns everything before and after: unsquashing base to a lowerdir (this
# script needs that same lowerdir as BaseTrees=), and -- critically -- a
# SECOND overlay mount of base+this-script's-output afterward, because the
# desktop role's brand-hook loop (20-desktop, 52-vivaldi, 53-chrome, etc.)
# chroots into a MERGED base+delta view to install further packages and run
# installer hooks. This script only produces the upperdir; it was never meant
# to replace that second mount, see "Integration" at the bottom for exactly
# why and how build_layer() uses this script's output.
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
# WHY THE OFFLINE PINNED MIRROR MATTERS HERE TOO (2026-09-14, found while
# wiring this into production): build_layer()'s apt_offline() exists because
# of a real incident (2026-08-11) -- a build that saw BOTH the pinned mirror
# AND a live Debian archive at once was not reproducible (same command,
# different day, different closure) and once produced an unsatisfiable
# desktop set when unpinned GNOME landed in testing mid-mirror-snapshot. This
# script's mkosi build MUST see the exact same single pinned source, not
# mkosi's own default live mirror -- otherwise wiring it into production
# would silently reintroduce the bug apt_offline() was written to prevent.
# If a populated mirror exists (mirror_available()-equivalent check below),
# bind it in and force --network=none for the actual mkosi build step (a
# stronger guarantee than apt_offline()'s post-hoc grep-for-a-remote-URL
# check -- no network path exists at all, so a live source cannot be reached
# even by accident). If no mirror is populated on this host yet (true for a
# fresh clone -- no build/$SUITE-mirror data is checked into git, only the
# scripts that build one), fall back to network with a loud warning, exactly
# matching build_base()'s existing mirror_available()-or-warn pattern -- this
# is not a new inconsistency, it is the same graceful-degradation rule
# already established elsewhere in this codebase.
#
# Usage: build-role-delta-mkosi.sh <role> <manifest-path> <base-dir> <out-dir> [arch]
set -euo pipefail

ROLE="${1:?usage: $0 <role> <manifest-path> <base-dir> <out-dir> [arch]}"
MANIFEST="${2:?manifest path required}"
BASE_DIR="${3:?base directory required (a plain extracted rootfs tree, not a tarball)}"
OUT_DIR="${4:?output directory required}"
ARCH="${5:-arm64}"
# mkosi's Architecture= uses systemd/uname-style tokens, not dpkg arch names
# -- "amd64" is rejected outright ("'amd64' is not a valid Architecture").
# NCZ_TARGET_ARCH/ARCH stay dpkg-style everywhere else in this pipeline
# (manifest/.deb-glob matching), so translate ONLY for mkosi's own config.
case "$ARCH" in
  amd64) MKOSI_ARCH=x86-64 ;;
  *)     MKOSI_ARCH="$ARCH" ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ -r "$ROOT/release.conf" ]; then
    # shellcheck source=../release.conf
    . "$ROOT/release.conf"
else
    echo "ERROR: $ROOT/release.conf not readable -- refusing to guess the base distro" >&2
    exit 1
fi
: "${NCZ_BASE_CODENAME:?release.conf did not define NCZ_BASE_CODENAME}"

# Same suite/components/mirror-dir convention as build-squashfs-layers.sh,
# duplicated rather than sourced (that script is a giant function library, not
# something safe to `source` standalone -- it has no include guard and runs
# top-level code). Keep these in sync by hand if the source of truth changes.
APT_SUITE="${APT_SUITE:-$NCZ_BASE_CODENAME}"
APT_COMPONENTS="${APT_COMPONENTS:-main}"
MIRROR_DIRS="${MIRROR_DIRS:-$NCZ_BASE_CODENAME-mirror $NCZ_BASE_CODENAME-vendor-mirror}"

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
mkdir -p "$WORK/conf" "$WORK/vartmp" "$WORK/pkgmgr/etc/apt/sources.list.d"
trap 'rm -rf "$WORK"' EXIT

_avail_gb=$(df -P --block-size=1G "$WORK" 2>/dev/null | awk 'NR==2{print $4+0}') || true
_avail_gb="${_avail_gb:-0}"
if [ "$_avail_gb" -lt 20 ]; then
    echo "[$ROLE] WARNING: only ${_avail_gb}G free on $(dirname "$WORK") -- a role delta plus its mkosi workspace can need well over that." >&2
fi

# Package list: one per line in the manifest, whole-line AND inline trailing
# '#'-comments stripped, blanks ignored -- byte-identical to
# build-squashfs-layers.sh's manifest_pkgs() (r190.1: a `pkg  # comment` line
# passed to apt-get VERBATIM once corrupted a whole batch install and
# silently dropped unrelated packages -- the same manifest format feeds both
# build_base()'s hand-rolled install and this script now, so both parsers
# must agree exactly, not just on the whole-line-comment case).
PKG_LIST="$WORK/conf/packages.txt"
sed 's/#.*//' "$MANIFEST" | sed -E 's/[[:space:]]+$//' | grep -vE '^[[:space:]]*$' > "$PKG_LIST"
[ -s "$PKG_LIST" ] || { echo "ERROR: manifest $MANIFEST has no packages after filtering" >&2; exit 1; }

# google-chrome-stable has no source anywhere in mkosi's sandboxed apt pass
# by design -- it ships from Google's own dl.google.com repo, deliberately
# excluded here and installed instead by post-install/53-chrome.sh in the
# LATER brand-hook loop chroot (build_layer(), after this script returns).
# That loop is STILL offline-mirror-pinned (apt_offline($MG)), not live
# internet -- the "real, network-connected chroot" framing in an earlier
# version of this comment was aspirational and wrong; correcting it
# 2026-09-16 after finding 53-chrome.sh never actually ran the install (see
# that file's own 2026-09-16 fix note). What actually makes this work is
# that build-vendor-mirror.sh fetches + pins + SHA256-verifies a real
# google-chrome-stable .deb into the SAME offline mirror this sandbox reads,
# so a later apt-get install against that mirror resolves fine even without
# live internet. The exclusion here just keeps it out of THIS pass (mkosi's
# own Packages=/overlay-dedup machinery), not out of the offline mirror
# itself. It stays listed in the manifest FILE (SBOM/preflight tooling reads
# that), just not passed to mkosi's own apt-get here. Confirmed empirically
# 2026-09-14: with a real, working apt index (Debian forky + NCZ
# Buildkite/R2), every OTHER manifest-listed package resolves fine -- this
# is the one genuine, by-design exception, not a source-wiring bug.
# grep -v returns exit 1 (not just "no matches removed") when its OUTPUT is
# empty -- if this exclusion ever left nothing behind, `&&` would skip the
# mv and silently ship the UNFILTERED list (Chrome included) instead of
# failing loud. Accept only exit 0/1 from grep, then hard-fail if the
# filtered list is empty (Codex review finding, 2026-09-14).
grep -vxF 'google-chrome-stable' "$PKG_LIST" > "$PKG_LIST.filtered" || {
    rc=$?
    [ "$rc" -eq 1 ] || exit "$rc"
}
mv "$PKG_LIST.filtered" "$PKG_LIST"
[ -s "$PKG_LIST" ] || { echo "ERROR: manifest has no mkosi-installable packages after exclusions" >&2; exit 1; }

# --- offline mirror discovery + bind mounts ---------------------------------
# Mirrors the exact single-pinned-source contract apt_offline() enforces in
# build-squashfs-layers.sh: EITHER every package comes from our snapshot, OR
# (mirror not populated on this host) the caller gets a loud warning and a
# live-network build -- never a silent mix of both.
MIRROR_MOUNTS=()
MIRROR_LIST_LINES=""
SANDBOX_TREE_LINES=""
for m in $MIRROR_DIRS; do
    [ -d "$ROOT/build/$m/dists/$APT_SUITE" ] || continue
    MIRROR_MOUNTS+=(-v "$ROOT/build/$m:/mnt/$m:ro,Z")
    MIRROR_LIST_LINES="$MIRROR_LIST_LINES
deb [trusted=yes] file:///mnt/$m $APT_SUITE $APT_COMPONENTS"
    # mkosi runs apt inside its OWN inner build sandbox (bubblewrap), separate
    # from this outer podman container -- the -v bind mount above only makes
    # /mnt/$m visible to the OUTER container, not to mkosi's inner sandbox
    # where apt actually executes. Without an explicit SandboxTrees= entry,
    # the offline sources.list.d file we just wrote points at a path
    # (file:///mnt/$m/...) that genuinely does not exist from apt's point of
    # view, even though it is real and populated one container layer out.
    # Confirmed by direct reproduction: the identical outer bind mount works
    # fine under a bare "podman run ... ls /mnt/$m"; only mkosi's own build
    # step (apt-get update inside its inner sandbox) fails to see it.
    SANDBOX_TREE_LINES="$SANDBOX_TREE_LINES
SandboxTrees=/mnt/$m:/mnt/$m"
done

if [ -n "$MIRROR_LIST_LINES" ]; then
    printf '%s\n' "$MIRROR_LIST_LINES" | sed '/^$/d' > "$WORK/pkgmgr/etc/apt/sources.list.d/ncz-offline-mirror.list"
    NETWORK_ARGS=(--network=none)
    echo "[$ROLE] offline mirror: $(printf '%s' "$MIRROR_LIST_LINES" | grep -c deb) source(s), --network=none for the build"
else
    NETWORK_ARGS=()
    _mirror_dir_list="${MIRROR_DIRS// /,}"
    echo "[$ROLE] WARNING: no populated mirror under build/{$_mirror_dir_list} for suite $APT_SUITE -- falling back to a LIVE network build (not reproducible, matches build_base()'s existing no-mirror fallback)" >&2
    # This delta's OWN mkosi apt pass does NOT inherit build_base()'s
    # /etc/apt/sources.list.d wiring via BaseTrees= -- confirmed empirically
    # 2026-09-14: base's 24-apt-sources.sh fix left every ordinary + NCZ
    # package resolvable in the BASE chroot, but this script's mkosi sandbox
    # still failed on chromium-ncz-sky1/ncz-ffmpeg/ncz-singularity-desktop/
    # firmware-* with the exact same errors as before that fix. mkosi's
    # PackageManagerTrees=/pkgmgr is populated BEFORE its package-manager
    # step runs and is the container-native equivalent of what 24-apt-
    # sources.sh does inside a live chroot -- write the same two NCZ
    # sources + dearmored keyrings there directly (gpg runs on the HOST,
    # not inside the sandbox, since PackageManagerTrees is copied in as
    # static files, not executed as a script).
    NCZ_PKGMGR_APT="$WORK/pkgmgr/etc/apt"
    install -d "$NCZ_PKGMGR_APT/keyrings" "$NCZ_PKGMGR_APT/sources.list.d"
    if [ -f "$ROOT/post-install/buildkite-ncz-apt-keyring.asc" ] && \
       gpg --dearmor < "$ROOT/post-install/buildkite-ncz-apt-keyring.asc" > "$NCZ_PKGMGR_APT/keyrings/buildkite-ncz-apt-keyring.gpg" 2>/dev/null; then
        cat > "$NCZ_PKGMGR_APT/sources.list.d/ncz-os-apt-buildkite.list" <<SRCEOF
deb [signed-by=/etc/apt/keyrings/buildkite-ncz-apt-keyring.gpg] https://packages.buildkite.com/ncz-os/ncz/any/ any main
SRCEOF
        echo "[$ROLE] NCZ Buildkite Packages source wired into mkosi pkgmgr tree"
    fi
    if [ -f "$ROOT/post-install/ncz-os-apt-keyring.asc" ] && \
       gpg --dearmor < "$ROOT/post-install/ncz-os-apt-keyring.asc" > "$NCZ_PKGMGR_APT/keyrings/ncz-os-apt-keyring.gpg" 2>/dev/null; then
        cat > "$NCZ_PKGMGR_APT/sources.list.d/ncz-os-apt-r2.list" <<SRCEOF
deb [signed-by=/etc/apt/keyrings/ncz-os-apt-keyring.gpg] https://pub-d7b784e01679403d9c70fcd23fff5b96.r2.dev any main
SRCEOF
        echo "[$ROLE] NCZ Cloudflare R2 source wired into mkosi pkgmgr tree"
    fi
fi

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
[ -s "$BUILDROOT/var/tmp/.saved-dpkg-status" ] || {
    echo "FATAL: save-dpkg-status produced an empty/missing stash -- refusing to continue" >&2
    exit 1
}
[ -f "$BUILDROOT/var/lib/dpkg/status-old" ] && \
    cp "$BUILDROOT/var/lib/dpkg/status-old" "$BUILDROOT/var/tmp/.saved-dpkg-status-old"
exit 0
SAVE
chmod +x "$WORK/conf/save-dpkg-status.sh"

# restore fails LOUD (not a silent no-op) if the stash is missing -- an absent
# stash means save-dpkg-status.sh above never ran or mkosi's dedup pass ate it
# before this hook could run, and shipping the base's stale dpkg status
# instead of failing is exactly the 2026-08-11-class hazard this pair of
# hooks exists to prevent (zoder cross-family review, 2026-09-14).
cat > "$WORK/conf/restore-dpkg-status.sh" <<'RESTORE'
#!/bin/bash
set -e
[ -f "$OUTPUTDIR/image/var/tmp/.saved-dpkg-status" ] || {
    echo "FATAL: no saved dpkg status to restore -- save-dpkg-status.sh did not" >&2
    echo "       run, or its output was removed before this hook ran. Refusing" >&2
    echo "       to ship a delta with a stale/base dpkg status." >&2
    exit 1
}
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
#
# PackageManagerTrees=/pkgmgr seeds our offline-mirror sources.list.d entry
# (when one was found above) into the image root BEFORE mkosi's package
# manager step runs, and Mirror= is deliberately left UNSET so mkosi never
# additionally writes its own live default source alongside it -- exactly the
# single-source contract apt_offline() enforces for every other layer.
PKG_YAML_LIST="$(sed 's/^/    /' "$PKG_LIST")"
cat > "$WORK/conf/mkosi.conf" <<EOF
[Distribution]
Distribution=debian
Release=$NCZ_BASE_CODENAME
Architecture=$MKOSI_ARCH
Repositories=${NCZ_BASE_COMPONENTS// /,}

[Output]
Format=directory
OutputDirectory=/out
Overlay=yes

[Content]
Bootable=no
BaseTrees=/base
CleanPackageMetadata=no
PackageManagerTrees=/pkgmgr
$(printf '%s\n' "$SANDBOX_TREE_LINES" | sed '/^$/d')
PostInstallationScripts=save-dpkg-status.sh
PostOutputScripts=restore-dpkg-status.sh
Packages=
$PKG_YAML_LIST
EOF

echo "[$ROLE] mkosi delta build (containerized): base=$BASE_DIR manifest=$MANIFEST arch=$ARCH mkosi=$MKOSI_PKG_VERSION"
# build_layer() always wipes $OUT_DIR before calling this script, so this is
# belt-and-suspenders for the one caller that matters -- but this script is
# also documented as directly callable standalone (see "Integration" at the
# bottom), and a standalone caller reusing a path from a prior failed run
# would otherwise let stale $OUT_DIR/image content silently pass the
# dpkg-status existence check below and get shipped (zoder cross-family
# review, 2026-09-14). Refuse rather than build on top of it.
if [ -d "$OUT_DIR" ] && [ -n "$(ls -A "$OUT_DIR" 2>/dev/null)" ]; then
    echo "ERROR: $OUT_DIR already exists and is non-empty (stale output from a" >&2
    echo "       prior run?) -- refusing to build on top of it. Remove it first." >&2
    exit 1
fi
mkdir -p "$OUT_DIR"

# --cap-add=SYS_ADMIN (not --privileged): tested both on PROTEUS 2026-09-14,
# SYS_ADMIN plus the two security-opt below (mount() needs the capability;
# apparmor/SELinux label confinement otherwise blocks the nested mount even
# with the capability granted) is sufficient and is the smaller grant.
# --rm: this container is pure scratch space, nothing inside it should
# outlive the build -- $OUT_DIR (bind-mounted) is the only durable output.
#
# The bootstrap step (installing mkosi itself into the container) runs
# WITHOUT the mirror bind mounts or --network=none applied to it -- it needs
# the debian:$NCZ_BASE_CODENAME image's own apt config to fetch the mkosi
# package, which is a build-tooling concern, not a question of which Debian
# archive the ROLE's packages come from. Only the actual `mkosi build`
# invocation gets the pinned-source contract (mirror mounts + --network=none
# when a mirror exists). Two podman runs, not one, to draw that line cleanly:
# the first (networked) prepares nothing that ships; the second (pinned or
# explicitly-warned-live) is the one whose output becomes the delta.
IMG="debian:$NCZ_BASE_CODENAME"
BOOTSTRAP_TAG="localhost/ncz-mkosi-builder:$MKOSI_PKG_VERSION"
if ! sudo podman image exists "$BOOTSTRAP_TAG" 2>/dev/null; then
    echo "[$ROLE] preparing mkosi builder image ($BOOTSTRAP_TAG, one-time per host+version)"
    _bootstrap_cid=$(sudo podman run -d "$IMG" sleep infinity)
    sudo podman exec "$_bootstrap_cid" bash -c "apt-get update -qq && apt-get install -y -qq mkosi=$MKOSI_PKG_VERSION"
    sudo podman commit "$_bootstrap_cid" "$BOOTSTRAP_TAG" >/dev/null
    sudo podman rm -f "$_bootstrap_cid" >/dev/null
fi

sudo podman run --rm \
    "${NETWORK_ARGS[@]}" \
    --cap-add=SYS_ADMIN \
    --security-opt apparmor=unconfined \
    --security-opt label=disable \
    -v "$WORK/conf":/work:Z \
    -v "$WORK/pkgmgr":/pkgmgr:ro,Z \
    "${MIRROR_MOUNTS[@]}" \
    -v "$BASE_DIR":/base:ro,Z \
    -v "$OUT_DIR":/out:Z \
    -v "$WORK/vartmp":/var/tmp:Z \
    "$BOOTSTRAP_TAG" bash -c "cd /work && mkosi --force build"

[ -f "$OUT_DIR/image/var/lib/dpkg/status" ] || {
    echo "ERROR: $ROLE delta produced no var/lib/dpkg/status -- the save/restore" >&2
    echo "       hooks did not run or failed silently. Do not ship this delta." >&2
    exit 1
}
echo "[$ROLE] DONE: $(du -sh "$OUT_DIR/image" | cut -f1) at $OUT_DIR/image"

# --- Integration ---------------------------------------------------------
# build_layer() in build-squashfs-layers.sh calls this script to produce the
# upperdir content (package install only), then:
#   1. moves $OUT_DIR/image into its own $U (upperdir) location
#   2. mounts overlay(lower=$L, upper=$U, work=$WK) -> $MG -- a SECOND overlay
#      mount, separate from mkosi's own internal one, needed because the
#      desktop role's brand-hook loop chroots into a MERGED base+delta view
#      to install further packages (vivaldi, chrome, Artist Pack debs) and
#      run installer hooks -- this script's static output directory alone
#      cannot be chrooted into (base's own binaries, e.g. apt/dpkg/bash,
#      are not present in the upperdir, only what mkosi additionally
#      installed)
#   3. runs its existing brand-hook loop, metacopy-materialization,
#      overlay-manifest-generation, and mksquashfs against that merged mount
#      exactly as before -- none of that changed, only how the upperdir's
#      package-install content gets produced in the first place.
