#!/bin/bash
# apt-release.sh -- write an apt Release file reproducibly.
#
#   . build/lib/apt-release.sh
#   ncz_apt_release OUT SUITE ARCH ORIGIN LABEL
#
# Writes OUT/dists/SUITE/Release for the indices already under
# OUT/dists/SUITE. Two things make the plain
#   apt-ftparchive release dists/S > dists/S/Release
# non-reproducible, and both are fixed here:
#   * apt-ftparchive ignores SOURCE_DATE_EPOCH and stamps the wall clock as
#     Date. The Date is passed from SOURCE_DATE_EPOCH when it is set.
#   * the redirect creates dists/S/Release before the scan, so the file lists
#     a checksum of itself (empty or half written). It is written to a temp
#     file outside dists/S and moved into place.
# Same rule as write-usb-image.py write_medium_release() for the medium copy.
# The Magnetar pool tarball (ncz-pool-<arch>.tar.gz) packs this mirror as is,
# so its sha256 pin depends on this file.

# SOURCE_DATE_EPOCH as an RFC 2822 date with English names, or nothing (rc 1)
# when it is unset or not a plain decimal epoch.
ncz_apt_release_date() {
    local sde="${SOURCE_DATE_EPOCH:-}"
    case "$sde" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#sde}" -le 12 ] || return 1
    LC_ALL=C date -u -d "@$sde" '+%a, %d %b %Y %H:%M:%S +0000'
}

ncz_apt_release() {
    local out="$1" suite="$2" arch="$3" origin="$4" label="$5" date tmp
    [ -d "$out/dists/$suite" ] || { echo "ncz_apt_release: no $out/dists/$suite" >&2; return 1; }
    local -a opts=(
        -o "APT::FTPArchive::Release::Origin=$origin"
        -o "APT::FTPArchive::Release::Label=$label"
        -o "APT::FTPArchive::Release::Suite=$suite"
        -o "APT::FTPArchive::Release::Codename=$suite"
        -o "APT::FTPArchive::Release::Components=main"
        -o "APT::FTPArchive::Release::Architectures=$arch"
    )
    if date="$(ncz_apt_release_date)"; then
        opts+=(-o "APT::FTPArchive::Release::Date=$date")
    fi
    # A stale Release must not be scanned (it would be listed, and with a stale
    # Packages beside it apt rejects the mirror with "Hash Sum mismatch").
    rm -f "$out/dists/$suite/Release"
    tmp="$(mktemp "$out/.Release.XXXXXX")" || return 1
    if ( cd "$out" && apt-ftparchive "${opts[@]}" release "dists/$suite" ) > "$tmp"; then
        chmod 0644 "$tmp" && mv -f "$tmp" "$out/dists/$suite/Release"
        return $?
    fi
    rm -f "$tmp"
    return 1
}
