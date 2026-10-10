#!/bin/bash
# check-substrate-pin.sh -- build preflight for the base pin.
#
# Verifies, for the target arch, that:
#   * manifests/base.pin has a row and is well formed;
#   * release.conf NCZ_BASE_MIRROR_SNAPSHOT EQUALS base.pin's snapshot (the
#     snapshot must be DERIVED from the substrate, not chosen independently);
#   * the pinned substrate's archive date is not older than
#     NCZ_SUBSTRATE_MAX_AGE_DAYS (default 8);
#   * the measured coverage of the substrate by the pinned snapshot is at least
#     NCZ_SUBSTRATE_MIN_COVERAGE (default 99).
#
# A build must never ship a substrate the pinned snapshot does not authorize.
# Run `build/refresh-substrate.sh --arch <a>` to refresh.
#
# Usage: build/check-substrate-pin.sh [ARCH]     Exit 0 ok, 1 finding, 2 usage.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ARCH="${1:-${NCZ_TARGET_ARCH:-$(dpkg --print-architecture 2>/dev/null)}}"
PIN="$ROOT/manifests/base.pin"
MAX_AGE_DAYS="${NCZ_SUBSTRATE_MAX_AGE_DAYS:-8}"
MIN_COV="${NCZ_SUBSTRATE_MIN_COVERAGE:-99}"
rc=0
bad() { echo "substrate-pin: FAIL: $*" >&2; rc=1; }

[ -f "$PIN" ] || { echo "substrate-pin: FAIL: missing $PIN (run build/refresh-substrate.sh)" >&2; exit 1; }
row="$(awk -F'\t' -v a="$ARCH" '$1==a{print; exit}' "$PIN")"
[ -n "$row" ] || { echo "substrate-pin: FAIL: no '$ARCH' row in $PIN (run build/refresh-substrate.sh --arch $ARCH)" >&2; exit 1; }
sub_sha="$(printf '%s' "$row" | cut -f2)"
sub_date="$(printf '%s' "$row" | cut -f3)"
pin_snap="$(printf '%s' "$row" | cut -f4)"
cov="$(printf '%s' "$row" | cut -f5)"

# release.conf's snapshot must equal the derived one.
. "$ROOT/build/lib/mirror-apt-opts.sh"
conf_snap="$(ncz_pin_snapshot "$ROOT" 2>/dev/null || true)"
if [ -z "$conf_snap" ]; then
    bad "release.conf NCZ_BASE_MIRROR_SNAPSHOT is missing/malformed"
elif [ "$conf_snap" != "$pin_snap" ]; then
    bad "release.conf snapshot '$conf_snap' != base.pin snapshot '$pin_snap' (re-run refresh-substrate.sh)"
else
    echo "substrate-pin: OK: release.conf snapshot == base.pin ($pin_snap)"
fi

# freshness
sub_epoch="$(date -u -d "$sub_date" +%s 2>/dev/null || echo 0)"
now="$(date -u +%s)"
if [ "$sub_epoch" -le 0 ]; then
    bad "cannot parse substrate date '$sub_date'"
else
    age_days=$(( (now - sub_epoch) / 86400 ))
    if [ "$age_days" -gt "$MAX_AGE_DAYS" ]; then
        bad "substrate ($sub_date) is ${age_days}d old (> ${MAX_AGE_DAYS}d); refresh required"
    else
        echo "substrate-pin: OK: substrate ${age_days}d old (<= ${MAX_AGE_DAYS}d)"
    fi
fi

# coverage
awk -v c="$cov" -v m="$MIN_COV" 'BEGIN{exit !(c+0 >= m+0)}' \
  && echo "substrate-pin: OK: coverage ${cov}% >= ${MIN_COV}%" \
  || bad "coverage ${cov}% < ${MIN_COV}%: the pinned netinst is not authorized by the pinned snapshot (run refresh-substrate.sh; a newer weekly is needed)"

echo "substrate-pin: sha=${sub_sha:0:8} date=${sub_date} snapshot=${pin_snap} coverage=${cov}%"
exit "$rc"
