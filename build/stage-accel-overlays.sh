#!/bin/bash
# stage-accel-overlays.sh -- per-kernel step: build ALL FOUR Sky1 accelerator
# overlays (mali, panthor, vpu, npu) against one Yocto kernel build, install
# them into assets/kernel/<drv>/<kver>/, and refuse to continue unless every
# one of them matches that kernel and today's source.
#
# WHY (operator 2026-10-07): panthor is part of the regular per-kernel build,
# every kernel, every time. Until now release-kernel.sh rebuilt panthor with
# whatever panthor-cix happened to be registered in the build host's DKMS
# and never staged the result, so the panthor.ko in assets/ was a hand step
# and the r200 O6N ended up with mali_kbase.ko only.
#
# What it does:
#   1. runs build/build-accel-overlays.sh in the Yocto container with the
#      kernel's own OE toolchain, against <kernel-work-dir>/build (the real
#      build tree: Module.symvers, .config, generated headers);
#   2. replaces assets/kernel/<drv>/<kver>/ with the result (.ko files plus
#      SOURCE.sha256);
#   3. verify-overlay-modversions.py against that build's Module.symvers and
#      verify-dkms-deb-sources.py --overlays. Any failure exits non-zero.
#
# Usage:
#   build/stage-accel-overlays.sh <kernel-work-dir> <kver>
#     kernel-work-dir  .../work/cixmini-nclawzero-linux/linux-cix-sky1-ncz/<ver>
#                      (must live under $NCZ_YBUILD_DIR, default ~/ybuild)
# Environment: NCZ_YBUILD_DIR, NCZ_YOCTO_IMAGE (default ncz-yocto-y6:trixie).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ "$#" -eq 2 ] || { echo "usage: $0 <kernel-work-dir> <kver>" >&2; exit 2; }
KDIR="$(cd "$1" && pwd)"; KVER="$2"
YB="$(cd "${NCZ_YBUILD_DIR:-$HOME/ybuild}" && pwd)"
IMAGE="${NCZ_YOCTO_IMAGE:-ncz-yocto-y6:trixie}"
DRIVERS=(mali panthor vpu npu)

die() { echo "stage-accel-overlays: FAIL: $*" >&2; exit 1; }

[ -f "$KDIR/build/Module.symvers" ] || die "$KDIR/build/Module.symvers missing (kernel not built?)"
built_kver="$(cat "$KDIR/build/include/config/kernel.release" 2>/dev/null || true)"
[ "$built_kver" = "$KVER" ] || die "$KDIR built '$built_kver', asked for '$KVER'"
case "$KDIR" in "$YB"/*) ;; *) die "$KDIR is not under $YB (set NCZ_YBUILD_DIR)" ;; esac
CKDIR="/ybuild${KDIR#"$YB"}"
TC="$CKDIR/recipe-sysroot-native/usr/bin/aarch64-nclawzero-linux"
[ -x "$KDIR/recipe-sysroot-native/usr/bin/aarch64-nclawzero-linux/aarch64-nclawzero-linux-gcc" ] \
    || die "no OE toolchain under $KDIR/recipe-sysroot-native"

WORK="$ROOT/build/accel-overlays"
OUT_REL="build/accel-overlays/$KVER"
rm -rf "${WORK:?}/$KVER" "$WORK/tmp"
mkdir -p "$WORK/tmp"

echo "== building ${DRIVERS[*]} against $KVER ($KDIR)"
podman run --rm --security-opt label=disable --userns=keep-id \
    -v "$YB:/ybuild" -v "$ROOT:/repo" --entrypoint /bin/bash "$IMAGE" \
    -c "set -e; export TMPDIR=/repo/build/accel-overlays/tmp PATH=$TC:/usr/bin:/bin \
       CROSS_COMPILE=aarch64-nclawzero-linux- ARCH=arm64; cd /repo && \
     bash build/build-accel-overlays.sh $CKDIR/build $KVER /repo/$OUT_REL ${DRIVERS[*]}" \
    || die "accelerator overlay build failed (logs: $ROOT/$OUT_REL/build-<drv>.log)"
rm -rf "$WORK/tmp"

for drv in "${DRIVERS[@]}"; do
    src="$ROOT/$OUT_REL/$drv/$KVER"
    ls "$src"/*.ko >/dev/null 2>&1 || die "$drv produced no .ko"
    [ -s "$src/SOURCE.sha256" ] || die "$drv has no SOURCE.sha256"
    dst="$ROOT/assets/kernel/$drv/$KVER"
    mkdir -p "$dst"
    rm -f "$dst"/*.ko "$dst/SOURCE.sha256"
    cp -a "$src"/*.ko "$src/SOURCE.sha256" "$dst/"
    echo "  staged $(ls "$dst"/*.ko | wc -l) module(s) -> assets/kernel/$drv/$KVER/"
done

python3 "$ROOT/build/verify-overlay-modversions.py" --root "$ROOT" \
    --symvers "$KDIR/build/Module.symvers" --kver "$KVER" \
    || die "overlay CRCs do not match $KDIR/build/Module.symvers"
python3 "$ROOT/build/verify-dkms-deb-sources.py" --root "$ROOT" --overlays "$KVER" \
    || die "overlay SOURCE.sha256 does not match assets/kernel/<drv>"
echo "stage-accel-overlays: OK ($KVER: ${DRIVERS[*]})"
