#!/bin/bash
# test-native-apt-overrides.sh -- prove the 2026-10-15 (native Forky policy) native Forky-only
# rows of ncz_apt_debian_overrides are enforced where they actually bite: at
# PUBLICATION time, by build/check-ncz-repo-policy.sh reading a real Packages
# index.
#
# build/test-apt-separation.sh proves the other half -- that on an installed
# system the resulting pin resolves the same names from NCZ and blocks the whole
# foreign T2/Intel hosts. This policy retains name-based client pins; the arch
# half of a row ('all,amd64' for the apples, 'amd64' for the selected Intel
# names) is enforced by refusing to publish the wrong architecture.
# That is this file: one tiny Packages index per expectation, run through the
# real checker, asserting the real verdict (exit 0 clean / exit 1 with the
# matching violation class) rather than any implementation string.
#
# Every version below is a labelled SYNTHETIC fixture value (9.9.9+ncz1) in a
# file this script writes under $TMPDIR. No real artefact, index, repo or
# network is touched; nothing is built, downloaded, signed or installed.
#
# Expectations covered:
#   A/B  apple-t2-audio-config, apple-firmware-script   all pass, amd64 pass, arm64 refused
#   C    libopenvino-2026.4.1 + the three intel-* plugins  amd64 pass, all/arm64 refused
#   D    intel-{driver-compiler,fw,level-zero,validation}-npu  amd64 pass, all/arm64 refused
#   --   apple-t2-other / libopenvino-extra / intel-other refused: unlisted names
#        must NOT pass just because they look like an allowlisted family
#   --   the pre-existing protections (Debian kernel names, libdrm*, libgtk4-layer-shell0)
#        still hold, so this file cannot mask a regression in the older rows
#
# Negative proof against the baseline rejects newly allowed positive cases;
# unrelated-name and pre-existing negative checks remain valid.
#
# Usage: build/test-native-apt-overrides.sh    (exit 0 = every expectation held)
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CHECK="$HERE/check-ncz-repo-policy.sh"
for c in awk mktemp cat; do
    command -v "$c" >/dev/null 2>&1 || { echo "SKIP: $c not available"; exit 0; }
done
[ -r "$CHECK" ] || { echo "SKIP: $CHECK not readable"; exit 0; }
# Honour the caller's TMPDIR (the supervisor points it inside ~/Projects); only
# this script's own scratch directory is ever removed.
[ -n "${TMPDIR:-}" ] && [ -d "$TMPDIR" ] || { echo "ERROR: set TMPDIR to a disk-backed Projects directory" >&2; exit 1; }
if command -v findmnt >/dev/null && [ "$(findmnt -no FSTYPE -T "$TMPDIR")" = tmpfs ]; then
    echo "ERROR: TMPDIR must not be tmpfs" >&2; exit 1
fi
T="$(mktemp -d "$TMPDIR/ncz-native-apt-overrides.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; return 0; }

# idx FILE NAME:ARCH... -- a minimal Packages index, one stanza per row.
idx() {
    local f="$1" tok; shift
    : > "$f"
    for tok in "$@"; do
        printf 'Package: %s\nVersion: 9.9.9+ncz1\nArchitecture: %s\nPriority: optional\nSection: misc\nInstalled-Size: 1\nMaintainer: Fixture <f@example.invalid>\nDescription: synthetic fixture row\nFilename: ./%s_9.9.9+ncz1.deb\nSize: 1\nSHA256: %064d\n\n' \
            "${tok%%:*}" "${tok##*:}" "${tok%%:*}" 0 >> "$f"
    done
}
run() { OUT="$(bash "$CHECK" "$1" 2>&1)"; RC=$?; }
want_pass() {  # label index
    run "$2"
    if [ "$RC" -eq 0 ]; then ok "$1"
    else bad "$1 (rc=$RC, wanted a clean verdict from check-ncz-repo-policy.sh)" "$OUT"; fi
}
want_fail() {  # label index expected-violation-class
    run "$2"
    if [ "$RC" -ne 1 ]; then bad "$1 (rc=$RC, wanted a policy violation)" "$OUT"; return; fi
    if printf '%s\n' "$OUT" | grep >/dev/null -F -- "$3"; then ok "$1 -- refused as: $3"
    else bad "$1: rc=1, but not for the expected reason ($3)" "$OUT"; fi
}

ARCHMSG='is an allowlisted Debian-name override but NOT for architecture'
UNLISTED='is a Debian-named package in the NCZ suite and is not in the allowlist'
KERNELMSG='is a Debian kernel name'

echo "=== A/B: apple-t2-audio-config, apple-firmware-script (rows: all,amd64) ==="
idx "$T/ab-all"    apple-t2-audio-config:all apple-firmware-script:all
idx "$T/ab-amd64"  apple-t2-audio-config:amd64 apple-firmware-script:amd64
idx "$T/ab-arm64"  apple-t2-audio-config:arm64 apple-firmware-script:arm64
want_pass "Architecture: all publishes (these are the real artifacts' architecture)" "$T/ab-all"
want_pass "amd64 publishes"                                                   "$T/ab-amd64"
want_fail "arm64 is refused"                                                  "$T/ab-arm64" "$ARCHMSG arm64"

echo "=== C: libopenvino-2026.4.1 + its three intel plugin shlibs (rows: amd64 ONLY) ==="
for n in libopenvino-2026.4.1 libopenvino-intel-cpu-plugin-2026.4.1 \
         libopenvino-intel-gpu-plugin-2026.4.1 libopenvino-intel-npu-plugin-2026.4.1; do
    idx "$T/c4"    "$n:amd64"
    idx "$T/c4all" "$n:all"
    idx "$T/c4arm" "$n:arm64"
    want_pass "$n amd64 publishes"        "$T/c4"
    want_fail "$n all is refused"         "$T/c4all" "$ARCHMSG all"
    want_fail "$n arm64 is refused"       "$T/c4arm" "$ARCHMSG arm64"
done

echo "=== D: the four Intel NPU CPack components (rows: amd64 ONLY, no intel-* glob) ==="
for n in intel-driver-compiler-npu intel-fw-npu intel-level-zero-npu intel-validation-npu; do
    idx "$T/d4"    "$n:amd64"
    idx "$T/d4all" "$n:all"
    idx "$T/d4arm" "$n:arm64"
    want_pass "$n amd64 publishes"  "$T/d4"
    want_fail "$n all is refused"   "$T/d4all" "$ARCHMSG all"
    want_fail "$n arm64 is refused" "$T/d4arm" "$ARCHMSG arm64"
done

echo "=== every allowed row in one index is accepted (no row is accidentally refused) ==="
ALLOWED="apple-t2-audio-config:all apple-firmware-script:all apple-t2-audio-config:amd64 apple-firmware-script:amd64"
for n in libopenvino-2026.4.1 libopenvino-intel-cpu-plugin-2026.4.1 libopenvino-intel-gpu-plugin-2026.4.1 \
         libopenvino-intel-npu-plugin-2026.4.1 intel-driver-compiler-npu intel-fw-npu intel-level-zero-npu intel-validation-npu; do
    ALLOWED="$ALLOWED $n:amd64"
done
idx "$T/allowed" $ALLOWED
want_pass "10 allowlisted rows (12 stanzas) publish cleanly together" "$T/allowed"

echo "=== unlisted names must NOT be admitted by resemblance (no globs, no families) ==="
for n in apple-t2-other libopenvino-extra intel-other; do
    idx "$T/un" "$n:amd64"
    want_fail "unlisted $n is refused" "$T/un" "$UNLISTED"
done
for n in apple-firmware-script-other apple-t2-audio-config-dev libopenvino-forky libopenvino-intel-cpu-plugin intel-level-zero-npu-dev; do
    idx "$T/un2" "$n:amd64"
    want_fail "unlisted $n is refused too" "$T/un2" "$UNLISTED"
done

echo "=== pre-existing protections are retained (Debian kernels, libdrm*, libgtk4-layer-shell0) ==="
idx "$T/kernels" linux-image-arm64:amd64 linux-headers-amd64:all linux-image-amd64:amd64
want_fail "Debian's own kernel names are still refused" "$T/kernels" "$KERNELMSG"
idx "$T/kern-ok" linux-image-7.3.0-t2-ncz:amd64 ncz-wallpapers-ncz:all linux-headers-7.3.0-t2-ncz:amd64
want_pass "NCZ's own kernel namespace still publishes" "$T/kern-ok"
idx "$T/libdrm" libdrm-common:all libdrm2:amd64 libdrm-amdgpu1:arm64 libdrm-etnaviv1:arm64 libdrm-tegra0:arm64
want_pass "the libdrm* rows still publish for their own architectures" "$T/libdrm"
idx "$T/libdrm-bad" libdrm-etnaviv1:amd64
want_fail "an arm64-only libdrm* row is still refused for amd64" "$T/libdrm-bad" "$ARCHMSG amd64"
idx "$T/gtk" libgtk4-layer-shell0:arm64
want_pass "libgtk4-layer-shell0 still publishes for arm64" "$T/gtk"
idx "$T/gtk-bad" libgtk4-layer-shell0:amd64
want_fail "libgtk4-layer-shell0 is still refused for amd64" "$T/gtk-bad" "$ARCHMSG amd64"
idx "$T/vendor" google-chrome-stable:amd64
want_pass "vendor-staged names are not override-gated" "$T/vendor"

echo "test-native-apt-overrides: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]