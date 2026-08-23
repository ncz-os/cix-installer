#!/usr/bin/env bash
# Verify required package seeds are present in the manifest package lists.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="${1:-$REPO/sbom/expected-packages.txt}"
FAILED=0

[ -f "$MANIFEST" ] || { echo "verify-packages: ERROR: manifest not found: $MANIFEST" >&2; exit 2; }

while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue ;; esac
    manifest_file="${line%%:*}"
    package="${line#*:}"
    if [ "$manifest_file" = "$line" ] || [ -z "$manifest_file" ] || [ -z "$package" ]; then
        echo "MALFORMED: $line" >&2
        FAILED=1
        continue
    fi
    file="$REPO/$manifest_file"
    if [ ! -f "$file" ]; then
        echo "MISSING MANIFEST: $manifest_file (required package $package)" >&2
        FAILED=1
        continue
    fi
    if ! grep -vE '^[[:space:]]*(#|$)' "$file" | awk '{print $1}' | grep -qxF "$package"; then
        echo "MISSING PACKAGE: $manifest_file:$package" >&2
        FAILED=1
    fi
done < "$MANIFEST"

if [ "$FAILED" -ne 0 ]; then
    echo "verify-packages: FAIL" >&2
    exit 1
fi

echo "verify-packages: PASS"
