#!/bin/bash
# test-public-binaries-manifest.sh - every binary listed in manifests/public-binaries.tsv exists with
# the recorded size and sha256, no listed file is 100 MiB or larger, and the listed files carry a
# licence and a source field. Run from the repository root or anywhere inside it.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; M="$ROOT/manifests/public-binaries.tsv"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "ok   $1"; }
bad(){ fail=$((fail+1)); echo "FAIL $1"; }
[ -f "$M" ] || { echo "FAIL manifest missing"; exit 1; }
rows=$(tail -n +2 "$M" | grep -c .)
[ "$rows" -gt 0 ] && ok "manifest has $rows rows" || bad "manifest is empty"
while IFS=$'\t' read -r path size sha what lic src; do
    [ -f "$ROOT/$path" ] || { bad "$path: listed file is missing"; continue; }
    [ "$(stat -c %s "$ROOT/$path" 2>/dev/null || stat -f %z "$ROOT/$path")" = "$size" ] || { bad "$path: size differs"; continue; }
    [ "$(sha256sum "$ROOT/$path" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$ROOT/$path" | cut -d' ' -f1)" = "$sha" ] || { bad "$path: sha256 differs"; continue; }
    [ "$size" -lt 104857600 ] || { bad "$path: 100 MiB or larger"; continue; }
    [ -n "$lic" ] && [ -n "$src" ] || { bad "$path: licence or source field empty"; continue; }
    ok "$path"
done < <(tail -n +2 "$M")
echo "test-public-binaries-manifest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
