#!/usr/bin/env bash
# Stage split NCZ-OS images in a new release directory.
set -euo pipefail
export LC_ALL=C

die() { echo "ERROR: $*" >&2; exit 2; }
usage() {
  cat <<'HELP'
Usage: stage-release.sh --out DIR [--dry-run|--apply] [--require-all|--allow-partial] [--level 1..19] [--part-size-mib N]
       [--amd64-desktop FILE.img] [--amd64-server FILE.img]
       [--arm64-desktop FILE.img] [--arm64-server FILE.img]
Dry-run is the default. Use --apply to stage. Supply all four images
unless using --allow-partial.
Each image needs a matching <image>.sha256 sidecar.
Defaults are zstd level 10 and 1900 MiB parts.
DIR must be new. A valid NCZ-OS input name supplies the date and build;
other names use the UTC staging date and the first 12 image hash digits.
HELP
}
out='' level=10 part_mib=1900 apply=0 require_all=1
keys=(amd64-desktop amd64-server arm64-desktop arm64-server)
declare -A inputs=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --apply) apply=1; shift ;;
    --dry-run) apply=0; shift ;;
    --require-all) require_all=1; shift ;;
    --allow-partial) require_all=0; shift ;;
    --out|--level|--part-size-mib|--amd64-desktop|--amd64-server|--arm64-desktop|--arm64-server)
      [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 needs a value"
      case "$1" in
        --out) out=$2 ;;
        --level) level=$2 ;;
        --part-size-mib) part_mib=$2 ;;
        *) key=${1#--}; [ -z "${inputs[$key]:-}" ] || die "duplicate option $1"; inputs[$key]=$2 ;;
      esac
      shift 2 ;;
    *) die "unknown option $1" ;;
  esac
done
[ -n "$out" ] || die "supply --out (see --help)"
[[ $level =~ ^([1-9]|1[0-9])$ ]] || die "--level must be 1 to 19"
[[ $part_mib =~ ^[1-9][0-9]{0,3}$ ]] && [ "$part_mib" -lt 2048 ] || die "--part-size-mib must be 1 to 2047"
missing=()
for key in "${keys[@]}"; do
  [ -n "${inputs[$key]:-}" ] || missing+=("$key")
done
if [ "$require_all" -eq 1 ] && [ "${#missing[@]}" -ne 0 ]; then
  die "missing required images: ${missing[*]}"
fi
[ "${#missing[@]}" -lt "${#keys[@]}" ] || die "supply at least one image"
out=${out%/}
[ -n "$out" ] && [ ! -e "$out" ] && [ ! -L "$out" ] || die "cannot create a new output directory: $out"

sha() {
  local result
  result=$(sha256sum < "$1") || return
  printf '%s' "${result%% *}"
}

declare -A hashes=() names=()
for key in "${keys[@]}"; do
  src=${inputs[$key]:-}
  [ -n "$src" ] || continue
  arch=${key%-*}
  flavor=${key#*-}
  [[ $src == *.img && -f $src && -r $src ]] || die "expected a readable .img file for $key: $src"
  sidecar=$src.sha256
  [ -f "$sidecar" ] && [ -r "$sidecar" ] || die "missing or unreadable sidecar for $key: $sidecar"
  expected=$(awk 'NR == 1 {print $1; exit}' "$sidecar") || die "cannot read sidecar: $sidecar"
  [[ $expected =~ ^[0-9a-fA-F]{64}$ ]] || die "invalid sha256 in $sidecar"
  raw_sha=$(sha "$src") || die "cannot hash $src"
  [ "$raw_sha" = "${expected,,}" ] || die "sha256 mismatch for $key: $src"
  hashes[$key]=$raw_sha
  base=${src##*/}
  if [[ $base =~ ^ncz-os-(amd64|arm64)-([0-9]{8})-([0-9a-f]{6,40})(-(desktop|server))?\.img$ ]]; then
    [ "${BASH_REMATCH[1]}" = "$arch" ] || die "$base does not match $arch"
    [ -z "${BASH_REMATCH[5]}" ] || [ "${BASH_REMATCH[5]}" = "$flavor" ] || die "$base does not match $flavor"
    stamp=${BASH_REMATCH[2]}
    build=${BASH_REMATCH[3]}
  else
    stamp=$(date -u +%Y%m%d)
    build=${raw_sha:0:12}
  fi
  img=ncz-os-$arch-$stamp-$build-$flavor.img
  names[$key]=$img
done

if [ "$apply" -eq 0 ]; then
  for key in "${keys[@]}"; do
    [ -n "${names[$key]:-}" ] || continue
    arch=${key%-*}
    printf 'Would stage %s/%s/%s.zst.part-NN (level %s, %s MiB parts), PARTS-%s.sha256, SHA256SUMS-%s and SHA256SUMS-%s\n' \
      "$out" "$arch" "${names[$key]}" "$level" "$part_mib" "$key" "$key" "$arch"
    printf 'Verified sha256 %s  %s\n' "${hashes[$key]}" "${inputs[$key]}"
  done
  printf 'Would write %s/SHA256SUMS and %s/ncz-join-image.sh\n' "$out" "$out"
  exit 0
fi

command -v zstd >/dev/null || die "zstd is required"
here=$(dirname -- "${BASH_SOURCE[0]}")
mkdir -- "$out" || die "cannot create a new output directory: $out"
trap 'rm -rf -- "$out"' EXIT
trap 'exit 1' HUP INT TERM

: > "$out/SHA256SUMS"
count=0
for arch in amd64 arm64; do
  for flavor in desktop server; do
    key=$arch-$flavor
    src=${inputs[$key]:-}
    [ -n "$src" ] || continue
    raw_sha=${hashes[$key]}
    img=${names[$key]}
    dest=$out/$arch
    if [ ! -d "$dest" ]; then
      mkdir -- "$dest"
      : > "$dest/SHA256SUMS-$arch"
    fi
    zstd -q -T0 "-$level" -c -- "$src" > "$dest/$img.zst"
    compressed_sha=$(sha "$dest/$img.zst")
    bytes=$(wc -c < "$dest/$img.zst")
    part_bytes=$((part_mib * 1024 * 1024))
    last=$(((bytes - 1) / part_bytes))
    digits=${#last}
    [ "$digits" -ge 2 ] || digits=2
    split -b "$part_bytes" -d -a "$digits" -- "$dest/$img.zst" "$dest/$img.zst.part-"
    rm -- "$dest/$img.zst"
    (
      cd "$dest"
      sha256sum -- "$img.zst.part-"* > "PARTS-$key.sha256"
      printf '%s  %s\n' "$raw_sha" "$img" "$compressed_sha" "$img.zst" > "SHA256SUMS-$key"
      cat "SHA256SUMS-$key" >> "SHA256SUMS-$arch"
    )
    printf '%s  %s part(s)  %s\n' "$img" "$((last + 1))" "$raw_sha"
    count=$((count + 1))
  done
  [ ! -d "$out/$arch" ] || cat "$out/$arch/SHA256SUMS-$arch" >> "$out/SHA256SUMS"
done
cp -- "$here/ncz-join-image.sh" "$out/ncz-join-image.sh"
trap - EXIT HUP INT TERM
printf 'Staged %s image(s) in %s\n' "$count" "$out"
