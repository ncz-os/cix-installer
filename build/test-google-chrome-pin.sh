#!/bin/bash
# test-google-chrome-pin.sh -- both mirror builders take Google Chrome only from the staged,
# pinned deb (build/lib/google-chrome-pin.sh), never from Google's live "current stable".
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $*"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $*"; }
command -v dpkg-deb >/dev/null 2>&1 || { echo "SKIP: dpkg-deb not available"; exit 0; }
T="$(mktemp -d "${TMPDIR:-/var/tmp}/chromepin.XXXXXX")"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/r/manifests" "$T/r/assets/google-chrome" "$T/p/DEBIAN"
printf 'Package: google-chrome-stable\nVersion: 9.9-1\nArchitecture: amd64\nMaintainer: t <t@example.invalid>\nDescription: t\n' > "$T/p/DEBIAN/control"
dpkg-deb --root-owner-group -b "$T/p" "$T/r/assets/google-chrome/google-chrome-stable_9.9-1_amd64.deb" >/dev/null
sha="$(sha256sum "$T/r/assets/google-chrome/google-chrome-stable_9.9-1_amd64.deb" | cut -d' ' -f1)"
printf 'google-chrome-stable\t9.9-1\tamd64\tGoogle LLC\thttps://example.invalid/x.deb\t%s\tvendor\n' "$sha" > "$T/r/manifests/vendor-debs.tsv"
. "$ROOT/build/lib/google-chrome-pin.sh"
got="$(ncz_chrome_staged_deb "$T/r" amd64 2>/dev/null)" && [ -f "$got" ] && ok "the pinned staged deb is selected" || bad "pinned staged deb not selected"
ncz_chrome_staged_deb "$T/r" arm64 >/dev/null 2>&1 && bad "an arch without a pin row was accepted" || ok "an arch without a pin row fails"
printf 'google-chrome-stable\t9.9-1\tamd64\tGoogle LLC\thttps://example.invalid/x.deb\t%s\tvendor\n' "$(printf '0%.0s' {1..64})" > "$T/r/manifests/vendor-debs.tsv"
ncz_chrome_staged_deb "$T/r" amd64 >/dev/null 2>&1 && bad "a staged deb with another sha256 was accepted" || ok "a staged deb that does not match the pin fails"
for b in build-vendor-mirror.sh build-desktop-mirror.sh; do
    grep -q 'ncz_chrome_staged_deb' "$ROOT/build/$b" && ok "$b uses the pinned staged deb" || bad "$b does not use the pin helper"
    grep -q 'dl.google.com/linux/chrome/deb/dists\|\$GOOGLE_CHROME_URL/dists/stable\|\$GOOGLE_CHROME_URL stable main' "$ROOT/build/$b" && bad "$b still resolves Chrome from Google's live index" || ok "$b has no live Google index"
done
awk -F'\t' '$1=="google-chrome-stable"{print $3" "$2" "$6}' "$ROOT/manifests/vendor-debs.tsv" | while read -r a v s; do
    grep -q "assets/google-chrome/google-chrome-stable_${v}_${a}.deb	$s	" "$ROOT/manifests/build-inputs.tsv" && echo "ok   $a pin $v is a staged build input with the same sha256" || echo "FAIL $a pin $v is not staged with the same sha256"
done > "$T/rows"
cat "$T/rows"; PASS=$((PASS + $(grep -c '^ok' "$T/rows"))); FAIL=$((FAIL + $(grep -c '^FAIL' "$T/rows")))
echo "test-google-chrome-pin: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
