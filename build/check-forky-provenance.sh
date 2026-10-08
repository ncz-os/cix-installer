#!/bin/bash
# check-forky-provenance.sh -- every package must have exactly one origin:
#   NCZ (our namespace / +ncz builds), a reviewed vendor deb (manifests/vendor-debs.tsv,
#   sha256-pinned), or byte-identical to the pinned Debian forky snapshot
#   (release.conf NCZ_BASE_MIRROR_SNAPSHOT). Anything else -- Ubuntu, another Debian
#   suite or an older snapshot, unknown origin -- fails. No allow-by-reason escape hatch.
# Also audits apt sources/preferences (only forky + the NCZ repo + offline pools + the
# reviewed vendor repos in manifests/vendor-repos.tsv) and os-release (no Ubuntu lineage).
#
# Usage: build/check-forky-provenance.sh SCAN...    (see build/forky-provenance.py --help)
#   --image IMG --work DIR     a finished .img (no root, no loop mount: uses debugfs)
#   --debs DIR | --packages F | --status F | --rootfs DIR | --squashfs F
# The snapshot Packages index is cached under $NCZ_FORKY_INDEX_DIR (default
# ~/.cache/ncz-forky-index/<pin>) and fetched from snapshot.debian.org when missing.
# Exit 0 clean, 1 violations, 2 usage / no index (fails closed).
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="${NCZ_PROVENANCE_ROOT:-$(cd "$HERE/.." && pwd)}"
PIN="$(sed -n 's/^NCZ_BASE_MIRROR_SNAPSHOT="\{0,1\}\([0-9TZ]*\)"\{0,1\}.*/\1/p' "$ROOT/release.conf" | head -1)"
IDX="${NCZ_FORKY_INDEX_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/ncz-forky-index/${PIN:-unpinned}}"
for a in "$@"; do [ "$a" = "--ubuntu-only" ] && exec python3 -I "$HERE/forky-provenance.py" "$@"; done
exec python3 -I "$HERE/forky-provenance.py" --index-dir "$IDX" --fetch-index "$@"
