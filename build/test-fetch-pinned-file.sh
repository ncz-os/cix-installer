#!/bin/bash
# test-fetch-pinned-file.sh -- behavioural tests for build/lib/fetch-pinned-file.sh
#
# M9 step 1 (docs/BUILD-STABILITY.md, "Pin and cache the network inputs"): fetch a URL
# into a cache only when its sha256 matches the pin.  The helper must copy a verified
# cache hit without touching the network; on a miss it must download to a temp file,
# verify, then rename; on a mismatch it must remove the temp file, leave DEST untouched
# and exit non-zero naming both hashes.
#
# Every URL is a file:// URL into a local directory: no network is required.
#
# Cases:
#   hit      -- cache holds the pinned bytes; copy succeeds, dest is exact
#   miss     -- cold cache; downloads, verifies, renames; cache is populated
#   mismatch -- downloaded bytes fail the pin; temp removed, dest untouched,
#               rc != 0, both hashes named
#   missdir  -- cache dir does not exist; created, download succeeds
#   corrupt  -- cache file exists but carries the WRONG hash (stale/poisoned entry);
#               never served; re-downloaded and replaced with the correct bytes
#   interrupt-- the download itself fails (404); dest untouched, rc != 0,
#               no temp file left behind
#   args     -- empty pin / non-hex pin / missing url / missing dest are refused
#
# Usage: bash build/test-fetch-pinned-file.sh    Exit 0 = all cases pass.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
T="$(mktemp -d "${TMPDIR:-$HOME}/.fetch-pinned-file-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; return 0; }
sha() { sha256sum "$1" | awk '{print $1}'; }

for t in curl sha256sum; do
    command -v "$t" >/dev/null 2>&1 || { echo "FAIL: required test tool not available: $t" >&2; exit 1; }
done

# shellcheck source=lib/fetch-pinned-file.sh
. "$HERE/lib/fetch-pinned-file.sh"

# --- fixture files served over file:// (no network) -------------------------
mkdir -p "$T/srv"
printf 'pinned substrate bytes\n' > "$T/srv/good.deb"
printf 'tampered bytes\n'        > "$T/srv/bad.deb"
GOOD_SHA="$(sha "$T/srv/good.deb")"
BAD_SHA="$(sha "$T/srv/bad.deb")"
URL_GOOD="file://$T/srv/good.deb"
URL_BAD="file://$T/srv/bad.deb"
URL_MISSING="file://$T/srv/does-not-exist.deb"

echo "== hit: cache holds the pinned bytes =="
mkdir -p "$T/c1"
cp "$T/srv/good.deb" "$T/c1/good.deb"
out="$(ncz_fetch_pinned_file "$URL_GOOD" "$GOOD_SHA" "$T/d1" "$T/c1" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(sha "$T/d1")" = "$GOOD_SHA" ]; then
    ok "cache hit copies the pinned file (rc=$rc)"
else
    bad "cache hit failed: rc=$rc" "$out"
fi
grep -qi "cache" <<<"$out" && ok "  the success message says it came from cache" || bad "  cache not named in output" "$out"

echo "== miss: cold cache downloads, verifies, renames =="
mkdir -p "$T/c2"
out="$(ncz_fetch_pinned_file "$URL_GOOD" "$GOOD_SHA" "$T/d2" "$T/c2" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(sha "$T/d2")" = "$GOOD_SHA" ]; then
    ok "cold-cache download lands on the pinned file (rc=$rc)"
else
    bad "cold-cache download failed: rc=$rc" "$out"
fi
if [ "$(sha "$T/c2/good.deb")" = "$GOOD_SHA" ]; then
    ok "the cache was populated with the verified bytes"
else
    bad "cache file missing or wrong after miss"
fi

echo "== mismatch: wrong download is refused, dest untouched, both hashes named =="
mkdir -p "$T/c3"; mkdir -p "$T/parent3"
SENTINEL="$T/parent3/d3"
printf 'untouched\n' > "$SENTINEL"
out="$(ncz_fetch_pinned_file "$URL_BAD" "$GOOD_SHA" "$SENTINEL" "$T/c3" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && [ "$(cat "$SENTINEL")" = "untouched" ]; then
    ok "mismatch exits non-zero ($rc) and leaves DEST untouched"
else
    bad "mismatch handling wrong: rc=$rc" "$out"
fi
grep -q "$GOOD_SHA" <<<"$out" && ok "  expected hash is named" || bad "  expected hash missing from message" "$out"
grep -q "$BAD_SHA" <<<"$out" && ok "  actual hash is named" || bad "  actual hash missing from message" "$out"
if ls "$T/c3"/bad.deb* >/dev/null 2>&1; then
    bad "temp file left behind: $(ls "$T/c3")"
else
    ok "  temp file removed"
fi
if [ -e "$T/c3/bad.deb" ]; then
    bad "mismatch stored in cache"
else
    ok "  cache entry not stored on mismatch"
fi

echo "== missdir: missing cache dir is created =="
out="$(ncz_fetch_pinned_file "$URL_GOOD" "$GOOD_SHA" "$T/d4" "$T/c4" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(sha "$T/d4")" = "$GOOD_SHA" ] && [ -f "$T/c4/good.deb" ]; then
    ok "missing cache dir is created and the download stored (rc=$rc)"
else
    bad "missing cache dir failed: rc=$rc" "$out"
fi

echo "== corrupt cache: a cache file with the wrong hash is never served =="
mkdir -p "$T/c5"
cp "$T/srv/bad.deb" "$T/c5/good.deb"   # wrong bytes under the cached name
SENTINEL="$T/d5"
printf 'sentinel\n' > "$SENTINEL"
out="$(ncz_fetch_pinned_file "$URL_GOOD" "$GOOD_SHA" "$SENTINEL" "$T/c5" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(sha "$SENTINEL")" = "$GOOD_SHA" ]; then
    ok "corrupt cache entry replaced by a verified download (rc=$rc)"
else
    bad "corrupt cache entry mishandled: rc=$rc" "$out"
fi
[ "$(sha "$T/c5/good.deb")" = "$GOOD_SHA" ] && ok "  the cache now holds the correct bytes" || bad "  cache entry not corrected"

echo "== interrupted download: URL 404 leaves no dest, no temp, non-zero rc =="
mkdir -p "$T/c6"
SENTINEL="$T/d6"
printf 'sentinel\n' > "$SENTINEL"
out="$(ncz_fetch_pinned_file "$URL_MISSING" "$GOOD_SHA" "$SENTINEL" "$T/c6" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && [ "$(cat "$SENTINEL")" = "sentinel" ]; then
    ok "download failure exits non-zero ($rc) and leaves DEST untouched"
else
    bad "download failure mishandled: rc=$rc" "$out"
fi
if find "$T/c6" -mindepth 1 | grep -q .; then
    bad "leftover files in cache dir: $(find "$T/c6" -mindepth 1)"
else
    ok "  no temp files left in the cache dir"
fi

echo "== argument refusal =="
out="$(ncz_fetch_pinned_file "$URL_GOOD" "" "$T/x" "$T/cx" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "empty pin refused (rc=$rc)" || bad "empty pin accepted" "$out"
out="$(ncz_fetch_pinned_file "$URL_GOOD" "not-a-hash" "$T/x" "$T/cx" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "non-hex pin refused (rc=$rc)" || bad "non-hex pin accepted" "$out"
out="$(ncz_fetch_pinned_file "" "$GOOD_SHA" "$T/x" "$T/cx" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "empty URL refused (rc=$rc)" || bad "empty URL accepted" "$out"
out="$(ncz_fetch_pinned_file "$URL_GOOD" "$GOOD_SHA" "" "$T/cx" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "empty DEST refused (rc=$rc)" || bad "empty DEST accepted" "$out"

echo "== cache-hit copy failure returns non-zero =="
mkdir -p "$T/c7"
cp "$T/srv/good.deb" "$T/c7/good.deb"   # primed valid cache entry
out="$(ncz_fetch_pinned_file "$URL_GOOD" "$GOOD_SHA" "$T/no-such-dir-$$/d7" "$T/c7" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
    ok "cache-hit copy failure exits non-zero ($rc)"
else
    bad "cache-hit copy failure returned success" "$out"
fi
grep -q "cannot copy" <<<"$out" && ok "  error names the failed copy" || bad "  copy error missing from message" "$out"

echo "== hostile basename is refused =="
out="$(ncz_fetch_pinned_file "file://$T/srv/.." "$GOOD_SHA" "$T/x7" "$T/c7x" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
    ok "basename '..' refused (rc=$rc)"
else
    bad "basename '..' accepted" "$out"
fi
if [ -e "$T/c7x/.." ] && [ ! -d "$T/c7x" ]; then
    bad "cache dir escaped"
else
    ok "  cache dir not escaped"
fi

echo "test-fetch-pinned-file: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
