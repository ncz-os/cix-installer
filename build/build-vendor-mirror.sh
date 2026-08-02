#!/bin/bash
# build-vendor-mirror.sh — regenerate the profile-matched vendor mirror indexes.
#
# The vendor mirror carries the packages that are NOT in the Debian archive and
# therefore cannot be resolved by build-forky-mirror.sh: the locally built
# ncz-singularity-desktop payload package and Google's signed Chrome build.
# build-forky-mirror.sh consumes it as `deb [trusted=yes] file://$VENDOR_MIRROR`
# and refuses to run without it, so the indexes here must match the pool.
#
# Drop a .deb into pool/main/ and re-run this to publish it.
#
# Usage:
#   ./build/build-vendor-mirror.sh
set -euo pipefail
export LC_ALL=C

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../release.conf
. "$REPO/release.conf"

SUITE="${SUITE:-$NCZ_BASE_CODENAME}"
ARCH="${ARCH:-arm64}"
VENDOR="${VENDOR_MIRROR:-$REPO/build/$SUITE-vendor-mirror}"
BINDIR="dists/$SUITE/main/binary-$ARCH"

command -v apt-ftparchive >/dev/null 2>&1 || {
    echo "ERROR: apt-ftparchive not found (apt-utils)" >&2; exit 1; }
[ -d "$VENDOR/pool" ] || { echo "ERROR: vendor pool missing: $VENDOR/pool" >&2; exit 1; }

cd "$VENDOR"
mkdir -p "$BINDIR"

apt-ftparchive packages pool > "$BINDIR/Packages"
[ -s "$BINDIR/Packages" ] || { echo "ERROR: no packages found under $VENDOR/pool" >&2; exit 1; }
gzip -9nc "$BINDIR/Packages" > "$BINDIR/Packages.gz"

# The Release is what build-forky-mirror.sh trusts; regenerate it from the
# indexes just written so the checksums can never describe a stale Packages.
rm -f "dists/$SUITE/Release"
apt-ftparchive \
    -o "APT::FTPArchive::Release::Origin=NCZ" \
    -o "APT::FTPArchive::Release::Label=NCZ-${SUITE^}-Vendor" \
    -o "APT::FTPArchive::Release::Suite=$SUITE" \
    -o "APT::FTPArchive::Release::Codename=$SUITE" \
    -o "APT::FTPArchive::Release::Architectures=$ARCH" \
    -o "APT::FTPArchive::Release::Components=main" \
    release "dists/$SUITE" > "dists/$SUITE/Release"

echo "== vendor mirror: $VENDOR ($SUITE/$ARCH) =="
grep -E "^Package:|^Version:" "$BINDIR/Packages" | paste - - | sed "s/^/   /"
