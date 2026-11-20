#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
STAGE=$ROOT/tools/stage-release.sh
T=$(mktemp -d "${TMPDIR:-$ROOT/build}/test-stage-release.XXXXXX")
trap 'rm -rf "$T"' EXIT
pass=0
ok() { printf 'ok   %s\n' "$*"; pass=$((pass+1)); }
reject() {
  local message=$1 out
  shift
  if out=$("$@" 2>&1) || ! grep -qF "$message" <<<"$out"; then
    printf 'Expected failure containing %s, got:\n%s\n' "$message" "$out" >&2
    exit 1
  fi
}

staged=$T/staged
args=()
for key in amd64-desktop amd64-server arm64-desktop arm64-server; do
  head -c 2200000 /dev/urandom > "$T/$key.img"
  printf '%s  /work/build/%s.img\n' "$(sha256sum < "$T/$key.img" | cut -d' ' -f1)" "$key" > "$T/$key.img.sha256"
  args+=("--$key" "$T/$key.img")
done
stage_reject() {
  local message=$1 rc=0 output
  shift
  output=$("$STAGE" --apply --out "$staged" "$@" 2>&1) || rc=$?
  [ "$rc" -eq 2 ] && grep -qF "$message" <<<"$output" && [ ! -e "$staged" ] || {
    printf 'Expected exit 2 without output directory. Got %s: %s\n' "$rc" "$output" >&2
    exit 1
  }
}
stage_reject 'missing required images: arm64-server' "${args[@]:0:6}"
ok "three images are refused before staging"
mv "$T/arm64-server.img.sha256" "$T/saved.sha256"
stage_reject 'missing or unreadable sidecar for arm64-server' "${args[@]}"
ok "missing sidecar exits 2 without staging"
printf '%064d  /work/build/arm64-server.img\n' 0 > "$T/arm64-server.img.sha256"
stage_reject 'sha256 mismatch for arm64-server' "${args[@]}"
ok "wrong sidecar exits 2 without staging"
mv "$T/saved.sha256" "$T/arm64-server.img.sha256"
mkdir "$T/bin"
printf '#!/bin/sh\nexit 99\n' > "$T/bin/zstd"
chmod +x "$T/bin/zstd"
plan=$(PATH="$T/bin:$PATH" "$STAGE" --out "$staged" "${args[@]}")
[ ! -e "$staged" ]
for key in amd64-desktop amd64-server arm64-desktop arm64-server; do
  grep -qF "Verified sha256 $(cut -d' ' -f1 "$T/$key.img.sha256")  $T/$key.img" <<<"$plan"
  grep -qF "PARTS-$key.sha256" <<<"$plan"
done
ok "default dry run verifies all four hashes without compressing or writing"
"$STAGE" --apply --require-all --out "$staged" --part-size-mib 1 "${args[@]}"
cmp "$staged/ncz-join-image.sh" "$ROOT/tools/ncz-join-image.sh"
ok "join script is staged"
cmp "$staged/SHA256SUMS" <(cat "$staged/amd64/SHA256SUMS-amd64" "$staged/arm64/SHA256SUMS-arm64")
ok "combined checksums are in architecture order"
flat=$T/flat
mkdir "$flat"
for arch in amd64 arm64; do
  d=$staged/$arch
  cmp "$d/SHA256SUMS-$arch" <(cat "$d/SHA256SUMS-$arch-desktop" "$d/SHA256SUMS-$arch-server")
  ok "$arch checksums are in flavor order"
  cp "$d/"* "$flat/"
done

join() { sh "$staged/ncz-join-image.sh" "$@"; }
reject 'architectures found: amd64 arm64' join -d "$flat"
ok "ambiguous architectures are listed"
reject 'flavors found for amd64: desktop server' join -d "$flat" amd64
ok "ambiguous flavors are listed"
for key in amd64-desktop amd64-server arm64-desktop arm64-server; do
  img=$(awk 'NR == 1 {print $2}' "$flat/SHA256SUMS-$key")
  mapfile -t parts < <(awk '{print $2}' "$flat/PARTS-$key.sha256")
  [ "${#parts[@]}" -eq 3 ]
  [ "$(wc -c < "$flat/${parts[0]}")" -eq 1048576 ]
  join -d "$flat" "${key%-*}" "${key#*-}" >/dev/null
  cmp "$flat/$img" "$T/$key.img"
  ok "$key joins three parts to the original image"
done

reject 'already exists' join -d "$flat" arm64 server
ok "join refuses to overwrite by default"
img=$(awk 'NR == 1 {print $2}' "$flat/SHA256SUMS-arm64-server")
rm "$flat/$img"
ln -s "$T/arm64-server.img" "$flat/$img"
reject 'is not a regular file' join -f -d "$flat" arm64 server
ok "join refuses a symlink destination"
rm "$flat/$img"
sums=$flat/SHA256SUMS-arm64-server
cp "$sums" "$T/good-sums"
sed '2s/^./x/' "$T/good-sums" > "$sums"
reject 'compressed image checksum mismatch' join -d "$flat" arm64 server
ok "join verifies the compressed image checksum"
sed '1s/^./x/' "$T/good-sums" > "$sums"
reject 'image checksum mismatch' join -d "$flat" arm64 server
[ ! -e "$flat/$img" ]
ok "join verifies the raw image before creating the output"
cp "$T/good-sums" "$sums"
printf x >> "$flat/${parts[1]}"
reject 'checksum mismatch' join -d "$flat" arm64 server
ok "join rejects a corrupted part"
reject 'cannot create a new output directory' "$STAGE" --out "$staged" "${args[@]}"
ok "staging refuses to overwrite an existing directory"

single=$T/single
input=ncz-os-arm64-20261119-abcdef12-server.img
cp "$T/arm64-server.img" "$T/$input"
cp "$T/arm64-server.img.sha256" "$T/$input.sha256"
"$STAGE" --apply --allow-partial --out "$single" --level 1 --arm64-server "$T/$input"
sh "$single/ncz-join-image.sh" -d "$single/arm64" >/dev/null
cmp "$T/$input" "$single/arm64/$input"
ok "staging preserves the build and join detects one architecture and flavor"
sh "$single/ncz-join-image.sh" -d "$single/arm64" -f server >/dev/null
ok "join detects the architecture for an explicit flavor"

echo "passed=$pass failed=0"
