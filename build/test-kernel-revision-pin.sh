#!/bin/bash
# test-kernel-revision-pin.sh -- docs/BUILD-STABILITY.md M7: the Sky1 kernel
# pin compares each deb's FULL Version (7.3.0-sky1-ncz+r293, 1.6+r293) and
# sha256 with assets/kernel-manifest.json, not just the KVER.
#
# Drives build/check-kernel-deb-pin.sh --manifest on throwaway debs, the real
# build/build-vendor-mirror.sh end to end (its pin runs before any network
# step), and asserts every caller passes --manifest: the vendor mirror (both
# calls), the Makefile kernel-debs reuse decision, and build-image.sh
# preflight's pin-coherence step (which compares mainline.release's revision
# with the manifest before stage 40 can build anything).
#
# Run: bash build/test-kernel-revision-pin.sh     Exit 0 = all cases pass.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
PIN="$HERE/check-kernel-deb-pin.sh"
for t in dpkg-deb python3 sha256sum; do
    command -v "$t" >/dev/null 2>&1 || { echo "FAIL: required test tool not available: $t" >&2; exit 1; }
done
W="$(mktemp -d "${TMPDIR:-$HOME}/.kernel-revision-pin-test.XXXXXX")"; trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }
expect_rc() {  # label want-rc cmd...
    local label="$1" want="$2" rc=0 out; shift 2
    out="$("$@" 2>&1)" || rc=$?
    if [ "$rc" = "$want" ]; then ok "$label (rc=$rc)"; else bad "$label: rc=$rc, wanted $want" "$out"; fi
    LAST="$out"
}

mkdeb() {  # dir pkg version [payload]
    local d="$1" root="$W/pkg.$RANDOM$RANDOM"
    mkdir -p "$root/DEBIAN" "$root/usr/share/doc/$2" "$d"
    printf 'Package: %s\nVersion: %s\nArchitecture: arm64\nMaintainer: t <t@t>\nDescription: pin fixture\n' \
        "$2" "$3" > "$root/DEBIAN/control"
    printf '%s\n' "${4:-$2 $3}" > "$root/usr/share/doc/$2/payload"
    SOURCE_DATE_EPOCH=1700000000 dpkg-deb --build --root-owner-group "$root" "$d/${2}_${3}_arm64.deb" >/dev/null
}
kset() {  # dir rev [payload-tag]
    mkdeb "$1" linux-image-cixmini   "7.3.0-sky1-ncz+$2" "img $2 ${3:-}"
    mkdeb "$1" linux-headers-cixmini "7.3.0-sky1-ncz+$2" "hdr $2 ${3:-}"
    mkdeb "$1" cixmini-boot          "1.6+$2"            "boot $2 ${3:-}"
}
mkmanifest() {  # out deb-dir -- a manifest pinning exactly the debs in deb-dir
    python3 -I - "$1" "$2" <<'PY'
import hashlib, json, sys
from pathlib import Path
debs = sorted(Path(sys.argv[2]).glob("*.deb"))
json.dump({"schema": 1, "kernel_debs": [
    {"file": "build/kernel-debs/" + p.name, "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}
    for p in debs], "variants": {"mainline": {"kver": "7.3.0-sky1-ncz"}}}, open(sys.argv[1], "w"), indent=1)
PY
}
printf '7.3.0-sky1-ncz' > "$W/KVER"

kset "$W/r293" r293;           mkmanifest "$W/m293.json" "$W/r293"
kset "$W/r292" r292
kset "$W/r293b" r293 rebuilt   # same versions, different bytes

echo "=== 1. positive ==="
expect_rc "r293 debs with an r293 manifest pass" 0 bash "$PIN" --manifest "$W/m293.json" "$W/KVER" "$W/r293"
if grep -q "Version and sha256 match" <<<"$LAST"; then ok "  OK line names the manifest"; else bad "  OK line lacks the manifest" "$LAST"; fi
mkdir -p "$W/empty"
expect_rc "a dir with no Sky1 kernel debs passes (amd64 mirror)" 0 bash "$PIN" --manifest "$W/m293.json" "$W/KVER" "$W/empty"
expect_rc "--manifest without a value is a usage error" 2 bash "$PIN" --manifest

echo "=== 2. negative ==="
expect_rc "r292 debs under an r293 manifest FAIL" 1 bash "$PIN" --manifest "$W/m293.json" "$W/KVER" "$W/r292"
if grep -q "linux-image-cixmini 7.3.0-sky1-ncz+r292 is not the pinned revision 7.3.0-sky1-ncz+r293" <<<"$LAST"; then ok "  finding names both revisions"; else bad "  finding does not name both revisions" "$LAST"; fi
expect_rc "  (the KVER-only pin passes them: why M7 exists)" 0 bash "$PIN" "$W/KVER" "$W/r292"
expect_rc "same Version, wrong sha256 FAILS" 1 bash "$PIN" --manifest "$W/m293.json" "$W/KVER" "$W/r293b"
if grep -q "sha256 .* != pinned" <<<"$LAST"; then ok "  finding names the sha mismatch"; else bad "  sha mismatch not named" "$LAST"; fi
mkdir -p "$W/part"; cp "$W/r293"/linux-image-cixmini_* "$W/r293"/linux-headers-cixmini_* "$W/part/"
expect_rc "an incomplete set (no cixmini-boot) FAILS" 1 bash "$PIN" --manifest "$W/m293.json" "$W/KVER" "$W/part"
if grep -q "incomplete Sky1 kernel set: cixmini-boot" <<<"$LAST"; then ok "  finding names the missing package"; else bad "  missing package not named" "$LAST"; fi
printf '{"kernel_debs": "nope"}' > "$W/broken.json"
expect_rc "an unreadable manifest FAILS a dir holding kernel debs" 1 bash "$PIN" --manifest "$W/broken.json" "$W/KVER" "$W/r293"
expect_rc "a missing manifest FAILS a dir holding kernel debs" 1 bash "$PIN" --manifest "$W/no-such.json" "$W/KVER" "$W/r293"

echo "=== 3. build-vendor-mirror.sh end to end: r292 debs, r293 manifest ==="
mkdir -p "$W/mirror"
expect_rc "vendor mirror refuses r292 debs under the r293 manifest" 1 env \
    KERNEL_DEBS="$W/r292" VENDOR_MIRROR="$W/mirror" SKY1_KVER_FILE="$W/KVER" \
    SKY1_KERNEL_MANIFEST="$W/m293.json" \
    ARCH=arm64 USB_RECOVERY_DEBS="$W/none" SINTY_DEBS="$W/none" CHROME_DEB_CACHE="$W/chrome" \
    bash "$REPO/build/build-vendor-mirror.sh"
if grep -q "is not the pinned revision" <<<"$LAST"; then ok "  refused by the revision pin"; else bad "  refused for another reason" "$LAST"; fi
if find "$W/mirror" -name '*.deb' | grep -q .; then bad "vendor mirror pool is not empty after the refused run"
else ok "nothing was published by the refused run"; fi

echo "=== 4. every caller pins the revision ==="
# The patterns below match source text, so their $ are literal (SC2016).
# shellcheck disable=SC2016
n="$(grep -c 'check-kernel-deb-pin.sh" --manifest "\$SKY1_KERNEL_MANIFEST"' "$REPO/build/build-vendor-mirror.sh")"
if [ "$n" = 2 ]; then ok "build-vendor-mirror.sh: both kernel-pin calls pass --manifest"
else bad "build-vendor-mirror.sh: $n of 2 kernel-pin calls pass --manifest"; fi
# shellcheck disable=SC2016
if grep -q 'check-kernel-deb-pin.sh --manifest "$(ROOT)/assets/kernel-manifest.json" "$(ROOT)/assets/kernel/mainline/KVER" "$(BUILD)/kernel-debs"' "$REPO/Makefile"; then
    ok "Makefile kernel-debs reuse decision passes --manifest"
else bad "Makefile kernel-debs reuse decision does not pass --manifest"; fi
pf="$(sed -n '/^stage_preflight() {/,/^}/p' "$REPO/build/build-image.sh")"
# shellcheck disable=SC2016
if grep -q 'build/check-pin-coherence.sh" --root "\$ROOT" --arch "\$ARCH"' <<<"$pf"; then
    ok "build-image.sh stage_preflight runs check-pin-coherence.sh for the build arch"
else bad "stage_preflight does not run check-pin-coherence.sh"; fi

echo
echo "kernel revision pin tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
