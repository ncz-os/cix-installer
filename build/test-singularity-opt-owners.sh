#!/bin/bash
# test-singularity-opt-owners.sh -- prove the payload-swap ownership gate in
# BOTH directions. A guard is only trusted once it has failed on purpose.
#
# Fixture: a synthetic installed root with a real dpkg database
# (var/lib/dpkg/status + info/*.list + info/*.md5sums), /opt/singularity, the
# screensaver-plugin files and two wallpaper-pack collection files. We then:
#
#   * simulate the O6N 2026-10-04 raw swap (mv aside + tar extract) and assert
#     build/verify-singularity-opt-owners.sh FAILS with `missing` (the bug);
#   * run tools/apply-singularity-payload.sh over the same fixture and assert
#     the gate PASSES and the package-owned files are back (the fix);
#   * perturb one package-owned file's bytes and assert the gate FAILS again
#     (content, not just existence);
#   * assert --require-shipping fails when a shipping pack is absent.
#
# Runs as a normal user (both tools support --root); no root, no real dpkg
# install needed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
VERIFIER="$HERE/verify-singularity-opt-owners.sh"
APPLY="$ROOT/tools/apply-singularity-payload.sh"
for t in "$VERIFIER" "$APPLY"; do [ -x "$t" ] || { echo "SKIP: $t not executable"; exit 0; }; done
command -v md5sum >/dev/null || { echo "SKIP: md5sum not available"; exit 0; }

PASS=0; FAILS=0
ok()  { PASS=$((PASS + 1)); echo "ok   $1"; }
bad() { FAILS=$((FAILS + 1)); echo "FAIL $1"; }

W="$(mktemp -d "${TMPDIR:-/tmp}/opt-owners-test.XXXXXX")"
trap 'rm -rf "$W"' EXIT

emit() { # $1=root; writes a healthy fixture
    local r="$1" f
    local d="$r/var/lib/dpkg"
    mkdir -p "$d/info" \
             "$r/opt/singularity/bin" \
             "$r/opt/singularity/lib/singularity/plugins/screensaver" \
             "$r/opt/singularity/share/singularity/wallpaper-collections" \
             "$r/opt/singularity/share/glib-2.0/schemas"
    printf '#!/bin/sh\necho old-shell\n' > "$r/opt/singularity/bin/singularity-desktop"
    chmod 0755 "$r/opt/singularity/bin/singularity-desktop"
    f="$r/opt/singularity/lib/singularity/plugins/screensaver/libscreensaver.so"; echo plug > "$f"
    f="$r/opt/singularity/share/singularity/wallpaper-collections/cygnus-2610.artistpack"; echo art-cygnus > "$f"
    f="$r/opt/singularity/share/singularity/wallpaper-collections/ncz.artistpack"; echo art-ncz > "$f"
    cat > "$d/status" <<'STATUS'
Package: ncz-screensavers-plugin
Status: install ok installed
Version: 0.3.1
Architecture: all
Maintainer: NCZ <ncz@example.invalid>
Description: fixture

Package: ncz-wallpapers-cygnus-2610
Status: install ok installed
Version: 1.0
Architecture: all
Maintainer: NCZ <ncz@example.invalid>
Description: fixture

Package: ncz-wallpapers-ncz
Status: install ok installed
Version: 1.0
Architecture: all
Maintainer: NCZ <ncz@example.invalid>
Description: fixture

STATUS
    # NOTE: dpkg md5sums paths are root-relative (/opt/...), never carrying $r.
    # dpkg .list files also include DIRECTORY entries; the helper must recreate
    # them without recursively copying into an existing directory (nesting bug).
    printf '/opt/singularity/lib/singularity/plugins/screensaver/\n/opt/singularity/lib/singularity/plugins/screensaver/libscreensaver.so\n' > "$d/info/ncz-screensavers-plugin.list"
    printf '%s  /opt/singularity/lib/singularity/plugins/screensaver/libscreensaver.so\n' \
        "$(md5sum "$r/opt/singularity/lib/singularity/plugins/screensaver/libscreensaver.so" | awk '{print $1}')" > "$d/info/ncz-screensavers-plugin.md5sums"
    printf '/opt/singularity/share/singularity/wallpaper-collections/cygnus-2610.artistpack\n' > "$d/info/ncz-wallpapers-cygnus-2610.list"
    printf '%s  /opt/singularity/share/singularity/wallpaper-collections/cygnus-2610.artistpack\n' \
        "$(md5sum "$r/opt/singularity/share/singularity/wallpaper-collections/cygnus-2610.artistpack" | awk '{print $1}')" > "$d/info/ncz-wallpapers-cygnus-2610.md5sums"
    printf '/opt/singularity/share/singularity/wallpaper-collections/ncz.artistpack\n' > "$d/info/ncz-wallpapers-ncz.list"
    printf '%s  /opt/singularity/share/singularity/wallpaper-collections/ncz.artistpack\n' \
        "$(md5sum "$r/opt/singularity/share/singularity/wallpaper-collections/ncz.artistpack" | awk '{print $1}')" > "$d/info/ncz-wallpapers-ncz.md5sums"
}

mkpayload() { # $1=out.tgz
    local t="$W/pay"
    rm -rf "$t"; mkdir -p "$t/opt/singularity/bin" "$t/opt/singularity/share/glib-2.0/schemas" \
        "$t/opt/singularity/lib/singularity/plugins/screensaver"
    printf '#!/bin/sh\necho new-shell\n' > "$t/opt/singularity/bin/singularity-desktop"
    chmod 0755 "$t/opt/singularity/bin/singularity-desktop"
    cat > "$t/opt/singularity/share/glib-2.0/schemas/dev.sinty.desktop.gschema.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<schemalist>
  <schema id="dev.sinty.desktop" path="/dev/sinty/desktop/">
    <key name="pinned-apps" type="as"><default>[]</default><summary>p</summary></key>
  </schema>
</schemalist>
XML
    tar -C "$t" -czf "$1" opt/singularity
}

# ---- 1. the raw swap drops the files: the gate must FAIL ---------------------
R="$W/root"; emit "$R"
mkpayload "$W/payload.tgz"
mv "$R/opt/singularity" "$R/opt/singularity.old"
tar -C "$R" -xzf "$W/payload.tgz"
if "$VERIFIER" --root "$R" --quiet >"$W/out" 2>&1; then
    bad "raw swap: gate PASSED but package-owned files were dropped (should FAIL)"
else
    if grep -q 'missing' "$W/out"; then ok "raw swap: gate FAILS on the dropped plugin/pack files"; else bad "raw swap: gate failed but no 'missing' line"; fi
fi
# put the tree back so the helper sees a healthy pre-state
rm -rf "$R/opt/singularity"; mv "$R/opt/singularity.old" "$R/opt/singularity"

# ---- 2. the sanctioned helper restores them: the gate must PASS --------------
if "$APPLY" --root "$R" --payload "$W/payload.tgz" --yes >"$W/apply.out" 2>&1; then
    ok "helper: apply exited 0"
else
    bad "helper: apply failed: $(tail -3 "$W/apply.out")"
fi
if "$VERIFIER" --root "$R" --quiet >"$W/out" 2>&1; then
    ok "helper: gate PASSES after the sanctioned apply"
else
    bad "helper: gate still FAILS after apply: $(tail -3 "$W/out")"
fi
for f in \
    "$R/opt/singularity/lib/singularity/plugins/screensaver/libscreensaver.so" \
    "$R/opt/singularity/share/singularity/wallpaper-collections/cygnus-2610.artistpack" \
    "$R/opt/singularity/share/singularity/wallpaper-collections/ncz.artistpack"; do
    [ -e "$f" ] && ok "helper: restored ${f##*/}" || bad "helper: did not restore $f"
done
if grep -qx '#!/bin/sh' "$R/opt/singularity/bin/singularity-desktop" && grep -q 'new-shell' "$R/opt/singularity/bin/singularity-desktop"; then
    ok "helper: payload file is the NEW shell (swap actually happened)"
else
    bad "helper: payload file was not updated"
fi
# The package-owned DIRECTORY entry must not nest (cp -a dir into existing dir).
[ ! -e "$R/opt/singularity/lib/singularity/plugins/screensaver/screensaver" ] \
    && ok "helper: package-owned directory restored without nesting" \
    || bad "helper: restoring a directory nested it (cp -a dir dst)"
_revert=""
for _n in "$R"/opt/singularity.ncz-backup-*/REVERT.txt; do [ -f "$_n" ] && _revert="$_n"; done
[ -n "$_revert" ] && ok "helper: wrote a revert note" || bad "helper: no revert note"

# ---- 3. content drift is caught, not just absence -----------------------------
echo tampered > "$R/opt/singularity/share/singularity/wallpaper-collections/cygnus-2610.artistpack"
if "$VERIFIER" --root "$R" --quiet >"$W/out" 2>&1; then
    bad "content drift: gate PASSED a modified package file (should FAIL)"
else
    ok "content drift: gate FAILS on a modified package file"
    grep -q 'cygnus-2610' "$W/out" && ok "content drift: failure names the package" || bad "content drift: failure does not name the package"
fi

# ---- 4. --require-shipping enforces the release contract ---------------------
if "$VERIFIER" --root "$R" --require-shipping --quiet >"$W/out" 2>&1; then
    bad "require-shipping: PASSED with four shipping packs absent (should FAIL)"
else
    ok "require-shipping: FAILS when shipping wallpaper packs are absent"
fi

# ---- 5. dry-run changes nothing ---------------------------------------------
before="$(find "$R/opt/singularity" -type f | LC_ALL=C sort | xargs -r md5sum | md5sum)"
"$APPLY" --root "$R" --payload "$W/payload.tgz" --dry-run >/dev/null 2>&1
after="$(find "$R/opt/singularity" -type f | LC_ALL=C sort | xargs -r md5sum | md5sum)"
[ "$before" = "$after" ] && ok "dry-run: leaves the tree untouched" || bad "dry-run: modified the tree"

echo "singularity-opt-owners tests: $PASS passed, $FAILS failed"
[ "$FAILS" = 0 ]
