#!/bin/bash
# rebuild-sid-udeb.sh -- rebuild a small-gap (Class B) installer udeb as an NCZ
# udeb, from source, in a clean forky container.
#
# Operator ruling (2026-10-10): a sid component with a SMALL forky gap should be
# rebuilt by us (an NCZ udeb) rather than carried as a sid exception.  This is
# the recipe: fetch the needed source version from the pinned snapshot's sid
# archive, build it inside a clean forky container (amd64 on HYDRA/ACHILLES,
# arm64 on ULTRA), apply an NCZ revision suffix, and emit a reproducible udeb.
#
# The result is recorded in manifests/ncz-packages.tsv (NCZ ledger origin) and
# its manifests/sid-exceptions.tsv row is REMOVED -- the image then carries an
# NCZ-ledgered udeb instead of a sid exception.  Only ABI-decoupled udebs may be
# rebuilt this way (pure d-i component/perl udebs); a shared-library udeb
# (libc6-udeb, libmount1-udeb, ...) must be rebuilt as part of a CONSISTENT
# closure with the installer initrd that unpacks it -- never mixed blindly
# (anna loads pool udebs against the unpacked initrd).  This script refuses the
# library-udeb names it knows to be ABI-coupled unless --force-closure is given.
#
# Usage:
#   build/rebuild-sid-udeb.sh --package nobootloader --version 1.75 \
#       --arch amd64 --snapshot 20261005T120000Z --out <dir> [--work <dir>]
#                               [--ncz-rev 1] [--suite sid] [--force-closure]
# Exit 0 on a built udeb, 2 usage, 3 build failure.

set -uo pipefail
# Normalise modes like every other deb/udeb builder (docs/APT-SEPARATION.md):
# a group-writable umask would change the udeb's content identity.
umask 022
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PKG=""; VER=""; ARCH=""; SNAP=""; OUT=""; WORK=""; NCZ_REV="1"; SUITE="sid"
FORCE_CLOSURE=0
CONTAINER="${NCZ_REBUILD_CONTAINER:-debian:forky}"
while [ $# -gt 0 ]; do
    case "$1" in
        --package) PKG="$2"; shift 2;;
        --version) VER="$2"; shift 2;;
        --arch) ARCH="$2"; shift 2;;
        --snapshot) SNAP="$2"; shift 2;;
        --out) OUT="$2"; shift 2;;
        --work) WORK="$2"; shift 2;;
        --ncz-rev) NCZ_REV="$2"; shift 2;;
        --suite) SUITE="$2"; shift 2;;
        --force-closure) FORCE_CLOSURE=1; shift;;
        *) echo "unknown arg: $1" >&2; exit 2;;
    esac
done
[ -n "$PKG" ] && [ -n "$VER" ] && [ -n "$ARCH" ] && [ -n "$SNAP" ] && [ -n "$OUT" ] \
    || { echo "usage: $0 --package P --version V --arch A --snapshot S --out DIR" >&2; exit 2; }

# ABI-coupled udebs: rebuilding one member in isolation is unsafe.
case "$PKG" in
    libc6-udeb|libblkid1-udeb|libmount1-udeb|libfdisk1-udeb|libuuid1-udeb|libsmartcols1-udeb|libpcre2-8-0-udeb|libasound2-udeb|libdbus-1-3-udeb|util-linux-udeb|fdisk-udeb|eject-udeb|dbus-udeb|grub-mount-udeb)
        if [ "$FORCE_CLOSURE" -ne 1 ]; then
            echo "refusing to rebuild ABI-coupled udeb '$PKG' in isolation;" >&2
            echo "rebuild the consistent closure (initrd libs + pool udebs) instead," >&2
            echo "or pass --force-closure after reviewing the closure (docs/FORKY-PROVENANCE.md)." >&2
            exit 2
        fi;;
esac

WORK="${WORK:-$(mktemp -d "${TMPDIR:-$HOME}/.ncz-rebuild.XXXXXX")}"
mkdir -p "$WORK" "$OUT"
SRC="$WORK/src"
DOCKER=docker; command -v docker >/dev/null 2>&1 || DOCKER=podman

echo "[rebuild] $PKG $VER ($ARCH) from $SUITE, container $CONTAINER, work $WORK"
set -x
"$DOCKER" run --rm -e DEBIAN_FRONTEND=noninteractive \
    -e PKG="$PKG" -e VER="$VER" -e SNAP="$SNAP" -e SUITE="$SUITE" \
    -e NCZ_REV="$NCZ_REV" \
    -v "$WORK":/work -w /work "$CONTAINER" bash -euo pipefail -c '
        umask 022
        export DEBIAN_FRONTEND=noninteractive
        # The base image may lack ca-certificates; install it from the image
        # default sources BEFORE adding the snapshot HTTPS sources.
        apt-get update -qq
        apt-get install -y -qq --no-install-recommends ca-certificates >/dev/null
        printf "deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/%s %s main\n" "$SNAP" "$SUITE" > /etc/apt/sources.list.d/sid-src.list
        printf "deb-src [check-valid-until=no] https://snapshot.debian.org/archive/debian/%s %s main\n" "$SNAP" "$SUITE" >> /etc/apt/sources.list.d/sid-src.list
        printf "deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/%s forky main\n" "$SNAP" > /etc/apt/sources.list.d/build.list
        apt-get update -qq
        apt-get install -y -qq --no-install-recommends build-essential fakeroot dpkg-dev >/dev/null
        apt-get build-dep -y -qq "$PKG" >/dev/null 2>&1 || echo "WARN: build-dep incomplete; continuing"
        # Reproducibility: pin SOURCE_DATE_EPOCH (and the changelog date) to the
        # snapshot timestamp, so two runs of this recipe produce identical bytes.
        sde=$(date -u -d "$(printf "%s" "$SNAP" | sed -E "s/^(....)(..)(..)T(..)(..)(..)Z/\1-\2-\3 \4:\5:\6/")" +%s)
        export SOURCE_DATE_EPOCH="$sde"
        CLDATE=$(date -u -R -d "@$sde")
        cd /work
        rm -rf src; mkdir src; cd src
        # Pin the EXACT source version -- never silently fall back to whatever
        # the mirror has (a different version would defeat the rebuild).
        apt-get source "$PKG=$VER"
        shopt -s nullglob
        matches=( "$PKG"-*/ )
        [ "${#matches[@]}" -eq 1 ] || { echo "FATAL: expected exactly one source dir for $PKG $VER, found ${#matches[@]}: ${matches[*]}" >&2; exit 3; }
        cd "${matches[0]}"
        base_ver=$(dpkg-parsechangelog -S Version)
        [ "$base_ver" = "$VER" ] || { echo "FATAL: fetched source version $base_ver != requested $VER" >&2; exit 3; }
        # Append the NCZ revision so the rebuilt udeb is distinguishable and
        # reviewer-visible (name <version>+ncz<N>).
        dch_ver="${base_ver}+ncz${NCZ_REV}"
        # Prepend a changelog entry (no devscripts dependency) so the rebuilt
        # udeb carries the NCZ revision and is reviewer-visible.
        { printf "%s (%s) forky; urgency=medium\n\n  * NCZ rebuild: forky-source backport of %s %s (sid-exceptions class B).\n\n -- Jason Perlow <jperlow@gmail.com>  %s\n\n" "$PKG" "$dch_ver" "$PKG" "$base_ver" "$CLDATE"; cat debian/changelog; } > debian/changelog.new
        mv debian/changelog.new debian/changelog
        MAKEFLAGS="-j$(nproc)" dpkg-buildpackage -b -uc -us -d
        cd ..
        mkdir -p /work/out
        found=0
        for f in *.udeb; do [ -e "$f" ] || continue; cp -v "$f" /work/out/; found=1; done
        [ "$found" = 1 ] || { echo "FATAL: no udeb produced for $PKG" >&2; exit 3; }
    '
rc=$?
set +x
[ "$rc" -eq 0 ] || { echo "[rebuild] FAILED ($rc)" >&2; exit 3; }
shopt -s nullglob
for f in "$WORK"/out/*.udeb; do cp -v "$f" "$OUT/"; done
shopt -u nullglob
echo "[rebuild] done: $(ls "$OUT"/*.udeb 2>/dev/null | wc -l) udeb(s) in $OUT"
