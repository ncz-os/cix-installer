#!/bin/bash
# build-vendor-mirror.sh — regenerate the profile-matched vendor mirror indexes.
#
# The vendor mirror carries the packages that are NOT in the Debian archive and
# therefore cannot be resolved by build-forky-mirror.sh: the locally built
# ncz-singularity-desktop payload package and Google's signed Chrome build.
# build-forky-mirror.sh consumes it as `deb [trusted=yes] file://$VENDOR_MIRROR`
# and refuses to run without it, so the indexes here must match the pool.
#
# Locally built .debs are published automatically from build/kernel-debs/ and,
# when present, assets/cix-debs/ before indexing. Other local/vendor packages
# may still be dropped into pool/main/ and re-indexed with this helper.
#
# 2026-08-27: SINTY_DEBS used to default to build/sinty-out/ -- a DIFFERENT
# directory than assets/cix-debs/, which is what build/build-squashfs-layers
# .sh's build_hotfix() actually reads (and what every session tonight staged
# new .debs into). Nothing ever wrote to build/sinty-out/, so this publish
# step silently found nothing new and the vendor-mirror kept re-indexing
# whatever singularity-desktop version happened to already be in its pool
# from days earlier -- while post-install/20-desktop.sh prefers dpkg -i from
# that same pool (staged onto the ISO as /cdrom/pool/main/) OVER the
# apt-get fallback, and runs AFTER the hotfix-squashfs layer extracts during
# d-i, so it silently overwrote a correctly-rebuilt hotfix layer with the
# stale package every time. Two consumers, two different "canonical"
# directories, only one of them ever actually written to -- same failure
# shape as the Makefile squashfs-dependency bug fixed earlier tonight, just
# a different path to the same file going stale. Both consumers now point
# at the one real canonical location.
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
KERNEL_DEBS="${KERNEL_DEBS:-$REPO/build/kernel-debs}"
SINTY_DEBS="${SINTY_DEBS:-$REPO/assets/cix-debs}"

command -v apt-ftparchive >/dev/null 2>&1 || {
    echo "ERROR: apt-ftparchive not found (apt-utils)" >&2; exit 1; }
mkdir -p "$VENDOR/pool/main"

publish_deb() {
    local src="$1"
    local dest="$VENDOR/pool/main/$(basename "$src")"
    local pkg arch src_sha dest_sha old

    pkg="$(dpkg-deb -f "$src" Package)"
    arch="$(dpkg-deb -f "$src" Architecture)"
    src_sha="$(sha256sum "$src" | awk '{print $1}')"

    if [ -f "$dest" ]; then
        dest_sha="$(sha256sum "$dest" | awk '{print $1}')"
        if [ "$src_sha" = "$dest_sha" ]; then
            echo "  publish: $(basename "$src") already present ($src_sha)"
        else
            cp -f "$src" "$dest"
            echo "  publish: replaced $(basename "$src") ($src_sha)"
        fi
    else
        cp -f "$src" "$dest"
        echo "  publish: copied $(basename "$src") ($src_sha)"
    fi

    # This mirror is a release input, not an archive. Keeping r251 beside r253
    # lets stale local packages remain silently ship-able and bloats the ISO.
    while IFS= read -r -d '' old; do
        [ "$old" = "$dest" ] && continue
        if [ "$(dpkg-deb -f "$old" Package 2>/dev/null || true)" = "$pkg" ] \
           && [ "$(dpkg-deb -f "$old" Architecture 2>/dev/null || true)" = "$arch" ]; then
            rm -f "$old"
            echo "  publish: removed superseded $pkg/$arch deb: $(basename "$old")"
        fi
    done < <(find "$VENDOR/pool/main" -type f -name "${pkg}_*.deb" -print0)
}

if compgen -G "$KERNEL_DEBS/*.deb" >/dev/null; then
    echo "== publishing kernel debs from $KERNEL_DEBS =="
    for deb in "$KERNEL_DEBS"/*.deb; do
        publish_deb "$deb"
    done
else
    echo "WARN: no kernel debs found in $KERNEL_DEBS; vendor mirror will only reindex existing pool" >&2
fi

if compgen -G "$SINTY_DEBS/ncz-singularity-desktop_*.deb" >/dev/null; then
    echo "== publishing Singularity desktop debs from $SINTY_DEBS =="
    for deb in "$SINTY_DEBS"/ncz-singularity-desktop_*.deb; do
        publish_deb "$deb"
    done
fi

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
