#!/bin/bash
# check-preseed-mirror-sync.sh — assert preseed.cfg's hardcoded mirror block
# still agrees with release.conf.
#
# WHY THIS EXISTS (2026-09-24): release.conf owns NCZ_BASE_MIRROR_SNAPSHOT and
# build/pin-forky-snapshot.sh bumps it. preseed.cfg carries the SAME snapshot
# as a hardcoded "mirror/http/directory" string, in a different file, with no
# templating step between them -- the raw-GPT pipeline copies preseed.cfg
# verbatim (see commit 073be1a, which notes exactly this). So the two can drift
# silently, and the failure surfaces as d-i's choose-mirror fetching a
# DIFFERENT archive state than the squashfs was built from: an install that
# looks fine and is quietly inconsistent, on the operator's hardware.
#
# Run it as a build gate. patch-initrd-t2-kernel.py calls it before baking
# preseed.cfg into the initrd, and pin-forky-snapshot.sh calls it after a bump.
#
# Usage: build/check-preseed-mirror-sync.sh [--fix]
#   (no args)  verify; exit 1 and say what disagrees
#   --fix      rewrite preseed.cfg's mirror block to match release.conf
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
# shellcheck source=../release.conf
. release.conf

PRESEED=preseed/preseed.cfg
FIX=0
[ "${1:-}" = "--fix" ] && FIX=1

: "${NCZ_BASE_MIRROR:?release.conf must define NCZ_BASE_MIRROR}"
: "${NCZ_BASE_CODENAME:?release.conf must define NCZ_BASE_CODENAME}"

# https://snapshot.debian.org/archive/debian/<SNAP>  ->  host + directory
_noscheme="${NCZ_BASE_MIRROR#*://}"
WANT_HOST="${_noscheme%%/*}"
WANT_DIR="/${_noscheme#*/}"
[ "$WANT_DIR" = "/$_noscheme" ] && WANT_DIR="/"

# question -> expected value
declare -A WANT=(
    [mirror/http/hostname]="$WANT_HOST"
    [mirror/http/directory]="$WANT_DIR"
    [mirror/http/suite]="$NCZ_BASE_CODENAME"
    [mirror/codename]="$NCZ_BASE_CODENAME"
    [mirror/suite]="$NCZ_BASE_CODENAME"
    [mirror/udeb/suite]="$NCZ_BASE_CODENAME"
    [cdrom/suite]="$NCZ_BASE_CODENAME"
    [cdrom/codename]="$NCZ_BASE_CODENAME"
)

get_value() {  # get_value <question>
    sed -n "s|^d-i $1 string \(.*\)\$|\1|p" "$PRESEED" | head -1
}

bad=0
for q in "${!WANT[@]}"; do
    got="$(get_value "$q")"
    want="${WANT[$q]}"
    if [ -z "$got" ]; then
        echo "[mirror-sync] MISSING: $PRESEED has no 'd-i $q string' line (expected '$want')" >&2
        bad=1
        continue
    fi
    if [ "$got" != "$want" ]; then
        echo "[mirror-sync] DRIFT: $q" >&2
        echo "                 preseed.cfg : $got" >&2
        echo "                 release.conf: $want" >&2
        bad=1
        if [ "$FIX" -eq 1 ]; then
            # `|` as the sed delimiter: every value here is a path or hostname.
            sed -i "s|^d-i $q string .*\$|d-i $q string $want|" "$PRESEED"
            echo "[mirror-sync] fixed: $q -> $want"
        fi
    fi
done

if [ "$bad" -eq 0 ]; then
    echo "[mirror-sync] OK: preseed.cfg mirror block matches release.conf (${WANT_HOST}${WANT_DIR}, suite ${NCZ_BASE_CODENAME})"
    exit 0
fi

if [ "$FIX" -eq 1 ]; then
    echo "[mirror-sync] rewrote $PRESEED -- review the diff and commit it"
    exit 0
fi

cat >&2 <<EOF
[mirror-sync] FAILED: $PRESEED and release.conf disagree.

  release.conf is the source of truth for the pinned snapshot; preseed.cfg
  carries a hardcoded copy because the pipeline stages it verbatim with no
  templating step. Fix with:

      build/check-preseed-mirror-sync.sh --fix

  Letting these drift means d-i's choose-mirror fetches a different archive
  state than the squashfs was built from.
EOF
exit 1
