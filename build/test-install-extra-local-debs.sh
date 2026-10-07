#!/bin/bash
# test-install-extra-local-debs.sh -- every NCZ package seeded by manifests/install-extra.pkgs must be
# something the offline-mirror build can actually RESOLVE.
#
# Why (r201 re-review, high): ncz-apt-policy was added to install-extra.pkgs, but build-forky-mirror.sh
# resolves its closure only from Debian, the vendor mirror and the desktop mirror, and the desktop mirror
# gets non-Debian packages only from NCZ_LOCAL_DEBS. With no NCZ_LOCAL_DEBS row the next image build
# failed on both arches and an offline install could not satisfy the verifier. The package is now a LOCAL
# deb the build creates (make apt-policy-deb -> build/ncz-apt-policy-deb), so no live-repo publish is needed.
#
# This test runs the REAL NCZ_LOCAL_DEBS resolution loop extracted from build/build-desktop-mirror.sh (the
# script's own text, for both arches) against a fixture tree:
#   1. with the deb built by build/build-ncz-apt-policy-deb.sh present: it lands in the pool and the closure
#   2. with it absent: the mirror build stops with an error that names the builder (no silent skip)
#   3. every ncz-* name in install-extra.pkgs ends up in the pool (the general invariant)
#   4. the Makefile builds it before the desktop mirror
# DESKTOP_MIRROR_SCRIPT=<path> runs the same checks against another version of the script (to show the old
# tip fails: `git show <old>:build/build-desktop-mirror.sh > x; DESKTOP_MIRROR_SCRIPT=x ...`).
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$HERE/.."
SCRIPT="${DESKTOP_MIRROR_SCRIPT:-$ROOT/build/build-desktop-mirror.sh}"
command -v dpkg-deb >/dev/null 2>&1 || { echo "SKIP: dpkg-deb not available"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }

# the real loop, verbatim from the script under test
python3 - "$SCRIPT" > "$T/loop.sh" <<'PY'
import sys
s = open(sys.argv[1]).read()
a = s.index('NCZ_LOCAL_DEBS="')
b = s.index('LC_ALL=C sort -u -o "$CLOSURE" "$CLOSURE"') + len('LC_ALL=C sort -u -o "$CLOSURE" "$CLOSURE"')
print(s[a:b])
PY
[ -s "$T/loop.sh" ] || { bad "could not extract the NCZ_LOCAL_DEBS loop from $SCRIPT"; echo "test-install-extra-local-debs: $PASS passed, $FAIL failed"; exit 1; }
# shellcheck disable=SC1091
. "$ROOT/build/screensavers-version.env"

mkdeb() {  # out name ver arch
    local w="$T/w.$RANDOM"; mkdir -p "$w/DEBIAN" "$w/usr/share/x"
    printf 'Package: %s\nVersion: %s\nArchitecture: %s\nMaintainer: T <t@example.invalid>\nDescription: t\n' "$2" "$3" "$4" > "$w/DEBIAN/control"
    echo "$2" > "$w/usr/share/x/f"; dpkg-deb --root-owner-group -b "$w" "$1" >/dev/null 2>&1
}

# a fixture REPO holding a stub for every other local row, so only ncz-apt-policy decides the outcome
mkrepo() {  # arch withpolicy(0|1) -> echoes repo dir
    local arch="$1" with="$2" repo="$T/repo-$1-$2" pkg glob path
    rm -rf "$repo"; mkdir -p "$repo/build"
    while IFS='|' read -r pkg glob req; do
        [ -n "$pkg" ] || continue
        glob="${glob//\$REPO/$repo}"; glob="${glob//\$\{ARCH\}/$arch}"
        path="${glob/\*/9.9.9}"; mkdir -p "$(dirname "$path")"
        case "$pkg" in
            ncz-screensavers) mkdeb "$path" ncz-screensavers "$NCZ_SCREENSAVERS_MIN_VERSION" all ;;
            ncz-apt-policy) : ;;
            *) mkdeb "$path" "$pkg" 9.9.9 "$arch" ;;
        esac
    done < <(REPO="$repo" ARCH="$arch" bash -c ". '$T/rows.sh'" 2>/dev/null)
    if [ "$with" = 1 ]; then
        : > "$T/empty"
        NCZ_PUBLISHED_INDEX="$T/empty" NCZ_APT_POLICY_OUT="$repo/build/ncz-apt-policy-deb" bash "$ROOT/build/build-ncz-apt-policy-deb.sh" >/dev/null 2>&1
    fi
    echo "$repo"
}
# the declared rows, printed (NCZ_LOCAL_DEBS evaluated for REPO/ARCH) -- used only to lay out the fixture
sed '/^printf .%s\\n. "\$NCZ_LOCAL_DEBS" | while/,$d' "$T/loop.sh" > "$T/rows.sh"; echo 'printf "%s\n" "$NCZ_LOCAL_DEBS"' >> "$T/rows.sh"

run_loop() {  # repo arch -> rc, output in $T/loop.out
    local repo="$1" arch="$2"
    rm -rf "$T/out-$arch"; mkdir -p "$T/out-$arch/pool/main"; : > "$T/closure-$arch"
    ( set -euo pipefail
      REPO="$repo"; ARCH="$arch"; OUT="$T/out-$arch"; CLOSURE="$T/closure-$arch"
      . "$T/loop.sh" ) > "$T/loop.out" 2>&1
}

for arch in amd64 arm64; do
    echo "=== $arch: the policy deb built by build-ncz-apt-policy-deb.sh is resolved ==="
    repo="$(mkrepo "$arch" 1)"
    ls "$repo"/build/ncz-apt-policy-deb/ncz-apt-policy_*_all.deb >/dev/null 2>&1 && ok "fixture: builder produced the deb" || bad "builder produced no deb"
    run_loop "$repo" "$arch"; rc=$?
    [ "$rc" = 0 ] && ok "$arch: the local-deb resolution succeeds (rc=0)" || bad "$arch: resolution failed rc=$rc" "$(tail -8 "$T/loop.out")"
    ls "$T/out-$arch/pool/main/n/ncz-apt-policy/"ncz-apt-policy_*_all.deb >/dev/null 2>&1 && ok "$arch: ncz-apt-policy is in the offline pool" || bad "$arch: ncz-apt-policy is NOT in the pool" "$(tail -8 "$T/loop.out")"
    grep -qxF ncz-apt-policy "$T/closure-$arch" && ok "$arch: ncz-apt-policy is in the mirror closure (not pruned)" || bad "$arch: not in the closure"
    # general invariant: every ncz-* install-extra seed is resolvable from the pool
    while IFS= read -r name; do
        ls "$T/out-$arch/pool/main/${name:0:1}/$name/${name}"_*.deb >/dev/null 2>&1 \
            && ok "$arch: install-extra seed $name resolves from the pool" || bad "$arch: install-extra seed $name has no local deb row (the mirror build cannot resolve it)"
    done < <(grep -vE '^[[:space:]]*(#|$)' "$ROOT/manifests/install-extra.pkgs" | awk '{print $1}' | grep '^ncz-')

    echo "=== $arch: without the deb the mirror build STOPS, naming the builder ==="
    repo0="$(mkrepo "$arch" 0)"
    run_loop "$repo0" "$arch"; rc=$?
    [ "$rc" != 0 ] && ok "$arch: no ncz-apt-policy deb => the build fails (rc=$rc)" || bad "$arch: the build passed without the policy deb"
    grep -q 'ncz-apt-policy' "$T/loop.out" && grep -q 'build-ncz-apt-policy-deb.sh' "$T/loop.out" \
        && ok "$arch: the error names ncz-apt-policy and build/build-ncz-apt-policy-deb.sh" || bad "$arch: error does not point at the builder" "$(tail -6 "$T/loop.out")"
done

echo "=== the Makefile builds it before the desktop mirror ==="
if grep -q '^apt-policy-deb:' "$ROOT/Makefile" && grep -Eq '^desktop-mirror:.*\bapt-policy-deb\b' "$ROOT/Makefile"; then
    ok "make desktop-mirror depends on apt-policy-deb"
else
    bad "Makefile: desktop-mirror does not depend on an apt-policy-deb target"
fi
grep -A4 '^apt-policy-deb:' "$ROOT/Makefile" | grep -q 'build-ncz-apt-policy-deb.sh' && ok "apt-policy-deb runs build/build-ncz-apt-policy-deb.sh" || bad "apt-policy-deb does not run the builder"
grep -q 'ncz-apt-policy|' "$ROOT/build/build-desktop-mirror.sh" && ok "build-desktop-mirror.sh carries the ncz-apt-policy NCZ_LOCAL_DEBS row" || bad "no ncz-apt-policy row in build-desktop-mirror.sh"

echo "test-install-extra-local-debs: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
