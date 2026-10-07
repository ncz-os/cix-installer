#!/bin/bash
# test-verify-dkms-deb-sources.sh -- drive build/verify-dkms-deb-sources.py
# against synthetic asset trees and debs, in both directions: a deb built from
# the current source passes, and each way a deb can be stale fails.
#
# Run: bash build/test-verify-dkms-deb-sources.sh
# Exit 0 = all cases pass, 1 = at least one failed, 2 = cannot run.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SCRIPT_DIR/verify-dkms-deb-sources.py"
[ -r "$GATE" ] || { echo "FATAL: cannot read $GATE" >&2; exit 2; }
command -v dpkg-deb >/dev/null || { echo "FATAL: dpkg-deb not found" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/verify-dkms-deb-sources.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PASS=0
FAILED=0

# mkroot <root>: a panthor asset tree shaped like assets/kernel/panthor.
mkroot() {
    local r="$1"
    rm -rf "$r"
    mkdir -p "$r/assets/kernel/panthor/patches" \
             "$r/assets/kernel/panthor/7.3.0-rc6-sky1-ncz" "$r/assets/cix-debs"
    printf 'PACKAGE_NAME="panthor-cix"\nPACKAGE_VERSION="7.2.0"\n' \
        > "$r/assets/kernel/panthor/dkms.conf"
    printf 'obj-m += panthor.o\n' > "$r/assets/kernel/panthor/Kbuild"
    printf 'int a(void) { return 0; }\n' > "$r/assets/kernel/panthor/panthor_drv.c"
    printf 'ELF' > "$r/assets/kernel/panthor/7.3.0-rc6-sky1-ncz/panthor.ko"
    printf 'patch\n' > "$r/assets/kernel/panthor/patches/0001.patch"
}

# mkdeb <root> <out.deb> [mutator]: package the tree the way
# build-dkms-debs.sh does, then let the mutator change the payload.
mkdeb() {
    local r="$1" out="$2" mut="${3:-}"
    local w="$WORK/pkg"
    rm -rf "$w"
    local src="$w/usr/src/panthor-cix-7.2.0"
    mkdir -p "$w/DEBIAN" "$src"
    cp -a "$r/assets/kernel/panthor/." "$src/"
    rm -rf "$src/patches" "$src/7.3.0-rc6-sky1-ncz"
    [ -n "$mut" ] && (cd "$src" && eval "$mut")
    printf 'Package: panthor-cix-dkms\nVersion: 7.2.0+ncz1\nArchitecture: all\nMaintainer: t <t@t>\nDescription: t\n' \
        > "$w/DEBIAN/control"
    dpkg-deb --build --root-owner-group "$w" "$out" >/dev/null
}

# expect <label> <want_rc> <want_regex> <root>
expect() {
    local label="$1" want_rc="$2" pat="$3" root="$4" out rc=0
    out=$(python3 "$GATE" --root "$root" --driver panthor 2>&1) || rc=$?
    if [ "$rc" = "$want_rc" ] && printf '%s\n' "$out" | grep -Eq "$pat"; then
        echo "PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $label (rc=$rc want=$want_rc, pattern '$pat')"
        printf '%s\n' "$out" | sed 's/^/    /'
        FAILED=$((FAILED + 1))
    fi
}

R="$WORK/root"

mkroot "$R"; mkdeb "$R" "$R/assets/cix-debs/panthor-cix-dkms_7.2.0+ncz1_all.deb"
expect "fresh deb -> PASS" 0 'OK panthor: .*\(3 files\)' "$R"

mkroot "$R"; mkdeb "$R" "$R/assets/cix-debs/panthor-cix-dkms_7.2.0+ncz1_all.deb" \
    'printf "#define DRIVER_GEM_GPUVA_OLD\n" >> panthor_drv.c'
expect "stale source in deb -> FAIL" 1 'differ: panthor_drv\.c' "$R"

mkroot "$R"; mkdeb "$R" "$R/assets/cix-debs/panthor-cix-dkms_7.2.0+ncz1_all.deb" \
    'printf "x\n" > panthor_old.c'
expect "file removed from source but still in deb -> FAIL" 1 'extra: panthor_old\.c' "$R"

mkroot "$R"; mkdeb "$R" "$R/assets/cix-debs/panthor-cix-dkms_7.2.0+ncz1_all.deb" \
    'rm -f Kbuild'
expect "file missing from deb -> FAIL" 1 'missing: Kbuild' "$R"

mkroot "$R"; mkdeb "$R" "$R/assets/cix-debs/panthor-cix-dkms_7.2.0+ncz1_all.deb"
cp "$R/assets/cix-debs/panthor-cix-dkms_7.2.0+ncz1_all.deb" \
   "$R/assets/cix-debs/panthor-cix-dkms_7.2.0+ncz2_all.deb"
expect "two versions staged -> FAIL" 1 '2 panthor-cix-dkms debs staged' "$R"

mkroot "$R"; mkdeb "$R" "$R/assets/cix-debs/panthor-cix-dkms_7.2.0+ncz1_all.deb" \
    'mkdir -p 7.2.7-sky1-ncz && printf ELF > 7.2.7-sky1-ncz/panthor.ko && printf o > x.o'
expect "prebuilt .ko dirs and artifacts in deb are ignored -> PASS" 0 'OK panthor' "$R"

mkroot "$R"; printf 'not a deb' > "$R/assets/cix-debs/panthor-cix-dkms_7.2.0+ncz1_all.deb"
expect "corrupt deb -> FAIL" 1 'FAIL panthor: cannot read' "$R"

mkroot "$R"
expect "no deb staged -> SKIP, PASS" 0 'SKIP panthor: no panthor-cix-dkms' "$R"

rm -rf "$R"; mkdir -p "$R/assets/cix-debs"
printf 'stub' > "$R/assets/cix-debs/panthor-cix-dkms_1.0.0_arm64.deb"
expect "no assets/kernel tree (gate-test fixture) -> SKIP, PASS" 0 'SKIP panthor: no ' "$R"

echo "---"
echo "passed=$PASS failed=$FAILED"
[ "$FAILED" -eq 0 ]
