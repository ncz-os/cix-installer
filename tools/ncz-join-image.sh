#!/bin/sh
# ncz-join-image.sh - join, unpack and verify an NCZ-OS Preview image.
#
# Usage: sh ncz-join-image.sh [arch] [flavor]
# Download the parts, PARTS-<arch>-<flavor>.sha256 and
# SHA256SUMS-<arch>-<flavor> into one folder. Legacy checksum names work too.
# A single architecture or flavor is selected automatically.
# The script verifies and unpacks the image into a local file.
#
# Options:  -d DIR   folder with the files (default: current folder)
#           -f       overwrite an existing regular .img file
#           -k       accepted for compatibility; parts are always kept
set -eu

dir=.; force=0; arch=""; flavor=""
while [ $# -gt 0 ]; do
  case "$1" in
    -d) dir=${2:?-d needs a folder}; shift 2 ;;
    -f) force=1; shift ;;
    -k) shift ;;
    arm64|amd64) [ -z "$arch" ] || { echo "name one architecture" >&2; exit 2; }; arch=$1; shift ;;
    desktop|server) [ -z "$flavor" ] || { echo "name one flavor" >&2; exit 2; }; flavor=$1; shift ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1 (try -h)" >&2; exit 2 ;;
  esac
done
cd "$dir"

die() { echo "ERROR: $*" >&2; exit 1; }
if command -v sha256sum >/dev/null 2>&1; then hash() { sha256sum | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then hash() { shasum -a 256 | cut -d' ' -f1; }
else die "need sha256sum or shasum"; fi
sha() { hash < "$1"; }
command -v zstd >/dev/null 2>&1 || die "zstd is required (Debian/Ubuntu: apt install zstd; macOS: brew install zstd; Fedora: dnf install zstd)"

# A flavor can also narrow architecture detection when it is supplied alone.
if [ -z "$arch" ]; then
  set --
  for a in amd64 arm64; do
    for p in ncz-os-"$a"-*"${flavor:+-$flavor}".img.zst.part-*; do
      [ -f "$p" ] || continue
      set -- "$@" "$a"
      break
    done
  done
  [ $# -ge 1 ] || die "no matching image parts found in $(pwd)"
  [ $# -eq 1 ] || die "architectures found: $*; name one (sh $0 <arch> [flavor])"
  arch=$1
fi

if [ -z "$flavor" ]; then
  set --
  for f in desktop server; do
    for p in ncz-os-"$arch"-*-"$f".img.zst.part-*; do
      [ -f "$p" ] || continue
      set -- "$@" "$f"
      break
    done
  done
  [ $# -le 1 ] || die "flavors found for $arch: $*; name one (sh $0 $arch <flavor>)"
  flavor=${1:-}
fi

key=$arch${flavor:+-$flavor}
parts=PARTS-$key.sha256
sums=SHA256SUMS-$key
if [ -z "$flavor" ]; then
  [ -f "$parts" ] || parts=PARTS.sha256
  [ -f "$sums" ] || sums=SHA256SUMS
fi
[ -f "$parts" ] || die "PARTS-$key.sha256 not found in $(pwd)"
[ -f "$sums" ] || die "SHA256SUMS-$key not found in $(pwd)"

expected=$(awk -v a="ncz-os-$arch-" '{ n=$2; sub(/^\*/, "", n); if (index(n,a)==1) print n }' "$parts" | LC_ALL=C sort)
[ -n "$expected" ] || die "$parts has no entries for $key"
img=$(printf '%s\n' "$expected" | sed -n '1s/\.zst\.part-[0-9][0-9]*$//p')
case "$img" in
  ncz-os-"$arch"-*"${flavor:+-$flavor}".img) ;;
  *) die "invalid image name in $parts" ;;
esac
case "$img" in */*) die "invalid image path in $parts" ;; esac
echo "Architecture: $arch   Image: $img"
set -f

# 1. every expected part must be present and match its checksum
n=0; bad=0
for p in $expected; do
  case "$p" in "$img".zst.part-*) ;; *) die "unexpected part name: $p" ;; esac
  case "${p##*.part-}" in ''|*[!0-9]*) die "invalid part number: $p" ;; esac
  n=$((n+1))
  if [ ! -f "$p" ]; then echo "  MISSING  $p"; bad=1; continue; fi
  want=$(awk -v f="$p" '$2==f || $2=="*" f {print $1}' "$parts")
  got=$(sha "$p")
  if [ "$want" = "$got" ]; then echo "  ok       $p"; else echo "  BAD      $p (checksum mismatch - download it again)"; bad=1; fi
done
[ "$bad" -eq 0 ] || die "$n part(s) expected; fix the problems above and run again"

# Verify the compressed stream where its checksum is available.
set --; for p in $expected; do set -- "$@" "$p"; done
want=$(awk -v f="$img.zst" '$2==f || $2=="*" f {print $1}' "$sums")
if [ -n "$flavor" ] || [ -n "$want" ]; then
  [ -n "$want" ] || die "$sums has no entry for $img.zst"
  got=$(cat "$@" | hash)
  [ "$want" = "$got" ] || die "compressed image checksum mismatch (expected $want, got $got)"
fi

# Unpack to a new regular file and verify it before installing it.
if [ -e "$img" ] || [ -L "$img" ]; then
  [ -f "$img" ] && [ ! -L "$img" ] || die "$img is not a regular file"
  [ "$force" -eq 1 ] || die "$img already exists (use -f to overwrite)"
fi
want=$(awk -v f="$img" '$2==f || $2=="*" f {print $1}' "$sums")
[ -n "$want" ] || die "$sums has no entry for $img"
scratch=$(mktemp -d "./.ncz-join.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
trap 'exit 1' HUP INT TERM
echo "Joining and unpacking..."
cat "$@" | zstd -d -q -c > "$scratch/$img" || die "unpack failed"
got=$(sha "$scratch/$img")
[ "$want" = "$got" ] || die "image checksum mismatch (expected $want, got $got)"
if [ "$force" -eq 1 ]; then mv -f "$scratch/$img" "$img"
else ln "$scratch/$img" "$img" || die "$img already exists"; fi
echo
echo "OK: $img verified ($got)"
echo "Next: write it to a drive of at least 16 GB. This ERASES the drive, so double-check the device name."
echo "  Linux example:  sudo dd if=$img of=/dev/DISK bs=4M status=progress conv=fsync"
echo "  Any OS:         balenaEtcher or Raspberry Pi Imager (\"Use custom\")"
