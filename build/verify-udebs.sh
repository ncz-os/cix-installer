#!/usr/bin/env bash
# Verify required installer-environment udebs are asserted by the image build.
#
# The raw GPT image build (build/build-installer-image.sh) stages the d-i udeb
# pool through build/iso/patch-debootstrap-stub.py, whose REQUIRED_UDEB_DI list
# is the assertion that fails the build when a required udeb is missing from
# the substrate pool. Every udeb in the SBOM manifest must be named there.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="${1:-$REPO/sbom/expected-udebs.txt}"
GATE="$REPO/build/iso/patch-debootstrap-stub.py"
FAILED=0

[ -f "$MANIFEST" ] || { echo "verify-udebs: ERROR: manifest not found: $MANIFEST" >&2; exit 2; }
[ -f "$GATE" ] || { echo "verify-udebs: ERROR: udeb gate not found: $GATE" >&2; exit 2; }

REQUIRED_LINE="$(grep -E '^REQUIRED_UDEB_DI = \[' "$GATE" || true)"
[ -n "$REQUIRED_LINE" ] || { echo "verify-udebs: ERROR: REQUIRED_UDEB_DI list not found in $GATE" >&2; exit 2; }

while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue ;; esac
    package="${line%%[[:space:]]*}"
    if ! printf '%s\n' "$REQUIRED_LINE" | grep -qF "\"$package\""; then
        echo "MISSING UDEB REQUIREMENT: build/iso/patch-debootstrap-stub.py REQUIRED_UDEB_DI:$package" >&2
        FAILED=1
    fi
done < "$MANIFEST"

if [ "$FAILED" -ne 0 ]; then
    echo "verify-udebs: FAIL" >&2
    exit 1
fi

echo "verify-udebs: PASS"
