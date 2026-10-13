#!/bin/bash
# test-mirror-libdrm-pin.sh -- BOTH arches' desktop mirrors carry exactly the pinned libdrm +ncz2 set.
#
# r201 amd64 image d90ed961 shipped libdrm-common 2.4.134-3+ncz1 (published index) and stock Debian
# libdrm2/amdgpu1/intel1/nouveau2 because the libdrm NCZ_LOCAL_DEBS rows existed for arm64 only.
#   1. row coverage: with the REAL manifests/build-inputs.tsv, every pinned libdrm runtime deb of an arch has a row
#      for that arch, and libdrm-common (arch:all, identical sha) is a row on both.
#   2. verifier: a mirror whose index has any libdrm that is not the pinned file (old revision, stock Debian,
#      same version/other bytes, unpinned name, missing file) FAILS; the pinned set passes. The first two cases
#      reproduce the d90ed961 amd64 mirror.
# LEGACY=<build-desktop-mirror.sh> evaluates the rows of another script (shows case 1 fails on d90ed961).
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$HERE/.."
BUILDER="${LEGACY:-$ROOT/build/build-desktop-mirror.sh}"
command -v dpkg-deb >/dev/null 2>&1 || { echo "SKIP: dpkg-deb not available"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }

sed -n '/^NCZ_LOCAL_DEBS="/,$p' "$BUILDER" | sed '/^printf .%s\\n. "\$NCZ_LOCAL_DEBS" | while/,$d' > "$T/rows.sh"
echo 'printf "%s\n" "$NCZ_LOCAL_DEBS"' >> "$T/rows.sh"
TSV="$ROOT/manifests/build-inputs.tsv"

# --- 1. row coverage against the real pins
for arch in amd64 arm64; do
    rows="$(REPO=/r ARCH="$arch" bash "$T/rows.sh" 2>/dev/null | awk -F'|' '$1 ~ /^libdrm/ {print $1}' | LC_ALL=C sort -u)"
    pinned="$(awk -F'\t' -v a="$arch" '$1==a && $2 ~ /^build\/libdrm-debs\// {b=$2; sub(/^.*\//,"",b); split(b,x,"_"); print x[1]}' "$TSV" | grep -v -e '-tests$' -e '-udeb$' | LC_ALL=C sort -u)"
    [ -n "$pinned" ] || { bad "$arch: no libdrm pins found in $TSV"; continue; }
    # amd64 deliberately does not carry libdrm-dev / libdrm-freedreno1 (see build-desktop-mirror.sh)
    [ "$arch" = amd64 ] && pinned="$(echo "$pinned" | grep -v -e '^libdrm-dev$' -e '^libdrm-freedreno1$')"
    miss="$(LC_ALL=C comm -23 <(echo "$pinned") <(echo "$rows"))"
    [ -z "$miss" ] && ok "$arch: every pinned libdrm runtime/dev package has a mirror row" || bad "$arch: pinned libdrm package(s) without a mirror row (taken from the published index instead)" "$miss"
    if [ "$arch" = amd64 ]; then echo "$rows" | grep >/dev/null -e '^libdrm-dev$' -e '^libdrm-freedreno1$' && bad "amd64 carries libdrm-dev/freedreno1 rows" || ok "amd64 does not carry libdrm-dev/freedreno1 (arm64-only)"; fi
    echo "$rows" | grep >/dev/null -x libdrm-common && ok "$arch: libdrm-common has a row" || bad "$arch: no libdrm-common row"
done
a="$(awk -F'\t' '$1=="amd64" && $2 ~ /libdrm-common/ {print $3}' "$TSV")"; b="$(awk -F'\t' '$1=="arm64" && $2 ~ /libdrm-common/ {print $3}' "$TSV")"
[ -n "$a" ] && [ "$a" = "$b" ] && ok "libdrm-common (arch:all) pin is identical across arches" || bad "libdrm-common pins differ across arches ($a vs $b)"

# --- 2. verifier on fixture mirrors
mkdeb() { local w="$T/w.$RANDOM"; mkdir -p "$w/DEBIAN" "$w/usr/share/x"
    printf 'Package: %s\nVersion: %s\nArchitecture: %s\nMaintainer: T <t@example.invalid>\nDescription: t\n' "$2" "$3" "$4" > "$w/DEBIAN/control"
    echo "$2 $3 ${5:-}" > "$w/usr/share/x/f"; dpkg-deb --root-owner-group -b "$w" "$1" >/dev/null 2>&1; }
V=2.4.134-3+ncz2
for arch in amd64 arm64; do
    fx="$T/fx-$arch"; mkdir -p "$fx/build/lib" "$fx/manifests" "$T/pinned-$arch"
    cp "$ROOT/release.conf" "$fx/"; cp "$ROOT"/manifests/desktop*.pkgs "$fx/manifests/"
    cp "$ROOT/build/verify-desktop-mirror-seeds.sh" "$fx/build/"; cp "$ROOT/build/lib/deb-version-gate.sh" "$fx/build/lib/"
    cp "$BUILDER" "$fx/build/build-desktop-mirror.sh"
    : > "$fx/manifests/build-inputs.tsv"
    for p in libdrm-common libdrm2 libdrm-amdgpu1 libdrm-intel1 libdrm-nouveau2; do
        ar=$arch; [ "$p" = libdrm-common ] && ar=all
        f="$T/pinned-$arch/${p}_${V}_${ar}.deb"; mkdeb "$f" "$p" "$V" "$ar"
        printf '%s\tbuild/libdrm-debs/%s\t%s\t1\tt\n' "$arch" "$(basename "$f")" "$(sha256sum "$f" | awk '{print $1}')" >> "$fx/manifests/build-inputs.tsv"
    done
done
# mkmirror <arch> <case>: Packages index + pool holding the five libdrm packages; case mutates one entry.
# cases: good | ncz1common | stock | rebuilt (same version, other bytes) | unpinned | nofile
mkmirror() {
    local arch="$1" c="$2" m="$T/m-$1-$2" p ar ver f src
    rm -rf "$m"; mkdir -p "$m/dists/forky/main/binary-$arch" "$m/pool/main"
    : > "$m/dists/forky/main/binary-$arch/Packages"
    for p in libdrm-common libdrm2 libdrm-amdgpu1 libdrm-intel1 libdrm-nouveau2; do
        ar=$arch; [ "$p" = libdrm-common ] && ar=all; ver=$V; src="$T/pinned-$arch/${p}_${V}_${ar}.deb"
        case "$c:$p" in
            ncz1common:libdrm-common) ver=2.4.134-3+ncz1; src="$T/ncz1.deb"; mkdeb "$src" "$p" "$ver" "$ar" ;;
            stock:libdrm2) ver=2.4.134-3; src="$T/stock.deb"; mkdeb "$src" "$p" "$ver" "$ar" ;;
            rebuilt:libdrm-intel1) src="$T/rebuilt.deb"; mkdeb "$src" "$p" "$ver" "$ar" other-toolchain ;;
            unpinned:libdrm-radeon1) ;;
        esac
        f="pool/main/${p}_${ver}_${ar}.deb"
        [ "$c:$p" = "nofile:libdrm2" ] || cp "$src" "$m/$f"
        printf 'Package: %s\nVersion: %s\nArchitecture: %s\nFilename: %s\n\n' "$p" "$ver" "$ar" "$f" >> "$m/dists/forky/main/binary-$arch/Packages"
    done
    [ "$c" = unpinned ] && { mkdeb "$m/pool/main/libdrm-radeon1_${V}_$arch.deb" libdrm-radeon1 "$V" "$arch"
        printf 'Package: libdrm-radeon1\nVersion: %s\nArchitecture: %s\nFilename: pool/main/libdrm-radeon1_%s_%s.deb\n\n' "$V" "$arch" "$V" "$arch" >> "$m/dists/forky/main/binary-$arch/Packages"; }
    echo "$m"
}
verify() { NCZ_TARGET_ARCH="$1" bash "$T/fx-$1/build/verify-desktop-mirror-seeds.sh" --mirror "$2" --label "fixture-$1" > "$T/v.out" 2>&1; }
# only the libdrm complaint matters here (the fixture has no desktop seeds): look for it, not for rc==0
libdrm_clean() { ! grep -q 'libdrm package' "$T/v.out"; }
for arch in amd64 arm64; do
    m="$(mkmirror "$arch" good)"; verify "$arch" "$m"
    libdrm_clean && ok "$arch: the pinned +ncz2 libdrm set raises no libdrm complaint" || bad "$arch: pinned set rejected" "$(cat "$T/v.out")"
    for c in ncz1common:"libdrm-common 2.4.134-3+ncz1" stock:"libdrm2 2.4.134-3 " rebuilt:"libdrm-intel1.*different sha256" unpinned:"libdrm-radeon1.*not a pinned" nofile:"libdrm2.*file is missing"; do
        name="${c%%:*}"; pat="${c#*:}"
        m="$(mkmirror "$arch" "$name")"; verify "$arch" "$m"; rc=$?
        [ $rc != 0 ] && grep -q "$pat" "$T/v.out" && ok "$arch: $name -> verifier FAILS and names it" || bad "$arch: $name mirror not rejected (rc=$rc)" "$(cat "$T/v.out")"
    done
done
echo "test-mirror-libdrm-pin: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
