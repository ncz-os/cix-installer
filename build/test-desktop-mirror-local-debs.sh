#!/bin/bash
# test-desktop-mirror-local-debs.sh -- an EXISTING build/desktop-mirror must not be reused when it lacks, or
# carries an older or different build of, an NCZ-OS local package.
#
# Why (r201 re-review, high): the Makefile reuses build/desktop-mirror whenever verify-desktop-mirror-seeds.sh
# passes, and that verifier only checked the desktop manifest NAMES. A host with a mirror built before the
# ncz-apt-policy row existed (all 181 desktop seeds present) passed, the mirror was reused, and
# build-forky-mirror.sh then could not resolve the install-extra seed; later pin changes never propagated.
#
# The verifier is run against fixture mirrors (a Packages index + pool) for both arches:
#   good mirror                                -> PASS
#   mirror without ncz-apt-policy              -> FAIL, names the package
#   mirror with an OLD ncz-apt-policy version  -> FAIL, shows the version it has
#   same version, DIFFERENT content (old pin)  -> FAIL (content identity)
#   an older ncz-screensavers / a missing seed -> FAIL
# VERIFIER=<path> runs the same cases against another verifier (to show the old one passes the broken mirrors).
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$HERE/.."
VERIFIER="${VERIFIER:-$ROOT/build/verify-desktop-mirror-seeds.sh}"
command -v dpkg-deb >/dev/null 2>&1 || { echo "SKIP: dpkg-deb not available"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }

mkdeb() {  # out name ver arch [extra-line-for-the-payload]
    local w="$T/w.$RANDOM"; mkdir -p "$w/DEBIAN" "$w/usr/share/x"
    printf 'Package: %s\nVersion: %s\nArchitecture: %s\nMaintainer: T <t@example.invalid>\nDescription: t\n' "$2" "$3" "$4" > "$w/DEBIAN/control"
    { echo "$2"; [ -n "${5:-}" ] && echo "$5"; } > "$w/usr/share/x/f"
    dpkg-deb --root-owner-group -b "$w" "$1" >/dev/null 2>&1
}

sed '/^printf .%s\\n. "\$NCZ_LOCAL_DEBS" | while/,$d' <(sed -n '/^NCZ_LOCAL_DEBS="/,$p' "$ROOT/build/build-desktop-mirror.sh") > "$T/rows.sh"
echo 'printf "%s\n" "$NCZ_LOCAL_DEBS"' >> "$T/rows.sh"
: > "$T/empty-index"

mkfix() {  # arch -> fixture root in $T/fx-<arch>
    local arch="$1" fx="$T/fx-$1" pkg glob req path
    rm -rf "$fx"; mkdir -p "$fx/build/lib" "$fx/manifests"
    cp "$ROOT/release.conf" "$fx/"; cp "$ROOT"/manifests/desktop*.pkgs "$fx/manifests/"
    cp "$VERIFIER" "$fx/build/verify-desktop-mirror-seeds.sh"; cp "$ROOT/build/build-desktop-mirror.sh" "$fx/build/"
    cp "$ROOT/build/lib/deb-version-gate.sh" "$fx/build/lib/"
    while IFS='|' read -r pkg glob req; do
        [ -n "$pkg" ] || continue
        path="${glob/\*/9.9.9}"
        mkdir -p "$(dirname "$path")"
        case "$pkg" in ncz-apt-policy) : ;; *) mkdeb "$path" "$pkg" 9.9.9 all ;; esac
    done < <(REPO="$fx" ARCH="$arch" bash "$T/rows.sh" 2>/dev/null)
    NCZ_PUBLISHED_INDEX="$T/empty-index" NCZ_APT_POLICY_OUT="$fx/build/ncz-apt-policy-deb" bash "$ROOT/build/build-ncz-apt-policy-deb.sh" >/dev/null 2>&1
}

# mirror <arch> <name>: Packages index with every desktop seed + every local deb; pool holds the local debs.
# $3.. = "skip:<pkg>" | "oldver:<pkg>=<ver>" | "oldpin" | "skipseed:<pkg>"
mkmirror() {
    local arch="$1" name="$2" fx="$T/fx-$1" m="$T/m-$1-$2" opt seedfile idx
    shift 2; rm -rf "$m"; idx="$m/dists/forky/main/binary-$arch/Packages"; mkdir -p "$(dirname "$idx")" "$m/pool/main"
    seedfile="$fx/manifests/desktop-$arch.pkgs"; [ -f "$seedfile" ] || seedfile="$fx/manifests/desktop.pkgs"
    sed 's/#.*//' "$seedfile" | awk 'NF{print $1}' | sort -u | while read -r s; do
        printf 'Package: %s\nVersion: 1\nArchitecture: %s\nFilename: pool/main/%s.deb\n\n' "$s" "$arch" "$s"
    done > "$idx"
    local pkg glob req deb ver base skip
    while IFS='|' read -r pkg glob req; do
        [ -n "$pkg" ] || continue
        deb="$(ls -1 $glob 2>/dev/null | sort -V | tail -1)"; [ -n "$deb" ] || continue
        ver="$(dpkg-deb -f "$deb" Version)"; base="$(basename "$deb")"; skip=0
        for opt in "$@"; do
            case "$opt" in
                skip:"$pkg") skip=1 ;;
                oldver:"$pkg"=*) ver="${opt#*=}"; base="${pkg}_${ver}_all.deb"; rm -f "$m/old.deb"
                    if [ "$pkg" = ncz-apt-policy ]; then NCZ_APT_POLICY_VERSION="$ver" NCZ_PUBLISHED_INDEX="$T/empty-index" NCZ_APT_POLICY_OUT="$m/oldbuild" bash "$ROOT/build/build-ncz-apt-policy-deb.sh" >/dev/null 2>&1; deb="$(ls "$m"/oldbuild/*.deb)"
                    else mkdeb "$m/old.deb" "$pkg" "$ver" all; deb="$m/old.deb"; fi ;;
                oldpin) if [ "$pkg" = ncz-apt-policy ]; then
                        rm -rf "$m/repack"; dpkg-deb -R "$deb" "$m/repack"; echo '# the previous pin' >> "$m/repack/usr/share/ncz-apt-policy/apt-separation.sh"
                        dpkg-deb --root-owner-group -b "$m/repack" "$m/oldpin.deb" >/dev/null 2>&1; deb="$m/oldpin.deb"; fi ;;
            esac
        done
        [ "$skip" = 1 ] && continue
        mkdir -p "$m/pool/main/${pkg:0:1}/$pkg"; cp "$deb" "$m/pool/main/${pkg:0:1}/$pkg/$base"
        printf 'Package: %s\nVersion: %s\nArchitecture: all\nFilename: pool/main/%s/%s/%s\n\n' "$pkg" "$ver" "${pkg:0:1}" "$pkg" "$base" >> "$idx"
    done < <(REPO="$fx" ARCH="$arch" bash "$T/rows.sh" 2>/dev/null)
    for opt in "$@"; do case "$opt" in skipseed:*) awk -v n="${opt#skipseed:}" 'BEGIN{RS="";ORS="\n\n"} $0 !~ "Package: " n "\n"' "$idx" > "$idx.n"; mv "$idx.n" "$idx" ;; esac; done
    echo "$m"
}

verify() {  # arch mirror -> rc ; output in $T/v.out
    NCZ_TARGET_ARCH="$1" bash "$T/fx-$1/build/verify-desktop-mirror-seeds.sh" --mirror "$2" --label "fixture-$1" > "$T/v.out" 2>&1
}

for arch in amd64 arm64; do
    echo "=== $arch ==="
    mkfix "$arch"
    ls "$T/fx-$arch/build/ncz-apt-policy-deb/"ncz-apt-policy_*_all.deb >/dev/null 2>&1 || { bad "$arch: fixture: no policy deb"; continue; }
    m="$(mkmirror "$arch" good)"; verify "$arch" "$m"; rc=$?
    [ "$rc" = 0 ] && ok "$arch: a mirror with every seed and every local package at its current build passes" || bad "$arch: good mirror failed" "$(cat "$T/v.out")"

    m="$(mkmirror "$arch" nopolicy skip:ncz-apt-policy)"; verify "$arch" "$m"; rc=$?
    [ "$rc" != 0 ] && grep -q 'ncz-apt-policy' "$T/v.out" && ok "$arch: a mirror WITHOUT ncz-apt-policy fails and names it" || bad "$arch: mirror without ncz-apt-policy passed or did not name it (rc=$rc)" "$(cat "$T/v.out")"

    m="$(mkmirror "$arch" oldver oldver:ncz-apt-policy=1.0.0)"; verify "$arch" "$m"; rc=$?
    [ "$rc" != 0 ] && grep -q 'mirror has: 1.0.0' "$T/v.out" && ok "$arch: a mirror with an OLD ncz-apt-policy version fails and shows 1.0.0" || bad "$arch: old-version mirror passed (rc=$rc)" "$(cat "$T/v.out")"

    m="$(mkmirror "$arch" oldpin oldpin)"; verify "$arch" "$m"; rc=$?
    [ "$rc" != 0 ] && grep -q 'different CONTENT' "$T/v.out" && ok "$arch: same version but an OLDER PIN fails (content identity)" || bad "$arch: old-pin mirror passed (rc=$rc)" "$(cat "$T/v.out")"

    m="$(mkmirror "$arch" oldss oldver:ncz-screensavers=0.1)"; verify "$arch" "$m"; rc=$?
    [ "$rc" != 0 ] && grep -q 'ncz-screensavers' "$T/v.out" && ok "$arch: an older ncz-screensavers (any NCZ_LOCAL_DEBS row) fails" || bad "$arch: old ncz-screensavers passed (rc=$rc)" "$(cat "$T/v.out")"

    seed="$(sed 's/#.*//' "$T/fx-$arch/manifests/desktop-$arch.pkgs" 2>/dev/null | awk 'NF{print $1}' | head -1)"; [ -n "$seed" ] || seed="$(sed 's/#.*//' "$T/fx-$arch/manifests/desktop.pkgs" | awk 'NF{print $1}' | head -1)"
    m="$(mkmirror "$arch" noseed "skipseed:$seed")"; verify "$arch" "$m"; rc=$?
    [ "$rc" != 0 ] && grep -q "$seed" "$T/v.out" && ok "$arch: a missing desktop seed still fails (existing behaviour kept)" || bad "$arch: missing seed passed (rc=$rc)" "$(cat "$T/v.out")"
done

echo "test-desktop-mirror-local-debs: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
