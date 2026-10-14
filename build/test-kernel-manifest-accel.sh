#!/bin/bash
# test-kernel-manifest-accel.sh -- prove the in-tree accelerator and VPU package
# checks of build/kernel-manifest.py fire on the bad shapes and stay quiet on a
# correct kernel.
#
# Builds a throwaway repository layout around a copy of kernel-manifest.py (its
# ROOT is derived from its own location): a staged rNNN-<kver>-<date> kernel
# directory behind assets/kernel/mainline, the accelerator overlay trees, the
# KERNEL-POLICY grandfather key and the package ledger, then runs `check`.
#
# Run: bash build/test-kernel-manifest-accel.sh     Exit 0 = all cases pass.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not available" >&2; exit 2; }

W="$(mktemp -d "${TMPDIR:-/tmp}/kmanifest-accel.XXXXXX")"
trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
KV=7.3.0-rc7-sky1-ncz

fake_ko() {   # path kver: a file whose .modinfo-style bytes carry vermagic=<kver>
    mkdir -p "$(dirname "$1")"
    printf 'ELF\0vermagic=%s SMP preempt mod_unload modversions aarch64\0' "$2" > "$1"
}

# fixture <name> <rev> <linlon: m|n> <intree-ko: 0|1>
fixture() {
    local r="$W/$1" rev="$2" linlon="$3" intree="$4" st mods
    mkdir -p "$r/build" "$r/assets/kernel" "$r/manifests"
    cp "$REPO/build/kernel-manifest.py" "$r/build/"
    printf 'DEFAULT_BASE=7.3\nINTREE_ACCEL_GRANDFATHERED_SKY1=r289\n' > "$r/assets/kernel/KERNEL-POLICY"
    st="$r/staging/$rev-$KV-20261013"
    mkdir -p "$st"
    printf '%s' "$KV" > "$st/KVER"
    printf 'Image' > "$st/Image-cixmini.bin"
    if [ "$linlon" = m ]; then
        printf 'CONFIG_ARM64=y\nCONFIG_VIDEO_LINLON=m\nCONFIG_VIDEOBUF2_DMA_SG=m\n' > "$st/config-$KV"
    else
        printf 'CONFIG_ARM64=y\n# CONFIG_VIDEO_LINLON is not set\nCONFIG_VIDEO_LINLON_OOT=m\nCONFIG_VIDEOBUF2_DMA_SG=m\n' > "$st/config-$KV"
    fi
    mods="$W/mods-$1/lib/modules/$KV/kernel/drivers"
    mkdir -p "$mods/gpu/drm/cix/linlon-dp"
    printf 'ko' > "$mods/gpu/drm/cix/linlon-dp/linlon-dp.ko"
    if [ "$intree" = 1 ]; then
        mkdir -p "$mods/media/platform/cix"
        printf 'ko' > "$mods/media/platform/cix/amvx.ko"
    fi
    tar -C "$W/mods-$1" -czf "$st/modules-cixmini.tgz" lib
    ln -s "$st" "$r/assets/kernel/mainline"
    fake_ko "$r/assets/kernel/mali/$KV/mali_kbase.ko" "$KV"
    fake_ko "$r/assets/kernel/panthor/$KV/panthor.ko" "$KV"
    fake_ko "$r/assets/kernel/vpu/$KV/amvx.ko" "$KV"
    printf 'amvx.ko src\n' > "$r/assets/kernel/vpu/$KV/SOURCE.sha256"
    printf 'PACKAGE_NAME="cix-vpu-driver"\nBUILT_MODULE_NAME[0]="amvx"\nDEST_MODULE_LOCATION[0]="/updates"\n' \
        > "$r/assets/kernel/vpu/dkms.conf"
    mkdir -p "$r/assets/kernel/npu/src"
    printf 'PACKAGE_NAME="aipu"\n' > "$r/assets/kernel/npu/dkms.conf"
    printf 'cix-vpu-driver-dkms\t1.0.2-ncz1+ncz3\tall\t%s\tbuild/build-dkms-debs.sh\tassets/kernel/vpu\tfixture\n' \
        "$(printf '%064d' 0)" > "$r/manifests/ncz-packages.tsv"
}

check() {   # label want_rc fixture [grep-pattern-that-must-appear]
    local label="$1" want="$2" r="$W/$3" pat="${4:-}" out rc
    out="$(python3 -I "$r/build/kernel-manifest.py" check 2>&1)"; rc=$?
    printf '%s\n' "$out" | sed 's/^/    /'
    if [ "$rc" != "$want" ]; then
        echo "  FAIL  $label (rc=$rc, want $want)"; FAIL=$((FAIL + 1)); return
    fi
    if [ -n "$pat" ] && ! printf '%s\n' "$out" | grep -- "$pat" >/dev/null; then
        echo "  FAIL  $label (output lacks '$pat')"; FAIL=$((FAIL + 1)); return
    fi
    echo "  PASS  $label (rc=$rc)"; PASS=$((PASS + 1))
}

echo "=== 1 POSITIVE: r290, VPU out-of-tree only, overlay + DKMS conf + ledger row ==="
fixture good r290 n 0
check "clean r290 passes" 0 good

echo "=== 2 NEGATIVE: r290 config builds CONFIG_VIDEO_LINLON=m ==="
fixture cfgm r290 m 0
check "r290 with CONFIG_VIDEO_LINLON=m fails" 1 cfgm "ERROR: .*CONFIG_VIDEO_LINLON=m is IN-TREE"

echo "=== 3 NEGATIVE: r290 modules tree carries kernel/drivers/media/platform/cix/amvx.ko ==="
fixture tgz r290 n 1
check "r290 with in-tree amvx.ko in the modules tgz fails" 1 tgz "ERROR: .*ships in-tree .*amvx.ko"

echo "=== 4 POSITIVE: grandfathered r289 (=m and in-tree amvx.ko) only warns ==="
fixture r289 r289 m 1
check "r289 warns, does not fail" 0 r289 "WARN: .*grandfathered: r289"

echo "=== 5 NEGATIVE: VPU overlay amvx.ko missing for the KVER ==="
fixture noovl r290 n 0
rm -f "$W/noovl/assets/kernel/vpu/$KV/amvx.ko"
check "missing VPU overlay fails" 1 noovl "VPU overlay .*amvx.ko missing"

echo "=== 6 NEGATIVE: ledger has no cix-vpu-driver-dkms row ==="
fixture noledger r290 n 0
: > "$W/noledger/manifests/ncz-packages.tsv"
check "missing DKMS ledger row fails" 1 noledger "no cix-vpu-driver-dkms row"

echo "=== 7 NEGATIVE: DKMS conf does not install amvx into /updates ==="
fixture nodest r290 n 0
sed -i.bak 's#/updates#/extra#' "$W/nodest/assets/kernel/vpu/dkms.conf"
check "DKMS conf without /updates fails" 1 nodest "does not install amvx into /updates"

echo "=== 8 NEGATIVE: r289 is no longer grandfathered once removed from KERNEL-POLICY ==="
fixture nogf r289 m 1
printf 'DEFAULT_BASE=7.3\n' > "$W/nogf/assets/kernel/KERNEL-POLICY"
check "r289 without the grandfather key fails" 1 nogf "ERROR: .*CONFIG_VIDEO_LINLON=m"

echo "=== 9 NEGATIVE: VPU driver out-of-tree but the videobuf2 DMA-SG helpers are not built ==="
fixture novb2 r290 n 0
sed -i.bak '/VIDEOBUF2_DMA_SG/d; /VIDEO_LINLON_OOT/d' "$W/novb2/staging/r290-$KV-20261013/config-$KV"
check "missing CONFIG_VIDEOBUF2_DMA_SG fails" 1 novb2 "no CONFIG_VIDEOBUF2_DMA_SG"

echo
echo "=== kernel manifest accelerator test: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
