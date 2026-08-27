#!/usr/bin/env bash
# Verify required installer-environment udebs are tracked by the ISO builder.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="${1:-$REPO/sbom/expected-udebs.txt}"
FAILED=0

[ -f "$MANIFEST" ] || { echo "verify-udebs: ERROR: manifest not found: $MANIFEST" >&2; exit 2; }

while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue ;; esac
    package="${line%%[[:space:]]*}"
    if ! grep -Eq "(^|[ (])$package([ )]|$)" "$REPO/build/build-iso-di.sh"; then
        echo "MISSING UDEB REQUIREMENT: build/build-iso-di.sh:$package" >&2
        FAILED=1
    fi
done < "$MANIFEST"

if [ "$FAILED" -ne 0 ]; then
    echo "verify-udebs: FAIL" >&2
    exit 1
fi

echo "verify-udebs: PASS"
