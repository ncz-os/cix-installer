#!/bin/bash
# verify-dual-arch-parity.sh -- arm64 and amd64 must carry the same COMMON fixes.
#
#   verify-dual-arch-parity.sh                     static checks: manifests, staged package debs, hook arch lint
#   verify-dual-arch-parity.sh --facts A.txt B.txt compare the [fact] lines the shared installed-target
#                                                  verifier printed for an arm64 and an amd64 target
#
# Static checks (all must pass):
#  1. manifests: every package in one of manifests/{desktop,installer-base,rescue}.pkgs and its -amd64
#     twin but not the other must appear in build/arch-parity-allowlist.tsv (pkg, side, reason).
#  2. ncz-screensavers: the highest staged version has BOTH an arm64 and an amd64 deb, from one source
#     commit (BUILT-FROM.txt), and their SHA256SUMS verify.
#  2b. the screensaver settings plugin pin covers both arches (post-install/lib/ncz-screensavers-plugin.lock).
#  3. hook arch lint (build/lint-hook-arch-gates.sh).
# --facts: both targets must report hostname_format_ok=1, sudo_ok=1, bing_plugin_patched=1,
#  sensors_plugin_patched=1, gpu_policy_ok=1, ssh_password_ok=1, and identical screensavers_version, release_version and release_codename.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="${PARITY_ROOT:-$(cd "$HERE/.." && pwd)}"
FAIL=0
bad() { echo "PARITY FAIL: $*" >&2; FAIL=1; }

pkgs_of() { sed 's/#.*//' "$1" 2>/dev/null | awk 'NF {print $1}' | LC_ALL=C sort -u; }

if [ "${1:-}" = "--facts" ]; then
    A="${2:?arm64 facts file}"; B="${3:?amd64 facts file}"
    fact() { sed -n "s/^\[fact\] $2=//p" "$1" | tail -1; }
    for k in hostname_format_ok sudo_ok bing_plugin_patched sensors_plugin_patched gpu_policy_ok ssh_password_ok; do
        [ "$(fact "$A" $k)" = 1 ] || bad "arm64 fact $k is '$(fact "$A" $k)', expected 1"
        [ "$(fact "$B" $k)" = 1 ] || bad "amd64 fact $k is '$(fact "$B" $k)', expected 1"
    done
    for k in screensavers_version screensaver_plugin_version release_version release_codename; do
        a="$(fact "$A" $k)"; b="$(fact "$B" $k)"
        if [ -z "$a" ] || [ -z "$b" ] || [ "$a" = none ] || [ "$b" = none ]; then bad "fact $k missing (arm64='$a' amd64='$b')"
        elif [ "$a" != "$b" ]; then bad "fact $k differs: arm64=$a amd64=$b"
        else echo "parity: $k = $a on both"; fi
    done
    [ "$(fact "$A" arch)" = arm64 ] && [ "$(fact "$B" arch)" = amd64 ] || bad "fact files are not (arm64, amd64)"
    [ "$FAIL" = 0 ] && echo "parity: installed-target facts agree" || exit 1
    exit 0
fi

# 1. manifests -----------------------------------------------------------------------------------------
ALLOW="$ROOT/build/arch-parity-allowlist.tsv"
for base in desktop installer-base rescue; do
    a="$ROOT/manifests/$base.pkgs"; b="$ROOT/manifests/$base-amd64.pkgs"
    [ -f "$a" ] && [ -f "$b" ] || { bad "manifest pair missing: $base / $base-amd64"; continue; }
    while IFS= read -r line; do
        pkg="${line#[[:space:]]}"; side="arm64-only"
        case "$line" in $'\t'*) side="amd64-only"; pkg="${line#$'\t'}" ;; esac
        if ! awk -F'\t' -v m="$base" -v p="$pkg" -v s="$side" '$1==m && $2==p && $3==s {f=1} END{exit(f?0:1)}' "$ALLOW" 2>/dev/null; then
            bad "manifest $base: '$pkg' is $side and not in build/arch-parity-allowlist.tsv (add it with a reason, or add the package to the other manifest)"
        fi
    done < <(LC_ALL=C comm -3 <(pkgs_of "$a") <(pkgs_of "$b"))
done
[ "$FAIL" = 0 ] && echo "parity: manifest pairs agree modulo the allowlist"

# 2. ncz-screensavers debs ------------------------------------------------------------------------------
DEBS=""
if [ -n "${NCZ_SCREENSAVERS_DEBS+x}" ]; then   # explicitly set (tests use a nonexistent path to skip the check)
    [ -d "$NCZ_SCREENSAVERS_DEBS" ] && DEBS="$NCZ_SCREENSAVERS_DEBS"
else
    . "$HERE/lib/ncz-site.sh"
    _pr="$(ncz_site_value NCZ_SSPLUGIN_SRC_ROOT projects-dir)"
    [ -n "$_pr" ] && [ -d "$_pr/ncz-screensavers-debs" ] && DEBS="$_pr/ncz-screensavers-debs"
fi
if [ -n "$DEBS" ]; then
    V="$(ls "$DEBS" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)"
    # The image floor (build/screensavers-version.env) decides which staged version can reach an image.
    # A staging dir whose newest version is below that floor is not an image input, so parity over it
    # proves nothing: say so and skip, instead of judging today's manifests against an old package set.
    SS_FLOOR="$(sed -n 's/^NCZ_SCREENSAVERS_MIN_VERSION=//p' "$ROOT/build/screensavers-version.env" 2>/dev/null | tail -1)"
    if [ -z "$V" ]; then bad "no version directory under $DEBS"
    elif [ -n "$SS_FLOOR" ] && [ "$V" != "$SS_FLOOR" ] && [ "$(printf '%s\n%s\n' "$V" "$SS_FLOOR" | sort -V | head -1)" = "$V" ]; then
        echo "parity: (skipped) newest staged ncz-screensavers under $DEBS is $V, below the image floor $SS_FLOOR (build/screensavers-version.env); stage >= $SS_FLOOR there to re-enable this check"
    else
        for arch in arm64 amd64; do
            [ -f "$DEBS/$V/ncz-screensavers_${V}_$arch.deb" ] || bad "ncz-screensavers $V has no $arch deb"
        done
        ( cd "$DEBS/$V" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ) || bad "ncz-screensavers $V SHA256SUMS do not verify"
        # the settings plugin is pinned separately (section 2b); the GTK4 reference app must not be in any list
        # package lines only (the manifests explain in comments why the reference app is excluded); no grep -q: under pipefail an early exit SIGPIPEs the loop
        if for m in "$ROOT"/manifests/*.pkgs; do pkgs_of "$m"; done | grep -x 'ncz-screensavers-gtk4-reference' >/dev/null; then bad "ncz-screensavers-gtk4-reference is listed in a manifest (it is for other distros)"; fi
        ls "$ROOT"/build/ncz-screensavers-out/ncz-screensavers-gtk4-reference* >/dev/null 2>&1 && bad "ncz-screensavers-gtk4-reference is staged for the image build"
        [ -s "$DEBS/$V/BUILT-FROM.txt" ] || bad "ncz-screensavers $V has no BUILT-FROM.txt (one source commit for both arches)"
        [ "$FAIL" = 0 ] && echo "parity: ncz-screensavers $V has arm64+amd64 debs from '$(cat "$DEBS/$V/BUILT-FROM.txt")'"
    fi
else
    echo "parity: (skipped) ncz-screensavers staging directory not mounted here"
fi

# 2b. Singularity screensaver settings plugin (pinned medium deb) -----------
# The pin must name a deb + payload + libsingularity for BOTH arches from ONE source commit; when the
# store directory is mounted both debs must be there and match the pin; a deb staged in
# build/ncz-screensavers-out/ for either arch must match the pin (a build host stages only its own
# arch, so one staged arch is normal; the stage-2 gate requires the build's own arch).
SSP_LOCK="$ROOT/post-install/lib/ncz-screensavers-plugin.lock"
if [ -f "$SSP_LOCK" ]; then
    ssp_val() { sed -n "s/^$1=//p" "$SSP_LOCK" | tail -1 | tr -d '"'; }
    SSP_PKG="$(ssp_val NCZ_SSPLUGIN_PKG)"; SSP_VER="$(ssp_val NCZ_SSPLUGIN_VERSION)"; SSP_DIR="$(ssp_val NCZ_SSPLUGIN_ARGONAS_DIR)"
    [ -n "$SSP_PKG" ] && [ -n "$SSP_VER" ] && [ -n "$SSP_DIR" ] && [ -n "$(ssp_val NCZ_SSPLUGIN_SOURCE)" ] || bad "plugin pin $SSP_LOCK lacks PKG/VERSION/ARGONAS_DIR/SOURCE"
    for arch in arm64 amd64; do
        for k in SHA256 PAYLOAD LIBSINGULARITY_SHA256; do
            [ -n "$(ssp_val "NCZ_SSPLUGIN_${k}_$arch")" ] || bad "plugin pin has no NCZ_SSPLUGIN_${k}_$arch"
        done
        want="$(ssp_val "NCZ_SSPLUGIN_SHA256_$arch")"
        st="$ROOT/build/ncz-screensavers-out/${SSP_PKG}_${SSP_VER}_$arch.deb"
        if [ -f "$st" ]; then
            [ "$(sha256sum "$st" | awk '{print $1}')" = "$want" ] || bad "staged $st does not match the $arch pin"
        fi
        # no grep -q on a pipe (pipefail + SIGPIPE, see section 2)
        [ -n "$(ls "$ROOT/build/ncz-screensavers-out/${SSP_PKG}_"*"_$arch.deb" 2>/dev/null | grep -v "_${SSP_VER}_$arch.deb\$")" ] && bad "build/ncz-screensavers-out holds a $SSP_PKG $arch deb other than the pinned $SSP_VER"
        if [ -n "$DEBS" ] && [ -d "$(dirname "$DEBS")/$SSP_DIR" ]; then
            src="$(dirname "$DEBS")/$SSP_DIR/${SSP_PKG}_${SSP_VER}_$arch.deb"
            if [ ! -f "$src" ]; then bad "plugin pin: $src missing in the store"
            elif [ "$(sha256sum "$src" | awk '{print $1}')" != "$want" ]; then bad "plugin pin: $src does not match the $arch sha256"; fi
        fi
    done
    [ "$FAIL" = 0 ] && echo "parity: screensaver plugin $SSP_PKG $SSP_VER pinned for arm64+amd64 from '$(ssp_val NCZ_SSPLUGIN_SOURCE)'"
else
    bad "plugin pin $SSP_LOCK missing (both images must ship the screensaver settings plugin)"
fi

# 3. hook arch lint ---------------------------------------------------------------------------------------
bash "$HERE/lint-hook-arch-gates.sh" || FAIL=1

[ "$FAIL" = 0 ] && { echo "parity: OK"; exit 0; }
exit 1
