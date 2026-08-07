#!/bin/bash
# Publish NCZ media-stack packages to the apt repository.
#
# Three packages form one stack and are published together, because installing
# the browser without the driver gives a browser that silently decodes in
# software - the failure mode this whole effort exists to fix:
#
#   cix-vaapi-driver     VA-API driver (Chrome, Vivaldi, VLC, mpv)
#   ncz-ffmpeg           libavcodec with av1_v4l2m2m (Firefox, explicit callers)
#   chromium-ncz-sky1    the browser
#
# Usage: publish-apt.sh <suite> <deb> [deb ...]
set -eu

SUITE="${1:?suite, e.g. resolute}"
shift
[ $# -gt 0 ] || { echo "no .deb files given" >&2; exit 1; }

REPO="${NCZ_APT_ROOT:?set NCZ_APT_ROOT to the repository root}"
COMP="${NCZ_APT_COMPONENT:-main}"
ARCH="arm64"
POOL="$REPO/pool/$COMP"
DIST="$REPO/dists/$SUITE/$COMP/binary-$ARCH"

mkdir -p "$POOL" "$DIST"

for deb in "$@"; do
    [ -f "$deb" ] || { echo "missing: $deb" >&2; exit 1; }
    # Refuse to publish a package that dpkg itself cannot read - a truncated or
    # empty .deb has shipped from a build that exited 0 before now.
    dpkg-deb --info "$deb" >/dev/null 2>&1 || { echo "not a valid .deb: $deb" >&2; exit 1; }
    sz=$(stat -c %s "$deb")
    [ "$sz" -gt 100000 ] || { echo "suspiciously small ($sz B), refusing: $deb" >&2; exit 1; }
    cp -f "$deb" "$POOL/"
    echo "  staged $(basename "$deb") ($((sz / 1024)) KiB)"
done

cd "$REPO"
apt-ftparchive packages "pool/$COMP" > "$DIST/Packages"
gzip -9cf "$DIST/Packages" > "$DIST/Packages.gz"

apt-ftparchive -o "APT::FTPArchive::Release::Origin=NCZ" \
               -o "APT::FTPArchive::Release::Label=NCZ-OS" \
               -o "APT::FTPArchive::Release::Suite=$SUITE" \
               -o "APT::FTPArchive::Release::Codename=$SUITE" \
               -o "APT::FTPArchive::Release::Architectures=$ARCH" \
               -o "APT::FTPArchive::Release::Components=$COMP" \
               release "dists/$SUITE" > "dists/$SUITE/Release"

if [ -n "${NCZ_APT_GPG_KEY:-}" ]; then
    rm -f "dists/$SUITE/Release.gpg" "dists/$SUITE/InRelease"
    gpg --batch --yes --default-key "$NCZ_APT_GPG_KEY" \
        -abs -o "dists/$SUITE/Release.gpg" "dists/$SUITE/Release"
    gpg --batch --yes --default-key "$NCZ_APT_GPG_KEY" \
        --clearsign -o "dists/$SUITE/InRelease" "dists/$SUITE/Release"
    echo "  signed with $NCZ_APT_GPG_KEY"
else
    # An unsigned repository makes every consumer disable verification, which
    # is worse than an inconvenient signing step. Say so rather than shipping
    # quietly.
    echo "  WARNING: NCZ_APT_GPG_KEY unset - repository is UNSIGNED" >&2
fi

echo "  published to $SUITE/$COMP"
