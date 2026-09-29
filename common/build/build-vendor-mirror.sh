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
# 2026-09-15: was hardcoded "arm64" -- an AMD64 build's own vendor-mirror
# index got published as (forky/arm64), so build-forky-mirror.sh's
# [arch=amd64] apt source never resolved anything from it (e.g. Chrome).
ARCH="${ARCH:-${NCZ_TARGET_ARCH:-$(dpkg --print-architecture)}}"
VENDOR="${VENDOR_MIRROR:-$REPO/build/$SUITE-vendor-mirror}"
BINDIR="dists/$SUITE/main/binary-$ARCH"
KERNEL_DEBS="${KERNEL_DEBS:-$REPO/build/kernel-debs}"
SINTY_DEBS="${SINTY_DEBS:-$REPO/assets/cix-debs}"
USB_RECOVERY_DEBS="${USB_RECOVERY_DEBS:-$REPO/build/usb-recovery-deb}"

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

if compgen -G "$USB_RECOVERY_DEBS/ncz-usb-recovery_*.deb" >/dev/null; then
    echo "== publishing USB recovery debs from $USB_RECOVERY_DEBS =="
    for deb in "$USB_RECOVERY_DEBS"/ncz-usb-recovery_*.deb; do
        publish_deb "$deb"
    done
elif [ "$ARCH" = arm64 ] && compgen -G "$KERNEL_DEBS/cixmini-boot_*.deb" >/dev/null; then
    echo "ERROR: cixmini-boot requires ncz-usb-recovery, but no package exists in $USB_RECOVERY_DEBS" >&2
    echo "       run: build/build-usb-recovery-deb.sh" >&2
    exit 1
fi

if compgen -G "$SINTY_DEBS/ncz-singularity-desktop_*.deb" >/dev/null; then
    echo "== publishing Singularity desktop debs from $SINTY_DEBS =="
    for deb in "$SINTY_DEBS"/ncz-singularity-desktop_*.deb; do
        publish_deb "$deb"
    done
fi

# Google Chrome (2026-09-15): this script's own header has documented since
# it was written that the vendor mirror carries "Google's signed Chrome
# build" alongside the kernel/singularity-desktop debs -- but the actual
# fetch-and-publish logic for it was never present. post-install/53-chrome.sh
# expects google-chrome-stable to already be apt-installed by 20-desktop.sh
# from this mirror, and hard-FATALs when it is not: confirmed live on O6N,
# "google-chrome-stable is absent from a desktop/browser-enabled install".
# Fetch is live (not staged/cached), same posture as the kernel-debs/
# singularity-desktop publish steps above: always the CURRENT stable release,
# checksum-verified against Google's own signed Packages index (not merely
# TLS transport trust) before it ever reaches the pool.
#
# 2026-09-25 AMD64 fix: this block was accidentally placed inside the
# SINTY_DEBS conditional above. AMD64 deliberately has no locally-built
# ncz-singularity-desktop package yet, so its vendor-mirror run skipped the
# entire Chrome fetch without saying so and published an index with no Chrome.
# Chrome is an independent release input: fetch it independently and fail the
# mirror build rather than allowing a browser-enabled ISO to be assembled with
# a known-incomplete pool.
CHROME_DEB_CACHE="${CHROME_DEB_CACHE:-$REPO/build/chrome-deb-cache}"
GOOGLE_CHROME_URL="${GOOGLE_CHROME_URL:-https://dl.google.com/linux/chrome/deb}"
if [ "$ARCH" = "arm64" ] || [ "$ARCH" = "amd64" ]; then
    echo "== publishing Google Chrome stable ($ARCH) =="
    mkdir -p "$CHROME_DEB_CACHE"
    if ! _chrome_pkgs="$(curl -fsSL -m 60 "$GOOGLE_CHROME_URL/dists/stable/main/binary-$ARCH/Packages")" \
       || [ -z "$_chrome_pkgs" ]; then
        echo "  ERROR: could not fetch Google's $ARCH Packages index; refusing an incomplete vendor mirror" >&2
        exit 1
    else
        _chrome_entry="$(printf '%s\n' "$_chrome_pkgs" | awk '/^Package: google-chrome-stable$/{f=1} f{print} f&&/^$/{exit}')"
        _chrome_file="$(printf '%s\n' "$_chrome_entry" | sed -n 's/^Filename: //p')"
        _chrome_sha="$(printf '%s\n' "$_chrome_entry" | sed -n 's/^SHA256: //p')"
        if [ -z "$_chrome_file" ] || [ -z "$_chrome_sha" ]; then
            echo "  ERROR: google-chrome-stable/$ARCH is absent or incomplete in Google's Packages index" >&2
            exit 1
        else
            _chrome_deb="$CHROME_DEB_CACHE/$(basename "$_chrome_file")"
            if [ -f "$_chrome_deb" ] && [ "$(sha256sum "$_chrome_deb" | awk '{print $1}')" = "$_chrome_sha" ]; then
                echo "  cached: $(basename "$_chrome_deb") already verified"
            else
                echo "  fetching $(basename "$_chrome_file") ..."
                if curl -fsSL -m 300 "$GOOGLE_CHROME_URL/$_chrome_file" -o "$_chrome_deb.part" \
                   && [ "$(sha256sum "$_chrome_deb.part" | awk '{print $1}')" = "$_chrome_sha" ]; then
                    mv -f "$_chrome_deb.part" "$_chrome_deb"
                else
                    echo "  ERROR: download or SHA256 mismatch for $_chrome_file -- refusing to publish" >&2
                    rm -f "$_chrome_deb.part"
                    exit 1
                fi
            fi
            publish_deb "$_chrome_deb"
        fi
    fi
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
