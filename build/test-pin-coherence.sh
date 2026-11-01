#!/bin/bash
# test-pin-coherence.sh -- positive AND negative fixtures for
# build/check-pin-coherence.sh (docs/BUILD-STABILITY.md, measure M3).
#
# A re-pin changes one input (the substrate + its snapshot) that several
# committed files depend on.  The check proves, with no host involved, that
# every one of them agrees with the pin:
#   snapshot          base.pin amd64 == arm64 == release.conf == forky-snapshot.tsv
#                     == determinism.pin snapshot
#   sid-exceptions    every ledger row was reviewed at the current snapshot
#   rootfs-inputs     every prebuilt rootfs row in build-inputs.tsv records the
#                     snapshot it was built from, and it is the current one
#   kernel-revision   the Sky1 kernel packaging revision the build produces
#                     (assets/kernel/mainline.release) == kernel-manifest.json
#                     == the manifests/ncz-packages.tsv kernel rows
#   tracked-debs      every .deb tracked in git under assets/ has an exact
#                     (name, version, arch, sha256) row in ncz-packages.tsv or
#                     vendor-debs.tsv (.udeb is out of scope: assets/ssh-udebs are
#                     Debian udebs, authorized by the forky provenance gate)
#
# Each rule is driven on an isolated fixture repo (mktemp -d under $TMPDIR)
# with a SYNTHETIC snapshot id, so no test literal depends on the real pin.
# Section 3 runs the check on this checkout; see KNOWN_FAIL there.
#
# Usage: build/test-pin-coherence.sh        Exit 0 = all cases pass.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CHK="$ROOT/build/check-pin-coherence.sh"
T="$(mktemp -d "${TMPDIR:-$HOME}/.pin-coherence-test.XXXXXX")"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0; XFAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }
expect_rc() {  # label want-rc cmd...
    local label="$1" want="$2" rc=0 out; shift 2
    out="$("$@" 2>&1)" || rc=$?
    if [ "$rc" = "$want" ]; then ok "$label (rc=$rc)"; else bad "$label: rc=$rc, wanted $want" "$out"; fi
    LAST="$out"
}
names_rule() {  # rule -- the last output must name the failing rule
    if grep -q "FAIL $1:" <<<"$LAST"; then ok "  finding names rule '$1'"; else bad "  rule '$1' not named" "$LAST"; fi
}

for t in git python3 sha256sum; do
    command -v "$t" >/dev/null 2>&1 || { echo "FAIL: required test tool not available: $t" >&2; exit 1; }
done

# --- fixture --------------------------------------------------------------
S=20300101T000000Z          # synthetic pin
OLD=20291201T000000Z        # a synthetic older snapshot
SHA_A="$(printf 'a%.0s' {1..64})"; SHA_R="$(printf 'b%.0s' {1..64})"
sha() { sha256sum "$1" | awk '{print $1}'; }

mkfix() {  # dir -- a coherent fixture repo
    local d="$1"
    mkdir -p "$d/manifests" "$d/assets/kernel" \
             "$d/assets/screensaver/amd64" "$d/assets/screensaver/arm64" \
             "$d/assets/nvidia" "$d/assets/ssh-udebs/amd64"
    printf '# fixture\nNCZ_BASE_MIRROR_SNAPSHOT="%s"\nNCZ_BASE_MIRROR_SNAPSHOT_MAX_AGE_DAYS="14"\n' "$S" > "$d/release.conf"
    printf '# arch\tsubstrate_sha256\tsubstrate_date\tsnapshot\tcoverage_pct\tsource_url\n' > "$d/manifests/base.pin"
    printf 'amd64\t%s\tTue, 01 Jan 2030 00:00:00 UTC\t%s\t100.0\thttps://example.invalid/amd64.iso\n' "$SHA_A" "$S" >> "$d/manifests/base.pin"
    printf 'arm64\t%s\tTue, 01 Jan 2030 00:00:00 UTC\t%s\t100.0\thttps://example.invalid/arm64.iso\n' "$SHA_R" "$S" >> "$d/manifests/base.pin"
    printf '# fixture\nsnapshot\t%s\ncodename\tforky\n' "$S" > "$d/manifests/forky-snapshot.tsv"
    printf 'base_codename\tforky\nsnapshot\t%s\nsnapshot_epoch\t1893456000\nsubstrate_sha256_amd64\t%s\nsubstrate_sha256_arm64\t%s\n' \
        "$S" "$SHA_A" "$SHA_R" > "$d/manifests/determinism.pin"
    printf '# columns (TAB): name version arch sha256 class forky_version gap reason\n#  first_seen snapshot owner_action review_by tracking_url\n' > "$d/manifests/sid-exceptions.tsv"
    printf 'foo-udeb\t1.0-1\tamd64\t%s\tB\t0.9-1\tsmall\tfixture\t2029-12-01\t%s\trebuild\t2030-02-01\thttps://example.invalid/1\n' \
        "$SHA_A" "$S" >> "$d/manifests/sid-exceptions.tsv"
    {
    printf '# arch\tdest\tsha256\tsize\tnote\n'
    printf 'amd64\tassets/mgmt/ncz-mgmt-rootfs.tar.zst\t%s\t10\tmgmt rootfs (rebuilt at pinned snapshot %s)\n' "$SHA_A" "$S"
    printf 'amd64\tassets/rescue/rescue-rootfs-amd64.tar.zst\t%s\t10\trescue rootfs (rebuilt at pinned snapshot %s)\n' "$SHA_A" "$S"
    printf 'arm64\tassets/rescue/rescue-rootfs-arm64.tar.zst\t%s\t10\trescue rootfs (rebuilt at pinned snapshot %s)\n' "$SHA_R" "$S"
    printf 'amd64\tassets/python311/uv\t%s\t10\tnot a rootfs; no snapshot needed\n' "$SHA_A"
    } > "$d/manifests/build-inputs.tsv"
    # tracked debs (content is irrelevant to the rule; the bytes are hashed)
    printf 'ss-amd64' > "$d/assets/screensaver/amd64/ncz-screensavers_0.8.19_amd64.deb"
    printf 'ss-arm64' > "$d/assets/screensaver/arm64/ncz-screensavers_0.8.19_arm64.deb"
    printf 'keyring'  > "$d/assets/nvidia/cuda-keyring_1.1-1_all.deb"
    printf 'debian'   > "$d/assets/ssh-udebs/amd64/libc6-udeb_2.43-7_amd64.udeb"   # .udeb: not judged
    # Sky1 kernel at r293 everywhere
    echo "r293-7.3.0-sky1-ncz-20261027" > "$d/assets/kernel/mainline.release"
    mkmanifest "$d" r293 r293 r293
    {
        printf '# name\tversion\tarch\tsha256\trecipe\tsource_revision\tnote\n'
        kernel_ledger r293
        printf 'ncz-screensavers\t0.8.19\tamd64\t%s\tr\ts\tn\n' "$(sha "$d/assets/screensaver/amd64/ncz-screensavers_0.8.19_amd64.deb")"
        printf 'ncz-screensavers\t0.8.19\tarm64\t%s\tr\ts\tn\n' "$(sha "$d/assets/screensaver/arm64/ncz-screensavers_0.8.19_arm64.deb")"
    } > "$d/manifests/ncz-packages.tsv"
    printf '# name\tversion\tarch\tvendor\tsource\tsha256\tnote\ncuda-keyring\t1.1-1\tall\tNVIDIA\thttps://example.invalid\t%s\tn\n' \
        "$(sha "$d/assets/nvidia/cuda-keyring_1.1-1_all.deb")" > "$d/manifests/vendor-debs.tsv"
    git -C "$d" init -q
    git -C "$d" add -- assets manifests release.conf
}
ksha() {  # pkg rev -> a stable synthetic sha for that deb
    printf '%s %s' "$1" "$2" | sha256sum | awk '{print $1}'
}
mkmanifest() {  # dir boot_rev image_rev headers_rev
    cat > "$1/assets/kernel-manifest.json" <<EOF
{
  "kernel_debs": [
    {"file": "build/kernel-debs/cixmini-boot_1.6+$2_arm64.deb", "sha256": "$(ksha cixmini-boot "$2")"},
    {"file": "build/kernel-debs/linux-headers-cixmini_7.3.0-sky1-ncz+$4_arm64.deb", "sha256": "$(ksha linux-headers-cixmini "$4")"},
    {"file": "build/kernel-debs/linux-image-cixmini_7.3.0-sky1-ncz+$3_arm64.deb", "sha256": "$(ksha linux-image-cixmini "$3")"}
  ],
  "schema": 1,
  "variants": {"mainline": {"kver": "7.3.0-sky1-ncz"}}
}
EOF
}
kernel_ledger() {  # rev
    printf 'linux-image-cixmini\t7.3.0-sky1-ncz+%s\tarm64\t%s\tr\ts\tn\n'   "$1" "$(ksha linux-image-cixmini "$1")"
    printf 'linux-headers-cixmini\t7.3.0-sky1-ncz+%s\tarm64\t%s\tr\ts\tn\n' "$1" "$(ksha linux-headers-cixmini "$1")"
    printf 'cixmini-boot\t1.6+%s\tarm64\t%s\tr\ts\tn\n'                     "$1" "$(ksha cixmini-boot "$1")"
}
fresh() {  # name -> path of a new coherent fixture
    rm -rf "${T:?}/$1"; mkfix "$T/$1"; printf '%s' "$T/$1"
}

# --- 1. positive -----------------------------------------------------------
echo "=== 1. a coherent fixture passes ==="
F="$(fresh good)"
expect_rc "coherent fixture passes" 0 bash "$CHK" --root "$F"
if grep -q "OK kernel-revision" <<<"$LAST"; then ok "  kernel rule ran"; else bad "  kernel rule did not run" "$LAST"; fi
if grep -q "OK tracked-debs" <<<"$LAST"; then ok "  tracked-debs rule ran"; else bad "  tracked-debs rule did not run" "$LAST"; fi
expect_rc "--arch amd64 passes" 0 bash "$CHK" --root "$F" --arch amd64
expect_rc "--arch arm64 passes" 0 bash "$CHK" --root "$F" --arch arm64
expect_rc "unknown argument is a usage error" 2 bash "$CHK" --root "$F" --bogus
expect_rc "bad --arch is a usage error" 2 bash "$CHK" --root "$F" --arch riscv
expect_rc "a root without manifests is a usage error" 2 bash "$CHK" --root "$T/nonexistent"

# --- 2. negatives, one per rule -------------------------------------------
echo "=== 2a. snapshot: a one-arch base.pin change ==="
F="$(fresh n-onearch)"
sed -i "s/^\(arm64\t[^\t]*\t[^\t]*\t\)$S/\1$OLD/" "$F/manifests/base.pin"
expect_rc "arm64 base.pin row at another snapshot FAILS" 1 bash "$CHK" --root "$F"; names_rule snapshot
expect_rc "  ... also with --arch amd64 (a half re-pin is repo-wide)" 1 bash "$CHK" --root "$F" --arch amd64

echo "=== 2b. snapshot: release.conf / forky-snapshot.tsv / determinism.pin ==="
F="$(fresh n-relconf)"; sed -i "s/$S/$OLD/" "$F/release.conf"
expect_rc "release.conf at another snapshot FAILS" 1 bash "$CHK" --root "$F"; names_rule snapshot
F="$(fresh n-relconf2)"; printf 'NCZ_BASE_MIRROR_SNAPSHOT="%s"\n' "$S" >> "$F/release.conf"
expect_rc "release.conf with a duplicate assignment FAILS" 1 bash "$CHK" --root "$F"; names_rule snapshot
F="$(fresh n-forky)"; sed -i "s/^snapshot\t$S/snapshot\t$OLD/" "$F/manifests/forky-snapshot.tsv"
expect_rc "forky-snapshot.tsv at another snapshot FAILS" 1 bash "$CHK" --root "$F"; names_rule snapshot
F="$(fresh n-det)"; sed -i "s/^snapshot\t$S/snapshot\t$OLD/" "$F/manifests/determinism.pin"
expect_rc "determinism.pin at another snapshot FAILS" 1 bash "$CHK" --root "$F"; names_rule snapshot

echo "=== 2c. sid-exceptions ==="
F="$(fresh n-sid)"; sed -i "s/\t$S\trebuild/\t$OLD\trebuild/" "$F/manifests/sid-exceptions.tsv"
expect_rc "sid-exceptions row reviewed at an older snapshot FAILS" 1 bash "$CHK" --root "$F"; names_rule sid-exceptions

echo "=== 2d. rootfs-inputs ==="
F="$(fresh n-rootfs)"; sed -i "s|\(rescue-rootfs-amd64.tar.zst.*snapshot \)$S|\1$OLD|" "$F/manifests/build-inputs.tsv"
expect_rc "rescue rootfs built at an older snapshot FAILS" 1 bash "$CHK" --root "$F"; names_rule rootfs-inputs
expect_rc "  ... and --arch arm64 does not see the amd64 row" 0 bash "$CHK" --root "$F" --arch arm64
F="$(fresh n-rootfs2)"; sed -i "s|(rebuilt at pinned snapshot $S)|(rebuilt)|" "$F/manifests/build-inputs.tsv"
expect_rc "rootfs row recording no snapshot FAILS" 1 bash "$CHK" --root "$F"; names_rule rootfs-inputs

echo "=== 2e. kernel-revision ==="
F="$(fresh n-krel)"; echo "r292-7.3.0-sky1-ncz-20261023" > "$F/assets/kernel/mainline.release"
expect_rc "mainline.release r292 with the manifest at r293 FAILS" 1 bash "$CHK" --root "$F"; names_rule kernel-revision
expect_rc "  ... with --arch arm64" 1 bash "$CHK" --root "$F" --arch arm64
expect_rc "  ... but an amd64-only check does not judge the Sky1 kernel" 0 bash "$CHK" --root "$F" --arch amd64
F="$(fresh n-kled)"
{ grep -v cixmini "$F/manifests/ncz-packages.tsv"; kernel_ledger r292; } > "$F/x" && mv "$F/x" "$F/manifests/ncz-packages.tsv"
expect_rc "ncz-packages kernel rows at r292 with the manifest at r293 FAILS" 1 bash "$CHK" --root "$F"; names_rule kernel-revision
# Review 2026-11-01 (item 1): the ledger rows are compared with mainline.release
# directly, not only through the manifest.  Here the manifest and its three
# ledger rows agree at r293; the ONLY defect is an extra r292 ledger row that
# no manifest entry points at, so only the ledger-vs-mainline.release
# comparison can catch it.
F="$(fresh n-kled-extra)"
printf 'linux-image-cixmini\t7.3.0-sky1-ncz+r292\tarm64\t%s\tr\ts\tn\n' "$(ksha linux-image-cixmini r292)" >> "$F/manifests/ncz-packages.tsv"
expect_rc "an extra r292 ledger row beside a coherent r293 set FAILS" 1 bash "$CHK" --root "$F"; names_rule kernel-revision
if grep -q "ncz-packages.tsv:[0-9]*: linux-image-cixmini 7.3.0-sky1-ncz+r292 is revision r292" <<<"$LAST"; then
    ok "  finding names the ledger row and its revision"; else bad "  ledger row not named" "$LAST"; fi
F="$(fresh n-kmix)"; mkmanifest "$F" r292 r293 r293
expect_rc "manifest mixing r292 boot with r293 image FAILS" 1 bash "$CHK" --root "$F"; names_rule kernel-revision
F="$(fresh n-ksha)"; sed -i "s/^\(linux-image-cixmini\t[^\t]*\tarm64\t\)[0-9a-f]*/\1$SHA_A/" "$F/manifests/ncz-packages.tsv"
expect_rc "ledger kernel sha != manifest sha FAILS" 1 bash "$CHK" --root "$F"; names_rule kernel-revision

echo "=== 2f. tracked-debs ==="
F="$(fresh n-ss)"
sed -i 's/^ncz-screensavers\t0\.8\.19/ncz-screensavers\t0.8.18/' "$F/manifests/ncz-packages.tsv"
expect_rc "ncz-screensavers 0.8.19 debs with 0.8.18 ledger rows only FAIL" 1 bash "$CHK" --root "$F"; names_rule tracked-debs
if grep -q "ncz-screensavers_0.8.19_amd64.deb" <<<"$LAST"; then ok "  finding names the deb"; else bad "  deb not named" "$LAST"; fi
F="$(fresh n-unl)"; printf 'x' > "$F/assets/screensaver/amd64/ncz-stray_1.0_amd64.deb"; git -C "$F" add -- assets
expect_rc "a tracked deb with no ledger row FAILS" 1 bash "$CHK" --root "$F"; names_rule tracked-debs
F="$(fresh n-untracked)"; printf 'x' > "$F/assets/screensaver/amd64/ncz-stray_1.0_amd64.deb"
expect_rc "an UNtracked stray deb is not judged (build-inputs rules cover staged files)" 0 bash "$CHK" --root "$F"
F="$(fresh n-sssha)"; printf 'rebuilt' > "$F/assets/screensaver/arm64/ncz-screensavers_0.8.19_arm64.deb"
expect_rc "a tracked deb whose bytes differ from its row FAILS" 1 bash "$CHK" --root "$F"; names_rule tracked-debs
expect_rc "  ... and --arch amd64 does not judge the arm64 deb" 0 bash "$CHK" --root "$F" --arch amd64
F="$(fresh n-vend)"; printf 'other' > "$F/assets/nvidia/cuda-keyring_1.1-1_all.deb"
expect_rc "a vendor deb whose bytes differ from vendor-debs.tsv FAILS" 1 bash "$CHK" --root "$F"; names_rule tracked-debs
expect_rc "  ... an Architecture: all deb is judged for every arch" 1 bash "$CHK" --root "$F" --arch arm64

# --- 3. the real tree ------------------------------------------------------
# KNOWN_FAIL lists the rules this checkout is KNOWN to fail, each with the
# reason it cannot be fixed by a commit alone.  A listed rule that fails is
# reported XFAIL (and does not fail the suite); a listed rule that PASSES fails
# the suite, so the marker is removed as soon as the defect is fixed.  A rule
# that fails and is NOT listed fails the suite.
#
#   rootfs-inputs: assets/mgmt/ncz-mgmt-rootfs.tar.zst and
#     assets/rescue/rescue-rootfs-<arch>.tar.zst were built at snapshot
#     20261018T082309Z (manifests/build-inputs.tsv notes); the pin is newer.
#     Fixing it means rebuilding both tarballs per arch at the current pin
#     (docs/BUILD-STABILITY.md M8), which is a build, not an edit.
#   kernel-revision: assets/kernel/mainline.release names
#     r292-7.3.0-sky1-ncz-20261023 while kernel-manifest.json and the
#     ncz-packages.tsv rows pin the r293 debs (overlay ABI rebuild + cixmini-boot
#     1.6).  The fix is to point mainline.release at the staged directory that
#     holds those r293 debs, but no r293 staging directory (and no +r293 deb)
#     exists in the shared kernel-staging pool, so its name cannot be read from
#     anywhere; reverting the pins to r292 would re-ship the debs r293 replaced.
#     Stage the r293 release, set mainline.release to it, and drop this entry.
KNOWN_FAIL="rootfs-inputs kernel-revision"
echo "=== 3. the real tree ==="
rc=0; out="$(bash "$CHK" --root "$ROOT" 2>&1)" || rc=$?
printf '%s\n' "$out" | sed 's/^/    /'
failed="$(sed -n 's/^\[pin-coherence\] FAIL \([a-z-]*\):.*/\1/p' <<<"$out" | sort -u)"
unknown=""; for r in $failed; do case " $KNOWN_FAIL " in *" $r "*) ;; *) unknown="$unknown $r" ;; esac; done
if [ "$rc" = 2 ]; then
    bad "check-pin-coherence.sh on this repo: usage/tree error (rc=2)"
elif [ -n "$unknown" ]; then
    bad "check-pin-coherence.sh on this repo: rc=$rc, rules failing:$unknown"
elif [ "$rc" = 0 ]; then
    ok "check-pin-coherence.sh on this repo passes"
else
    for r in $failed; do XFAIL=$((XFAIL+1)); echo "  XFAIL real tree rule '$r' (known; see KNOWN_FAIL)"; done
fi
for r in $KNOWN_FAIL; do
    if ! grep -qx "$r" <<<"$failed"; then
        if grep -q "OK $r" <<<"$out"; then bad "real tree rule '$r' now PASSES: remove it from KNOWN_FAIL"; fi
    fi
done

echo
echo "pin-coherence tests: $PASS passed, $FAIL failed, $XFAIL known failure(s)"
[ "$FAIL" -eq 0 ]
