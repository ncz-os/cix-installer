#!/bin/bash
# test-singularity-deb-version.sh -- the ncz-singularity-desktop version must be
# monotonic: every new build sorts strictly above every earlier one.
#
# Defect (found on the O6N, 2026-10-07): the scheme was YYYYMMDD+bkN+tgz<hash>.
# Two builds on the same day differ only in the hex content hash, so
#   20261007+bk0+tgzb025ea52  (newer build)
#   20261007+bk0+tgzb69d3482  (installed)
# compared the wrong way round: apt saw the new deb as a downgrade and never
# offered it. The fix is a UTC timestamp before bk/hash (build-singularity-deb.sh).
#
# Hermetic: builds tiny fixture debs through the real packaging script, reads
# their Version with dpkg-deb and orders them with `dpkg --compare-versions`.
# Fixture tarballs are made until two of them have a content hash that sorts in
# the OPPOSITE order to their build order, which is exactly the case the old
# scheme got wrong, so this test fails on the old scheme and passes on the new.
#
# Checks:
#   1. negative control: the OLD scheme is non-monotonic (dpkg says so);
#   2. a new build sorts above every previously shipped version, including
#      20261007+bk0+tgzb69d3482 and 20261007+bk0+tgzb025ea52;
#   3. N consecutive fixture builds (random content hashes, increasing
#      timestamps) are strictly increasing, and a hash-descending pair among
#      them is ordered by build time, not by hash;
#   4. bk number breaks a timestamp tie upward;
#   5. same tarball + same timestamp -> same version (reproducible), and
#      SOURCE_DATE_EPOCH gives the same timestamp as NCZ_SINGULARITY_BUILD_TS;
#   6. a malformed timestamp is refused.
#
# Run against another copy of the script with NCZ_SINGULARITY_DEB_SCRIPT=<path>
# (e.g. `git show <old-commit>:build/build-singularity-deb.sh`) to see it fail.
# Needs dpkg, dpkg-deb, dpkg-shlibdeps (dpkg-dev), readelf; missing -> exit 77.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEB_SCRIPT="${NCZ_SINGULARITY_DEB_SCRIPT:-$ROOT/build/build-singularity-deb.sh}"
RESOLVER="$ROOT/build/singularity-deb-depends.sh"

fails=0
pass() { echo "ok   - $*"; }
fail() { echo "FAIL - $*" >&2; fails=$((fails + 1)); }
skip() { echo "SKIP: $*" >&2; exit 77; }
for t in dpkg dpkg-deb dpkg-shlibdeps readelf tar gzip; do
    command -v "$t" >/dev/null 2>&1 || skip "$t not available"
done
[ -f "$DEB_SCRIPT" ] || { echo "FAIL - deb script missing: $DEB_SCRIPT" >&2; exit 1; }

lt() { dpkg --compare-versions "$1" lt "$2"; }
gt() { dpkg --compare-versions "$1" gt "$2"; }

# --- 1. negative control: dpkg really orders the old scheme by hash ----------
OLD_NEW_BUILD=20261007+bk0+tgzb025ea52
OLD_INSTALLED=20261007+bk0+tgzb69d3482
if lt "$OLD_NEW_BUILD" "$OLD_INSTALLED"; then
    pass "control: old scheme sorts the newer build $OLD_NEW_BUILD BELOW $OLD_INSTALLED (the O6N defect)"
else
    fail "control: dpkg no longer orders the old scheme by hash; the test premise is gone"
fi

T="$(mktemp -d "${TMPDIR:-/tmp}/test-sing-deb-version.XXXXXX")"
trap 'rm -rf "$T"' EXIT
ARCH="$(dpkg --print-architecture)"

# --- fixture payload ----------------------------------------------------------
SYS_ELF=""
for cand in /usr/bin/dpkg-deb /usr/bin/ls /usr/bin/tar; do
    [ -x "$cand" ] || continue
    if readelf -d "$cand" 2>/dev/null | grep '(NEEDED)' | grep -vq 'libc\.so'; then SYS_ELF="$cand"; break; fi
done
[ -n "$SYS_ELF" ] || skip "no system ELF with a non-libc DT_NEEDED found"
P="$T/payload/opt/singularity"
mkdir -p "$P/bin" "$P/share"
cp "$SYS_ELF" "$P/bin/singularity-desktop"
printf '#!/bin/sh\nexec /opt/singularity/bin/singularity-desktop "$@"\n' > "$P/bin/singularity-labwc-session"
chmod 0755 "$P/bin/singularity-desktop" "$P/bin/singularity-labwc-session"

# Deterministic tarball (no gzip/tar timestamps) so the content hash is a pure
# function of the variant number.
mktgz() {  # <variant> <out.tgz>
    printf 'variant %s\n' "$1" > "$P/share/variant.txt"
    ( cd "$T/payload" && tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf - opt/singularity | gzip -n > "$2" )
}
# One Depends sidecar derived once from the first tarball; later tarballs reuse
# it with the payload hash rewritten (the packager refuses a sidecar naming a
# different payload hash, which is not what is under test here).
mktgz 0 "$T/seed.tgz"
[ -x "$RESOLVER" ] && "$RESOLVER" --direct -o "$T/seed.depends" "$T/seed.tgz" 2>"$T/resolver.log" \
    || { cat "$T/resolver.log" >&2; echo "FAIL - resolver failed on the fixture" >&2; exit 1; }

build_version() {  # <variant> <env assignments...>  -> prints the deb's Version
    local v="$1"; shift
    local tgz="$T/v$v.tgz" out="$T/out.$v.$RANDOM"
    [ -f "$tgz" ] || mktgz "$v" "$tgz"
    local sha; sha="$(sha256sum "$tgz" | cut -d' ' -f1)"
    sed "s/^X-Payload-SHA256: .*/X-Payload-SHA256: $sha/" "$T/seed.depends" > "$T/v$v.tgz.depends"
    mkdir -p "$out"
    env "$@" NCZ_SINGULARITY_ARCH="$ARCH" NCZ_SINGULARITY_DEPENDS_CONTAINER=0 OUT="$out" \
        bash "$DEB_SCRIPT" "$tgz" > "$T/build.$v.log" 2>&1 \
        || { cat "$T/build.$v.log" >&2; echo "FAIL - $DEB_SCRIPT failed on fixture $v" >&2; exit 1; }
    dpkg-deb -f "$out"/ncz-singularity-desktop_*.deb Version
}

# --- 2. above every previously shipped version --------------------------------
V="$(build_version 1 NCZ_SINGULARITY_BUILD_TS=20261007120000)"
echo "     fixture build version: $V"
shipped=(
    "$OLD_INSTALLED"               # installed on the O6N (arm64, r200 image 382cc11a)
    "$OLD_NEW_BUILD"               # the 2026-10-07 arm64 refresh deb
    20261007+bk0+tgzbf349870       # amd64 r201 payload
    20261006+bk0+tgz5fa6f59c       # r199 arm64
    20261005+bk0+tgz00000000+deps1
    20260824+bk0~g6c87c48
    20260820+bk0~g19e6662ffff0
    20260817+bk4~v7
)
allabove=1
for s in "${shipped[@]}"; do
    gt "$V" "$s" || { fail "new build $V does not sort above shipped $s"; allabove=0; }
done
[ "$allabove" = 1 ] && pass "new build $V sorts above all ${#shipped[@]} previously shipped versions (incl. $OLD_INSTALLED)"

# --- 3. N builds: strictly increasing whatever the hashes do --------------------
prev=""; prevtag=""; n=0; inversions=0; bad=0
for i in $(seq 1 14); do
    ts="$(printf '20261008%02d0000' "$i")"
    cur="$(build_version "$((i + 1))" "NCZ_SINGULARITY_BUILD_TS=$ts")"
    tag="${cur##*+}"
    if [ -n "$prev" ]; then
        gt "$cur" "$prev" || { fail "build $cur (ts $ts) does not sort above the previous build $prev"; bad=1; }
        # a pair whose HASH order is the reverse of the build order: the old scheme's failure case
        [[ "$tag" < "$prevtag" ]] && inversions=$((inversions + 1))
    fi
    prev="$cur"; prevtag="$tag"; n=$((n + 1))
done
[ "$bad" = 0 ] && pass "$n consecutive builds are strictly increasing ($inversions of them had a smaller content hash than their predecessor)"
if [ "$inversions" -ge 1 ]; then
    pass "fixture exercised a hash-descending pair (the case the old scheme got wrong)"
else
    fail "no hash-descending pair among the fixtures; the test did not exercise the defect"
fi

# --- 4. bk number tie-break ------------------------------------------------------
A="$(build_version 2 NCZ_SINGULARITY_BUILD_TS=20261009000000 BUILDKITE_BUILD_NUMBER=7)"
B="$(build_version 2 NCZ_SINGULARITY_BUILD_TS=20261009000000 BUILDKITE_BUILD_NUMBER=12)"
gt "$B" "$A" && pass "same timestamp: bk12 sorts above bk7 ($B > $A)" || fail "bk tie-break wrong: $B vs $A"

# --- 5. reproducibility ------------------------------------------------------------
R1="$(build_version 3 NCZ_SINGULARITY_BUILD_TS=20261010101010)"
R2="$(build_version 3 NCZ_SINGULARITY_BUILD_TS=20261010101010)"
[ "$R1" = "$R2" ] && pass "same tarball + same timestamp -> identical version ($R1)" || fail "version not reproducible: $R1 vs $R2"
# 20261010101010 UTC = epoch 1791627010
R3="$(build_version 3 SOURCE_DATE_EPOCH=1791627010)"
[ "$R3" = "$R1" ] && pass "SOURCE_DATE_EPOCH maps to the same timestamp" || fail "SOURCE_DATE_EPOCH version $R3 != $R1"

# --- 6. malformed timestamp refused ---------------------------------------------------
if grep -q BUILD_TS "$DEB_SCRIPT"; then
    mkdir -p "$T/outbad"
    if NCZ_SINGULARITY_BUILD_TS=20261010 NCZ_SINGULARITY_ARCH="$ARCH" NCZ_SINGULARITY_DEPENDS_CONTAINER=0 OUT="$T/outbad" \
       bash "$DEB_SCRIPT" "$T/v3.tgz" > "$T/bad.log" 2>&1; then
        fail "an 8-digit NCZ_SINGULARITY_BUILD_TS was accepted"
    else
        pass "a malformed build timestamp is refused"
    fi
else
    fail "the packaging script has no build timestamp (old scheme)"
fi

if [ "$fails" -eq 0 ]; then echo "singularity deb version tests: all passed"; else echo "singularity deb version tests: $fails FAILED" >&2; exit 1; fi
