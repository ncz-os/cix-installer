#!/bin/bash
# build-accel-overlays.sh -- rebuild every Sky1 accelerator DKMS overlay
# (mali GPU, panthor GPU, VPU amvx, NPU aipu) against ONE kernel build's
# staged headers, exactly the way DKMS would on the target.
#
# Why this exists: the kernel checklist (0c) says a new kernel means new
# overlays for ALL FOUR, from THIS build's headers (1). Until now that was a
# hand procedure (r278: "bitbake cix-gpu-kmd for mali, host gcc M= for the
# rest"), so each rebuild could differ in source, flags or compiler. This
# script drives the MAKE[0] line of each driver's own assets/kernel/<drv>/
# dkms.conf, the same line DKMS runs, over a copy of the same src/ tree
# build/build-dkms-debs.sh packages. The overlay and the DKMS package cannot
# drift apart.
#
# Usage:
#   build/build-accel-overlays.sh <kernel-build-dir> <kver> <out-dir> [drv...]
#     kernel-build-dir  a prepared tree (headers-dir/lib/modules/<kver>/build)
#     out-dir           receives <drv>/<kver>/*.ko plus OVERLAYS.txt
#   Toolchain: CROSS_COMPILE / CC in the environment are honored. mali's gpu.mk
#   hard-codes aarch64-linux-gnu-, so put a matching prefix on PATH when the
#   kernel was built with a different triplet (the r279 run does).
#
# Verification per module: vermagic must start with <kver>, the .ko must be
# uncompressed ELF with a GNU build-id, and every undefined symbol must be
# satisfied by <kernel-build-dir>/Module.symvers or a sibling overlay module.
set -euo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ "$#" -ge 3 ] || { echo "usage: $0 <kernel-build-dir> <kver> <out-dir> [mali panthor vpu npu]" >&2; exit 2; }
KB="$(cd "$1" && pwd)"; KVER="$2"; OUT="$3"; shift 3
DRIVERS=("$@"); [ ${#DRIVERS[@]} -eq 0 ] && DRIVERS=(mali panthor vpu npu)
[ -f "$KB/Module.symvers" ] || { echo "ERROR: $KB/Module.symvers missing (not a prepared build tree)" >&2; exit 1; }
mkdir -p "$OUT"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/accel-overlays.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

stage_src() {   # mirror build/build-dkms-debs.sh's staging rule
    local drv="$1" dst="$2" asset="$ROOT/assets/kernel/$1"
    mkdir -p "$dst"
    if [ "$drv" = panthor ]; then
        cp -a "$asset"/. "$dst"/
        rm -rf "$dst"/patches "$dst"/[0-9]*.*-* 2>/dev/null || true
        find "$dst" -name '*.ko' -delete
    else
        cp -a "$asset/src"/. "$dst"/
        cp -a "$asset/dkms.conf" "$dst/dkms.conf"
    fi
}

: > "$OUT/OVERLAYS.txt"
for drv in "${DRIVERS[@]}"; do
    conf="$ROOT/assets/kernel/$drv/dkms.conf"
    [ -f "$conf" ] || { echo "ERROR: no $conf" >&2; exit 1; }
    (
        # dkms.conf is shell; DKMS sources it with these two variables set.
        # shellcheck disable=SC2034
        kernel_source_dir="$KB"
        # shellcheck disable=SC2034
        dkms_tree="$WORK/dkms"
        # shellcheck source=/dev/null
        . "$conf"
        build="$dkms_tree/$PACKAGE_NAME/$PACKAGE_VERSION/build"
        stage_src "$drv" "$build"
        echo "== $drv ($PACKAGE_NAME $PACKAGE_VERSION) against $KVER"
        ( cd "$build" && eval "${MAKE[0]}" ) > "$OUT/build-$drv.log" 2>&1 \
            || { tail -30 "$OUT/build-$drv.log" >&2; echo "ERROR: $drv build failed (log: $OUT/build-$drv.log)" >&2; exit 1; }
        mkdir -p "$OUT/$drv/$KVER"
        i=0
        while [ -n "${BUILT_MODULE_NAME[$i]:-}" ]; do
            ko="$build/${BUILT_MODULE_LOCATION[$i]:-.}/${BUILT_MODULE_NAME[$i]}.ko"
            [ -f "$ko" ] || { echo "ERROR: $drv did not produce $ko" >&2; exit 1; }
            cp "$ko" "$OUT/$drv/$KVER/"
            i=$((i + 1))
        done
    )
done

# --- verification over everything just built --------------------------------
fail=0
all_exports="$WORK/exports"
awk '{print $2}' "$KB/Module.symvers" > "$all_exports"
for ko in "$OUT"/*/"$KVER"/*.ko; do
    nm --defined-only "$ko" 2>/dev/null | awk '$2 ~ /[TDRB]/ {print $3}' >> "$all_exports"
done
sort -u -o "$all_exports" "$all_exports"
for ko in "$OUT"/*/"$KVER"/*.ko; do
    rel="${ko#"$OUT"/}"
    # .modinfo read directly: kmod's modinfo is absent from build containers
    vm="$(objcopy -O binary --only-section=.modinfo "$ko" /dev/stdout 2>/dev/null \
          | tr '\0' '\n' | sed -n 's/^vermagic=//p' | head -1)"
    bid="$(readelf -n "$ko" 2>/dev/null | sed -n 's/.*Build ID: //p' | head -1)"
    unres="$(nm -u "$ko" | awk '{print $2}' | sort -u | comm -23 - "$all_exports" | tr '\n' ' ')"
    sha="$(sha256sum "$ko" | cut -d' ' -f1)"
    case "$vm" in "$KVER "*) ;; *) echo "FAIL $rel: vermagic '$vm' does not start with $KVER" >&2; fail=1 ;; esac
    [ -n "$bid" ] || { echo "FAIL $rel: no GNU build-id" >&2; fail=1; }
    head -c4 "$ko" | grep -q "ELF" || { echo "FAIL $rel: not an uncompressed ELF" >&2; fail=1; }
    [ -z "$unres" ] || { echo "FAIL $rel: unresolved symbols: $unres" >&2; fail=1; }
    printf '%s  vermagic=%s  build-id=%s  sha256=%s\n' "$rel" "$vm" "$bid" "$sha" | tee -a "$OUT/OVERLAYS.txt"
done
[ "$fail" -eq 0 ] || { echo "accel overlays: FAIL" >&2; exit 1; }
echo "accel overlays: OK (${#DRIVERS[@]} driver(s), $(find "$OUT" -name '*.ko' | wc -l) module(s)) -> $OUT"
