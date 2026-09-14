#!/bin/bash
# build-role-delta-mkosi.sh — build one role delta (e.g. desktop, server) as an
# overlayfs upperdir via mkosi, against a base rootfs tree.
#
# STATUS: mkosi phase 2, standalone producer. Verified on PROTEUS
# (2026-09-14) against a real mmdebstrap base + a real package set (curl and
# its 10 dependencies) -- see docs/mkosi-phase2-design.md for the full
# verification trail, including the dpkg-status hazard this script's hooks
# exist to close.
#
# NOT YET WIRED into build-squashfs-layers.sh's build_layer(). This produces
# the delta as a directory (mkosi Format=directory); it does NOT yet do the
# metacopy-materialization / overlay-manifest-generation / mksquashfs steps
# build_layer() does after producing its upperdir by hand -- those steps are
# unchanged by this replacement (they operate on the upperdir's CONTENT, not
# on how the overlay mount was created) and should be reused from
# build_layer(), not duplicated here. See "Integration" at the bottom.
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

[ -d "$BASE_DIR" ] || { echo "ERROR: base dir not found: $BASE_DIR" >&2; exit 1; }
[ -f "$BASE_DIR/var/lib/dpkg/status" ] || {
    echo "ERROR: $BASE_DIR has no var/lib/dpkg/status -- not a real base tree" >&2
    echo "       (CleanPackageMetadata=no must have been used to build it)" >&2
    exit 1
}
[ -f "$MANIFEST" ] || { echo "ERROR: manifest not found: $MANIFEST" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/var/tmp}/mkosi-delta-$ROLE.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Package list: one per line in the manifest, '#'-comments and blanks
# ignored -- same format build-squashfs-layers.sh's manifest_pkgs() reads.
PKG_LIST="$WORK/packages.txt"
grep -vE '^\s*(#|$)' "$MANIFEST" > "$PKG_LIST"
[ -s "$PKG_LIST" ] || { echo "ERROR: manifest $MANIFEST has no packages after filtering" >&2; exit 1; }

# --- the dpkg-status preservation hooks (REQUIRED, see design doc) ---------
# mkosi's Overlay=yes dedup pass unconditionally strips /var/lib/dpkg/status
# (and status-old) from the delta output as a "duplicate path", even when the
# content differs from base (confirmed empirically -- it is not a content
# check, package-manager runtime state is treated the same as lock files and
# ld.so.cache). Stash to a path with no base counterpart before the dedup
# pass runs, restore it into the finalized output after.
cat > "$WORK/save-dpkg-status.sh" <<'SAVE'
#!/bin/bash
set -e
mkdir -p "$BUILDROOT/var/tmp"
cp "$BUILDROOT/var/lib/dpkg/status" "$BUILDROOT/var/tmp/.saved-dpkg-status"
[ -f "$BUILDROOT/var/lib/dpkg/status-old" ] && \
    cp "$BUILDROOT/var/lib/dpkg/status-old" "$BUILDROOT/var/tmp/.saved-dpkg-status-old"
exit 0
SAVE
chmod +x "$WORK/save-dpkg-status.sh"

cat > "$WORK/restore-dpkg-status.sh" <<'RESTORE'
#!/bin/bash
set -e
[ -f "$OUTPUTDIR/image/var/tmp/.saved-dpkg-status" ] && \
    mv "$OUTPUTDIR/image/var/tmp/.saved-dpkg-status" "$OUTPUTDIR/image/var/lib/dpkg/status"
[ -f "$OUTPUTDIR/image/var/tmp/.saved-dpkg-status-old" ] && \
    mv "$OUTPUTDIR/image/var/tmp/.saved-dpkg-status-old" "$OUTPUTDIR/image/var/lib/dpkg/status-old"
exit 0
RESTORE
chmod +x "$WORK/restore-dpkg-status.sh"

# --- mkosi config -----------------------------------------------------------
PKG_YAML_LIST="$(sed 's/^/    /' "$PKG_LIST")"
cat > "$WORK/mkosi.conf" <<EOF
[Distribution]
Distribution=debian
Release=$NCZ_BASE_CODENAME
Architecture=$ARCH

[Output]
Format=directory
OutputDirectory=$OUT_DIR

[Content]
Bootable=no
BaseTrees=$BASE_DIR
Overlay=yes
CleanPackageMetadata=no
PostInstallationScripts=save-dpkg-status.sh
PostOutputScripts=restore-dpkg-status.sh
Packages=
$PKG_YAML_LIST
EOF

echo "[$ROLE] mkosi delta build: base=$BASE_DIR manifest=$MANIFEST arch=$ARCH"
mkdir -p "$OUT_DIR"
( cd "$WORK" && sudo mkosi --force build )

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
