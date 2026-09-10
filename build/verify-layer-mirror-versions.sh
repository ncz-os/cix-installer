#!/usr/bin/env bash
# Refuse to assemble an ISO when a prebuilt squashfs contains an older version
# of an explicit seed package than the offline mirror used to build that layer.
set -euo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAYER=""
POOL=""
LABEL="offline mirror"

usage() {
    echo "usage: $0 --layer FILE --pool DIR [--label NAME]" >&2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --layer) LAYER="${2:-}"; shift 2 ;;
        --pool) POOL="${2:-}"; shift 2 ;;
        --label) LABEL="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done

[ -f "$LAYER" ] || { echo "ERROR: squashfs layer not found: $LAYER" >&2; exit 1; }
[ -d "$POOL" ] || { echo "ERROR: mirror pool not found: $POOL" >&2; exit 1; }
command -v unsquashfs >/dev/null || { echo "ERROR: unsquashfs is required" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if ! unsquashfs -cat "$LAYER" var/lib/dpkg/status > "$tmp/status" 2>/dev/null; then
    echo "ERROR: cannot read var/lib/dpkg/status from $LAYER" >&2
    exit 1
fi

{
    for manifest in "$ROOT/manifests/installer-base.pkgs" "$ROOT/manifests/desktop.pkgs"; do
        [ -s "$manifest" ] || { echo "ERROR: missing manifest: $manifest" >&2; exit 1; }
        sed 's/#.*//' "$manifest" | awk 'NF {print $1}'
    done
} | sort -u > "$tmp/seeds"

awk '
    /^Package: / { pkg=$2 }
    /^Version: / { ver=$2 }
    /^Status: install ok installed$/ { installed=1 }
    /^$/ {
        if (installed && pkg != "" && ver != "") print pkg "\t" ver
        pkg=ver=""; installed=0
    }
    END { if (installed && pkg != "" && ver != "") print pkg "\t" ver }
' "$tmp/status" | sort -u > "$tmp/installed"

failed=0
while IFS="$(printf '\t')" read -r pkg installed_ver; do
    grep -qxF "$pkg" "$tmp/seeds" || continue
    best=""
    while IFS= read -r -d '' deb; do
        [ "$(dpkg-deb -f "$deb" Package 2>/dev/null || true)" = "$pkg" ] || continue
        arch="$(dpkg-deb -f "$deb" Architecture 2>/dev/null || true)"
        case "$arch" in arm64|all) ;; *) continue ;; esac
        ver="$(dpkg-deb -f "$deb" Version)"
        if [ -z "$best" ] || dpkg --compare-versions "$ver" gt "$best"; then
            best="$ver"
        fi
    done < <(find "$POOL" -type f -name "${pkg}_*.deb" -print0)

    # Some installed packages are intentionally absent from a pruned/special
    # pool. Compare only packages for which this mirror publishes a candidate.
    [ -n "$best" ] || continue
    if dpkg --compare-versions "$installed_ver" lt "$best"; then
        echo "verify-layer-mirror-versions: FAIL: $pkg is $installed_ver in $(basename "$LAYER"), but $LABEL contains newer $best" >&2
        failed=1
    fi
done < "$tmp/installed"

if [ "$failed" -ne 0 ]; then
    echo "verify-layer-mirror-versions: rebuild the squashfs layers against the current mirror before assembling the ISO" >&2
    exit 1
fi

echo "verify-layer-mirror-versions: PASS ($(basename "$LAYER") is not older than $LABEL for explicit seed packages)"
