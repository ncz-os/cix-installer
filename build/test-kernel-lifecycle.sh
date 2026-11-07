#!/bin/bash
# test-kernel-lifecycle.sh -- exercise build/check-kernel-lifecycle.py, the gate
# that keeps a retired or too-old kernel from ever being pinned again.
#
# Why (2026-11-07): release candidate rc3 (ba74b7c7) shipped 7.3.0-t2-ncz and
# 7.3.0-sky1-ncz after 7.3.0 had been retired in favour of 7.3.1. Nothing in the
# tree knew 7.3.0 was retired: the policy only checked the 7.3 series. The
# lifecycle file assets/kernel/KERNEL-LIFECYCLE now records MIN_VERSION, the
# promoted CURRENT kernel per arch and the RETIRED list; the kernel-ci promotion
# registry regenerates it, and every committed pin must agree with it.
#
# Fixture trees cover every refusal; the last block checks the real tree.
#
# Run: bash build/test-kernel-lifecycle.sh     Exit 0 = all cases pass.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
GATE="$HERE/check-kernel-lifecycle.py"
POLICY_VERIFIER="$HERE/verify-kernel-default-policy.sh"
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 not available" >&2; exit 1; }
[ -f "$GATE" ] || { echo "FAIL: $GATE is missing"; exit 1; }

W="$(mktemp -d "${TMPDIR:-$HOME}/.kernel-lifecycle-test.XXXXXX")"; trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }
# expect <label> <want-rc> <grep-pattern-or-empty> cmd...
expect() {
    local label="$1" want="$2" pat="$3" rc=0 out; shift 3
    out="$("$@" 2>&1)" || rc=$?
    if [ "$rc" != "$want" ]; then bad "$label: rc=$rc, wanted $want" "$out"; return; fi
    if [ -n "$pat" ] && ! printf '%s\n' "$out" | grep -qE -- "$pat"; then
        bad "$label: output lacks /$pat/" "$out"; return
    fi
    ok "$label (rc=$rc)"
}

# lifecycle <root> [KEY=value ...]: write a lifecycle file; later args override.
lifecycle() {
    local root="$1"; shift
    mkdir -p "$root/assets/kernel"
    {
        echo "LIFECYCLE_SCHEMA=1"
        echo "LIFECYCLE_SOURCE=test-fixture"
        echo "MIN_VERSION=7.3.1"
        echo "CURRENT_KVER_amd64=7.3.1-t2-ncz"
        echo "CURRENT_PKG_amd64=7.3.1-r295"
        echo "CURRENT_KVER_arm64=7.3.1-sky1-ncz"
        echo "CURRENT_PKG_arm64=7.3.1-sky1-ncz+r297"
        echo "RETIRED=7.3.0-t2-ncz,7.3.0-sky1-ncz"
    } > "$root/assets/kernel/KERNEL-LIFECYCLE"
    local kv k
    for kv in "$@"; do
        k="${kv%%=*}"
        sed -i "/^$k=/d" "$root/assets/kernel/KERNEL-LIFECYCLE"
        [ "${kv#*=}" = "<absent>" ] || echo "$kv" >> "$root/assets/kernel/KERNEL-LIFECYCLE"
    done
}

# amd64tree <root> <kver> <pkgver> [manifest-kver] [manifest-pkg]
amd64tree() {
    local root="$1" kver="$2" pkg="$3" mk="${4:-$2}" mp="${5:-$3}"
    mkdir -p "$root/assets/kernel/amd64-stable" "$root/manifests"
    printf '%s\n' "$kver" > "$root/assets/kernel/amd64-stable/KVER"
    printf '%s\n' "$pkg"  > "$root/assets/kernel/amd64-stable/PKGVERSION"
    printf '{"schema":1,"arch":"amd64","kver":"%s","package_revision":"%s"}\n' "$mk" "$mp" \
        > "$root/assets/kernel/amd64-stable-manifest.json"
    printf '# ledger\nlinux-image-%s\t%s\tamd64\t%064d\tbuild/stage-amd64-kernel.sh\tx\tn\n' "$kver" "$pkg" 0 \
        > "$root/manifests/ncz-packages.tsv"
    printf 'linux-headers-%s\t%s\tamd64\t%064d\tbuild/stage-amd64-kernel.sh\tx\tn\n' "$kver" "$pkg" 0 \
        >> "$root/manifests/ncz-packages.tsv"
}

# arm64tree <root> <kver> <pkgver> [sky1-manifest-kver]
arm64tree() {
    local root="$1" kver="$2" pkg="$3" sk="${4:-$2}"
    mkdir -p "$root/assets/kernel" "$root/manifests"
    cat > "$root/assets/kernel-manifest.json" <<JSON
{"schema":1,"kernel_debs":[
 {"file":"build/kernel-debs/linux-image-cixmini_${pkg}_arm64.deb","sha256":"$(printf '%064d' 0)"},
 {"file":"build/kernel-debs/linux-headers-cixmini_${pkg}_arm64.deb","sha256":"$(printf '%064d' 0)"}],
 "variants":{"mainline":{"dir":"assets/kernel/mainline","kver":"$kver"}}}
JSON
    printf '{"schema":1,"arch":"arm64","kver":"%s"}\n' "$sk" > "$root/assets/kernel/sky1-manifest.json"
    printf 'linux-image-cixmini\t%s\tarm64\t%064d\tbuild/build-kernel-debs.sh\tx\tn\n' "$pkg" 0 \
        >> "$root/manifests/ncz-packages.tsv"
}

echo "=== positive: pins equal the promoted CURRENT kernel ==="
r="$W/p1"; amd64tree "$r" 7.3.1-t2-ncz 7.3.1-r295; lifecycle "$r"
expect "amd64: 7.3.1-t2-ncz 7.3.1-r295 = CURRENT" 0 "OK" python3 "$GATE" --root "$r" --arch amd64
r="$W/p2"; arm64tree "$r" 7.3.1-sky1-ncz 7.3.1-sky1-ncz+r297; lifecycle "$r"
expect "arm64: 7.3.1-sky1-ncz +r297 = CURRENT" 0 "OK" python3 "$GATE" --root "$r" --arch arm64
r="$W/p3"; amd64tree "$r" 7.3.3-t2-ncz 7.3.3-r297; arm64tree "$r" 7.3.3-sky1-ncz 7.3.3-sky1-ncz+r300
lifecycle "$r" MIN_VERSION=7.3.3 CURRENT_KVER_amd64=7.3.3-t2-ncz CURRENT_PKG_amd64=7.3.3-r297 \
    CURRENT_KVER_arm64=7.3.3-sky1-ncz CURRENT_PKG_arm64=7.3.3-sky1-ncz+r300 \
    RETIRED=7.3.0-t2-ncz,7.3.0-sky1-ncz,7.3.1-t2-ncz,7.3.1-sky1-ncz
expect "both arches: a promotion (7.3.3 current, 7.3.1 retired)" 0 "OK" python3 "$GATE" --root "$r" --arch all
r="$W/p4"; amd64tree "$r" 7.3.1-t2-ncz 7.3.1-r295; lifecycle "$r" CURRENT_PKG_amd64=
expect "amd64: CURRENT_PKG empty = any revision of the current KVER" 0 "" python3 "$GATE" --root "$r" --arch amd64

echo "=== negative: retired or too old ==="
r="$W/n1"; amd64tree "$r" 7.3.0-t2-ncz 7.3.0-2; lifecycle "$r" CURRENT_KVER_amd64=7.3.0-t2-ncz CURRENT_PKG_amd64=7.3.0-2
expect "amd64: 7.3.0-t2-ncz (rc3's kernel) refused as retired" 1 "retired" python3 "$GATE" --root "$r" --arch amd64
r="$W/n2"; arm64tree "$r" 7.3.0-sky1-ncz 7.3.0-sky1-ncz+r293; lifecycle "$r" CURRENT_KVER_arm64=7.3.0-sky1-ncz CURRENT_PKG_arm64=7.3.0-sky1-ncz+r293
expect "arm64: 7.3.0-sky1-ncz (rc3's kernel) refused as retired" 1 "retired" python3 "$GATE" --root "$r" --arch arm64
r="$W/n3"; amd64tree "$r" 7.3.1-t2-ncz 7.3.1-r295; lifecycle "$r" MIN_VERSION=7.3.0 RETIRED=7.3.1-t2-ncz
expect "amd64: retired even when above MIN_VERSION" 1 "retired" python3 "$GATE" --root "$r" --arch amd64
r="$W/n4"; amd64tree "$r" 7.3.0-rc7-t2-ncz 7.3.0-rc7-2; lifecycle "$r" CURRENT_KVER_amd64=7.3.0-rc7-t2-ncz CURRENT_PKG_amd64=7.3.0-rc7-2
expect "amd64: 7.3.0-rc7 below MIN_VERSION 7.3.1 refused" 1 "below" python3 "$GATE" --root "$r" --arch amd64
r="$W/n5"; amd64tree "$r" 7.3.1-rc2-t2-ncz 7.3.1-rc2-1; lifecycle "$r" CURRENT_KVER_amd64=7.3.1-rc2-t2-ncz CURRENT_PKG_amd64=7.3.1-rc2-1
expect "amd64: 7.3.1-rc2 sorts below 7.3.1 final" 1 "below" python3 "$GATE" --root "$r" --arch amd64
r="$W/n6"; amd64tree "$r" 7.2.9-2-t2-ncz 7.2.9-2; lifecycle "$r" CURRENT_KVER_amd64=7.2.9-2-t2-ncz CURRENT_PKG_amd64=7.2.9-2
expect "amd64: 7.2.9 below MIN_VERSION refused" 1 "below" python3 "$GATE" --root "$r" --arch amd64

echo "=== negative: pin disagrees with the promoted CURRENT ==="
r="$W/n7"; amd64tree "$r" 7.3.3-t2-ncz 7.3.3-r297; lifecycle "$r"
expect "amd64: pin 7.3.3 while CURRENT is 7.3.1 (unpromoted kernel) refused" 1 "CURRENT" python3 "$GATE" --root "$r" --arch amd64
r="$W/n8"; amd64tree "$r" 7.3.1-t2-ncz 7.3.1-r999; lifecycle "$r"
expect "amd64: PKGVERSION differs from CURRENT_PKG refused" 1 "CURRENT_PKG" python3 "$GATE" --root "$r" --arch amd64
r="$W/n9"; arm64tree "$r" 7.3.1-sky1-ncz 7.3.1-sky1-ncz+r295; lifecycle "$r"
expect "arm64: kernel deb +r295 while CURRENT_PKG is +r297 refused" 1 "CURRENT_PKG" python3 "$GATE" --root "$r" --arch arm64
r="$W/n10"; arm64tree "$r" 7.3.1-sky1-ncz 7.3.1-sky1-ncz+r297; lifecycle "$r" CURRENT_KVER_arm64= CURRENT_PKG_arm64=
expect "arm64: no promoted CURRENT kernel fails closed" 1 "no promoted" python3 "$GATE" --root "$r" --arch arm64

echo "=== negative: pin sources disagree / ledger / lifecycle file ==="
r="$W/n11"; amd64tree "$r" 7.3.1-t2-ncz 7.3.1-r295 7.3.0-t2-ncz 7.3.0-2; lifecycle "$r"
expect "amd64: manifest still names 7.3.0 while KVER says 7.3.1" 1 "disagree|retired" python3 "$GATE" --root "$r" --arch amd64
r="$W/n12"; arm64tree "$r" 7.3.1-sky1-ncz 7.3.1-sky1-ncz+r297 7.3.0-sky1-ncz; lifecycle "$r"
expect "arm64: sky1-manifest.json still names 7.3.0" 1 "disagree|retired" python3 "$GATE" --root "$r" --arch arm64
r="$W/n13"; amd64tree "$r" 7.3.1-t2-ncz 7.3.1-r295; lifecycle "$r"
printf 'linux-image-7.3.0-t2-ncz\t7.3.0-2\tamd64\t%064d\tbuild/stage-amd64-kernel.sh\tx\tn\n' 0 >> "$r/manifests/ncz-packages.tsv"
expect "amd64: ledger row for a retired kernel refused" 1 "ncz-packages.tsv.*retired" python3 "$GATE" --root "$r" --arch amd64
r="$W/n14"; amd64tree "$r" 7.3.1-t2-ncz 7.3.1-r295
expect "amd64: no KERNEL-LIFECYCLE file fails closed" 1 "KERNEL-LIFECYCLE" python3 "$GATE" --root "$r" --arch amd64
r="$W/n15"; amd64tree "$r" 7.3.1-t2-ncz 7.3.1-r295; lifecycle "$r" RETIRED=7.3.0-t2-ncz,7.3.1-t2-ncz
expect "lifecycle: CURRENT listed as RETIRED is self-contradictory" 1 "retired" python3 "$GATE" --root "$r" --arch amd64
r="$W/n16"; amd64tree "$r" 7.3.1-t2-ncz 7.3.1-r295; lifecycle "$r" MIN_VERSION="<absent>"
expect "lifecycle: missing MIN_VERSION refused" 1 "MIN_VERSION" python3 "$GATE" --root "$r" --arch amd64
r="$W/n17"; amd64tree "$r" banana-t2-ncz 1; lifecycle "$r" CURRENT_KVER_amd64=banana-t2-ncz CURRENT_PKG_amd64=1
expect "amd64: unparseable KVER refused" 1 "parse" python3 "$GATE" --root "$r" --arch amd64
r="$W/n18"; amd64tree "$r" 7.3.1-t2-ncz 7.3.1-r295; lifecycle "$r" LIFECYCLE_SCHEMA=2
expect "lifecycle: unknown schema refused" 1 "SCHEMA" python3 "$GATE" --root "$r" --arch amd64
expect "misuse: bad --arch" 2 "" python3 "$GATE" --root "$W/p1" --arch riscv64

echo "=== the policy verifier runs the lifecycle gate ==="
grep -q 'check-kernel-lifecycle.py' "$POLICY_VERIFIER" \
    && ok "verify-kernel-default-policy.sh calls check-kernel-lifecycle.py" \
    || bad "verify-kernel-default-policy.sh does not call check-kernel-lifecycle.py"

echo "=== real tree ==="
LC="$REPO/assets/kernel/KERNEL-LIFECYCLE"
if [ -s "$LC" ]; then
    ok "assets/kernel/KERNEL-LIFECYCLE is committed"
    for k in 7.3.0-t2-ncz 7.3.0-sky1-ncz; do
        sed -nE 's/^RETIRED=(.*)/\1/p' "$LC" | tr ',' '\n' | grep -qx "$k" \
            && ok "real RETIRED lists $k" || bad "real RETIRED does not list $k"
    done
    min=$(sed -nE 's/^MIN_VERSION=([^[:space:]#]+).*/\1/p' "$LC")
    [ "$(printf '%s\n7.3.1\n' "$min" | sort -V | head -1)" = 7.3.1 ] \
        && ok "real MIN_VERSION ($min) >= 7.3.1" || bad "real MIN_VERSION ($min) < 7.3.1"
else
    bad "assets/kernel/KERNEL-LIFECYCLE is not committed"
fi
expect "real tree amd64 pins pass the lifecycle gate" 0 "OK" python3 "$GATE" --root "$REPO" --arch amd64
# arm64 must pass exactly when a Sky1 kernel has been promoted; with none
# promoted (CURRENT_KVER_arm64 empty) the gate must refuse the build.
if [ -n "$(sed -nE 's/^CURRENT_KVER_arm64=([^[:space:]#]*).*/\1/p' "$LC" 2>/dev/null)" ]; then
    expect "real tree arm64 pins pass (a Sky1 kernel is promoted)" 0 "OK" python3 "$GATE" --root "$REPO" --arch arm64
else
    expect "real tree arm64 refused while no Sky1 kernel is promoted" 1 "no promoted|retired" python3 "$GATE" --root "$REPO" --arch arm64
fi

echo
echo "=== summary: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" = 0 ]
