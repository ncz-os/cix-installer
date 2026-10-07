#!/bin/bash
# check-ncz-repo-policy.sh -- fail when a Debian-named package is published or
# seeded into the NCZ apt suite without being a reviewed, intentional override.
#
# The rule (post-install/lib/apt-separation.sh is the single source):
#   * ncz-* cix-* cixmini-* chromium-ncz-* panthor-cix-dkms zoder linux-image-*
#     linux-headers-* are NCZ's namespace: always allowed.
#   * a Debian-named package (libdrm2, fonts-liberation, ...) is allowed ONLY if
#     it is a row of ncz_apt_debian_overrides (and for its listed architectures).
#   * Debian's own kernels (linux-image-amd64, linux-image-*-arm64, ...) are
#     never allowed in the NCZ suite.
#
# Usage:
#   build/check-ncz-repo-policy.sh INDEX...        Packages / Packages.gz files or http(s) URLs
#   build/check-ncz-repo-policy.sh --components [manifests/components.tsv]
#                                                  rows seeded as ncz-apt / staged-deb
#   build/check-ncz-repo-policy.sh --live          fetch the live Buildkite + R2 indexes (needs
#                                                  network; skips with exit 0 when offline) and
#                                                  assert R2's Release Origin is NCZ-OS
# Exit 0 clean, 1 violations, 2 usage.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../post-install/lib/apt-separation.sh
. "$HERE/../post-install/lib/apt-separation.sh"

BK_BASE="${NCZ_BK_BASE:-https://packages.buildkite.com/ncz-os/ncz/any/dists/any}"
R2_BASE="${NCZ_R2_BASE:-https://pub-d7b784e01679403d9c70fcd23fff5b96.r2.dev/dists/any}"
BAD=0; SEEN=0

judge() {  # label name version arch
    local label="$1" name="$2" ver="$3" arch="$4" cls
    SEEN=$((SEEN + 1))
    cls="$(ncz_apt_name_class "$name")"
    case "$cls" in
        namespace|vendor) return 0 ;;
        override)
            if ncz_apt_override_arch_ok "$name" "$arch"; then return 0; fi
            echo "FAIL: $label: $name $ver ($arch) is an allowlisted Debian-name override but NOT for architecture $arch"
            BAD=$((BAD + 1)) ;;
        debian-kernel)
            echo "FAIL: $label: $name $ver ($arch) is a Debian kernel name; NCZ kernels must not use Debian's -amd64/-arm64 names"
            BAD=$((BAD + 1)) ;;
        *)
            echo "FAIL: $label: $name $ver ($arch) is a Debian-named package in the NCZ suite and is not in the allowlist (ncz_apt_debian_overrides in post-install/lib/apt-separation.sh)"
            BAD=$((BAD + 1)) ;;
    esac
}

read_index() {  # src label
    local src="$1" label="$2" tmp rc=0 n v a
    tmp="$(mktemp)"
    case "$src" in
        http://*|https://*) curl -fsSL -m 90 -o "$tmp" "$src" || { rm -f "$tmp"; echo "FAIL: cannot fetch $src"; BAD=$((BAD + 1)); return 0; } ;;
        *.gz) gzip -dc "$src" > "$tmp" || rc=$? ;;
        *)    cat "$src" > "$tmp" || rc=$? ;;
    esac
    [ "$rc" = 0 ] || { rm -f "$tmp"; echo "FAIL: cannot read $src"; BAD=$((BAD + 1)); return 0; }
    while IFS=' ' read -r n v a; do
        [ -n "$n" ] && judge "$label" "$n" "$v" "$a"
    done < <(awk '/^Package:/{p=$2} /^Version:/{v=$2} /^Architecture:/{a=$2} /^$/{if(p!="")print p, v, a; p=""} END{if(p!="")print p, v, a}' "$tmp")
    rm -f "$tmp"
}

case "${1:-}" in
    --components)
        f="${2:-$HERE/../manifests/components.tsv}"
        [ -r "$f" ] || { echo "no such file: $f" >&2; exit 2; }
        while IFS=$'\t' read -r name kind source arch rest; do
            case "$name" in ''|'#'*) continue ;; esac
            case "$kind" in ncz-apt|staged-deb) ;; *) continue ;; esac
            judge "components.tsv($kind)" "$name" "-" "$arch"
        done < "$f"
        ;;
    --live)
        if ! curl -fsS -m 20 -o /dev/null -L "$BK_BASE/InRelease" 2>/dev/null; then
            echo "SKIP: cannot reach the live NCZ repos"; exit 0
        fi
        for a in amd64 arm64; do
            read_index "$BK_BASE/main/binary-$a/Packages" "buildkite/$a"
            read_index "$R2_BASE/main/binary-$a/Packages" "r2/$a"
        done
        origin="$(curl -fsSL -m 30 "$R2_BASE/Release" 2>/dev/null | sed -n 's/^Origin: //p')"
        if [ "$origin" = "$NCZ_APT_NCZ_RELEASE_ORIGIN" ]; then
            echo "OK: R2 Release Origin is $origin"
        else
            echo "FAIL: R2 Release Origin is '$origin', expected '$NCZ_APT_NCZ_RELEASE_ORIGIN' (reprepro conf/distributions on ARGOS)"
            BAD=$((BAD + 1))
        fi
        ;;
    ''|-h|--help)
        sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
    *)
        for src in "$@"; do read_index "$src" "$(basename "$src")"; done
        ;;
esac

echo "check-ncz-repo-policy: $SEEN package row(s) examined, $BAD violation(s)"
[ "$BAD" -eq 0 ]
