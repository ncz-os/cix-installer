#!/bin/bash
# download-iso.sh — fetch the NCZ-OS cix-installer ISO from GitLab's generic
# package registry (split into 3 parts to stay under GitLab's upload size
# cap, see README.md -> "Current ISO") and reassemble it into one file.
#
# Usage: bash download-iso.sh [version] [output-file]
#   version      package version, e.g. 26.6-r193 (default: latest tag on the
#                ncz-os/cix-installer GitLab release page)
#   output-file  where to write the reassembled ISO
#                (default: nclawzero-installer-cixmini-<date-from-name>.iso)
set -euo pipefail

PROJECT_ID=81838641
PACKAGE=ncz-iso
BASE="https://gitlab.com/api/v4/projects/${PROJECT_ID}/packages/generic/${PACKAGE}"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    VERSION=$(curl -fsSL "https://gitlab.com/api/v4/projects/${PROJECT_ID}/releases" \
        | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['tag_name'].lstrip('v'))")
    echo "[download-iso] no version given -- using latest release tag: $VERSION"
fi

echo "[download-iso] listing parts for $PACKAGE/$VERSION"
FILES=$(curl -fsSL "https://gitlab.com/api/v4/projects/${PROJECT_ID}/packages?package_name=${PACKAGE}&package_version=${VERSION}" \
    | python3 -c "
import json, sys
pkgs = json.load(sys.stdin)
if not pkgs:
    print('ERROR: no package found for version $VERSION', file=sys.stderr)
    sys.exit(1)
print(pkgs[0]['id'])
")
PART_NAMES=$(curl -fsSL "https://gitlab.com/api/v4/projects/${PROJECT_ID}/packages/${FILES}/package_files" \
    | python3 -c "
import json, sys
files = json.load(sys.stdin)
names = sorted(f['file_name'] for f in files)
print('\n'.join(names))
")

if [ -z "$PART_NAMES" ]; then
    echo "ERROR: no files found for $PACKAGE/$VERSION" >&2
    exit 1
fi

OUT="${2:-}"
if [ -z "$OUT" ]; then
    # strip the trailing .partNN / .rNNN-partNN suffix to get the real ISO name
    FIRST=$(echo "$PART_NAMES" | head -1)
    OUT=$(echo "$FIRST" | sed -E 's/\.[a-zA-Z0-9_-]*part[0-9]+$//')
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "[download-iso] parts to fetch:"
echo "$PART_NAMES" | sed 's/^/  /'

: > "$OUT"
while IFS= read -r name; do
    echo "[download-iso] downloading $name"
    curl -fsSL "${BASE}/${VERSION}/${name}" -o "$TMPDIR/$name"
    cat "$TMPDIR/$name" >> "$OUT"
    rm -f "$TMPDIR/$name"
done <<< "$PART_NAMES"

echo "[download-iso] reassembled -> $OUT"
echo "[download-iso] sha256:"
sha256sum "$OUT" 2>/dev/null || shasum -a 256 "$OUT"
