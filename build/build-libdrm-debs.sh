#!/bin/bash
# build-libdrm-debs.sh -- rebuild Debian libdrm with the NCZ ACPI platform fix.
#
# Output is intentionally a build artifact under build/libdrm-debs/. The desktop
# mirror treats these packages as required because stock libdrm collapses Sky1's
# ACPI platform DRM devices and hides panthor behind linlondp.
set -euo pipefail
umask 022   # reproducible file modes: the version gate compares content, modes included

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Revision defaults come from release.conf (one value for both arches); see the BUMP RULE there.
# shellcheck source=../release.conf
. "$ROOT/release.conf"
OUT="$ROOT/build/libdrm-debs"
WORK="${TMPDIR:-/tmp}/ncz-libdrm-build.$$"
SRC_VER="${LIBDRM_SRC_VER:-2.4.134}"
DEB_REV="${LIBDRM_DEB_REV:-3}"
NCZ_REV="${LIBDRM_NCZ_REV:-${NCZ_LIBDRM_NCZ_REV:?release.conf must define NCZ_LIBDRM_NCZ_REV}}"
SUITE="${LIBDRM_SUITE:-forky}"
BASE_URL="${LIBDRM_DEBIAN_POOL:-https://deb.debian.org/debian/pool/main/libd/libdrm}"
PATCH="$ROOT/docs/upstream-patches/libdrm-xf86drm-acpi-platform-identity.patch"

# REUSE, DON'T REBUILD. The version gate (build/lib/deb-version-gate.sh) compares file contents, and a
# libdrm rebuilt on a different toolchain (another container, another snapshot) is not byte-identical:
# that is how the first revision tripped it in r201, and the arm64 libdrm2 contains compiled objects. Once a
# revision is built (in the pinned forky container) its binary debs are published to the ARGONAS build-inputs
# store, pinned by sha256 in manifests/build-inputs.tsv under build/libdrm-debs/. When the pinned set matches
# THIS version (SRC_VER-DEB_REV+NCZ_REV, whose patch hash is pinned in release.conf) it is staged and used as
# is, so every host and both arches ship the same bytes. LIBDRM_REBUILD=1 forces a build (then publish the
# result with `build/stage-build-inputs.sh --arch <a> --publish --only build/libdrm-debs/` and commit the pins).
WANT_VER="${SRC_VER}-${DEB_REV}+${NCZ_REV}"
HOST_ARCH="${LIBDRM_ARCH:-$(dpkg --print-architecture 2>/dev/null || true)}"
if [ "${LIBDRM_REBUILD:-0}" != 1 ] && [ -n "$HOST_ARCH" ] && [ -x "$ROOT/build/stage-build-inputs.sh" ]; then
    mkdir -p "$OUT"
    if bash "$ROOT/build/stage-build-inputs.sh" --arch "$HOST_ARCH" --only build/libdrm-debs/ >/dev/null 2>&1 \
       && [ -f "$OUT/libdrm2_${WANT_VER}_${HOST_ARCH}.deb" ] && [ -f "$OUT/libdrm-common_${WANT_VER}_all.deb" ]; then
        echo "reusing the published libdrm ${WANT_VER} ($HOST_ARCH) from the build-inputs store (sha256-pinned); LIBDRM_REBUILD=1 to rebuild"
        find "$OUT" -maxdepth 1 -type f \( -name 'libdrm*_*.deb' -o -name 'libdrm*_*.udeb' \) | sort | sed 's/^/  /'
        exit 0
    fi
    echo "no published libdrm ${WANT_VER} for $HOST_ARCH in the build-inputs store; building from source (the version gate applies)" >&2
fi

for t in curl dpkg-source dpkg-buildpackage patch; do
    command -v "$t" >/dev/null 2>&1 || { echo "ERROR: missing tool: $t" >&2; exit 1; }
done
[ -f "$PATCH" ] || { echo "ERROR: missing patch: $PATCH" >&2; exit 1; }
# The patch is part of the package content: changing it under the same revision republishes
# different bytes under a published version (the deb-version-gate refuses that, late). Fail early.
_psha="$(sha256sum "$PATCH" | awk '{print $1}')"
if [ "$_psha" != "${NCZ_LIBDRM_PATCH_SHA256:-}" ]; then
    echo "ERROR: $PATCH changed (sha256 $_psha, pinned ${NCZ_LIBDRM_PATCH_SHA256:-unset})." >&2
    echo "       Bump NCZ_LIBDRM_NCZ_REV and update NCZ_LIBDRM_PATCH_SHA256 in release.conf together." >&2
    exit 1
fi

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

# shellcheck source=lib/deb-version-gate.sh
. "$ROOT/build/lib/deb-version-gate.sh"
for _d in "$OUT"/libdrm*_*.deb; do
    [ -e "$_d" ] || continue
    ncz_deb_version_gate "$_d" || exit 1
done

echo "built patched libdrm packages:"
find "$OUT" -maxdepth 1 -type f \( -name 'libdrm*_*.deb' -o -name 'libdrm*_*.udeb' \) \
    | sort | sed 's/^/  /'
