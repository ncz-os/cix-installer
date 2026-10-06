#!/bin/bash
# build-wallpaper-contrib-deb.sh — package wallpaper art (NCZ's own set or a
# contributed Artist Pack) as a .deb.
#
# Originally contributor-art only; the NCZ set moved in here too (2026-09-06)
# so every Artist Pack -- ours or contributed -- goes through ONE mechanism:
# a .deb with its own images plus one .collection file, staged into
# assets/wallpaper-debs/ and installed by post-install/45-wallpaper-rotator.sh
# (see build/build-squashfs-layers.sh for how that directory reaches the ISO).
# Packaging is separate from the rotator script for two reasons:
#
#   1. Provenance. Each pack has its own author and its own copyright file, so
#      it is always clear who made a given image and under what terms. Mixing
#      packs into one flat set loses that.
#   2. Size. Art packs are megabytes of JPEG. Keeping them installable rather
#      than baked lets a build include or omit them without touching the
#      rotator.
#
# Usage: build/build-wallpaper-contrib-deb.sh [pack-name]
#        default pack: cygnus-2610
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACK="${1:-cygnus-2610}"
OUT="${WALLPAPER_DEB_OUT:-$ROOT/build/wallpaper-debs}"
ARTISTPACK_SOURCE_ROOT="${ARTISTPACK_SOURCE_ROOT:-${HOME:?}/Projects/artistpack/packs}"

# Pack metadata, and where its source images and installed images live.
# Add a case here when adding a pack; refusing to guess an author or a
# licence is deliberate -- this package is redistributed, and an invented
# licence line is worse than no package.
#
# ART_DIR is where images install TO. NCZ keeps its historical flat
# /usr/share/backgrounds/ncz (post-install/55-greeter.sh and 20-desktop.sh
# both reference .../ncz/default.jpg directly) -- moving it into its own
# subdirectory, like contributed packs use, would need updating both of
# those too, for no behavioural gain. Contributed packs use their own
# subdirectory precisely so they DON'T collide with that flat NCZ set or
# with each other.
CONTRIB_ROYALTY_FREE_NOTE=" LICENCE NOT YET PINNED. The author has granted permission to distribute this
 artwork as part of NCZ-OS, but a specific licence has not been recorded here.
 Anyone redistributing this package separately, or reusing the artwork outside
 NCZ-OS, should contact the author first. This notice exists so the ambiguity
 is visible rather than assumed away."

case "$PACK" in
    ncz)
        PKG="ncz-wallpapers-ncz"
        SRC="$ROOT/assets/branding/wallpaper"
        ARTISTPACK_SRC="$ARTISTPACK_SOURCE_ROOT/ncz"
        ART_SUBPATH=""
        AUTHOR="NCZ"
        YEAR="2026"
        BLURB="The default NCZ-OS wallpaper set"
        HOMEPAGE="https://github.com/ncz-os"
        CREDITS="  NCZ-OS: https://github.com/ncz-os"
        LONG=" The cosmic wallpaper set NCZ-OS ships by default: cinematic, interstellar
 gargantua, an M87 astrophotograph, a retro sci-fi poster, magnetar jets,
 and Cygnus vacuum decay.
 .
 Installing this package adds them to the NCZ wallpaper rotation. They are
 picked up automatically by ncz-wallpaper-rotate; no configuration is needed."
        COPYRIGHT_BODY=" These images are original artwork produced for the NCZ-OS project.

 The project:
$CREDITS
"
        ;;
    cygnus-2610)
        PKG="ncz-wallpapers-cygnus-2610"
        SRC="$ROOT/assets/branding/wallpaper/contrib/$PACK"
        ARTISTPACK_SRC="$ARTISTPACK_SOURCE_ROOT/$PACK"
        ART_SUBPATH="/$PACK"
        AUTHOR="NCZ-OS Cygnus"
        YEAR="2026"
        BLURB="NCZ-OS 26.10 Cygnus wallpaper set (default)"
        HOMEPAGE="https://gitlab.com/ncz-os/cix-installer"
        CREDITS="  NCZ-OS: https://gitlab.com/ncz-os/cix-installer"
        LONG=" Twelve 4K wallpapers of the NCZ-OS 26.10 Cygnus release: the edge-on
 and reveal hero pieces plus ten black hole, merger, tidal disruption and
 white hole studies rendered around the Cygnus theme.
 .
 This is the default Artist Pack: the desktop wallpaper and the wallpaper
 rotator start from it. Installing it adds them to the NCZ wallpaper
 rotation; no configuration is needed."
        COPYRIGHT_BODY=" These images are original artwork produced for the NCZ-OS project.

 The project:
$CREDITS
"
        ;;
    brandon-perlow)
        PKG="ncz-wallpapers-brandon-perlow"
        SRC="$ROOT/assets/branding/wallpaper/contrib/$PACK"
        ARTISTPACK_SRC="$ARTISTPACK_SOURCE_ROOT/brandon-perlow"
        ART_SUBPATH="/$PACK"
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
        COPYRIGHT_BODY=" These images were contributed to NCZ-OS by $AUTHOR for distribution with
 the operating system.

 The artist:
$CREDITS

 Each image carries the artist's signature and those URLs rendered into the
 artwork itself. That is deliberate on the artist's part and must not be
 cropped, painted over or otherwise removed.

$CONTRIB_ROYALTY_FREE_NOTE"
        ;;
    alex-jay-brady)
        PKG="ncz-wallpapers-alex-jay-brady"
        SRC="$ROOT/assets/branding/wallpaper/contrib/$PACK"
        ARTISTPACK_SRC="$ARTISTPACK_SOURCE_ROOT/alex-jay-brady"
        ART_SUBPATH="/$PACK"
        AUTHOR="Alex Jay Brady"
        YEAR="2026"
        BLURB="Wallpaper artwork by Alex Jay Brady"
        HOMEPAGE="https://www.artstation.com/boac"
        CREDITS="  ArtStation: https://www.artstation.com/boac"
        LONG=" Eight 4K wallpapers contributed to NCZ-OS by Alex Jay Brady: Heavy
 hydrogen mine, two Winnebago singularity drive ship pieces, Killing the star,
 Approaching moebius world, Anti-stellar projectile gun, Destroying the braided
 ringworld, and Galaxies exiting this doomed universe.
 .
 Installing this package adds them to the NCZ wallpaper rotation. They are
 picked up automatically by ncz-wallpaper-rotate; no configuration is needed."
        COPYRIGHT_BODY=" These images were contributed to NCZ-OS by $AUTHOR for distribution with
 the operating system.

 The artist:
$CREDITS

$CONTRIB_ROYALTY_FREE_NOTE"
        ;;
    singularity)
        PKG="ncz-wallpapers-singularity"
        SRC="$ROOT/assets/branding/wallpaper/contrib/$PACK"
        ARTISTPACK_SRC="$ARTISTPACK_SOURCE_ROOT/singularity"
        ART_SUBPATH="/$PACK"
        AUTHOR="Singularity Desktop"
        YEAR="2026"
        BLURB="The default wallpaper set for the Singularity Desktop Environment"
        HOMEPAGE="https://github.com/singularityos-lab/singularity-wallpapers"
        CREDITS="  singularityos-lab/singularity-wallpapers: $HOMEPAGE"
        LONG=" The official wallpaper set shipped with upstream Singularity Desktop:
 default, epic, and prospective raster backgrounds plus the aurora, grid,
 nebula, topology, void, and waves vector backdrops. Sourced directly from
 the singularity-wallpapers repository upstream ships with the desktop.
 .
 Installing this package adds them to the NCZ wallpaper rotation. They are
 picked up automatically by ncz-wallpaper-rotate; no configuration is needed."
        COPYRIGHT_BODY=" These images are the official Singularity Desktop wallpaper set, taken
 unmodified from $HOMEPAGE (subprojects/singularity-wallpapers in the
 singularity-desktop superproject).

 The artist:
$CREDITS

 License: GNU General Public License v3.0-only (GPL-3.0-only). See the
 upstream repository's LICENSE file. Individual artwork may carry its own
 terms per that repository's own README."
        ;;
    *)
        echo "ERROR: unknown pack '$PACK' — add its metadata to this script." >&2
        exit 1 ;;
esac

# The Singularity pack is derived from the freshly built desktop payload.  A
# desktop-only layer rebuild does not populate the gitignored branding source
# directory, so consume the canonical payload directly instead of silently
# omitting the fourth shipping pack.
SRC_TMP=""
if [ "$PACK" = singularity ] && [ ! -d "$SRC" ]; then
    SINGULARITY_TGZ="$ROOT/build/sinty-out/singularity-opt.tgz"
    [ -s "$SINGULARITY_TGZ" ] || SINGULARITY_TGZ="$ROOT/assets/singularity/singularity-opt.tgz"
    if [ -s "$SINGULARITY_TGZ" ]; then
        SRC_TMP="$(mktemp -d)"
        tar -xzf "$SINGULARITY_TGZ" -C "$SRC_TMP" --strip-components=5 \
            'opt/singularity/share/backgrounds/singularity/'
        SRC="$SRC_TMP"
    fi
fi

[ -d "$SRC" ] || { echo "ERROR: no such pack: $SRC" >&2; exit 1; }
[ -f "$ARTISTPACK_SRC/artist.json" ] || { echo "ERROR: missing ArtistPack manifest: $ARTISTPACK_SRC/artist.json" >&2; exit 1; }
[ -f "$ARTISTPACK_SRC/pack.json" ] || { echo "ERROR: missing ArtistPack manifest: $ARTISTPACK_SRC/pack.json" >&2; exit 1; }

VERSION="${NCZ_WALLPAPER_PACK_VERSION:-1.0}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK" ${SRC_TMP:+"$SRC_TMP"}' EXIT

# ART PAKS ARE COLLECTIONS -- see post-install/45-wallpaper-rotator.sh.
# The .collection file goes where WallpaperCollections.default_search_roots()
# (libsingularity) scans, so the pack shows up in the Settings UI's own
# Wallpaper Source picker, not just the bash rotator.
ART_DIR="$WORK/usr/share/backgrounds/ncz$ART_SUBPATH"
COLLECTIONS_DIR="$WORK/opt/singularity/share/singularity/wallpaper-collections"
install -d "$WORK/DEBIAN" \
           "$ART_DIR" \
           "$COLLECTIONS_DIR" \
           "$WORK/usr/share/doc/$PKG"

count=0
for f in "$SRC"/*.jpg "$SRC"/*.png "$SRC"/*.svg; do
    [ -f "$f" ] || continue
    # NCZ's own source directory also holds default.jpg and the contrib/
    # subdirectory for OTHER packs -- only the ncz-wallpaper-*.jpg files
    # belong in this pack.
    case "$PACK" in
        ncz) [[ "$(basename "$f")" == ncz-wallpaper-*.jpg ]] || continue
             # 26.7 release art retired with the Cygnus rebrand.
             [[ "$(basename "$f")" == ncz-wallpaper-07-maximilian-* ]] && continue ;;
    esac
    install -m 0644 "$f" "$ART_DIR/"
    count=$((count + 1))
done
[ "$count" -gt 0 ] || { echo "ERROR: no .jpg/.png/.svg files in $SRC" >&2; exit 1; }
echo "  packaging $count image(s) from $PACK into /usr/share/backgrounds/ncz$ART_SUBPATH"

# ASPECT VARIANTS (docs/WALLPAPER-SAFE-AREA.md). A <W>x<H>/ subdirectory of the
# pack source (e.g. 16x10/) holds pre-composed variants with the SAME basenames
# as the originals. They install OUTSIDE the collection Dir, under
# /usr/share/ncz-wallpapers/aspect/<W>x<H>/<pack>/: the Singularity shell's
# rotator and gallery scan a collection Dir recursively and would otherwise
# list every image twice. The .collection file names them under [Variants];
# ncz-wallpaper-fit picks the one whose aspect ratio fits the output. A variant
# without an original, or an original missing its variant, fails the build:
# a half set would silently show the cropped 16:9 file on some images only.
VARIANT_LINES=""
for vdir in "$SRC"/*x*/; do
    [ -d "$vdir" ] || continue
    tag="$(basename "$vdir")"
    [[ "$tag" =~ ^[0-9]+x[0-9]+$ ]] || continue
    vdest="/usr/share/ncz-wallpapers/aspect/$tag/$PACK"
    install -d "$WORK$vdest"
    vcount=0
    for f in "$ART_DIR"/*.jpg "$ART_DIR"/*.png "$ART_DIR"/*.svg; do
        [ -f "$f" ] || continue
        v="$vdir$(basename "$f")"
        [ -f "$v" ] || { echo "ERROR: $tag variant missing for $(basename "$f") in $vdir" >&2; exit 1; }
        install -m 0644 "$v" "$WORK$vdest/"
        vcount=$((vcount + 1))
    done
    for v in "$vdir"*.jpg "$vdir"*.png "$vdir"*.svg; do
        [ -f "$v" ] || continue
        [ -f "$ART_DIR/$(basename "$v")" ] || { echo "ERROR: $tag variant $(basename "$v") has no original in $SRC" >&2; exit 1; }
    done
    VARIANT_LINES="$VARIANT_LINES$tag=$vdest"$'\n'
    echo "  packaging $vcount $tag variant(s) into $vdest"
done

cat > "$COLLECTIONS_DIR/$PACK.collection" <<COLLECTION
[Collection]
Id=$PACK
Name=$AUTHOR
Comment=$BLURB
Artist=$AUTHOR
Homepage=$HOMEPAGE
Type=static
Dir=/usr/share/backgrounds/ncz$ART_SUBPATH
COLLECTION
if [ -n "$VARIANT_LINES" ]; then
    printf '\n[Variants]\n%s' "$VARIANT_LINES" >> "$COLLECTIONS_DIR/$PACK.collection"
fi
echo "  collection: $PACK ($AUTHOR)"

ARTISTPACK_DIR="$COLLECTIONS_DIR/$PACK.artistpack"
install -d "$ARTISTPACK_DIR"
install -m 0644 "$ARTISTPACK_SRC/artist.json" "$ARTISTPACK_DIR/artist.json"
install -m 0644 "$ARTISTPACK_SRC/pack.json" "$ARTISTPACK_DIR/pack.json"
# The source manifest is catalog-ready and uses commit-pinned GitLab URLs.
# Its packaged copy is offline-first, so point file entries at the exact
# basenames installed in ART_DIR while leaving hashes and dimensions intact.
sed -Ei 's#("file": ")https://gitlab\.com/[^"]*/([^"/]+)(")#\1\2\3#' \
    "$ARTISTPACK_DIR/pack.json"
echo "  ArtistPack metadata: $PACK.artistpack/{artist.json,pack.json}"

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

Files: usr/share/backgrounds/ncz$ART_SUBPATH/*
Copyright: $YEAR $AUTHOR
License: see below

$COPYRIGHT_BODY
COPYRIGHT

install -d "$OUT"
DEB="$OUT/${PKG}_${VERSION}_all.deb"
dpkg-deb --build --root-owner-group "$WORK" "$DEB" >/dev/null
echo "  built: $DEB ($(du -h "$DEB" | cut -f1))"
dpkg-deb --info "$DEB" | sed 's/^/    /'
