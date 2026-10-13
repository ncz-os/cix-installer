#!/bin/sh
# ncz-join-image.sh - join, unpack and verify an NCZ-OS Preview image.
#
# Put this script, SHA256SUMS, PARTS.sha256 and the downloaded
#   ncz-os-<arch>-<date>-<sha>.img.zst.part-NN files in one folder, then run:
#   sh ncz-join-image.sh            (auto-detects the architecture if only one is present)
#   sh ncz-join-image.sh arm64      (or amd64)
# It checks every part, joins and unpacks them to ncz-os-<arch>-<date>-<sha>.img,
# and checks the finished image. It never writes to a disk device; writing the
# image to a drive is a separate step you do yourself.
#
# Options:  -d DIR   folder with the files (default: this folder / current folder)
#           -f       overwrite an existing .img
#           -k       (accepted for compatibility; parts are always kept)
set -eu

dir=.; force=0; arch=""
while [ $# -gt 0 ]; do
  case "$1" in
    -d) dir=${2:?-d needs a folder}; shift 2 ;;
    -f) force=1; shift ;;
    -k) shift ;;
    arm64|amd64) arch=$1; shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1 (try -h)" >&2; exit 2 ;;
  esac
done
cd "$dir"

die() { echo "ERROR: $*" >&2; exit 1; }
if command -v sha256sum >/dev/null 2>&1; then sha() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
else die "need sha256sum or shasum"; fi
command -v zstd >/dev/null 2>&1 || die "zstd is required (Debian/Ubuntu: apt install zstd; macOS: brew install zstd; Fedora: dnf install zstd)"
[ -f SHA256SUMS ] || die "SHA256SUMS not found in $(pwd)"
[ -f PARTS.sha256 ] || die "PARTS.sha256 not found in $(pwd)"

# pick the architecture
if [ -z "$arch" ]; then
  have=""
  for a in arm64 amd64; do
    ls ncz-os-"$a"-*.img.zst.part-* >/dev/null 2>&1 && have="$have $a"
  done
  # shellcheck disable=SC2086
  set -- $have
  [ $# -ge 1 ] || die "no ncz-os-*.img.zst.part-* files found in $(pwd)"
  [ $# -eq 1 ] || die "both architectures are present; run: sh $0 arm64   (or amd64)"
  arch=$1
fi

# expected parts for this architecture come from PARTS.sha256
expected=$(awk -v a="ncz-os-$arch-" 'index($2,a)==1 {print $2}' PARTS.sha256 | sort)
[ -n "$expected" ] || die "PARTS.sha256 has no entries for $arch"
img=$(echo "$expected" | head -1 | sed 's/\.zst\.part-[0-9]*$//')
echo "Architecture: $arch   Image: $img"

# 1. every expected part must be present and match its checksum
n=0; bad=0
for p in $expected; do
  n=$((n+1))
  if [ ! -f "$p" ]; then echo "  MISSING  $p"; bad=1; continue; fi
  want=$(awk -v f="$p" '$2==f {print $1}' PARTS.sha256)
  got=$(sha "$p")
  if [ "$want" = "$got" ]; then echo "  ok       $p"; else echo "  BAD      $p (checksum mismatch - download it again)"; bad=1; fi
done
[ "$bad" -eq 0 ] || die "$n part(s) expected; fix the problems above and run again"

# 2. do not clobber an existing image; check free space (~8 GB)
if [ -e "$img" ] && [ "$force" -ne 1 ]; then die "$img already exists (use -f to overwrite)"; fi
free_kb=$(df -Pk . | awk 'NR==2{print $4}')
[ "${free_kb:-0}" -ge 8500000 ] || die "need about 8 GB free in $(pwd)"

# 3. join + unpack in one pass
echo "Joining and unpacking (this takes a minute or two)..."
rm -f "$img.partial"
set --; for p in $expected; do set -- "$@" "$p"; done
cat "$@" | zstd -d -q -o "$img.partial" || { rm -f "$img.partial"; die "unpack failed"; }

# 4. verify the finished image
want=$(awk -v f="$img" '$2==f {print $1}' SHA256SUMS)
[ -n "$want" ] || { rm -f "$img.partial"; die "SHA256SUMS has no entry for $img"; }
got=$(sha "$img.partial")
if [ "$want" != "$got" ]; then rm -f "$img.partial"; die "image checksum mismatch (expected $want, got $got)"; fi
mv -f "$img.partial" "$img"
echo
echo "OK: $img verified ($got)"
echo "Next: write it to a drive of at least 16 GB. This ERASES the drive, so double-check the device name."
echo "  Linux example:  sudo dd if=$img of=/dev/DISK bs=4M status=progress conv=fsync"
echo "  Any OS:         balenaEtcher or Raspberry Pi Imager (\"Use custom\")"
