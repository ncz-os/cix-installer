#!/bin/bash
# test-kernel-revision-pin.sh -- docs/BUILD-STABILITY.md M7: the Sky1 kernel
# pin compares each deb's FULL Version (7.3.0-sky1-ncz+r293, 1.6+r293) and
# sha256 with assets/kernel-manifest.json, not just the KVER.
#
# Drives build/check-kernel-deb-pin.sh --manifest on throwaway debs, the real
# build/build-vendor-mirror.sh end to end (its pin runs before any network
# step), and asserts every caller passes --manifest: the vendor mirror (both
# calls), the Makefile kernel-debs reuse decision, and build-image.sh
# preflight's pin-coherence step (which compares the packaging revision
# with the manifest before stage 40 can build anything).
#
# Run: bash build/test-kernel-revision-pin.sh     Exit 0 = all cases pass.

# This suite builds .deb fixtures. If the host cannot, say so once instead of
# letting every assertion fail on an empty archive (build/lib/deb-fixture.sh).
# shellcheck source=lib/deb-fixture.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/deb-fixture.sh"
ncz_deb_fixture_check || { echo "test-kernel-revision-pin: ENVIRONMENT: this host cannot build deb fixtures; not a code failure" >&2; exit 3; }

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
if grep  "Version and sha256 match" <<<"$LAST" >/dev/null; then ok "  OK line names the manifest"; else bad "  OK line lacks the manifest" "$LAST"; fi
mkdir -p "$W/empty"
expect_rc "a dir with no Sky1 kernel debs passes (amd64 mirror)" 0 bash "$PIN" --manifest "$W/m293.json" "$W/KVER" "$W/empty"
expect_rc "--manifest without a value is a usage error" 2 bash "$PIN" --manifest

echo "=== 2. negative ==="
expect_rc "r292 debs under an r293 manifest FAIL" 1 bash "$PIN" --manifest "$W/m293.json" "$W/KVER" "$W/r292"
if grep  "linux-image-cixmini 7.3.0-sky1-ncz+r292 is not the pinned revision 7.3.0-sky1-ncz+r293" <<<"$LAST" >/dev/null; then ok "  finding names both revisions"; else bad "  finding does not name both revisions" "$LAST"; fi
expect_rc "  (the KVER-only pin passes them: why M7 exists)" 0 bash "$PIN" "$W/KVER" "$W/r292"
expect_rc "same Version, wrong sha256 FAILS" 1 bash "$PIN" --manifest "$W/m293.json" "$W/KVER" "$W/r293b"
if grep  "sha256 .* != pinned" <<<"$LAST" >/dev/null; then ok "  finding names the sha mismatch"; else bad "  sha mismatch not named" "$LAST"; fi
mkdir -p "$W/part"; cp "$W/r293"/linux-image-cixmini_* "$W/r293"/linux-headers-cixmini_* "$W/part/"
expect_rc "an incomplete set (no cixmini-boot) FAILS" 1 bash "$PIN" --manifest "$W/m293.json" "$W/KVER" "$W/part"
if grep  "incomplete Sky1 kernel set: cixmini-boot" <<<"$LAST" >/dev/null; then ok "  finding names the missing package"; else bad "  missing package not named" "$LAST"; fi
printf '{"kernel_debs": "nope"}' > "$W/broken.json"
expect_rc "an unreadable manifest FAILS a dir holding kernel debs" 1 bash "$PIN" --manifest "$W/broken.json" "$W/KVER" "$W/r293"
expect_rc "a missing manifest FAILS a dir holding kernel debs" 1 bash "$PIN" --manifest "$W/no-such.json" "$W/KVER" "$W/r293"
# Review 2026-11-01 (item 3): a malformed manifest is fatal even when no
# directory holds a Sky1 deb (amd64 mirror, empty pool, or a dir that does
# not exist yet): a broken pin file must never read as "nothing to check".
expect_rc "an unreadable manifest FAILS even with no Sky1 debs present" 1 bash "$PIN" --manifest "$W/broken.json" "$W/KVER" "$W/empty"
if grep  "kernel-pin\] FAIL: .*broken.json" <<<"$LAST" >/dev/null; then ok "  finding names the manifest"; else bad "  manifest not named" "$LAST"; fi
expect_rc "a missing manifest FAILS even with no Sky1 debs present" 1 bash "$PIN" --manifest "$W/no-such.json" "$W/KVER" "$W/empty"
expect_rc "a malformed manifest FAILS even when no deb dir exists" 1 bash "$PIN" --manifest "$W/broken.json" "$W/KVER" "$W/no-such-dir"
printf '{"kernel_debs": []}' > "$W/nodebs.json"
expect_rc "a manifest that pins no kernel debs FAILS" 1 bash "$PIN" --manifest "$W/nodebs.json" "$W/KVER" "$W/empty"

echo "=== 3. build-vendor-mirror.sh end to end: r292 debs, r293 manifest ==="
mkdir -p "$W/mirror"
expect_rc "vendor mirror refuses r292 debs under the r293 manifest" 1 env \
    KERNEL_DEBS="$W/r292" VENDOR_MIRROR="$W/mirror" SKY1_KVER_FILE="$W/KVER" \
    SKY1_KERNEL_MANIFEST="$W/m293.json" \
    ARCH=arm64 USB_RECOVERY_DEBS="$W/none" SINTY_DEBS="$W/none" CHROME_DEB_CACHE="$W/chrome" \
    bash "$REPO/build/build-vendor-mirror.sh"
if grep  "is not the pinned revision" <<<"$LAST" >/dev/null; then ok "  refused by the revision pin"; else bad "  refused for another reason" "$LAST"; fi
if find "$W/mirror" -name '*.deb' | grep  . >/dev/null; then bad "vendor mirror pool is not empty after the refused run"
else ok "nothing was published by the refused run"; fi

echo "=== 3b. build-kernel-debs.sh packaging revision ==="
# r293 repackaged the r292 staged release: mainline.release names the staged
# dir, assets/kernel/mainline.deb-revision the revision the debs must carry.
# Without it, stage 40 can only ever build +r292 (the R2 failure).
KD="$W/kd"; mkdir -p "$KD/build" "$KD/assets/kernel" "$KD/manifests"
cp "$REPO/build/build-kernel-debs.sh" "$KD/build/"; cp "$REPO/manifests/base.pin" "$KD/manifests/"
echo "r292-7.3.0-sky1-ncz-20261023" > "$KD/assets/kernel/mainline.release"
kd_rev() { env -u BUILD_REV "$@" bash "$KD/build/build-kernel-debs.sh" --print-build-rev; }
expect_rc "no deb-revision: BUILD_REV is the staged r292" 0 kd_rev
[ "$LAST" = r292 ] && ok "  -> r292" || bad "  wanted r292" "$LAST"
printf '# packaging revision over the staged release\nr293\n' > "$KD/assets/kernel/mainline.deb-revision"
expect_rc "deb-revision r293 over staged r292: BUILD_REV is r293" 0 kd_rev
[ "$LAST" = r293 ] && ok "  -> r293" || bad "  wanted r293" "$LAST"
expect_rc "an explicit BUILD_REV still wins" 0 kd_rev BUILD_REV=r295
[ "$LAST" = r295 ] && ok "  -> r295" || bad "  wanted r295" "$LAST"
# Review 2026-11-01 (DeepSeek item 2): --print-build-rev is a pure query.  It
# was recognised only as $1; anywhere else the script ran the real packaging
# path (rm -rf build/kernel-debs and onward).  It must be honoured in any
# position and leave the tree untouched.
kd_tree() { (cd "$KD" && find . -printf '%p %s %T@\n' | sort); }
before="$(kd_tree)"
expect_rc "--print-build-rev after another argument is still the query" 0 \
    env -u BUILD_REV bash "$KD/build/build-kernel-debs.sh" --unused --print-build-rev
[ "$LAST" = r293 ] && ok "  -> r293" || bad "  wanted r293" "$LAST"
[ "$before" = "$(kd_tree)" ] && ok "  the query wrote nothing under the tree" \
    || bad "  the query changed the tree" "$(diff <(printf '%s\n' "$before") <(kd_tree))"
printf 'r291\n' > "$KD/assets/kernel/mainline.deb-revision"
expect_rc "deb-revision older than the staged release is refused" 1 kd_rev
grep  "mainline.deb-revision" <<<"$LAST" >/dev/null && ok "  refusal names mainline.deb-revision" || bad "  refused for another reason" "$LAST"
printf '293\n' > "$KD/assets/kernel/mainline.deb-revision"
expect_rc "a malformed deb-revision is refused" 1 kd_rev
grep  "mainline.deb-revision" <<<"$LAST" >/dev/null && ok "  refusal names mainline.deb-revision" || bad "  refused for another reason" "$LAST"
printf '# empty\n' > "$KD/assets/kernel/mainline.deb-revision"
expect_rc "an empty deb-revision is refused" 1 kd_rev
grep  "mainline.deb-revision" <<<"$LAST" >/dev/null && ok "  refusal names mainline.deb-revision" || bad "  refused for another reason" "$LAST"

echo "=== 3c. the pinned revision's deb epoch does not follow base.pin ==="
# 2026-11-07: the substrate re-pin to 20261102T082611Z (c9b4ef0d) moved the
# arm64 snapshot, build-kernel-debs.sh derived SOURCE_DATE_EPOCH from it for
# r293, and every member mtime changed: the same staged r292 inputs repacked
# to three sha256s that kernel-manifest.json does not pin (vendor-mirror
# kernel-pin FAIL).  The pinned r293 debs carry the 20261018T082309Z snapshot
# epoch.  A revision whose debs are pinned must have a frozen epoch.
mkdir -p "$KD/build/lib"; cp "$REPO/build/lib/reproducible.py" "$KD/build/lib/"
pinned_rev="$(python3 -I -c '
import json, re, sys
for d in json.load(open(sys.argv[1], encoding="utf-8"))["kernel_debs"]:
    m = re.match(r"^linux-image-cixmini_[^_]*\+(r[0-9]+)_arm64\.deb$", d["file"].rsplit("/", 1)[-1])
    if m: print(m.group(1))
' "$REPO/assets/kernel-manifest.json")"
[ -n "$pinned_rev" ] && ok "kernel-manifest.json pins linux-image-cixmini at $pinned_rev" \
    || bad "kernel-manifest.json pins no linux-image-cixmini revision"
printf '%s\n' "$pinned_rev" > "$KD/assets/kernel/mainline.deb-revision"
kd_epoch() { env -u BUILD_REV -u NCZ_KERNEL_DEB_EPOCH bash "$KD/build/build-kernel-debs.sh" --print-deb-epoch; }
set_snapshot() {  # rewrite the arm64 snapshot column of the sandbox base.pin
    awk -F'\t' -v OFS='\t' -v s="$1" '$1=="arm64"{$4=s} {print}' "$REPO/manifests/base.pin" > "$KD/manifests/base.pin"
}
set_snapshot 20261018T082309Z
before="$(kd_tree)"
expect_rc "--print-deb-epoch at snapshot 20261018T082309Z" 0 kd_epoch
e1="$LAST"
[ "$before" = "$(kd_tree)" ] && ok "  the epoch query wrote nothing under the tree" \
    || bad "  the epoch query changed the tree" "$(diff <(printf '%s\n' "$before") <(kd_tree))"
set_snapshot 20261201T000000Z
expect_rc "--print-deb-epoch at snapshot 20261201T000000Z" 0 kd_epoch
e2="$LAST"
case "$e1" in ''|*[!0-9]*) bad "  epoch is not an integer" "$e1"; e1="?$e1" ;; *) ok "  epoch is an integer ($e1)" ;; esac
[ "$e1" = "$e2" ] && ok "  $pinned_rev epoch is frozen across base.pin refreshes ($e1)" \
    || bad "  $pinned_rev epoch follows base.pin ($e1 -> $e2): its pinned debs cannot be rebuilt"
if [ "$pinned_rev" = r293 ]; then
    [ "$e1" = 1792311789 ] && ok "  r293 epoch is 1792311789 (20261018T082309Z, the pinned debs' mtime)" \
        || bad "  r293 epoch $e1 is not 1792311789, the mtime of the pinned r293 debs"
fi
cp "$REPO/manifests/base.pin" "$KD/manifests/base.pin"
expect_rc "NCZ_KERNEL_DEB_EPOCH still overrides the frozen epoch" 0 \
    env -u BUILD_REV NCZ_KERNEL_DEB_EPOCH=1700000000 bash "$KD/build/build-kernel-debs.sh" --print-deb-epoch
[ "$LAST" = 1700000000 ] && ok "  -> 1700000000" || bad "  wanted 1700000000" "$LAST"

echo "=== 4. every caller pins the revision ==="
# The patterns below match source text, so their $ are literal (SC2016).
# shellcheck disable=SC2016
n="$(grep -c 'check-kernel-deb-pin.sh" --manifest "\$SKY1_KERNEL_MANIFEST"' "$REPO/build/build-vendor-mirror.sh")"
if [ "$n" = 2 ]; then ok "build-vendor-mirror.sh: both kernel-pin calls pass --manifest"
else bad "build-vendor-mirror.sh: $n of 2 kernel-pin calls pass --manifest"; fi
# shellcheck disable=SC2016
if grep  'check-kernel-deb-pin.sh --manifest "$(ROOT)/assets/kernel-manifest.json" "$(ROOT)/assets/kernel/mainline/KVER" "$(BUILD)/kernel-debs"' "$REPO/Makefile" >/dev/null; then
    ok "Makefile kernel-debs reuse decision passes --manifest"
else bad "Makefile kernel-debs reuse decision does not pass --manifest"; fi
pf="$(sed -n '/^stage_preflight() {/,/^}/p' "$REPO/build/build-image.sh")"
# shellcheck disable=SC2016
# (through build/lib/pin-coherence-gate.sh, which runs the checker it is given
# with --root/--arch; the WARN/abort decision is tested in test-build-image.sh 2f)
if grep  'ncz_pin_coherence_gate "\$ROOT/build/check-pin-coherence.sh" "\$ROOT" "\$ARCH"' <<<"$pf" >/dev/null \
   && grep  'bash "\$checker" --root "\$root" --arch "\$arch"' "$REPO/build/lib/pin-coherence-gate.sh" >/dev/null; then
    ok "build-image.sh stage_preflight runs check-pin-coherence.sh for the build arch"
else bad "stage_preflight does not run check-pin-coherence.sh"; fi

echo
echo "kernel revision pin tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
