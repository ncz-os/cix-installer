#!/bin/bash
# build-libdrm-debs.sh -- rebuild Debian libdrm with the NCZ ACPI platform fix.
#
# Output is intentionally a build artifact under build/libdrm-debs/. The desktop
# mirror treats these packages as required because stock libdrm collapses Sky1's
# ACPI platform DRM devices and hides panthor behind linlondp.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/libdrm-debs"
WORK="${TMPDIR:-/tmp}/ncz-libdrm-build.$$"
SRC_VER="${LIBDRM_SRC_VER:-2.4.134}"
DEB_REV="${LIBDRM_DEB_REV:-3}"
NCZ_REV="${LIBDRM_NCZ_REV:-ncz1}"
SUITE="${LIBDRM_SUITE:-forky}"
BASE_URL="${LIBDRM_DEBIAN_POOL:-https://deb.debian.org/debian/pool/main/libd/libdrm}"
PATCH="$ROOT/docs/upstream-patches/libdrm-xf86drm-acpi-platform-identity.patch"

for t in curl dpkg-source dpkg-buildpackage patch; do
    command -v "$t" >/dev/null 2>&1 || { echo "ERROR: missing tool: $t" >&2; exit 1; }
done
[ -f "$PATCH" ] || { echo "ERROR: missing patch: $PATCH" >&2; exit 1; }

rm -rf "$WORK"
mkdir -p "$WORK" "$OUT"
trap 'rm -rf "$WORK"' EXIT

cd "$WORK"
for f in \
    "libdrm_${SRC_VER}-${DEB_REV}.dsc" \
    "libdrm_${SRC_VER}.orig.tar.xz" \
    "libdrm_${SRC_VER}.orig.tar.xz.asc" \
    "libdrm_${SRC_VER}-${DEB_REV}.debian.tar.xz"; do
    curl -fsSLO "$BASE_URL/$f"
done

dpkg-source -x "libdrm_${SRC_VER}-${DEB_REV}.dsc"
cd "libdrm-${SRC_VER}"
patch -p1 < "$PATCH"

{
    printf 'libdrm (%s-%s+%s) %s; urgency=medium\n\n' "$SRC_VER" "$DEB_REV" "$NCZ_REV" "$SUITE"
    printf '  * Fix ACPI platform DRM identity so panthor is not hidden behind linlondp.\n\n'
    printf ' -- Jason Perlow <jperlow@gmail.com>  Thu, 20 Aug 2026 13:15:00 +0000\n\n'
    cat debian/changelog
} > debian/changelog.new
mv debian/changelog.new debian/changelog

DEB_BUILD_OPTIONS="${DEB_BUILD_OPTIONS:-nocheck}" dpkg-buildpackage -us -uc -b

find "$WORK" -maxdepth 1 -type f \( -name 'libdrm*_*.deb' -o -name 'libdrm*_*.udeb' \) \
    ! -name '*-dbgsym_*' -exec cp -f {} "$OUT/" \;

echo "built patched libdrm packages:"
find "$OUT" -maxdepth 1 -type f \( -name 'libdrm*_*.deb' -o -name 'libdrm*_*.udeb' \) \
    | sort | sed 's/^/  /'
