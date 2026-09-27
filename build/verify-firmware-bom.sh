#!/bin/bash
# Fail unless every firmware-* package published for this build is declared
# in the firmware BOM and present in the offline closure.
set -euo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../release.conf
. "$ROOT/release.conf"
SUITE="${NCZ_BASE_CODENAME:?release.conf did not define NCZ_BASE_CODENAME}"
ARCH="${ARCH:-${NCZ_TARGET_ARCH:-$(dpkg --print-architecture)}}"
MIRROR="$ROOT/build/$SUITE-mirror"
PUBLISHED_INDEX=""
ALLOW_LIST="$ROOT/manifests/firmware-bom.allow"
BOM="$ROOT/manifests/firmware.pkgs"
LABEL=""

usage() {
    cat >&2 <<EOF
usage: $0 [--mirror DIR] [--published-index FILE] [--allow-list FILE]
          [--bom FILE] [--arch ARCH] [--label NAME]

The default publication index is MIRROR/.ncz-published-packages/ARCH/Packages,
captured from apt's local indices by build-forky-mirror.sh.  --published-index
is intended for isolated tests and other already-local archive snapshots.
The allow-list records deliberate firmware-* exclusions, one name per line.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --mirror) MIRROR="${2:-}"; shift 2 ;;
        --published-index) PUBLISHED_INDEX="${2:-}"; shift 2 ;;
        --allow-list) ALLOW_LIST="${2:-}"; shift 2 ;;
        --bom) BOM="${2:-}"; shift 2 ;;
        --arch) ARCH="${2:-}"; shift 2 ;;
        --label) LABEL="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "verify-firmware-bom: ERROR: unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done

LABEL="${LABEL:-$(basename "$MIRROR")}" 
PUBLISHED_INDEX="${PUBLISHED_INDEX:-$MIRROR/.ncz-published-packages/$ARCH/Packages}"
[ -d "$MIRROR/pool" ] || { echo "verify-firmware-bom: ERROR: pool not found: $MIRROR/pool" >&2; exit 2; }
[ -s "$PUBLISHED_INDEX" ] || { echo "verify-firmware-bom: ERROR: local publication index not found: $PUBLISHED_INDEX" >&2; exit 2; }
[ -s "$BOM" ] || { echo "verify-firmware-bom: ERROR: BOM not found: $BOM" >&2; exit 2; }
[ -f "$ALLOW_LIST" ] || { echo "verify-firmware-bom: ERROR: allow-list not found: $ALLOW_LIST" >&2; exit 2; }

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

awk '/^Package: firmware-/ {print $2}' "$PUBLISHED_INDEX" | sort -u > "$TMP/published"
sed 's/#.*//' "$ALLOW_LIST" | awk 'NF {print $1}' | sort -u > "$TMP/allowed"
sed 's/#.*//' "$BOM" | awk 'NF {print $1}' | sort -u > "$TMP/declared"
comm -23 "$TMP/published" "$TMP/allowed" > "$TMP/required"

# Read Package from the archives themselves: filenames are not a trustworthy
# package identity and the generated closure index is what this gate audits.
find "$MIRROR/pool" -type f -name '*.deb' -print0 | \
    xargs -0 -r -n1 dpkg-deb -f 2>/dev/null | \
    awk '/^Package: firmware-/ {print $2}' | sort -u > "$TMP/present"

comm -23 "$TMP/required" "$TMP/declared" > "$TMP/missing-bom"
comm -23 "$TMP/required" "$TMP/present" > "$TMP/missing-pool"
comm -13 "$TMP/published" "$TMP/allowed" > "$TMP/unknown-allowed"

failed=0
if [ -s "$TMP/unknown-allowed" ]; then
    echo "verify-firmware-bom: FAIL: allow-list names package(s) not published for $SUITE/$ARCH:" >&2
    sed 's/^/  /' "$TMP/unknown-allowed" >&2
    failed=1
fi
if [ -s "$TMP/missing-bom" ]; then
    echo "verify-firmware-bom: FAIL: published firmware package(s) missing from $(basename "$BOM"):" >&2
    sed 's/^/  /' "$TMP/missing-bom" >&2
    failed=1
fi
if [ -s "$TMP/missing-pool" ]; then
    echo "verify-firmware-bom: FAIL: $LABEL closure is missing published firmware package(s):" >&2
    sed 's/^/  /' "$TMP/missing-pool" >&2
    failed=1
fi
[ "$failed" -eq 0 ] || exit 1

echo "verify-firmware-bom: PASS: suite=$SUITE arch=$ARCH published=$(wc -l < "$TMP/published") allowed=$(wc -l < "$TMP/allowed") required=$(wc -l < "$TMP/required") declared=$(wc -l < "$TMP/declared") closure=$(wc -l < "$TMP/present")"
