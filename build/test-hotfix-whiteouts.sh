#!/bin/bash
# test-hotfix-whiteouts.sh -- prove the desktop-hotfix overlay manifest no
# longer uses `opaque opt/singularity` (which dropped package-owned files) and
# instead whiteouts ONLY the stale payload files. Uses real mksquashfs/
# unsquashfs so the previous-layer parse is exercised, not just comm(1).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for t in mksquashfs unsquashfs; do
    command -v "$t" >/dev/null 2>&1 || { echo "SKIP: $t not available"; exit 0; }
done
# shellcheck source=lib/hotfix-overlay-manifest.sh
. "$HERE/lib/hotfix-overlay-manifest.sh"

PASS=0; FAILS=0
ok()  { PASS=$((PASS + 1)); echo "ok   $1"; }
bad() { FAILS=$((FAILS + 1)); echo "FAIL $1"; }

W="$(mktemp -d "${TMPDIR:-/tmp}/hotfix-whiteout-test.XXXXXX")"
trap 'rm -rf "$W"' EXIT

# previous payload: desktop shell + old tool + kept lib, plus a directory that
# disappears entirely this rebuild.
mkdir -p "$W/prev/opt/singularity/bin" "$W/prev/opt/singularity/lib" "$W/prev/opt/singularity/share/old-dir"
printf a > "$W/prev/opt/singularity/bin/singularity-desktop"
printf b > "$W/prev/opt/singularity/bin/old-tool"
printf c > "$W/prev/opt/singularity/lib/keep.so"
printf d > "$W/prev/opt/singularity/share/old-dir/gone"
mksquashfs "$W/prev" "$W/prev.squashfs" -noappend -no-progress >/dev/null 2>&1

PREV="$W/prev.list"
hotfix_capture_prev_files "$W/prev.squashfs" "$PREV"
grep -q 'opt/singularity/bin/old-tool' "$PREV" && ok "capture: lists payload files" || bad "capture: missing old-tool"
grep -q '^opt/singularity$' "$PREV" && bad "capture: included the top directory" || ok "capture: excludes directories"

# new payload: old-tool and the old-dir are gone; desktop + keep remain
mkdir -p "$W/new/opt/singularity/bin" "$W/new/opt/singularity/lib"
printf a2 > "$W/new/opt/singularity/bin/singularity-desktop"
printf c2 > "$W/new/opt/singularity/lib/keep.so"

OUT="$W/manifest"
hotfix_overlay_manifest "$PREV" "$W/new" "$OUT"
if grep -q '^opaque' "$OUT"; then bad "manifest: still contains an opaque entry"; else ok "manifest: no opaque entry"; fi
grep -qxF $'whiteout\topt/singularity/bin/old-tool' "$OUT" && ok "manifest: whiteouts the removed payload file" || bad "manifest: did not whiteout old-tool"
# A directory that vanished must NOT be whited out as a directory (rm -rf risk).
grep -q 'whiteout.*old-dir$' "$OUT" && bad "manifest: whited out a directory" || ok "manifest: never whiteouts a directory"
# The removed directory's file is whiteouted by file path instead.
grep -qxF $'whiteout\topt/singularity/share/old-dir/gone' "$OUT" && ok "manifest: whiteouts the file inside the removed dir" || bad "manifest: missed the removed dir's file"
# Keep.so is present in both: not whited out.
grep -q 'keep.so' "$OUT" && bad "manifest: whited out a file that still exists" || ok "manifest: leaves surviving files alone"
# A package-owned file is not in the previous payload at all, so it can never
# appear (the base layer keeps it under a non-opaque overlay).
grep -q 'plugins/screensaver' "$OUT" && bad "manifest: mentioned a package-owned file" || ok "manifest: never mentions package-owned files"

# No previous layer -> no whiteouts, clean header only.
hotfix_overlay_manifest "" "$W/new" "$W/manifest-empty"
grep -q '^whiteout' "$W/manifest-empty" && bad "empty: emitted a whiteout with no previous layer" || ok "empty: no whiteouts without a previous layer"
grep -q '^# NCZ overlay manifest v1' "$W/manifest-empty" && ok "empty: header present" || bad "empty: header missing"

echo "hotfix-whiteout tests: $PASS passed, $FAILS failed"
[ "$FAILS" = 0 ]
