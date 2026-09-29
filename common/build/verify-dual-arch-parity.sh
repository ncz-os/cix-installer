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
#  3. hook arch lint (build/lint-hook-arch-gates.sh).
# --facts: both targets must report hostname_format_ok=1, sudo_ok=1, bing_plugin_patched=1,
#  sensors_plugin_patched=1, and identical screensavers_version, release_version and release_codename.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="${PARITY_ROOT:-$(cd "$HERE/.." && pwd)}"
FAIL=0
bad() { echo "PARITY FAIL: $*" >&2; FAIL=1; }

pkgs_of() { sed 's/#.*//' "$1" 2>/dev/null | awk 'NF {print $1}' | LC_ALL=C sort -u; }

if [ "${1:-}" = "--facts" ]; then
    A="${2:?arm64 facts file}"; B="${3:?amd64 facts file}"
    fact() { sed -n "s/^\[fact\] $2=//p" "$1" | tail -1; }
    for k in hostname_format_ok sudo_ok bing_plugin_patched sensors_plugin_patched; do
        [ "$(fact "$A" $k)" = 1 ] || bad "arm64 fact $k is '$(fact "$A" $k)', expected 1"
        [ "$(fact "$B" $k)" = 1 ] || bad "amd64 fact $k is '$(fact "$B" $k)', expected 1"
    done
    for k in screensavers_version release_version release_codename; do
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
for c in "${NCZ_SCREENSAVERS_DEBS:-}" /mnt/argonas-projects/ncz-screensavers-debs /mnt/argonas/datapool/projects/ncz-screensavers-debs /nfs-shared/ncz-screensavers-debs; do
    [ -n "$c" ] && [ -d "$c" ] && { DEBS="$c"; break; }
done
if [ -n "$DEBS" ]; then
    V="$(ls "$DEBS" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)"
    if [ -z "$V" ]; then bad "no version directory under $DEBS"
    else
        for arch in arm64 amd64; do
            [ -f "$DEBS/$V/ncz-screensavers_${V}_$arch.deb" ] || bad "ncz-screensavers $V has no $arch deb"
        done
        ( cd "$DEBS/$V" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ) || bad "ncz-screensavers $V SHA256SUMS do not verify"
        [ -s "$DEBS/$V/BUILT-FROM.txt" ] || bad "ncz-screensavers $V has no BUILT-FROM.txt (one source commit for both arches)"
        [ "$FAIL" = 0 ] && echo "parity: ncz-screensavers $V has arm64+amd64 debs from '$(cat "$DEBS/$V/BUILT-FROM.txt")'"
    fi
else
    echo "parity: (skipped) ncz-screensavers staging directory not mounted here"
fi

# 3. hook arch lint ---------------------------------------------------------------------------------------
bash "$HERE/lint-hook-arch-gates.sh" || FAIL=1

[ "$FAIL" = 0 ] && { echo "parity: OK"; exit 0; }
exit 1
