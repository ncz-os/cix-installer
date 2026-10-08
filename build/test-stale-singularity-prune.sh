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
printf 'deb-bytes' > "$W/ncz-singularity-desktop_20261007184442+bk0+tgzfc441ab9_arm64.deb"
SHA="$(sha256sum "$W/ncz-singularity-desktop_20261007184442+bk0+tgzfc441ab9_arm64.deb" | cut -d' ' -f1)"
run() { ( ROOT="$W/p"; NCZ_TARGET_ARCH=arm64; mkdir -p "$ROOT/build/sinty-out" "$ROOT/assets/cix-debs"
          : > "$ROOT/assets/cix-debs/ncz-singularity-desktop_stale_arm64.deb"
          eval "$fn"; export NCZ_SINGULARITY_PREBUILT_DEB="$1" NCZ_SINGULARITY_PREBUILT_SHA256="$2"
          build_singularity_payload ) >/dev/null 2>&1; }
D1="$W/ncz-singularity-desktop_20261007184442+bk0+tgzfc441ab9_arm64.deb"
rm -rf "$W/p"; run "$D1" "$SHA"; rc=$?
n=$(ls "$W/p/assets/cix-debs"/ncz-singularity-desktop_* 2>/dev/null | wc -l)
if [ $rc = 0 ] && [ "$n" = 1 ] && [ -e "$W/p/build/sinty-out/$(basename "$D1")" ] && [ -e "$W/p/assets/cix-debs/$(basename "$D1")" ]; then
    ok "prebuilt deb staged in sinty-out and assets/cix-debs, stale one removed"
else bad "prebuilt staging wrong (rc=$rc, debs=$n)"; fi
rm -rf "$W/p"; run "$D1" "deadbeef"; rc=$?
if [ $rc != 0 ]; then ok "wrong sha256 refused"; else bad "wrong sha256 accepted"; fi

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
