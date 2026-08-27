#!/usr/bin/env bash
# Hard-fail when locally built packages staged for the ISO do not match the
# freshly built .debs in build/kernel-debs and other local build output dirs.
set -euo pipefail
export LC_ALL=C

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DEB_DIRS=("$REPO/build/kernel-debs")
POOL=""
LABEL="pool"

usage() {
    cat <<'EOF'
Usage: build/verify-local-package-versions.sh --pool PATH [--kernel-debs PATH] [--debs-dir PATH] [--label NAME]

Compares locally built package versions in build/kernel-debs, plus any extra
--debs-dir paths, against the
actual .debs present in a vendor/offline/staged ISO pool. A mismatch, missing
package, or multiple versions of the same local package is a hard failure.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --pool) POOL="${2:-}"; shift 2 ;;
        --kernel-debs) DEB_DIRS=("${2:-}"); shift 2 ;;
        --debs-dir) DEB_DIRS+=("${2:-}"); shift 2 ;;
        --label) LABEL="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "verify-local-package-versions: ERROR: unknown arg: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[ -n "$POOL" ] || { echo "verify-local-package-versions: ERROR: --pool required" >&2; exit 2; }
[ -d "$POOL" ] || { echo "verify-local-package-versions: ERROR: pool not found: $POOL" >&2; exit 2; }
for dir in "${DEB_DIRS[@]}"; do
    [ -n "$dir" ] || { echo "verify-local-package-versions: ERROR: empty deb dir argument" >&2; exit 2; }
    [ -d "$dir" ] || { echo "verify-local-package-versions: ERROR: deb dir not found: $dir" >&2; exit 2; }
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

expected="$tmp/expected"
: > "$expected"
for dir in "${DEB_DIRS[@]}"; do
    compgen -G "$dir/*.deb" >/dev/null || continue
    for deb in "$dir"/*.deb; do
        pkg="$(dpkg-deb -f "$deb" Package)"
        ver="$(dpkg-deb -f "$deb" Version)"
        arch="$(dpkg-deb -f "$deb" Architecture)"
        printf '%s\t%s\t%s\t%s\n' "$pkg" "$arch" "$ver" "$deb" >> "$expected"
    done
done
[ -s "$expected" ] || {
    echo "verify-local-package-versions: ERROR: no *.deb found in local build dirs: ${DEB_DIRS[*]}" >&2
    exit 1
}

# Collapse duplicates in build/kernel-debs to the highest Debian version for
# each package/arch. This lets a developer keep older build outputs locally
# while still pinning the ISO to the freshest package version.
expected_best="$tmp/expected-best"
awk -F '\t' '{print $1 "\t" $2}' "$expected" | sort -u | while IFS="$(printf '\t')" read -r pkg arch; do
    best=""
    best_deb=""
    while IFS="$(printf '\t')" read -r epkg earch ever edeb; do
        [ "$epkg" = "$pkg" ] && [ "$earch" = "$arch" ] || continue
        if [ -z "$best" ] || dpkg --compare-versions "$ever" gt "$best"; then
            best="$ever"
            best_deb="$edeb"
        fi
    done < "$expected"
    printf '%s\t%s\t%s\t%s\n' "$pkg" "$arch" "$best" "$best_deb"
done > "$expected_best"

failed=0
echo "verify-local-package-versions: checking $LABEL against local deb dirs: ${DEB_DIRS[*]}"

while IFS="$(printf '\t')" read -r pkg arch expected_ver expected_deb; do
    found="$tmp/found-$pkg-$arch"
    : > "$found"
    while IFS= read -r -d '' deb; do
        actual_pkg="$(dpkg-deb -f "$deb" Package 2>/dev/null || true)"
        actual_arch="$(dpkg-deb -f "$deb" Architecture 2>/dev/null || true)"
        [ "$actual_pkg" = "$pkg" ] && [ "$actual_arch" = "$arch" ] || continue
        actual_ver="$(dpkg-deb -f "$deb" Version)"
        printf '%s\t%s\n' "$actual_ver" "$deb" >> "$found"
    done < <(find "$POOL" -type f -name "${pkg}_*.deb" -print0)

    if [ ! -s "$found" ]; then
        echo "verify-local-package-versions: FAIL: $pkg/$arch missing from $LABEL (expected $expected_ver from $(basename "$expected_deb"))" >&2
        failed=1
        continue
    fi

    versions="$(cut -f1 "$found" | sort -u)"
    version_count="$(printf '%s\n' "$versions" | sed '/^$/d' | wc -l | tr -d ' ')"
    if [ "$version_count" != "1" ]; then
        echo "verify-local-package-versions: FAIL: $pkg/$arch has multiple versions in $LABEL; expected only $expected_ver" >&2
        sed 's/^/  /' "$found" >&2
        failed=1
        continue
    fi

    actual_ver="$versions"
    if [ "$actual_ver" != "$expected_ver" ]; then
        echo "verify-local-package-versions: FAIL: $pkg/$arch version mismatch in $LABEL: expected $expected_ver from $(basename "$expected_deb"), got $actual_ver" >&2
        sed 's/^/  /' "$found" >&2
        failed=1
        continue
    fi

    echo "verify-local-package-versions: ok: $pkg/$arch=$actual_ver"
done < "$expected_best"

if [ "$failed" -ne 0 ]; then
    echo "verify-local-package-versions: FAIL" >&2
    exit 1
fi

echo "verify-local-package-versions: PASS"
