#!/bin/bash
# build-wallpaper-contrib-deb.sh — package contributed wallpaper art as a .deb.
#
# The wallpapers NCZ-OS ships by default are installed by
# post-install/45-wallpaper-rotator.sh straight out of the installer assets.
# Contributed art is packaged separately instead, for two reasons:
#
#   1. Provenance. Each pack has its own author and its own copyright file, so
#      it is always clear who made a given image and under what terms. Mixing
#      contributed art into the default set loses that.
#   2. Size. Art packs are megabytes of JPEG. Keeping them installable rather
#      than baked lets a build include or omit them without touching the
#      rotator.
#
# The rotator globs /usr/share/backgrounds/ncz/ncz-wallpaper-*.jpg, so anything
# this package drops there joins the rotation automatically with no hook change.
# That glob used to be ncz-wallpaper-0*.jpg, which silently ignored anything
# numbered 10 or above -- the files installed fine and simply never appeared.
#
# Usage: build/build-wallpaper-contrib-deb.sh [pack-name]
#        default pack: brandon-perlow
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACK="${1:-brandon-perlow}"
SRC="$ROOT/assets/branding/wallpaper/contrib/$PACK"
OUT="$ROOT/build/wallpaper-debs"

[ -d "$SRC" ] || { echo "ERROR: no such pack: $SRC" >&2; exit 1; }

# Pack metadata. Add a case here when adding a pack; refusing to guess an
# author or a licence is deliberate -- this package is redistributed, and an
# invented licence line is worse than no package.
case "$PACK" in
    brandon-perlow)
        PKG="ncz-wallpapers-brandon-perlow"
        AUTHOR="Brandon Perlow"
        YEAR="2026"
        BLURB="Wallpaper artwork by Brandon Perlow"
        HOMEPAGE="https://www.artstation.com/brandonperlow"
        CREDITS="  ArtStation: https://www.artstation.com/brandonperlow
  Studio:     https://www.newparadigmstudios.com
  Instagram:  https://www.instagram.com/newparadigmstudios"
        LONG=" Seven 4K wallpapers contributed to NCZ-OS by Brandon Perlow: the
 Nimbus studies and a set of Cthulhu pieces.
 .
 Installing this package adds them to the NCZ wallpaper rotation. They are
 picked up automatically by ncz-wallpaper-rotate; no configuration is needed."
        ;;
    *)
        echo "ERROR: unknown pack '$PACK' — add its metadata to this script." >&2
        exit 1 ;;
esac

VERSION="${NCZ_WALLPAPER_PACK_VERSION:-1.0}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ART PAKS ARE COLLECTIONS.
#
# Images go in their OWN directory, /usr/share/backgrounds/ncz/<pack>/, and the
# pak ships a .collection file describing them. Dumping every contributor's work
# flat into /usr/share/backgrounds/ncz/ (what this script used to do) mixes it
# with the shipped NCZ art and makes "show me just this artist" impossible --
# the rotator cannot tell the images apart because nothing records who made what.
#
# A collection file is all the rotator needs; see post-install/45-wallpaper-rotator.sh.
ART_DIR="$WORK/usr/share/backgrounds/ncz/$PACK"
install -d "$WORK/DEBIAN" \
           "$ART_DIR" \
           "$WORK/usr/share/ncz-wallpapers/collections" \
           "$WORK/usr/share/doc/$PKG"

count=0
for f in "$SRC"/*.jpg; do
    [ -f "$f" ] || continue
    install -m 0644 "$f" "$ART_DIR/"
    count=$((count + 1))
done
[ "$count" -gt 0 ] || { echo "ERROR: no .jpg files in $SRC" >&2; exit 1; }
echo "  packaging $count image(s) from $PACK into /usr/share/backgrounds/ncz/$PACK"

cat > "$WORK/usr/share/ncz-wallpapers/collections/$PACK.collection" <<COLLECTION
[Collection]
Id=$PACK
Name=$AUTHOR
Comment=$BLURB
Artist=$AUTHOR
Homepage=$HOMEPAGE
Type=static
Dir=/usr/share/backgrounds/ncz/$PACK
COLLECTION
echo "  collection: $PACK ($AUTHOR)"

# Installed-Size is in KiB and dpkg expects it to be roughly honest.
SIZE_KB=$(du -sk "$WORK/usr" | cut -f1)

cat > "$WORK/DEBIAN/control" <<CONTROL
Package: $PKG
Version: $VERSION
Section: graphics
Priority: optional
Architecture: all
Maintainer: Jason Perlow <jperlow@gmail.com>
Homepage: $HOMEPAGE
Installed-Size: $SIZE_KB
Depends: \${misc:Depends}
Description: $BLURB
$LONG
CONTROL
sed -i 's/Depends: ${misc:Depends}//' "$WORK/DEBIAN/control"
sed -i '/^$/d;' "$WORK/DEBIAN/control"

cat > "$WORK/usr/share/doc/$PKG/copyright" <<COPYRIGHT
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: $PKG

Files: usr/share/backgrounds/ncz/$PACK/*
Copyright: $YEAR $AUTHOR
License: see below

 These images were contributed to NCZ-OS by $AUTHOR for distribution with
 the operating system.

 The artist:
$CREDITS

 Each image carries the artist's signature and those URLs rendered into the
 artwork itself. That is deliberate on the artist's part and must not be
 cropped, painted over or otherwise removed.

 LICENCE NOT YET PINNED. The author has granted permission to distribute this
 artwork as part of NCZ-OS, but a specific licence has not been recorded here.
 Anyone redistributing this package separately, or reusing the artwork outside
 NCZ-OS, should contact the author first. This notice exists so the ambiguity
 is visible rather than assumed away.
COPYRIGHT

install -d "$OUT"
DEB="$OUT/${PKG}_${VERSION}_all.deb"
dpkg-deb --build --root-owner-group "$WORK" "$DEB" >/dev/null
echo "  built: $DEB ($(du -h "$DEB" | cut -f1))"
dpkg-deb --info "$DEB" | sed 's/^/    /'
