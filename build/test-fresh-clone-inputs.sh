#!/bin/bash
# test-fresh-clone-inputs.sh -- a fresh clone must be able to stage every input
# the arms of the build need, with no hand-copying.
#
# 2026-10-11 "fix open items", the fresh-clone gaps from the r203
# nextbuild report:
#   #1 the ncz-screensavers ENGINE deb is a required local row in
#      build/build-desktop-mirror.sh but was neither pinned nor in the store, so
#      a truly fresh clone aborted at offline-mirror.  (The error hint named
#      build/build-screensavers-deb.sh, which does not exist.)
#   #2 the amd64 installer kernel was staged by build/stage-amd64-kernel.sh,
#      which the pipeline never ran -> the image stage aborted with
#      "set KERNEL_DEB to the amd64 installer kernel package".
#   #3 the arm64 assets/sky1-firmware/ + assets/cix-debs/*.deb were gitignored
#      and unpinned -> the image stage aborted in verify-arm64-inputs.  They are
#      now two pinned tarballs (manifests/build-inputs.tsv) materialized by
#      build/stage-arm64-assets.sh.
#
# The store checks run only when the build-inputs store is configured and mounted
# (a fresh clone without it still passes); the extraction test runs unless
# zstd/GNU-tar are unavailable.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TSV="$ROOT/manifests/build-inputs.tsv"
NCZ="$ROOT/manifests/ncz-packages.tsv"
T="$(mktemp -d "${TMPDIR:-/var/tmp}/freshclone.XXXXXX")"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

pin_sha() { awk -F'\t' -v a="$1" -v d="$2" '$1==a && $2==d {print $3}' "$TSV" | head -1; }
pin_size() { awk -F'\t' -v a="$1" -v d="$2" '$1==a && $2==d {print $4}' "$TSV" | head -1; }
is_sha() { printf '%s' "$1" | grep -Eq '^[0-9a-f]{64}$'; }

# Store: NCZ_BUILD_INPUTS_DIR, else ~/.config/ncz/build-inputs-dir (build/lib/ncz-site.sh).
STORE="$(. "$ROOT/build/lib/ncz-site.sh"; ncz_site_value NCZ_BUILD_INPUTS_DIR build-inputs-dir)"
[ -n "$STORE" ] && [ -d "$STORE" ] || STORE=""

# --- #1 the screensavers ENGINE deb is pinned for both arches, sha == the ledger ---
for a in amd64 arm64; do
    ver="$(awk -F'\t' -v a="$a" '$1=="ncz-screensavers" && $3==a {print $2}' "$NCZ" | head -1)"
    dest="build/ncz-screensavers-out/ncz-screensavers_${ver}_${a}.deb"
    sha="$(pin_sha "$a" "$dest")"; size="$(pin_size "$a" "$dest")"
    led="$(awk -F'\t' -v a="$a" '$1=="ncz-screensavers" && $3==a {print $4}' "$NCZ" | head -1)"
    if is_sha "$sha" && [ "${size:-0}" -gt 1000 ] && [ "$sha" = "$led" ]; then
        ok "build-inputs.tsv pins the ncz-screensavers engine deb $a (sha256 == ncz-packages.tsv)"
    else bad "no valid $a engine-deb pin (sha='$sha' ledger='$led' size='$size')"; fi
    if [ -n "$STORE" ]; then
        if [ -f "$STORE/$a/$dest" ] && [ "$(sha256sum "$STORE/$a/$dest" | awk '{print $1}')" = "$sha" ]; then
            ok "the store holds the $a engine deb (sha256 matches)"
        else bad "store $STORE/$a/$dest missing or differs from the pin"; fi
    fi
done
if grep -q 'build-screensavers-deb.sh' "$ROOT/build/build-desktop-mirror.sh"; then
    bad "build-desktop-mirror.sh still hints at the non-existent build/build-screensavers-deb.sh"
else ok "build-desktop-mirror.sh no longer names the non-existent build-screensavers-deb.sh"; fi
grep -q 'stage the pinned deb: build/stage-build-inputs.sh --arch' "$ROOT/build/build-desktop-mirror.sh" \
    && ok "build-desktop-mirror.sh names build/stage-build-inputs.sh as the fix" \
    || bad "build-desktop-mirror.sh does not name the stager"

# --- #2 the pipeline / make image stage the amd64 installer kernel ---
grep -q 'bash build/stage-amd64-kernel.sh' "$ROOT/build/build-image.sh" \
    && grep -q '\[ "$ARCH" = amd64 \]' "$ROOT/build/build-image.sh" \
    && ok "build/build-image.sh stage-inputs runs build/stage-amd64-kernel.sh for amd64" \
    || bad "build-image.sh does not stage the amd64 installer kernel"
# The image target deliberately does NOT stage the kernel (its own comment:
# "...staged via build/stage-amd64-kernel.sh, never via this target"); the
# pipeline's stage-inputs stage owns all raw-input staging, so there is exactly
# one site and no duplicated work.
grep -q 'build/stage-screensaver-plugin.sh' "$ROOT/build/build-image.sh" \
    && ok "build-image.sh stage-inputs stages the pinned screensaver settings plugin" \
    || bad "build-image.sh does not stage the screensaver settings plugin"

# --- #3 the arm64 asset groups are two pinned tarballs, materialized by the pipeline ---
for dest in assets/sky1-firmware.tar.zst assets/cix-debs.tar.zst; do
    sha="$(pin_sha arm64 "$dest")"; size="$(pin_size arm64 "$dest")"
    if is_sha "$sha" && [ "${size:-0}" -gt 0 ]; then
        ok "build-inputs.tsv pins the arm64 asset tarball $dest ($size B)"
    else bad "no valid arm64 tarball pin for $dest (sha='$sha' size='$size')"; fi
    if [ -n "$STORE" ]; then
        if [ -f "$STORE/arm64/$dest" ] && [ "$(sha256sum "$STORE/arm64/$dest" | awk '{print $1}')" = "$sha" ]; then
            ok "the store holds $dest (sha256 matches)"
        else bad "store $STORE/arm64/$dest missing or differs from the pin"; fi
    fi
done
grep -q 'bash build/stage-arm64-assets.sh' "$ROOT/build/build-image.sh" \
    && ok "build-image.sh stage-inputs runs build/stage-arm64-assets.sh for arm64" \
    || bad "build-image.sh does not materialize the arm64 asset groups"

# functional: stage-arm64-assets.sh verifies the pin and extracts, refusing a tampered tarball
if command -v zstd >/dev/null 2>&1 && tar --zstd -tf /dev/null >/dev/null 2>&1; then
    A="$T/tree"; mkdir -p "$A/build" "$A/manifests" "$A/assets" "$T/src/sky1-firmware" "$T/src/cix-debs"
    cp "$ROOT/build/stage-arm64-assets.sh" "$A/build/"
    echo fw > "$T/src/sky1-firmware/dsp_fw.bin"; echo deb > "$T/src/cix-debs/x_arm64.deb"
    ( cd "$T/src" && tar --zstd -cf "$A/assets/sky1-firmware.tar.zst" sky1-firmware && tar --zstd -cf "$A/assets/cix-debs.tar.zst" cix-debs )
    s1="$(sha256sum "$A/assets/sky1-firmware.tar.zst" | awk '{print $1}')"
    s2="$(sha256sum "$A/assets/cix-debs.tar.zst" | awk '{print $1}')"
    printf 'arm64\tassets/sky1-firmware.tar.zst\t%s\t10\tt\narm64\tassets/cix-debs.tar.zst\t%s\t10\tt\n' "$s1" "$s2" > "$A/manifests/build-inputs.tsv"
    if bash "$A/build/stage-arm64-assets.sh" >"$T/o1" 2>&1 && [ -f "$A/assets/sky1-firmware/dsp_fw.bin" ] && [ -f "$A/assets/cix-debs/x_arm64.deb" ]; then
        ok "stage-arm64-assets.sh extracts both pinned archives"
    else bad "stage-arm64-assets.sh did not extract the fixtures"; cat "$T/o1"; fi
    rm -rf "$A/assets/sky1-firmware"; echo x >> "$A/assets/sky1-firmware.tar.zst"
    if bash "$A/build/stage-arm64-assets.sh" >"$T/o2" 2>&1; then
        bad "stage-arm64-assets.sh accepted a tampered tarball"
    else ok "stage-arm64-assets.sh refuses a tampered tarball"; fi
else
    echo "SKIP extraction test: zstd/GNU-tar --zstd unavailable on this host"
fi

# --- #4 the pinned substrate can be materialized into a fresh clone's downloads/ ---
# r203/amd64 RC5 finding A: a fresh clone (empty downloads/) hit
# "[download] SUBSTRATE ROTATED" because the 01 refresh-substrate stage verified
# the pin under --substrate pinned and returned WITHOUT restoring the pinned ISO.
# build/stage-substrate.sh now owns the restore and the pipeline calls it.
[ -x "$ROOT/build/stage-substrate.sh" ] \
    && ok "build/stage-substrate.sh present (fresh-clone substrate stager)" \
    || bad "build/stage-substrate.sh missing (a fresh clone cannot stage the pinned substrate)"
grep -q 'build/stage-substrate.sh' "$ROOT/build/build-image.sh" \
    && ok "build-image.sh refresh-substrate restores the pinned substrate on a fresh clone" \
    || bad "build-image.sh does not call build/stage-substrate.sh"
# functional: copy the pinned ISO from a cache dir (sha256-verified), be idempotent,
# and refuse a rotated/tampered ISO or an absent pin.
SS="$T/ss"; mkdir -p "$SS/build" "$SS/manifests" "$SS/downloads" "$SS/cache"
cp "$ROOT/build/stage-substrate.sh" "$SS/build/"
printf 'FAKE-ISO-BYTES-123a250b' > "$SS/cache/fake.iso"
iso_sha="$(sha256sum "$SS/cache/fake.iso" | awk '{print $1}')"
cache_iso="$SS/cache/debian-testing-amd64-netinst-20261010-${iso_sha:0:8}.iso"
mv "$SS/cache/fake.iso" "$cache_iso"
printf '# arch\tsha\tdate\tsnapshot\tcov\tsrc\namd64\t%s\tMon, 05 Oct 2026 02:11:49 UTC\t20261005T120000Z\t100.0\thttps://x\n' "$iso_sha" > "$SS/manifests/base.pin"
if NCZ_SUBSTRATE_CACHE_DIRS="$SS/cache" bash "$SS/build/stage-substrate.sh" --arch amd64 --check >/dev/null 2>&1; then
    bad "stage-substrate --check passed with nothing staged"
else ok "stage-substrate --check fails fast when the substrate is not staged"; fi
if NCZ_SUBSTRATE_CACHE_DIRS="$SS/cache" bash "$SS/build/stage-substrate.sh" --arch amd64 >"$T/ss1" 2>&1 \
   && [ "$(sha256sum "$SS/downloads/debian-testing-amd64-netinst.iso" | awk '{print $1}')" = "$iso_sha" ]; then
    ok "stage-substrate.sh stages the pinned ISO from the cache (sha256 verified)"
else bad "stage-substrate.sh did not stage the pinned ISO"; cat "$T/ss1"; fi
if NCZ_SUBSTRATE_CACHE_DIRS="$SS/cache" bash "$SS/build/stage-substrate.sh" --arch amd64 >/dev/null 2>&1; then
    ok "stage-substrate.sh is idempotent when already staged"
else bad "stage-substrate.sh not idempotent"; fi
echo x >> "$cache_iso"
rm -f "$SS/downloads/debian-testing-amd64-netinst.iso"
if NCZ_SUBSTRATE_CACHE_DIRS="$SS/cache" bash "$SS/build/stage-substrate.sh" --arch amd64 >/dev/null 2>&1; then
    bad "stage-substrate.sh accepted a rotated/tampered ISO"
else ok "stage-substrate.sh refuses a rotated/tampered ISO"; fi

# every pin in the manifest is a real sha256 (guards against a bad append)
badpins="$(awk -F'\t' '!/^[[:space:]]*(#|$)/ && $3 !~ /^[0-9a-f]{64}$/ {print $1" "$2}' "$TSV")"
[ -z "$badpins" ] && ok "every pin in build-inputs.tsv is a sha256" || bad "unpinned rows: $badpins"

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
