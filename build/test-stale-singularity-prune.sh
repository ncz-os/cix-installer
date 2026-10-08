#!/bin/bash
# test-stale-singularity-prune.sh -- build-squashfs-layers.sh (1) must not leave a
# stale ncz-singularity-desktop deb in the base layer's assets/cix-debs when
# build/sinty-out supplies one, and (2) with NCZ_SINGULARITY_PREBUILT_DEB must
# stage exactly that sha256-checked deb instead of recompiling.
# r201 amd64 image: two Singularity debs (older build 46 MB) shipped in
# /usr/local/lib/cix-installer/assets/cix-debs/.
set -u
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
SCRIPT="${NCZ_SCRIPT_UNDER_TEST:-$HERE/build-squashfs-layers.sh}"
W="$(mktemp -d "${TMPDIR:-/var/tmp}/stale-sing.XXXXXX")"; trap 'rm -rf "$W"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
sudo() { "$@"; }
log() { :; }

# --- 1. base prune block, extracted verbatim -------------------------------
blk="$(sed -n '/BEGIN prune-singularity-from-base/,/END prune-singularity-from-base/p' "$SCRIPT")"
mk() { ROOT="$W/r$1"; WORK="$W/w$1"; D="$WORK/base/usr/local/lib/cix-installer/assets/cix-debs"
       mkdir -p "$ROOT/build/sinty-out" "$D"; : > "$D/ncz-singularity-desktop_old_arm64.deb"; : > "$D/cix-env_1.0.0_arm64.deb"; }
mk 1; : > "$ROOT/build/sinty-out/ncz-singularity-desktop_new_arm64.deb"
if [ -n "$blk" ]; then ( eval "$blk" ); fi
if [ -n "$blk" ] && [ ! -e "$D/ncz-singularity-desktop_old_arm64.deb" ] && [ -e "$D/cix-env_1.0.0_arm64.deb" ]; then
    ok "stale singularity deb removed from base, other debs kept"
else bad "stale singularity deb still in base (or block missing)"; fi
# CLEAN tree: build_base runs before build_singularity_payload in STAGE=all, so
# build/sinty-out is still empty here and the base copy must be pruned anyway.
for arch in amd64 arm64; do
    ROOT="$W/c$arch"; WORK="$W/cw$arch"; D="$WORK/base/usr/local/lib/cix-installer/assets/cix-debs"
    mkdir -p "$ROOT/build" "$D"   # no build/sinty-out at all
    : > "$D/ncz-singularity-desktop_20261006000000+bk0+tgzold00000_$arch.deb"; : > "$D/cix-env_1.0.0_$arch.deb"
    if [ -n "$blk" ]; then ( eval "$blk" ); fi
    if [ -n "$blk" ] && ! ls "$D"/ncz-singularity-desktop_* >/dev/null 2>&1 && [ -e "$D/cix-env_1.0.0_$arch.deb" ]; then
        ok "clean tree ($arch): stale singularity deb pruned from base, other debs kept"
    else bad "clean tree ($arch): base layer still carries an ncz-singularity-desktop deb"; fi
done

# --- 2. prebuilt mode -------------------------------------------------------
fn="$(sed -n '/^build_singularity_payload(){/,/^}/p' "$SCRIPT")"
if ! command -v dpkg-deb >/dev/null 2>&1; then
    echo "SKIP prebuilt-mode cases: dpkg-deb not available"
    echo "--- $pass passed, $fail failed"; [ "$fail" -eq 0 ]; exit
fi
# Real (tiny) debs: prebuilt mode regenerates singularity-opt.tgz from the deb's
# opt/singularity tree, so the fixture must carry one.
mkdeb() {  # arch tag -> prints path
    local a="$1" t="$2" d="$W/fx-$1-$2" n="ncz-singularity-desktop_${2}_${1}.deb"
    mkdir -p "$d/DEBIAN" "$d/opt/singularity/share/backgrounds/singularity" "$d/opt/singularity/lib"
    printf 'Package: ncz-singularity-desktop\nVersion: %s\nArchitecture: %s\nMaintainer: t <t@example.invalid>\nDescription: fixture\n' "$t" "$a" > "$d/DEBIAN/control"
    printf 'wall-%s' "$t" > "$d/opt/singularity/share/backgrounds/singularity/wall.jpg"
    printf 'lib-%s' "$t" > "$d/opt/singularity/lib/libsingularity.so.0"
    mkdir -p "$W/debs"; dpkg-deb --build "$d" "$W/debs/$n" >/dev/null 2>&1; echo "$W/debs/$n"
}
# run <arch> <deb> <sha> -> rc; log in $W/log, tree in $W/p. The tree starts as a
# CLEAN-ish checkout holding a stale deb AND a stale tgz + sidecars from an
# earlier run (the state a re-used build tree is in).
run() {
    ( ROOT="$W/p"; NCZ_TARGET_ARCH="$1"; export NCZ_TARGET_ARCH
      rm -rf "$ROOT"; mkdir -p "$ROOT/build/sinty-out" "$ROOT/assets/cix-debs"
      : > "$ROOT/assets/cix-debs/ncz-singularity-desktop_stale_$1.deb"
      : > "$ROOT/build/sinty-out/ncz-singularity-desktop_stale_$1.deb"
      printf 'STALE' > "$ROOT/build/sinty-out/singularity-opt.tgz"
      : > "$ROOT/build/sinty-out/singularity-opt.tgz.depends"; : > "$ROOT/build/sinty-out/singularity-opt.tgz.sources"
      log() { echo "$*" >> "$W/log"; }
      eval "$fn"
      if [ -n "${2:-}" ]; then export NCZ_SINGULARITY_PREBUILT_DEB="$2"; fi
      if [ -n "${3:-}" ]; then export NCZ_SINGULARITY_PREBUILT_SHA256="$3"; fi
      build_singularity_payload ) >/dev/null 2>&1
}
for arch in amd64 arm64; do
    D1="$(mkdeb $arch 20261007184442+bk0+tgzfc441ab9)"; SHA="$(sha256sum "$D1" | cut -d' ' -f1)"; B="$(basename "$D1")"
    : > "$W/log"; run $arch "$D1" "$SHA"; rc=$?
    n=$(ls "$W/p/assets/cix-debs"/ncz-singularity-desktop_* 2>/dev/null | wc -l)
    if [ $rc = 0 ] && [ "$n" = 1 ] && [ -e "$W/p/build/sinty-out/$B" ] && [ -e "$W/p/assets/cix-debs/$B" ] \
       && ! ls "$W/p/build/sinty-out"/ncz-singularity-desktop_stale_* >/dev/null 2>&1; then
        ok "prebuilt ($arch): deb staged in sinty-out and assets/cix-debs, stale ones removed"
    else bad "prebuilt ($arch) staging wrong (rc=$rc, debs=$n)"; fi
    # tgz consistency: regenerated from THIS deb, sidecars of the old build gone
    T="$W/p/build/sinty-out/singularity-opt.tgz"; X="$W/x-$arch"; rm -rf "$X"; mkdir -p "$X"
    if tar -xzf "$T" -C "$X" --strip-components=5 'opt/singularity/share/backgrounds/singularity/' 2>/dev/null \
       && [ "$(cat "$X/wall.jpg" 2>/dev/null)" = "wall-20261007184442+bk0+tgzfc441ab9" ] \
       && tar -tzf "$T" | grep -q '^opt/singularity/lib/libsingularity.so.0$' \
       && [ ! -e "$T.depends" ] && [ ! -e "$T.sources" ]; then
        ok "prebuilt ($arch): singularity-opt.tgz regenerated from the staged deb, stale sidecars removed"
    else bad "prebuilt ($arch): singularity-opt.tgz is stale or inconsistent with the staged deb"; fi
    # refusals must be loud AND specific, and must leave the tree untouched
    : > "$W/log"; run $arch "$D1" "deadbeef"; rc=$?
    if [ $rc != 0 ] && grep -q 'sha256 .* != expected deadbeef' "$W/log" \
       && [ "$(cat "$W/p/build/sinty-out/singularity-opt.tgz")" = STALE ] && [ -e "$W/p/assets/cix-debs/ncz-singularity-desktop_stale_$arch.deb" ]; then
        ok "wrong sha256 refused with the sha256 mismatch error, tree untouched ($arch)"
    else bad "wrong sha256 not refused for the right reason, or tree modified ($arch, rc=$rc)"; fi
    : > "$W/log"; run $arch "$D1" ""; rc=$?
    if [ $rc != 0 ] && grep -q 'needs NCZ_SINGULARITY_PREBUILT_SHA256' "$W/log"; then ok "deb without sha256 refused ($arch)"
    else bad "deb without sha256 not refused for the right reason ($arch, rc=$rc)"; fi
    : > "$W/log"; run $arch "" "$SHA"; rc=$?
    if [ $rc != 0 ] && grep -q 'NCZ_SINGULARITY_PREBUILT_SHA256 .*NCZ_SINGULARITY_PREBUILT_DEB' "$W/log" \
       && ! grep -q 'rebuilding' "$W/log"; then
        ok "sha256 without a deb path fails loudly instead of recompiling ($arch)"
    else bad "sha256 without a deb path was not refused (silently ignored?) ($arch, rc=$rc)"; fi
    # a deb without an opt/singularity tree cannot yield a tarball: refuse, tree untouched
    BD="$W/fx-bad-$arch"; mkdir -p "$BD/DEBIAN" "$BD/usr/share/x"; : > "$BD/usr/share/x/f"
    printf 'Package: ncz-singularity-desktop\nVersion: 1\nArchitecture: %s\nMaintainer: t <t@example.invalid>\nDescription: fixture\n' "$arch" > "$BD/DEBIAN/control"
    BDEB="$W/debs/bad/ncz-singularity-desktop_1_${arch}.deb"; mkdir -p "$W/debs/bad"; dpkg-deb --build "$BD" "$BDEB" >/dev/null 2>&1
    : > "$W/log"; run $arch "$BDEB" "$(sha256sum "$BDEB" | cut -d' ' -f1)"; rc=$?
    if [ $rc != 0 ] && grep -q 'no usable opt/singularity tree' "$W/log" \
       && [ "$(cat "$W/p/build/sinty-out/singularity-opt.tgz")" = STALE ] && [ -e "$W/p/assets/cix-debs/ncz-singularity-desktop_stale_$arch.deb" ]; then
        ok "deb without an opt/singularity tree refused, tree untouched ($arch)"
    else bad "deb without an opt/singularity tree accepted or tree modified ($arch, rc=$rc)"; fi
    other=amd64; [ $arch = amd64 ] && other=arm64
    O="$(mkdeb $other 20261007184442+bk0+tgzfc441ab9)"
    : > "$W/log"; run $arch "$O" "$(sha256sum "$O" | cut -d' ' -f1)"; rc=$?
    if [ $rc != 0 ] && grep -q "not an ncz-singularity-desktop deb for $arch" "$W/log"; then ok "wrong-arch deb refused ($arch)"
    else bad "wrong-arch deb not refused for the right reason ($arch, rc=$rc)"; fi
done

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
