#!/usr/bin/env bash
# Verify gitignored build assets against the declared SBOM-style manifest.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="${1:-$REPO/sbom/expected-assets.txt}"
FAILED=0

[ -f "$MANIFEST" ] || { echo "verify-assets: ERROR: manifest not found: $MANIFEST" >&2; exit 2; }

size_of() {
    stat -c %s "$1"
}

while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue ;; esac
    IFS='|' read -r rel expected_size expected_sha extra <<EOF
$line
EOF
    if [ -n "${extra:-}" ] || [ -z "${rel:-}" ] || [ -z "${expected_size:-}" ] || [ -z "${expected_sha:-}" ]; then
        echo "MALFORMED: $line" >&2
        FAILED=1
        continue
    fi
    path="$REPO/$rel"
    if [ ! -e "$path" ]; then
        echo "MISSING: $rel (expected sha256 $expected_sha, file absent)" >&2
        FAILED=1
        continue
    fi
    if [ ! -f "$path" ]; then
        echo "NOT A FILE: $rel" >&2
        FAILED=1
        continue
    fi
    actual_size="$(size_of "$path")"
    if [ "$actual_size" != "$expected_size" ]; then
        echo "SIZE MISMATCH: $rel (expected $expected_size bytes, got $actual_size bytes)" >&2
        FAILED=1
        continue
    fi
    actual_sha="$(sha256sum "$path" | awk '{print $1}')"
    if [ "$actual_sha" != "$expected_sha" ]; then
        echo "SHA256 MISMATCH: $rel (expected $expected_sha, got $actual_sha)" >&2
        FAILED=1
    fi
done < "$MANIFEST"

if [ "$FAILED" -ne 0 ]; then
    echo "verify-assets: FAIL" >&2
    exit 1
fi

echo "verify-assets: PASS"
