#!/bin/bash
# test-singularity-deb-depends.sh -- hermetic regression test for the
# ncz-singularity-desktop Depends: derivation.
#
# Guards the defect where the head-built deb (stage 1, build_singularity_payload)
# carried an 18-entry hand-kept Depends: while the payload links ~65 packages,
# so a clean install left the desktop unrunnable. The fix derives Depends from
# the payload ELF closure (build/singularity-deb-depends.sh) and
# build-singularity-deb.sh consumes it.
#
# Hermetic: no network, no containers. Uses a fixture payload made from ELF
# binaries already on this Debian host, the host's dpkg database as the
# soname -> package oracle, and a container-free build-singularity-deb.sh run
# (NCZ_SINGULARITY_DEPENDS_CONTAINER=0).
#
# Checks:
#   1. a fixture payload's control Depends contains every package owning a
#      soname the fixture links (computed independently with dpkg -S), the
#      explicit runtime packages, and no payload-private library;
#   2. Recommends is exactly the vetted +deps1 set;
#   3. the deb ships exactly the tarball's files (packaging adds only DEBIAN/);
#   4. a sidecar for a different tarball is refused (no silent stale Depends);
#   5. an external soname no package owns is a hard error;
#   6. the old literal-Depends script fails check 1 (run with
#      NCZ_SINGULARITY_DEB_SCRIPT=<old copy> to see fail-before).
#
# Needs: dpkg, dpkg-deb, dpkg-shlibdeps (dpkg-dev), readelf, a C compiler (cc)
# for the private-library fixture. Missing tools -> exit 77 (skipped), never a
# silent pass.
#
# Usage: build/test-singularity-deb-depends.sh
set -euo pipefail
# Hermetic: the version gate must read a fixture index, never the live Buildkite one.
export NCZ_PUBLISHED_INDEX="${NCZ_PUBLISHED_INDEX:-/dev/null}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEB_SCRIPT="${NCZ_SINGULARITY_DEB_SCRIPT:-$ROOT/build/build-singularity-deb.sh}"
RESOLVER="$ROOT/build/singularity-deb-depends.sh"
EXTRA_FILE="$ROOT/build/singularity-runtime-extra-deps.txt"

fails=0
pass() { echo "ok   - $*"; }
fail() { echo "FAIL - $*" >&2; fails=$((fails + 1)); }
skip() { echo "SKIP: $*" >&2; exit 77; }

for t in dpkg dpkg-deb dpkg-shlibdeps dpkg-architecture readelf cc; do
    command -v "$t" >/dev/null 2>&1 || skip "$t not available"
done
[ -f "$DEB_SCRIPT" ] || { echo "FAIL - deb script missing: $DEB_SCRIPT" >&2; exit 1; }
[ -x "$RESOLVER" ] || { echo "FAIL - resolver missing: $RESOLVER" >&2; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/test-sing-deb-deps.XXXXXX")"
trap 'rm -rf "$T"' EXIT
ARCH="$(dpkg --print-architecture)"
TRIPLET="$(dpkg-architecture -qDEB_HOST_MULTIARCH)"

# --- fixture payload ---------------------------------------------------------
# A system ELF that links more than libc, so the result is not trivially libc6.
SYS_ELF=""
for cand in /usr/bin/dpkg-deb /usr/bin/ls /usr/bin/tar; do
    [ -x "$cand" ] || continue
    if readelf -d "$cand" 2>/dev/null | grep '(NEEDED)' | grep -vq 'libc\.so'; then
        SYS_ELF="$cand"; break
    fi
done
[ -n "$SYS_ELF" ] || skip "no system ELF with a non-libc DT_NEEDED found"

P="$T/payload/opt/singularity"
mkdir -p "$P/bin" "$P/lib" "$P/share/glib-2.0/schemas"
cp "$SYS_ELF" "$P/bin/singularity-desktop"
printf '#!/bin/sh\nexec /opt/singularity/bin/singularity-desktop "$@"\n' > "$P/bin/singularity-labwc-session"
chmod 0755 "$P/bin/singularity-desktop" "$P/bin/singularity-labwc-session"
echo '<schemalist/>' > "$P/share/glib-2.0/schemas/dev.sinty.fixture.gschema.xml"
# payload-private library + a binary that links it (must NOT become a Depends)
printf 'int ncz_fixture(void){return 42;}\n' > "$T/lib.c"
printf 'int ncz_fixture(void);\nint main(void){return ncz_fixture()==42?0:1;}\n' > "$T/main.c"
cc -shared -fPIC -Wl,-soname,libncz-fixture.so.0 -o "$P/lib/libncz-fixture.so.0" "$T/lib.c"
cc -o "$P/bin/ncz-fixture-tool" "$T/main.c" -L"$P/lib" -l:libncz-fixture.so.0
( cd "$T/payload" && tar -czf "$T/singularity-opt.tgz" opt/singularity )

# --- independent oracle: owners of the fixture's external sonames -----------
expected=()
while IFS= read -r so; do
    [ "$so" = libncz-fixture.so.0 ] && continue
    owner="$(dpkg -S "/usr/lib/$TRIPLET/$so" "/lib/$TRIPLET/$so" 2>/dev/null \
             | grep -v '^diversion' | head -n1 | sed 's/[:,].*//' || true)"
    [ -n "$owner" ] || skip "host cannot resolve owner of $so"
    expected+=("$owner")
done < <(for f in "$P/bin/singularity-desktop" "$P/bin/ncz-fixture-tool"; do
             readelf -d "$f" | sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p'; done | sort -u)
while IFS= read -r p; do expected+=("$p"); done < <(grep -vE '^[[:space:]]*(#|$)' "$EXTRA_FILE")
[ "${#expected[@]}" -ge 5 ] || skip "fixture produced too few expected packages"

# --- build: resolver (as build-singularity.sh runs it) + packager -----------
"$RESOLVER" --direct -o "$T/singularity-opt.tgz.depends" "$T/singularity-opt.tgz" 2>"$T/resolver.log" \
    || { cat "$T/resolver.log" >&2; echo "FAIL - resolver failed on the fixture" >&2; exit 1; }
mkdir -p "$T/out"
if ! NCZ_SINGULARITY_ARCH="$ARCH" NCZ_SINGULARITY_DEPENDS_CONTAINER=0 NCZ_SINGULARITY_VERSION=20990101+bk0+test \
     OUT="$T/out" bash "$DEB_SCRIPT" "$T/singularity-opt.tgz" > "$T/build.log" 2>&1; then
    cat "$T/build.log" >&2
    echo "FAIL - $DEB_SCRIPT failed on the fixture" >&2
    exit 1
fi
DEB="$(ls "$T/out"/ncz-singularity-desktop_*.deb)"
DEPENDS="$(dpkg-deb -f "$DEB" Depends)"
RECOMMENDS="$(dpkg-deb -f "$DEB" Recommends 2>/dev/null || true)"
bare_list() { printf '%s\n' "$1" | tr ',|' '\n\n' | sed 's/(.*//;s/^[[:space:]]*//;s/[[:space:]]*$//' | sed '/^$/d' | sort -u; }
DEP_BARE="$(bare_list "$DEPENDS")"

# 1. every expected package present, no private lib leak
miss=()
for p in "${expected[@]}"; do printf '%s\n' "$DEP_BARE" | grep -qxF "$p" || miss+=("$p"); done
if [ "${#miss[@]}" -eq 0 ]; then
    pass "Depends covers all ${#expected[@]} expected packages (${SYS_ELF##*/} closure + runtime extras)"
else
    fail "Depends is missing: ${miss[*]} (Depends: $DEPENDS)"
fi
if printf '%s\n' "$DEPENDS" | grep -q 'ncz-fixture\|ncz-singularity-desktop'; then
    fail "payload-private library or self leaked into Depends: $DEPENDS"
else
    pass "no payload-private library or self-dependency in Depends"
fi

# 2. Recommends pinned to the +deps1 set
want_rec="adwaita-icon-theme ca-certificates dconf-gsettings-backend glib-networking gsettings-desktop-schemas gstreamer1.0-gtk4 gstreamer1.0-libav gstreamer1.0-plugins-base gstreamer1.0-plugins-good xdg-desktop-portal"
got_rec="$(bare_list "$RECOMMENDS" | paste -sd' ' -)"
if [ "$got_rec" = "$want_rec" ]; then pass "Recommends matches the +deps1 set"; else fail "Recommends drifted: '$got_rec'"; fi

# 3. shipped files unchanged
tar -tzf "$T/singularity-opt.tgz" | sed 's|/$||;s|^\./||' | sort > "$T/tgz.list"
dpkg-deb -c "$DEB" | awk '{print $6}' | sed 's|^\./||;s|/$||' | sed '/^$/d' | sort > "$T/deb.list"
# dpkg-deb lists the parent "opt" directory entry; the tarball does not.
if diff -u <(grep -vx opt "$T/tgz.list") <(grep -vx opt "$T/deb.list") > "$T/files.diff"; then
    pass "deb ships exactly the payload files"
else
    fail "deb file list differs from the payload: $(head -20 "$T/files.diff")"
fi

# 4. stale sidecar refused (only meaningful for the sidecar-aware script)
if grep -q 'singularity-deb-depends.sh' "$DEB_SCRIPT"; then
    echo extra > "$T/payload/opt/singularity/share/extra.txt"
    ( cd "$T/payload" && tar -czf "$T/other.tgz" opt/singularity )
    cp "$T/singularity-opt.tgz.depends" "$T/other.tgz.depends"
    if NCZ_SINGULARITY_ARCH="$ARCH" NCZ_SINGULARITY_DEPENDS_CONTAINER=0 OUT="$T/out2" \
       bash "$DEB_SCRIPT" "$T/other.tgz" > "$T/stale.log" 2>&1; then
        fail "a sidecar describing another tarball was accepted"
    elif grep -q 'not this payload' "$T/stale.log"; then
        pass "sidecar for a different tarball is refused"
    else
        fail "stale sidecar run failed for an unexpected reason: $(tail -3 "$T/stale.log")"
    fi
else
    fail "$DEB_SCRIPT does not use the payload-derived Depends"
fi

# 5. unresolvable external soname is a hard error
rm -f "$P/lib/libncz-fixture.so.0" "$P/share/extra.txt"
if "$RESOLVER" --direct "$T/payload" > "$T/unres.out" 2> "$T/unres.log"; then
    fail "resolver accepted a payload whose libncz-fixture.so.0 nobody provides"
elif grep -q 'libncz-fixture.so.0' "$T/unres.log"; then
    pass "unresolvable external soname is a hard error"
else
    fail "resolver failed without naming the missing soname: $(tail -3 "$T/unres.log")"
fi

if [ "$fails" -ne 0 ]; then
    echo "FAIL: $fails check(s) failed" >&2
    exit 1
fi
echo "PASS: singularity deb Depends derivation"
