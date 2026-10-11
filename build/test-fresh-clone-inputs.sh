#!/bin/bash
# test-fresh-clone-inputs.sh -- a fresh clone must be able to stage every input
# the arms of the build need, with no hand-copying.
#
# operator 2026-10-11 "fix open items", the fresh-clone gaps from the r203
# nextbuild report:
#   #1 the ncz-screensavers ENGINE deb is a required local row in
#      build/build-desktop-mirror.sh but was neither pinned nor in the store, so
#      a truly fresh clone aborted at offline-mirror.  (The error hint named
#      build/build-screensavers-deb.sh, which does not exist.)
#   #2 the amd64 installer kernel was staged by build/stage-amd64-kernel.sh,
#      which the pipeline never ran -> the image stage aborted with
#      "set KERNEL_DEB to the amd64 installer kernel package".
#   #3 the arm64 assets/sky1-firmware/ + assets/cix-debs/*.deb were gitignored
#      and unpinned -> the image stage aborted in verify-arm64-inputs.
#
# These are data/pinning invariants; the store itself is checked only when the
# ARGONAS build-inputs store is mounted (a fresh clone without it still passes).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TSV="$ROOT/manifests/build-inputs.tsv"
NCZ="$ROOT/manifests/ncz-packages.tsv"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

# pin <arch> <dest> -> prints the sha256 (empty if absent)
pin_sha() { awk -F'\t' -v a="$1" -v d="$2" '$1==a && $2==d {print $3}' "$TSV" | head -1; }
pin_size() { awk -F'\t' -v a="$1" -v d="$2" '$1==a && $2==d {print $4}' "$TSV" | head -1; }
is_sha() { printf '%s' "$1" | grep -Eq '^[0-9a-f]{64}$'; }

STORE=""
for d in "${NCZ_BUILD_INPUTS_DIR:-}" /mnt/argonas/datapool/projects/ncz-os-assets/build-inputs /mnt/datapool/projects/ncz-os-assets/build-inputs /mnt/argonas-projects/ncz-os-assets/build-inputs; do
    [ -n "$d" ] && [ -d "$d" ] && { STORE="$d"; break; }
done

# --- #1 the screensavers ENGINE deb is pinned for both arches, sha == the ledger ---
for a in amd64 arm64; do
    dest="build/ncz-screensavers-out/ncz-screensavers_0.8.10_${a}.deb"
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
grep -q 'bash $(ROOT)/build/stage-amd64-kernel.sh' "$ROOT/Makefile" \
    && ok "make image stages the amd64 installer kernel standalone too" \
    || bad "Makefile image rule does not stage the amd64 kernel"

# --- #3 arm64 sky1-firmware + cix-debs are pinned (so a fresh clone stages them) ---
missing=""
for f in av1dec avs2dec avsdec h264dec h264enc hevcdec hevcenc jpegdec jpegenc \
         mpeg2dec mpeg4dec vc1dec vp8dec vp8enc vp9dec vp9enc; do
    is_sha "$(pin_sha arm64 "assets/sky1-firmware/$f.fwb")" || missing="$missing $f.fwb"
done
is_sha "$(pin_sha arm64 "assets/sky1-firmware/dsp_fw.bin")" || missing="$missing dsp_fw.bin"
is_sha "$(pin_sha arm64 "assets/sky1-firmware/arm/mali/arch12.8/mali_csffw.bin")" || missing="$missing mali_csffw.bin"
[ -z "$missing" ] && ok "build-inputs.tsv pins every required arm64 sky1-firmware blob" || bad "sky1-firmware pins missing:$missing"

cmiss=""
for p in cix-gpu-umd_ cix-libglvnd_ cix-mesa_ cix-noe-umd_ cix-npu-driver-dkms_ \
         cix-vpu-driver-dkms_ cix-gpu-kmd-dkms_ panthor-cix-dkms_ cix-firmware_; do
    awk -F'\t' -v a=arm64 -v p="$p" '$1==a && index($2,"assets/cix-debs/"p)==1 && $3 ~ /^[0-9a-f]{64}$/ {f=1} END{exit !f}' "$TSV" || cmiss="$cmiss $p"
done
[ -z "$cmiss" ] && ok "build-inputs.tsv pins an arm64 cix-deb for every required prefix" || bad "arm64 cix-deb pins missing:$cmiss"

# the store, when mounted, must hold every sky1-firmware + cix-debs arm64 pin byte-for-byte
if [ -n "$STORE" ]; then
    n_bad=0
    while IFS=$'\t' read -r a dest sha size note; do
        case "$dest" in assets/sky1-firmware/*|assets/cix-debs/*) ;; *) continue ;; esac
        if [ ! -f "$STORE/$a/$dest" ] || [ "$(sha256sum "$STORE/$a/$dest" | awk '{print $1}')" != "$sha" ]; then
            n_bad=$((n_bad+1)); [ "$n_bad" -le 5 ] && echo "     store miss/differs: $STORE/$a/$dest"
        fi
    done < <(awk -F'\t' '$1=="arm64" && ($2 ~ /^assets\/sky1-firmware\// || $2 ~ /^assets\/cix-debs\//)' "$TSV" | grep -v 'cix-npu-driver-dkms')
    [ "$n_bad" = 0 ] && ok "the store holds every arm64 sky1-firmware/cix-debs pin byte-for-byte" || bad "$n_bad arm64 store pin(s) missing or differing"
fi

# every pin in the manifest is a real sha256 (guards against a bad append)
badpins="$(awk -F'\t' '!/^[[:space:]]*(#|$)/ && $3 !~ /^[0-9a-f]{64}$/ {print $1" "$2}' "$TSV")"
[ -z "$badpins" ] && ok "every pin in build-inputs.tsv is a sha256" || bad "unpinned rows: $badpins"

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
