#!/bin/bash
# test-verify-dkms-deb-sources.sh -- drive build/verify-dkms-deb-sources.py
# against synthetic asset trees and debs, in both directions: a deb built from
# the current source passes, and each way a deb can be stale fails.
#
# Fixtures use the mali (cix-gpu-kmd) driver and its staging rule (src/ plus
# dkms.conf). Panthor fixtures are gone with Panthor (order 01:35Z 2026-11-15,
# "NO PANTHOR ANYWHERE"): panthor-cix-dkms is never staged or built.
#
# Run: bash build/test-verify-dkms-deb-sources.sh
# Exit 0 = all cases pass, 1 = at least one failed, 2 = cannot run.

# This suite builds .deb fixtures. If the host cannot, say so once instead of
# letting every assertion fail on an empty archive (build/lib/deb-fixture.sh).
# shellcheck source=lib/deb-fixture.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/deb-fixture.sh"
ncz_deb_fixture_check || { echo "test-verify-dkms-deb-sources: ENVIRONMENT: this host cannot build deb fixtures; not a code failure" >&2; exit 3; }

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SCRIPT_DIR/verify-dkms-deb-sources.py"
[ -r "$GATE" ] || { echo "FATAL: cannot read $GATE" >&2; exit 2; }
command -v dpkg-deb >/dev/null || { echo "FATAL: dpkg-deb not found" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/verify-dkms-deb-sources.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PASS=0
FAILED=0

# mkroot <root>: a mali asset tree shaped like assets/kernel/mali (src/ +
# dkms.conf = the build-dkms-debs.sh generic staging rule).
mkroot() {
    local r="$1"
    rm -rf "$r"
    mkdir -p "$r/assets/kernel/mali/src" "$r/assets/cix-debs"
    printf 'PACKAGE_NAME="cix-gpu-kmd"\nPACKAGE_VERSION="1.0"\n' \
        > "$r/assets/kernel/mali/dkms.conf"
    printf 'obj-m += mali_kbase.o\n' > "$r/assets/kernel/mali/src/Kbuild"
    printf 'int a(void) { return 0; }\n' > "$r/assets/kernel/mali/src/mali_drv.c"
    mkdir -p "$r/assets/kernel/mali/7.3.0-rc6-sky1-ncz"
    printf 'ELF' > "$r/assets/kernel/mali/7.3.0-rc6-sky1-ncz/mali_kbase.ko"
}

# mkdeb <root> <out.deb> [mutator]: package the tree the way
# build-dkms-debs.sh does, then let the mutator change the payload.
mkdeb() {
    local r="$1" out="$2" mut="${3:-}"
    local w="$WORK/pkg"
    rm -rf "$w"
    local src="$w/usr/src/cix-gpu-kmd-1.0"
    mkdir -p "$w/DEBIAN" "$src"
    cp -a "$r/assets/kernel/mali/src/." "$src/"
    cp -a "$r/assets/kernel/mali/dkms.conf" "$src/dkms.conf"
    [ -n "$mut" ] && (cd "$src" && eval "$mut")
    printf 'Package: cix-gpu-kmd-dkms\nVersion: 1.0+ncz1\nArchitecture: all\nMaintainer: t <t@t>\nDescription: t\n' \
        > "$w/DEBIAN/control"
    dpkg-deb --build --root-owner-group "$w" "$out" >/dev/null
}

# expect <label> <want_rc> <want_regex> <root>
expect() {
    local label="$1" want_rc="$2" pat="$3" root="$4" out rc=0
    out=$(python3 "$GATE" --root "$root" --driver mali 2>&1) || rc=$?
    if [ "$rc" = "$want_rc" ] && printf '%s\n' "$out" | grep >/dev/null -E "$pat"; then
        echo "PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $label (rc=$rc want=$want_rc, pattern '$pat')"
        printf '%s\n' "$out" | sed 's/^/    /'
        FAILED=$((FAILED + 1))
    fi
}

R="$WORK/root"

mkroot "$R"; mkdeb "$R" "$R/assets/cix-debs/cix-gpu-kmd-dkms_1.0+ncz1_all.deb"
expect "fresh deb -> PASS" 0 'OK mali: .*\(3 files\)' "$R"

mkroot "$R"; mkdeb "$R" "$R/assets/cix-debs/cix-gpu-kmd-dkms_1.0+ncz1_all.deb" \
    'printf "#define DRIVER_GEM_GPUVA_OLD\n" >> mali_drv.c'
expect "stale source in deb -> FAIL" 1 'differ: mali_drv\.c' "$R"

mkroot "$R"; mkdeb "$R" "$R/assets/cix-debs/cix-gpu-kmd-dkms_1.0+ncz1_all.deb" \
    'printf "x\n" > mali_old.c'
expect "file removed from source but still in deb -> FAIL" 1 'extra: mali_old\.c' "$R"

mkroot "$R"; mkdeb "$R" "$R/assets/cix-debs/cix-gpu-kmd-dkms_1.0+ncz1_all.deb" \
    'rm -f Kbuild'
expect "file missing from deb -> FAIL" 1 'missing: Kbuild' "$R"

mkroot "$R"; mkdeb "$R" "$R/assets/cix-debs/cix-gpu-kmd-dkms_1.0+ncz1_all.deb"
cp "$R/assets/cix-debs/cix-gpu-kmd-dkms_1.0+ncz1_all.deb" \
   "$R/assets/cix-debs/cix-gpu-kmd-dkms_1.0+ncz2_all.deb"
expect "two versions staged -> FAIL" 1 '2 cix-gpu-kmd-dkms debs staged' "$R"

mkroot "$R"; mkdeb "$R" "$R/assets/cix-debs/cix-gpu-kmd-dkms_1.0+ncz1_all.deb" \
    'mkdir -p 7.2.7-sky1-ncz && printf ELF > 7.2.7-sky1-ncz/mali_kbase.ko && printf o > x.o'
expect "prebuilt .ko dirs and artifacts in deb are ignored -> PASS" 0 'OK mali' "$R"

mkroot "$R"; printf 'not a deb' > "$R/assets/cix-debs/cix-gpu-kmd-dkms_1.0+ncz1_all.deb"
expect "corrupt deb -> FAIL" 1 'FAIL mali: cannot read' "$R"

mkroot "$R"
expect "no deb staged -> SKIP, PASS" 0 'SKIP mali: no cix-gpu-kmd-dkms' "$R"

rm -rf "$R"; mkdir -p "$R/assets/cix-debs"
printf 'stub' > "$R/assets/cix-debs/cix-gpu-kmd-dkms_1.0.0_arm64.deb"
expect "no assets/kernel tree (gate-test fixture) -> SKIP, PASS" 0 'SKIP mali: no ' "$R"

# --- overlay SOURCE.sha256 stamps (--overlays) -------------------------------
# expect_ovl <label> <want_rc> <want_regex> <root> [kver]
expect_ovl() {
    local label="$1" want_rc="$2" pat="$3" root="$4" kver="${5:-}" out rc=0
    if [ -n "$kver" ]; then
        out=$(python3 "$GATE" --root "$root" --driver mali --overlays "$kver" 2>&1) || rc=$?
    else
        out=$(python3 "$GATE" --root "$root" --driver mali --overlays 2>&1) || rc=$?
    fi
    if [ "$rc" = "$want_rc" ] && printf '%s\n' "$out" | grep >/dev/null -E "$pat"; then
        echo "PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $label (rc=$rc want=$want_rc, pattern '$pat')"
        printf '%s\n' "$out" | sed 's/^/    /'
        FAILED=$((FAILED + 1))
    fi
}
K=7.3.0-rc6-sky1-ncz
stamp() { python3 "$GATE" --root "$1" --source-digest mali > "$1/assets/kernel/mali/$K/SOURCE.sha256"; }

mkroot "$R"; stamp "$R"
expect_ovl "overlay stamped from current source -> PASS" 0 'OK mali: .*built from current source' "$R" "$K"

mkroot "$R"
printf '{"variants": {"mainline": {"kver": "%s"}}}\n' "$K" > "$R/assets/kernel-manifest.json"
stamp "$R"
expect_ovl "kver taken from kernel-manifest.json -> PASS" 0 "overlays $K: PASS" "$R"

mkroot "$R"
expect_ovl "overlay without SOURCE.sha256 -> FAIL" 1 'SOURCE\.sha256 missing' "$R" "$K"

mkroot "$R"; stamp "$R"
printf '/* changed */\n' >> "$R/assets/kernel/mali/src/mali_drv.c"
expect_ovl "source changed after the overlay was built -> FAIL" 1 'built from other source' "$R" "$K"

mkroot "$R"; stamp "$R"
printf 'x' > "$R/assets/kernel/mali/src/x.o"
printf 'ELF2' > "$R/assets/kernel/mali/$K/mali_kbase.ko"
expect_ovl "artifacts and .ko changes do not move the digest -> PASS" 0 'OK mali' "$R" "$K"

mkroot "$R"
expect_ovl "no overlay dir for the pinned kernel -> FAIL" 1 'no overlay dir' "$R" "7.4.0-sky1-ncz"

mkroot "$R"
expect_ovl "no pinned kver -> SKIP, PASS" 0 'overlays: SKIP' "$R"

# --- prebuilt kernel BOM (--bom): no per-KVER overlays, DKMS source debs pinned
# A tree whose Sky1 kernel is the prebuilt-deb BOM (assets/kernel/mainline.debs)
# ships no prebuilt accelerator overlays: aipu, amvx and mali are built by DKMS
# on the target. --bom then requires the three DKMS source debs instead:
# each present exactly once, its sha256 the single manifests/ncz-packages.tsv
# row for its (Package, Version, Architecture), its dkms.conf coherent with the
# deb version and with the BOM kernel. --overlays --bom accepts a missing
# <kver>/ dir but still checks the stamp of any overlay dir that exists.
BK=7.3.1-sky1-ncz

# mkdkmsdeb <out.deb> <package> <version> <dkms-name> <dkms-version> [extra dkms.conf line]
mkdkmsdeb() {
    local out="$1" pkg="$2" ver="$3" dn="$4" dv="$5" extra="${6:-}"
    local w="$WORK/pkg-$pkg"
    rm -rf "$w"
    mkdir -p "$w/DEBIAN" "$w/usr/src/$dn-$dv"
    printf 'PACKAGE_NAME="%s"\nPACKAGE_VERSION="%s"\nAUTOINSTALL="yes"\n%s\n' "$dn" "$dv" "$extra" \
        > "$w/usr/src/$dn-$dv/dkms.conf"
    printf 'obj-m += %s.o\n' "$dn" > "$w/usr/src/$dn-$dv/Kbuild"
    printf 'Package: %s\nVersion: %s\nArchitecture: all\nMaintainer: t <t@t>\nDescription: t\n' "$pkg" "$ver" \
        > "$w/DEBIAN/control"
    dpkg-deb --build --root-owner-group "$w" "$out" >/dev/null
}

# ledger <root>: (re)write manifests/ncz-packages.tsv from the staged debs.
ledger() {
    local r="$1" d
    mkdir -p "$r/manifests"
    printf '# name\tversion\tarch\tsha256\trecipe\tsource_revision\tnote\n' > "$r/manifests/ncz-packages.tsv"
    for d in "$r"/assets/cix-debs/*.deb; do
        printf '%s\t%s\t%s\t%s\ttest\ttest\ttest\n' \
            "$(dpkg-deb -f "$d" Package)" "$(dpkg-deb -f "$d" Version)" \
            "$(dpkg-deb -f "$d" Architecture)" "$(sha256sum "$d" | awk '{print $1}')" \
            >> "$r/manifests/ncz-packages.tsv"
    done
}

# mkbom <root>: the mali asset tree plus a kernel BOM and the three DKMS debs,
# every one of them in the ledger.
mkbom() {
    local r="$1"
    mkroot "$r"
    printf 'KVER=%s\nPKGVERSION=%s+r297\n' "$BK" "$BK" > "$r/assets/kernel/mainline.debs"
    printf '{"variants": {"mainline": {"kver": "%s"}}}\n' "$BK" > "$r/assets/kernel-manifest.json"
    mkdeb "$r" "$r/assets/cix-debs/cix-gpu-kmd-dkms_1.0+ncz1_all.deb"
    mkdkmsdeb "$r/assets/cix-debs/cix-vpu-driver-dkms_1.0.2-ncz1+ncz3_all.deb" cix-vpu-driver-dkms 1.0.2-ncz1+ncz3 cix-vpu-driver 1.0.2-ncz1
    mkdkmsdeb "$r/assets/cix-debs/cix-npu-driver-dkms_6.2.0-cixdeb13-260714+ncz3_arm64.deb" cix-npu-driver-dkms 6.2.0-cixdeb13-260714+ncz3 aipu 6.2.0
    ledger "$r"
}

# expect_bom <label> <want_rc> <want_regex> <root> [extra gate args]
expect_bom() {
    local label="$1" want_rc="$2" pat="$3" root="$4" out rc=0
    shift 4
    out=$(python3 "$GATE" --root "$root" --bom "$@" 2>&1) || rc=$?
    if [ "$rc" = "$want_rc" ] && printf '%s\n' "$out" | grep >/dev/null -E "$pat"; then
        echo "PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $label (rc=$rc want=$want_rc, pattern '$pat')"
        printf '%s\n' "$out" | sed 's/^/    /'
        FAILED=$((FAILED + 1))
    fi
}

mkbom "$R"
expect_bom "BOM: three pinned DKMS source debs -> PASS" 0 'bom 7\.3\.1-sky1-ncz: PASS \(3 DKMS source debs' "$R"

mkbom "$R"; rm -f "$R"/assets/cix-debs/cix-npu-driver-dkms_*.deb
expect_bom "BOM: aipu DKMS deb missing -> FAIL" 1 'FAIL cix-npu-driver-dkms: no cix-npu-driver-dkms_\*\.deb' "$R"

mkbom "$R"; rm -f "$R"/assets/cix-debs/cix-npu-driver-dkms_*.deb
out=$(python3 "$GATE" --root "$R" 2>&1); rc=$?
if [ "$rc" = 0 ]; then echo "PASS: no --bom: aipu deb absence is not this gate's job (unchanged)"; PASS=$((PASS + 1));
else echo "FAIL: no --bom changed behavior (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/    /'; FAILED=$((FAILED + 1)); fi

mkbom "$R"
mkdkmsdeb "$R/assets/cix-debs/cix-vpu-driver-dkms_1.0.2-ncz1+ncz3_all.deb" cix-vpu-driver-dkms 1.0.2-ncz1+ncz3 cix-vpu-driver 1.0.2-ncz1 '# rebuilt'
expect_bom "BOM: amvx deb bytes differ from the ledger pin -> FAIL" 1 'FAIL cix-vpu-driver-dkms: .*sha256 [0-9a-f]{12}.* != manifests/ncz-packages\.tsv' "$R"

mkbom "$R"; grep -v '^cix-gpu-kmd-dkms' "$R/manifests/ncz-packages.tsv" > "$R/l" && mv "$R/l" "$R/manifests/ncz-packages.tsv"
expect_bom "BOM: mali DKMS deb not in the ledger -> FAIL" 1 'FAIL cix-gpu-kmd-dkms: .*: 0 manifests/ncz-packages\.tsv row' "$R"

mkbom "$R"; grep "^cix-vpu-driver-dkms" "$R/manifests/ncz-packages.tsv" > "$R/dup"; cat "$R/dup" >> "$R/manifests/ncz-packages.tsv"
expect_bom "BOM: a DKMS deb listed twice in the ledger (same sha256) -> FAIL" 1 \
    "FAIL cix-vpu-driver-dkms: .*: 2 manifests/ncz-packages\\.tsv row" "$R"

mkbom "$R"; cp "$R/assets/cix-debs/cix-gpu-kmd-dkms_1.0+ncz1_all.deb" "$R/assets/cix-debs/cix-gpu-kmd-dkms_1.0+ncz2_all.deb"
expect_bom "BOM: two mali DKMS debs staged -> FAIL" 1 'FAIL cix-gpu-kmd-dkms: 2 cix-gpu-kmd-dkms debs staged' "$R"

mkbom "$R"; mv "$R/assets/cix-debs/cix-gpu-kmd-dkms_1.0+ncz1_all.deb" "$R/assets/cix-debs/cix-gpu-kmd-dkms_1.0+ncz9_all.deb"
expect_bom "BOM: file name version != control Version -> FAIL" 1 'FAIL cix-gpu-kmd-dkms: .*file name says 1\.0\+ncz9, control Version is 1\.0\+ncz1' "$R"

mkbom "$R"
mkdkmsdeb "$R/assets/cix-debs/cix-npu-driver-dkms_6.2.0-cixdeb13-260714+ncz3_arm64.deb" cix-npu-driver-dkms 6.2.0-cixdeb13-260714+ncz3 aipu 6.1.0
ledger "$R"
expect_bom "BOM: dkms.conf PACKAGE_VERSION not the deb's upstream version -> FAIL" 1 'FAIL cix-npu-driver-dkms: .*PACKAGE_VERSION 6\.1\.0' "$R"

mkbom "$R"
mkdkmsdeb "$R/assets/cix-debs/cix-vpu-driver-dkms_1.0.2-ncz1+ncz3_all.deb" cix-vpu-driver-dkms 1.0.2-ncz1+ncz3 cix-vpu-driver 1.0.2-ncz1 'BUILD_EXCLUSIVE_KERNEL="^7\.2\."'
ledger "$R"
expect_bom "BOM: BUILD_EXCLUSIVE_KERNEL excludes the BOM kernel -> FAIL" 1 'FAIL cix-vpu-driver-dkms: .*BUILD_EXCLUSIVE_KERNEL .* excludes 7\.3\.1-sky1-ncz' "$R"

mkbom "$R"
mkdkmsdeb "$R/assets/cix-debs/cix-vpu-driver-dkms_1.0.2-ncz1+ncz3_all.deb" cix-vpu-driver-dkms 1.0.2-ncz1+ncz3 cix-vpu-driver 1.0.2-ncz1 'BUILD_EXCLUSIVE_KERNEL="^7\.3\."'
ledger "$R"
expect_bom "BOM: BUILD_EXCLUSIVE_KERNEL that admits the BOM kernel -> PASS" 0 'bom 7\.3\.1-sky1-ncz: PASS' "$R"

mkbom "$R"; printf '{"variants": {"mainline": {"kver": "7.3.0-sky1-ncz"}}}\n' > "$R/assets/kernel-manifest.json"
expect_bom "BOM: KVER disagrees with kernel-manifest.json -> FAIL" 1 'mainline\.debs KVER 7\.3\.1-sky1-ncz != .*kernel-manifest\.json.* 7\.3\.0-sky1-ncz' "$R"

mkbom "$R"; printf '/* newer */\n' >> "$R/assets/kernel/mali/src/mali_drv.c"
expect_bom "BOM: mali deb stale vs assets/kernel/mali/src still -> FAIL" 1 'differ: mali_drv\.c' "$R"

mkroot "$R"
expect_bom "--bom on a tree without assets/kernel/mainline.debs -> exit 2" 2 'requires assets/kernel/mainline\.debs' "$R"

# --overlays --bom
mkbom "$R"
expect_bom "BOM overlays: no <kver>/ dir -> SKIP, PASS (DKMS on the target)" 0 \
    "SKIP mali: no prebuilt overlay assets/kernel/mali/$BK/" "$R" --driver mali --overlays
mkbom "$R"
expect_ovl "no --bom: no overlay dir for the BOM kernel still FAILs (unchanged)" 1 'no overlay dir' "$R"
mkbom "$R"; mkdir -p "$R/assets/kernel/mali/$BK"; printf 'ELF' > "$R/assets/kernel/mali/$BK/mali_kbase.ko"
expect_bom "BOM overlays: an overlay dir without SOURCE.sha256 -> FAIL" 1 'SOURCE\.sha256 missing' "$R" --driver mali --overlays
mkbom "$R"; mkdir -p "$R/assets/kernel/mali/$BK"
python3 "$GATE" --root "$R" --source-digest mali > "$R/assets/kernel/mali/$BK/SOURCE.sha256"
printf '/* changed */\n' >> "$R/assets/kernel/mali/src/mali_drv.c"
expect_bom "BOM overlays: an overlay dir built from other source -> FAIL" 1 'built from other source' "$R" --driver mali --overlays

echo "---"
echo "passed=$PASS failed=$FAILED"
[ "$FAILED" -eq 0 ]
