#!/bin/bash
# test-singularity-depends-floors.sh -- build/build-singularity-deb.sh applies the
# version floors in build/singularity-depends-floors.tsv to the derived Depends.
#
# Why (2026-10-13): Preview 1 arm64 installs kept libgtk4-layer-shell0
# 1.3.0-1+ncz20260925 (no patch 0002) after `apt upgrade`, because the payload's
# derived Depends only asked for libgtk4-layer-shell0 (>= 1.0.2) -- dpkg-shlibdeps
# cannot express a runtime fix that changed no symbols.
#
#   1. arm64: the derived "(>= 1.0.2)" entry becomes "(>= 1.3.0-1+ncz20261013)"
#   2. amd64: the same Depends is left unchanged (the floor row is arm64 only)
#   3. a derived floor that is already higher is kept
#   4. a floored package the derived Depends lacks is added
#   5. an alternative group naming the package is left alone
#   6. negative control: an empty floors file leaves arm64 at (>= 1.0.2)
#   7. the committed floors file carries the arm64 libgtk4-layer-shell0 row
# Hermetic: fixture payload + matching Depends sidecar, no container, no network.
# Usage: build/test-singularity-depends-floors.sh
set -uo pipefail
export NCZ_PUBLISHED_INDEX="${NCZ_PUBLISHED_INDEX:-/dev/null}"
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
for t in dpkg dpkg-deb tar sha256sum; do command -v "$t" >/dev/null 2>&1 || { echo "SKIP: $t not available"; exit 77; }; done
T="$(mktemp -d "${TMPDIR:-/tmp}/test-sing-floors.XXXXXX")"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }

mkdir -p "$T/p/opt/singularity/bin"
for b in singularity-desktop singularity-labwc-session; do printf '#!/bin/sh\nexit 0\n' > "$T/p/opt/singularity/bin/$b"; chmod 0755 "$T/p/opt/singularity/bin/$b"; done
tar -C "$T/p" -czf "$T/singularity-opt.tgz" opt
SHA="$(sha256sum "$T/singularity-opt.tgz" | cut -d' ' -f1)"

build() {  # arch depends [floors-file] -> control Depends on stdout
    local arch="$1" deps="$2" floors="${3:-$HERE/singularity-depends-floors.tsv}" out="$T/out.$RANDOM"
    mkdir -p "$out"
    printf 'X-Payload-SHA256: %s\nX-Architecture: %s\nX-Suite: forky\nDepends: %s\n' "$SHA" "$arch" "$deps" > "$T/dep.$arch"
    NCZ_SINGULARITY_ARCH="$arch" NCZ_SINGULARITY_DEPENDS_FILE="$T/dep.$arch" NCZ_SINGULARITY_DEPENDS_CONTAINER=0 \
        NCZ_SINGULARITY_DEPENDS_FLOORS="$floors" NCZ_SINGULARITY_BUILD_TS=20261013000000 OUT="$out" \
        bash "$HERE/build-singularity-deb.sh" "$T/singularity-opt.tgz" > "$T/build.log" 2>&1 || { cat "$T/build.log" >&2; return 1; }
    dpkg-deb -f "$out"/*.deb Depends
}
BASE='libc6 (>= 2.43), libgtk-4-1 (>= 4.20), libgtk4-layer-shell0 (>= 1.0.2), libwayland-client0 (>= 1.20.0)'
FLOOR='libgtk4-layer-shell0 (>= 1.3.0-1+ncz20261013)'

d="$(build arm64 "$BASE")" || bad "arm64 build failed" "$(cat "$T/build.log")"
case ", $d," in *", $FLOOR,"*) ok "arm64: $FLOOR" ;; *) bad "arm64 Depends lacks the floor" "$d" ;; esac
case "$d" in *'(>= 1.0.2)'*) bad "arm64 still carries (>= 1.0.2)" "$d" ;; *) ok "arm64: the derived (>= 1.0.2) is replaced" ;; esac
[ "$(printf '%s\n' "$d" | tr ',' '\n' | grep -c 'libgtk4-layer-shell0')" = 1 ] && ok "arm64: exactly one libgtk4-layer-shell0 entry" || bad "duplicate entries" "$d"
case "$d" in "libc6 (>= 2.43), libgtk-4-1 (>= 4.20), $FLOOR, libwayland-client0 (>= 1.20.0)") ok "arm64: other entries and order unchanged" ;; *) bad "arm64: other entries changed" "$d" ;; esac
grep -q 'Depends floor (arm64): libgtk4-layer-shell0' "$T/build.log" && ok "arm64: the build log names the floor" || bad "no floor line in the build log"

d="$(build amd64 "$BASE")" || bad "amd64 build failed" "$(cat "$T/build.log")"
[ "$d" = "$BASE" ] && ok "amd64: Depends unchanged" || bad "amd64 Depends changed" "$d"

d="$(build arm64 'libc6, libgtk4-layer-shell0 (>= 1.4.0-1)')" || bad "higher-floor build failed"
[ "$d" = 'libc6, libgtk4-layer-shell0 (>= 1.4.0-1)' ] && ok "a higher derived floor is kept" || bad "higher derived floor lowered" "$d"

d="$(build arm64 'libc6, libgtk-4-1')" || bad "missing-entry build failed"
[ "$d" = "libc6, libgtk-4-1, $FLOOR" ] && ok "an absent package is added with its floor" || bad "absent package not added" "$d"

d="$(build arm64 'libc6, libgtk4-layer-shell0 | libfoo, libgtk-4-1')" || bad "alternative build failed"
case "$d" in "libc6, libgtk4-layer-shell0 | libfoo, libgtk-4-1, $FLOOR") ok "an alternative group is left alone (floor added separately)" ;; *) bad "alternative group handling" "$d" ;; esac

printf '# empty\n' > "$T/nofloors.tsv"
d="$(build arm64 "$BASE" "$T/nofloors.tsv")" || bad "negative-control build failed"
[ "$d" = "$BASE" ] && ok "negative control: without the floor row arm64 keeps (>= 1.0.2) (the Preview 1 gap)" || bad "negative control changed Depends" "$d"

printf 'arm64\tlibgtk4-layer-shell0\tnot a version!\twhy\n' > "$T/badfloors.tsv"
build arm64 "$BASE" "$T/badfloors.tsv" >/dev/null 2>&1 && bad "a malformed floor version was accepted" || ok "a malformed floor version fails the build"

awk -F'\t' '$1=="arm64" && $2=="libgtk4-layer-shell0" && $3=="1.3.0-1+ncz20261013"' "$HERE/singularity-depends-floors.tsv" | grep -q . \
    && ok "committed floors file: arm64 libgtk4-layer-shell0 >= 1.3.0-1+ncz20261013" || bad "committed floors file lacks the arm64 row"
awk -F'\t' '$2=="libgtk4-layer-shell0" && $1!="arm64"' "$HERE/singularity-depends-floors.tsv" | grep -q . \
    && bad "libgtk4-layer-shell0 floor must stay arm64 only (amd64 ships Debian's build)" || ok "the libgtk4-layer-shell0 floor is arm64 only"

echo "test-singularity-depends-floors: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
