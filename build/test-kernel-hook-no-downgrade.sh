#!/usr/bin/env bash
# test-kernel-hook-no-downgrade.sh -- 10-our-kernel.sh must never downgrade
# an installed package when it installs zstd and its libraries from the
# /cdrom pool.
#
# 2026-11-07 (arm64 build c808502f, KVM gate): d-i base-installer upgraded the
# target from the live mirror (zlib1g and zlib1g-dev 1.3.2-3 -> 1.3.2-4).
# The hook then ran `dpkg -i` on the pool's zlib1g 1.3.2-3, a downgrade under
# zlib1g-dev (Depends: zlib1g (= 1.3.2-4)). From then on every apt-get install
# in the run failed with "Unmet dependencies": the firmware BOM (13) installed
# nothing and 20-desktop.sh stopped before it wrote the enabled-plugins
# default the screensaver plugin hook (59) checks.
#
# Cases for ncz_debs_to_install (extracted from the hook):
#   - a deb older than the installed version is skipped
#   - a deb equal to the installed version is skipped
#   - a deb newer than the installed version is kept
#   - a deb for a package that is not installed is kept
#   - a package that is only config-files (removed) is kept
# Plus: the hook's dpkg -i of the zstd dependency set goes through the filter.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$ROOT/post-install/10-our-kernel.sh"
PASS=0; FAIL=0
ok() { echo "PASS: $1"; PASS=$((PASS + 1)); }
no() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

for t in dpkg dpkg-deb; do
    command -v "$t" >/dev/null 2>&1 || { echo "SKIP: $t not available"; exit 77; }
done
T="$(mktemp -d "${TMPDIR:-/tmp}/test-kernel-no-downgrade.XXXXXX")"
trap 'rm -rf "$T"' EXIT

sed -n '/^# >>> ncz_debs_to_install/,/^# <<< ncz_debs_to_install/p' "$HOOK" > "$T/fn.sh"
if [ -s "$T/fn.sh" ]; then
    ok "10-our-kernel.sh carries ncz_debs_to_install"
else
    no "10-our-kernel.sh has no ncz_debs_to_install block"
fi

mkdeb() {  # mkdeb <pkg> <version> <arch> -> path of a minimal .deb
    local d="$T/src-$1-$3"
    rm -rf "$d"; mkdir -p "$d/DEBIAN"
    printf 'Package: %s\nVersion: %s\nArchitecture: %s\nMaintainer: t <t@t>\nDescription: t\n' \
        "$1" "$2" "$3" > "$d/DEBIAN/control"
    dpkg-deb --root-owner-group -b "$d" "$T/$1_$3.deb" >/dev/null 2>&1 || dpkg-deb -b "$d" "$T/$1_$3.deb" >/dev/null
    echo "$T/$1_$3.deb"
}

# Fake dpkg-query: answers from $T/status ("<pkg>:<arch> <status> <version>").
mkdir -p "$T/bin"
cat > "$T/bin/dpkg-query" <<'Q'
#!/bin/sh
fmt=""; pkg=""
for a in "$@"; do
    case "$a" in -W|--show) ;; -f*|--showformat=*) fmt="$a" ;; *) pkg="$a" ;; esac
done
line=$(grep -F -- "$pkg " "$NCZ_TEST_STATUS" | head -1)
[ -n "$line" ] || { echo "dpkg-query: no packages found matching $pkg" >&2; exit 1; }
set -- $line
printf '%s %s' "$2" "$3"
Q
chmod +x "$T/bin/dpkg-query"
cat > "$T/status" <<'S'
zlib1g:arm64 installed 1:1.3.dfsg+really1.3.2-4
libgcc-s1:arm64 installed 16.2.0-3
liblz4-1:arm64 installed 1.10.0-9
liblzma5:arm64 config-files 5.8.4-1
S

ZLIB=$(mkdeb zlib1g 1:1.3.dfsg+really1.3.2-3 arm64)
GCC=$(mkdeb libgcc-s1 16.2.0-3 arm64)
LZ4=$(mkdeb liblz4-1 1.10.0-10 arm64)
LZMA=$(mkdeb liblzma5 5.8.4-1 arm64)
ZSTD=$(mkdeb zstd 1.5.7+dfsg-4 arm64)

OUT=$(PATH="$T/bin:$PATH" NCZ_TEST_STATUS="$T/status" bash -c \
    ". '$T/fn.sh'; ncz_debs_to_install '$GCC' '$LZ4' '$LZMA' '$ZLIB' '$ZSTD'" 2>&1)
has() { printf '%s\n' "$OUT" | grep -qxF -- "$1"; }
has "$ZLIB" && no "older zlib1g deb kept (would downgrade 1.3.2-4 -> 1.3.2-3)" || ok "older zlib1g deb skipped"
has "$GCC"  && no "same-version libgcc-s1 deb kept" || ok "same-version libgcc-s1 deb skipped"
has "$LZ4"  && ok "newer liblz4-1 deb kept" || no "newer liblz4-1 deb dropped"
has "$LZMA" && ok "config-files-only liblzma5 deb kept" || no "config-files-only liblzma5 deb dropped"
has "$ZSTD" && ok "not-installed zstd deb kept" || no "not-installed zstd deb dropped"

# The hook must hand dpkg -i the filtered list, never the raw pool debs.
if grep -nE '^[[:space:]]*dpkg -i[^#]*\$ZLIB_DEB' "$HOOK" >/dev/null; then
    no "10-our-kernel.sh still runs dpkg -i on the raw \$ZLIB_DEB"
else
    ok "10-our-kernel.sh does not dpkg -i the raw pool zlib1g"
fi
if grep -qE 'ncz_debs_to_install "\$LIBGCC_DEB"' "$HOOK"; then
    ok "10-our-kernel.sh filters the zstd dependency set"
else
    no "10-our-kernel.sh does not filter the zstd dependency set through ncz_debs_to_install"
fi

echo "test-kernel-hook-no-downgrade: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
