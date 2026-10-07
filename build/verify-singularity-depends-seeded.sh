#!/bin/bash
# verify-singularity-depends-seeded.sh --deb FILE [--arch ARCH] [--seed FILE]
#
# Gate: every package ncz-singularity-desktop Depends on must be in the closure
# of the desktop seed (manifests/desktop[-ARCH].pkgs) on the pinned Debian
# snapshot, at a version that satisfies the Depends constraint.
#
# WHY (2026-10-07): build/build-desktop-mirror.sh builds the offline desktop
# mirror from the SEED only. The local deb's Depends are not an input, so a
# payload refresh that links new libraries (freerdp, sane, ges, ...) produced a
# deb whose Depends the mirror could not satisfy, and the installer's
# `apt-get install ncz-singularity-desktop` failed offline. This resolves the
# closure the same way the mirror does (apt-get -s over release.conf's pinned
# snapshot, Install-Recommends=0) and compares it with the deb's Depends.
#
# Excluded from the seed while resolving: ncz-singularity-desktop (the subject;
# its published Depends are not an input) and google-chrome-stable (comes from
# Google's repo, not the snapshot). Needs network (the snapshot) and apt-get;
# exit 77 (skipped) without apt-get, 1 on any uncovered Depends, 2 on bad usage.
set -uo pipefail
export LC_ALL=C
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEB=""; ARCH=""; SEED=""
while [ $# -gt 0 ]; do
    case "$1" in
        --deb) DEB="${2:-}"; shift 2 ;;
        --arch) ARCH="${2:-}"; shift 2 ;;
        --seed) SEED="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown argument $1" >&2; exit 2 ;;
    esac
done
[ -f "$DEB" ] || { echo "usage: $0 --deb FILE [--arch ARCH] [--seed FILE]" >&2; exit 2; }
command -v apt-get >/dev/null 2>&1 && command -v dpkg-deb >/dev/null 2>&1 || { echo "SKIP: apt-get/dpkg-deb not available"; exit 77; }
# shellcheck disable=SC1091
. "$ROOT/release.conf"
ARCH="${ARCH:-$(dpkg-deb -f "$DEB" Architecture)}"
if [ -z "$SEED" ]; then
    SEED="$ROOT/manifests/desktop.pkgs"
    [ -f "$ROOT/manifests/desktop-$ARCH.pkgs" ] && SEED="$ROOT/manifests/desktop-$ARCH.pkgs"
fi
[ -f "$SEED" ] || { echo "ERROR: seed $SEED missing" >&2; exit 2; }
T="$(mktemp -d "${TMPDIR:-/tmp}/ncz-depseed.XXXXXX")"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/etc/apt/preferences.d" "$T/etc/apt/apt.conf.d" "$T/var/lib/apt/lists/partial" "$T/var/lib/dpkg" "$T/var/cache/apt/archives/partial"
: > "$T/var/lib/dpkg/status"
OPTS="arch=$ARCH trusted=yes"; [ -n "${NCZ_BASE_MIRROR_APT_OPTS:-}" ] && OPTS="$OPTS $NCZ_BASE_MIRROR_APT_OPTS"
echo "deb [$OPTS] $NCZ_BASE_MIRROR $NCZ_BASE_CODENAME $NCZ_BASE_COMPONENTS" > "$T/etc/apt/sources.list"
APT=(-o Dir="$T" -o Dir::State="$T/var/lib/apt" -o Dir::State::status="$T/var/lib/dpkg/status" -o Dir::Cache="$T/var/cache/apt" -o Dir::Etc="$T/etc/apt" -o APT::Architecture="$ARCH" -o APT::Architectures="$ARCH" -o Acquire::Languages=none -o APT::Install-Recommends=0)
apt-get "${APT[@]}" update >"$T/update.log" 2>&1 || { echo "ERROR: apt-get update on $NCZ_BASE_MIRROR failed:"; tail -5 "$T/update.log"; exit 1; }
apt-cache "${APT[@]}" pkgnames | sort -u > "$T/names"
grep -vE '^\s*(#|$)' "$SEED" | awk '{print $1}' | grep -vxE 'ncz-singularity-desktop|google-chrome-stable' | sort -u > "$T/seed"
comm -12 "$T/seed" "$T/names" > "$T/present"
echo "seed $SEED: $(wc -l < "$T/seed") names, $(wc -l < "$T/present") in snapshot $NCZ_BASE_MIRROR_SNAPSHOT ($ARCH)"
apt-get "${APT[@]}" install -s -y $(tr '\n' ' ' < "$T/present") > "$T/sim.log" 2>&1 || { echo "ERROR: seed closure does not resolve:"; grep -E "^E:|Depends:" "$T/sim.log" | head; exit 1; }
awk '/^Inst /{print $2}' "$T/sim.log" | sort -u > "$T/closure"
echo "closure: $(wc -l < "$T/closure") packages"
fail=0; n=0
# Depends: "a (>= 1), b | c (<< 2)" -> one alternative group per line
dpkg-deb -f "$DEB" Depends | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep . > "$T/depends"
while IFS= read -r grp; do
    n=$((n+1)); ok=0; why=""
    IFS='|' read -ra alts <<< "$grp"
    for a in "${alts[@]}"; do
        a="${a#"${a%%[![:space:]]*}"}"
        name="${a%% *}"; name="${name%%:*}"
        op=""; ver=""
        if [[ "$a" =~ \(([\<\>=]+)[[:space:]]*([^\)]+)\) ]]; then op="${BASH_REMATCH[1]}"; ver="${BASH_REMATCH[2]}"; fi
        if ! grep -qxF "$name" "$T/closure"; then why="$why [$name not in seed closure]"; continue; fi
        if [ -n "$op" ]; then
            cand="$(apt-cache "${APT[@]}" policy "$name" | awk '/Candidate:/{print $2}')"
            case "$op" in '>=') o=ge;; '<=') o=le;; '>>') o=gt;; '<<') o=lt;; '=') o=eq;; *) o=ge;; esac
            if dpkg --compare-versions "$cand" "$o" "$ver"; then ok=1; break; else why="$why [$name $cand does not satisfy $op $ver]"; fi
        else ok=1; break; fi
    done
    if [ "$ok" = 1 ]; then :; else fail=$((fail+1)); echo "UNSEEDED: $grp -> $why"; fi
done < "$T/depends"
echo "Depends groups checked: $n, uncovered: $fail"
[ "$fail" = 0 ] && echo "PASS: every Depends of $(basename "$DEB") is covered by the $(basename "$SEED") closure" || echo "FAIL: add the missing packages to $(basename "$SEED")"
[ "$fail" = 0 ]
