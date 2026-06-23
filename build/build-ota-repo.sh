#!/bin/bash
# build-ota-repo.sh — assemble the NCZ OTA APT repo and pack it as a squashfs.
#
# Contents: the three kernel debs (cixmini-boot + linux-image-cixmini-{lts,edge})
# plus the proprietary CIX driver/runtime debs from assets/cix-debs. The result
# is a self-contained, GPG-signed APT repo (InRelease/Release.gpg signed by the
# NCZ OTA archive key) squashed into cix-repo.squashfs, ready to be wrapped in an
# OCI image and loop-mounted on device. Devices verify via signed-by, not
# trusted=yes.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"   # cix-installer/
KDEBS="$REPO/build/kernel-debs"
CIXDEBS="$REPO/assets/cix-debs"
OTA="$REPO/build/ota-repo"
SQUASH="$REPO/build/cix-repo.squashfs"

SUITE=ncz
COMP=main
ARCH=arm64
ORIGIN="NCZ"
LABEL="NCZ-OTA"
DESC="NCZ nclawzero OTA channel (kernel + CIX drivers)"

echo "== build-ota-repo =="
rm -rf "$OTA" "$SQUASH"
mkdir -p "$OTA/pool/main" "$OTA/dists/$SUITE/$COMP/binary-$ARCH"

echo "  collecting debs..."
n=0
for d in "$KDEBS"/*.deb "$CIXDEBS"/*.deb; do
    [ -f "$d" ] || continue
    # Guard: never ship the stale vendor generic kernel/headers in the OTA repo.
    # Our supported kernels are linux-image-cixmini-{lts,edge} + cixmini-boot;
    # the 6.6.10-cix-build-generic debs are vermagic-incompatible residue and
    # are already filtered out of on-target install (post-install/25-cix-proprietary.sh).
    case "$(basename "$d")" in
        linux-image-*-cix-build-generic_*.deb|linux-headers-*-cix-build-generic_*.deb)
            echo "  skip (stale vendor generic kernel): $(basename "$d")"; continue ;;
    esac
    cp -n "$d" "$OTA/pool/main/"
    n=$((n+1))
done
echo "  $n debs -> pool/main"

cd "$OTA"
echo "  generating Packages..."
apt-ftparchive packages pool/main > "dists/$SUITE/$COMP/binary-$ARCH/Packages"
gzip -9c "dists/$SUITE/$COMP/binary-$ARCH/Packages" > "dists/$SUITE/$COMP/binary-$ARCH/Packages.gz"
pkgcount=$(grep -c '^Package: ' "dists/$SUITE/$COMP/binary-$ARCH/Packages" || true)
echo "  Packages: $pkgcount entries"

echo "  generating Release..."
apt-ftparchive \
    -o "APT::FTPArchive::Release::Origin=$ORIGIN" \
    -o "APT::FTPArchive::Release::Label=$LABEL" \
    -o "APT::FTPArchive::Release::Suite=$SUITE" \
    -o "APT::FTPArchive::Release::Codename=$SUITE" \
    -o "APT::FTPArchive::Release::Components=$COMP" \
    -o "APT::FTPArchive::Release::Architectures=$ARCH" \
    -o "APT::FTPArchive::Release::Description=$DESC" \
    release "dists/$SUITE" > "dists/$SUITE/Release"

echo "  --- Release ---"
sed -n '1,12p' "dists/$SUITE/Release"

# Sign the Release with the dedicated NCZ OTA archive key so devices can verify
# via signed-by (no trusted=yes). Produces clearsigned InRelease + detached
# Release.gpg. Private key + GNUPGHOME live in build/keys/ (gitignored); the
# matching public keyring ships in assets/keys/ncz-ota-archive-keyring.gpg.
OTA_GNUPGHOME="$REPO/build/keys/gnupg"
OTA_KEYID="$(cat "$REPO/build/keys/ncz-ota-signing-keyid" 2>/dev/null || true)"
if [ -n "$OTA_KEYID" ] && [ -d "$OTA_GNUPGHOME" ]; then
    echo "  signing Release with $OTA_KEYID (InRelease + Release.gpg)..."
    rm -f "dists/$SUITE/InRelease" "dists/$SUITE/Release.gpg"
    GNUPGHOME="$OTA_GNUPGHOME" gpg --batch --yes --pinentry-mode loopback \
        --default-key "$OTA_KEYID" --digest-algo SHA256 \
        --clearsign -o "dists/$SUITE/InRelease" "dists/$SUITE/Release"
    GNUPGHOME="$OTA_GNUPGHOME" gpg --batch --yes --pinentry-mode loopback \
        --default-key "$OTA_KEYID" --digest-algo SHA256 \
        -abs -o "dists/$SUITE/Release.gpg" "dists/$SUITE/Release"
    echo "  signed: $(ls dists/$SUITE/InRelease dists/$SUITE/Release.gpg | tr '\n' ' ')"
else
    echo "  WARN: no OTA signing key in $REPO/build/keys — repo will be UNSIGNED" >&2
    echo "        (run build/gen-ota-key.sh or restore build/keys/ before shipping)" >&2
fi

echo "  packing squashfs (zstd)..."
mksquashfs "$OTA" "$SQUASH" -comp zstd -noappend -no-progress >/dev/null
ls -lh "$SQUASH"
echo "  squashfs sha256: $(sha256sum "$SQUASH" | cut -d' ' -f1)"
echo "done."
