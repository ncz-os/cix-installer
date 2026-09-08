#!/bin/bash
# release-kernel.sh — build the COMPLETE NCZ Sky1 kernel stack for one KVER.
#
# WHY THIS EXISTS.
#
# The pieces were all here and each one worked, but nothing ran them as a set,
# so a kernel bump shipped whatever the operator remembered to rebuild. The
# 7.2.0 -> 7.2.3 bump proved the cost: every accelerator module is
# VERMAGIC-LOCKED to the kernel release string, so changing KVER silently
# invalidated all four of them at once. Only the manifest check caught it, and
# only for mali:
#
#   ERROR: [edge] no mali overlay for kver=7.2.3-sky1-ncz
#          -- this board would boot with no /dev/mali0
#
# The kernel debs built happily with ZERO GPU modules inside them. A board
# installed from those debs comes up on software rendering, which looks like a
# working system until someone asks why everything is slow.
#
# So this script builds the whole stack in one place, in dependency order, and
# refuses to continue when a step produces something that does not match the
# kernel it was built against.
#
# WHAT THE STACK IS (measured on a shipped O6N, `dkms status`):
#
#   aipu/6.2.0                 NPU    (armchina zhouyi-v3)
#   cix-gpu-kmd/1.0            GPU    (mali_kbase + memory_group_manager +
#                                      protected_memory_allocator -- all three,
#                                      kbase defers with -517 without the MGM)
#   panthor-cix/7.2.0          GPU    (the second, alternative GPU stack)
#   cix-vpu-driver/1.0.2-ncz1  VPU    (amvx)
#
# Both GPU stacks ship. They are alternatives selected at boot by
# ncz-gpu-switcher, not a primary and a spare -- r245 shipped a working mali
# entry and an Oopsing panthor entry precisely because only the default was
# tested.
#
# Usage:
#   BUILD_REV=r263 build/release-kernel.sh
#   BUILD_REV=r263 build/release-kernel.sh --skip-kernel   # kernel already built
#   BUILD_REV=r263 build/release-kernel.sh --skip-kernel --skip-mali-build # resume after GPU build
#   BUILD_REV=r263 build/release-kernel.sh --no-dkms-debs
#
# Exit non-zero on the first failure. Nothing here publishes or pushes: the
# output is a staged asset dir, a set of .debs and a passing manifest, and a
# human decides whether that ships.
set -uo pipefail

# modinfo/dkms live in /usr/sbin, which is NOT on PATH for a non-interactive
# ssh/script shell on this system (confirmed missing on both cixmini and O6N)
# -- a script meant to run identically everywhere cannot depend on the
# caller's interactive PATH having it.
export PATH="$PATH:/usr/sbin:/sbin"

# NEVER manually xz-compress a .ko file (or write one into place already
# compressed) anywhere in this pipeline. The kernel's in-kernel XZ
# decompressor requires --check=crc32 (or --check=none); a plain "xz -k
# module.ko" uses xz's CLI default --check=crc64, which the kernel cannot
# read. Symptom: modprobe "Invalid argument" + dmesg "decompression failed
# with status 6" -- easy to misread as a vermagic/ABI mismatch, it is not.
# Leave modules UNCOMPRESSED (plain .ko); kmod loads both .ko and .ko.xz
# fine, so there is no need to compress at all. Measured 2026-09-07, O6N.

REV="${BUILD_REV:?set BUILD_REV, e.g. BUILD_REV=r263}"
REPO="${NCZ_INSTALLER_DIR:-$HOME/isobuild/cix-installer}"
YOCTO="${NCZ_YOCTO_DIR:-$HOME/yocto-work}"
RUNNER="${NCZ_YOCTO_RUNNER:-$YOCTO/y6-run-ultra.sh}"
WORKROOT="${NCZ_WORKROOT:-$HOME/ybuild/tmp/work/cixmini-nclawzero-linux}"
EXTRA_CONF="${NCZ_BITBAKE_EXTRA_CONF:-}"

SKIP_KERNEL=0; DO_DKMS=1; SKIP_GPU=0; SKIP_MALI=0
while [ $# -gt 0 ]; do
    case "$1" in
        --skip-kernel)  SKIP_KERNEL=1; shift ;;
        --skip-mali-build) SKIP_MALI=1; shift ;;
        --skip-gpu-kmd) SKIP_GPU=1;    shift ;;
        --no-dkms-debs) DO_DKMS=0;     shift ;;
        -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

step() { printf '\n=== %s\n' "$*"; }
die()  { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
bb()   { ( cd "$YOCTO" && "$RUNNER" "bitbake ${EXTRA_CONF:+-R $EXTRA_CONF }$*" ); }

# Debian packaging needs a Debian userspace. ULTRA is Fedora Asahi and has no
# dpkg-deb -- that is exactly how a kernel got "packaged" into nothing once,
# with build-kernel-debs.sh dying on "dpkg-deb: command not found" AFTER the
# gates had already passed. Run those steps in the isobuild container when the
# host cannot do it, instead of letting the caller find out at packaging time.
DEB_IMAGE="${NCZ_DEB_IMAGE:-localhost/ncz-isobuild:trixie}"
deb_run() {  # deb_run <shell command, cwd = repo root>
    if command -v dpkg-deb >/dev/null 2>&1; then
        ( cd "$REPO" && bash -c "$1" )
    else
        podman run --rm --security-opt label=disable --userns=keep-id \
            -v "$REPO:/repo" --entrypoint /bin/bash "$DEB_IMAGE" \
            -c "cd /repo && $1"
    fi
}

[ -d "$REPO" ]   || die "no cix-installer at $REPO"
[ -x "$RUNNER" ] || die "no yocto runner at $RUNNER"

# ---------------------------------------------------------------- 1. kernel
if [ "$SKIP_KERNEL" = 0 ]; then
    step "1/7 build kernel"
    bb linux-cix-sky1-ncz || die "kernel build failed"
else
    step "1/7 build kernel -- SKIPPED"
fi

# Derive KVER from what was actually built. Do NOT take it from the recipe or
# from a variable: those describe intent, and the whole failure mode here is
# intent and artifact disagreeing.
KDIR="$(ls -dt "$WORKROOT"/linux-cix-sky1-ncz/*+ncz 2>/dev/null | head -1)"
[ -n "$KDIR" ] || die "no kernel work dir under $WORKROOT"
KVER="$(cat "$KDIR/build/include/config/kernel.release" 2>/dev/null)"
[ -n "$KVER" ] || die "cannot read kernel.release from $KDIR"
echo "  KVER = $KVER"
echo "  from = $KDIR"

# ------------------------------------------------------------- 2. gpu (mali)
if [ "$SKIP_GPU" = 0 ] && [ "$SKIP_MALI" = 0 ]; then
    step "2/7 build cix-gpu-kmd (mali) against $KVER"
    bb -c cleansstate cix-gpu-kmd || die "cix-gpu-kmd cleansstate failed"
    bb cix-gpu-kmd                || die "cix-gpu-kmd build failed"
else
    step "2/7 build cix-gpu-kmd -- SKIPPED"
fi

step "3/7 stage mali overlay + verify vermagic"
GPUDIR="$(ls -dt "$WORKROOT"/cix-gpu-kmd/*/image/usr/lib/modules/*/extra/cix 2>/dev/null | head -1)"
[ -n "$GPUDIR" ] || die "no cix-gpu-kmd image dir -- the module did not build"
DEST="$REPO/assets/kernel/mali/$KVER"
install -d "$DEST"
n=0
for ko in "$GPUDIR"/*.ko; do
    [ -e "$ko" ] || continue
    # vermagic is THE check. A module built for one release is refused by any
    # other, and a stale overlay is how a board ends up with no /dev/mali0
    # while every build step reports success.
    vm="$(modinfo -F vermagic "$ko" 2>/dev/null | awk '{print $1}')"
    [ "$vm" = "$KVER" ] || die "vermagic mismatch: $(basename "$ko") is '$vm', kernel is '$KVER'"
    install -m 0644 "$ko" "$DEST/"
    n=$((n+1))
done
# kbase alone is not enough: it defers with -517 "Memory group manager is not
# ready" unless memory_group_manager and protected_memory_allocator are present.
[ "$n" -ge 3 ] || die "staged only $n GPU module(s), need 3 (mali_kbase, memory_group_manager, protected_memory_allocator)"
echo "  staged $n modules into $DEST, all vermagic=$KVER"

# ------------------------------------------------------- 4. assets + gates
step "4/7 stage kernel assets and run boot/ABI gates"
NCZ_SKIP_PACKAGING=1 BUILD_REV="$REV" "$REPO/build/stage-kernel.sh" || die "staging or gates failed"

# ---------------------------------------------------- 4b. panthor (DKMS-only)
# Panthor has no Yocto recipe -- unlike cix-gpu-kmd (mali), it only ever
# builds via DKMS. The generic path (dpkg -i linux-headers-cixmini, let
# postinst run dkms autoinstall against /lib/modules/$KVER/build) rebuilds
# the headers own host tools locally and silently swaps the build identity
# out from under it -- confirmed 2026-09-07 on O6N: image built oe-user@
# oe-host/binutils-2.46.1, but dkms-abi-gate caught the installed headers
# reporting root@ncz-20e7bc/binutils-2.47. Exactly the r245 failure mode,
# just via panthor instead of mali this time.
#
# Fix: point dkms explicitly at the SAME staged headers-dir stage-kernel.sh
# just extracted from the real OE build tree (never a generic apt/dpkg
# install of the headers package), so there is no second, drifted copy to
# accidentally build against.
if [ $SKIP_GPU = 0 ]; then
    step "4b/7 rebuild panthor-cix DKMS module against staged headers for $KVER"
    HDRDIR="$(readlink -f "$REPO/assets/kernel/edge")/headers-dir/lib/modules/$KVER/build"
    [ -d "$HDRDIR" ] || die "no staged headers-dir at $HDRDIR -- did stage-kernel.sh run?"
    PANTHOR_VER="$(command -v dkms >/dev/null 2>&1 || PATH="$PATH:/usr/sbin"; dkms status 2>/dev/null | grep -oE '^panthor-cix/[0-9.]+' | head -1 | cut -d/ -f2)"
    [ -n "$PANTHOR_VER" ] || die "panthor-cix not registered in dkms -- nothing to rebuild"
    python3 "$REPO/build/prepare-staged-kbuild-tools.py" "$HDRDIR" || die "native staged-header tools failed"
    "$REPO/build/dkms-abi-gate.sh" "$REPO/assets/kernel/edge/Image-cixmini.bin" "$HDRDIR" --config "$REPO/assets/kernel/edge/config-$KVER" || die "ABI gate after host-tool preparation failed"
    sudo dkms build panthor-cix/"$PANTHOR_VER" -k "$KVER" --kernelsourcedir "$HDRDIR" --force || die "panthor-cix dkms build failed against $HDRDIR"
    "$REPO/build/dkms-abi-gate.sh" "$REPO/assets/kernel/edge/Image-cixmini.bin" "$HDRDIR" --config "$REPO/assets/kernel/edge/config-$KVER" || die "ABI gate after DKMS build failed"

    # Export DKMS build output rather than invoking install on the build
    # host: Fedora DKMS runs a host-wide dracut post-transaction hook even
    # with --installtree and --no-depmod. Packages need the built module,
    # not a build-host kernel installation or an initramfs regeneration.
    STAGED="$(readlink -f "$REPO/assets/kernel/edge")"
    PANTHOR_ROOT="$(mktemp -d "$STAGED/panthor-root.XXXXXX")" || die "cannot create module staging root"
    tar -xzf "$STAGED/modules-cixmini.tgz" -C "$PANTHOR_ROOT" || die "cannot extract staged modules"
    PKO_SOURCE="/var/lib/dkms/panthor-cix/$PANTHOR_VER/$KVER/$(uname -m)/module/panthor.ko"
    [ -s "$PKO_SOURCE" ] || die "panthor.ko missing from the completed DKMS build"
    PKO="$PANTHOR_ROOT/lib/modules/$KVER/updates/dkms/panthor.ko"
    install -D -m 0644 "$PKO_SOURCE" "$PKO" || die "cannot stage built panthor.ko"
    pvm="$(modinfo -F vermagic "$PKO" 2>/dev/null | awk '{print $1}')"
    [ "$pvm" = "$KVER" ] || die "panthor vermagic mismatch: '$pvm' vs kernel '$KVER'"
    depmod -b "$PANTHOR_ROOT" -a "$KVER" || die "staged module depmod failed"
    tar -C "$PANTHOR_ROOT" -czf "$STAGED/modules-cixmini.tgz.new" "lib/modules/$KVER" || die "cannot pack staged Panthor module"
    mv "$STAGED/modules-cixmini.tgz.new" "$STAGED/modules-cixmini.tgz" || die "cannot update staged modules"
    echo "  panthor.ko vermagic=$KVER confirmed, built against $HDRDIR and included in staged modules"

else
    step "4b/7 panthor-cix rebuild -- SKIPPED"
fi

# ------------------------------------------------------------ 5. kernel debs
step "5/7 build kernel debs (must contain the GPU modules)"
deb_run "BUILD_REV=$REV build/build-kernel-debs.sh" || die "kernel deb build failed"

IMGDEB="$(ls -t "$REPO"/build/kernel-debs/linux-image-cixmini_*"$REV"_arm64.deb 2>/dev/null | head -1)"
[ -n "$IMGDEB" ] || die "no linux-image deb produced for $REV"
DEBBASE="$(basename "$IMGDEB")"
got="$(deb_run "dpkg-deb -c build/kernel-debs/$DEBBASE | grep -cE 'mali_kbase|memory_group_manager|protected_memory_allocator'" 2>/dev/null | tail -1 | tr -dc '0-9')"
[ -n "$got" ] && [ "$got" -ge 3 ] || die "linux-image deb contains ${got:-0} GPU modules, expected 3 -- it would install a GPU-less kernel"
echo "  ok: $got GPU modules inside $DEBBASE"

# -------------------------------------------------------------- 6. dkms debs
if [ "$DO_DKMS" = 1 ]; then
    step "6/7 build accelerator DKMS debs (mali, panthor, vpu, npu)"
    deb_run "build/build-dkms-debs.sh" || die "dkms deb build failed"
    ls -la "$REPO/build/dkms-debs/" 2>/dev/null | tail -6
else
    step "6/7 dkms debs -- SKIPPED"
fi

# -------------------------------------------------------------- 7. manifest
step "7/7 regenerate and enforce the kernel manifest"
( cd "$REPO" && python3 build/kernel-manifest.py gen ) || die "manifest gen failed"
( cd "$REPO" && python3 build/kernel-manifest.py check --strict ) || die "manifest check FAILED -- do not ship this"

cat <<DONE

=== release-kernel: COMPLETE
    rev      $REV
    kver     $KVER
    assets   $(readlink "$REPO/assets/kernel/edge")
    debs     $REPO/build/kernel-debs/
    dkms     $REPO/build/dkms-debs/

Not yet done, and deliberately not automated:
  - boot the image on real hardware, BOTH GPU entries (mali and panthor)
  - run build/validate-accelerators.sh on the booted board: a module that is
    resident in lsmod may be bound to nothing
  - publish to the Buildkite registry
DONE
