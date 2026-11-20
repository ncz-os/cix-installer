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
# Review 2026-11-01 (DeepSeek item 3): a version with no +rNNN suffix was
# reported as "is revision None"; the finding must say what is wrong and name
# the row / the manifest entry.
F="$(fresh n-knorev)"
printf 'linux-image-cixmini\t7.3.0-sky1-ncz\tarm64\t%s\tr\ts\tn\n' "$SHA_A" >> "$F/manifests/ncz-packages.tsv"
expect_rc "a ledger kernel row with no +rNNN revision FAILS" 1 bash "$CHK" --root "$F"; names_rule kernel-revision
if grep -q "ncz-packages.tsv:[0-9]*: linux-image-cixmini version has no +rNNN revision (7.3.0-sky1-ncz)" <<<"$LAST" \
   && ! grep -q "None" <<<"$LAST"; then
    ok "  finding names the ledger row and says it has no +rNNN revision"; else bad "  misleading finding" "$LAST"; fi
F="$(fresh n-kmnorev)"; sed -i 's/linux-image-cixmini_7.3.0-sky1-ncz+r293_arm64/linux-image-cixmini_7.3.0-sky1-ncz_arm64/' "$F/assets/kernel-manifest.json"
expect_rc "a manifest kernel deb with no +rNNN revision FAILS" 1 bash "$CHK" --root "$F"; names_rule kernel-revision
if grep -q "kernel-manifest.json pins linux-image-cixmini_7.3.0-sky1-ncz_arm64.deb: version has no +rNNN revision (7.3.0-sky1-ncz)" <<<"$LAST" \
   && ! grep -q "None" <<<"$LAST"; then
    ok "  finding names the manifest entry and says it has no +rNNN revision"; else bad "  misleading finding" "$LAST"; fi
F="$(fresh n-kmix)"; mkmanifest "$F" r292 r293 r293
expect_rc "manifest mixing r292 boot with r293 image FAILS" 1 bash "$CHK" --root "$F"; names_rule kernel-revision
F="$(fresh n-ksha)"; sed -i "s/^\(linux-image-cixmini\t[^\t]*\tarm64\t\)[0-9a-f]*/\1$SHA_A/" "$F/manifests/ncz-packages.tsv"
expect_rc "ledger kernel sha != manifest sha FAILS" 1 bash "$CHK" --root "$F"; names_rule kernel-revision

echo "=== 2e'. kernel-revision: a packaging revision over a staged release ==="
# r293 (2026-10-27) repackaged the r292 staged kernel (same Image) with rebuilt
# overlays and a fixed headers tree, BUILD_REV=r293.  mainline.release names
# the staged directory (r292-...); assets/kernel/mainline.deb-revision names
# the packaging revision the debs carry.  The rule compares the latter with
# the manifest and the ledger, and refuses one older than the staged dir.
F="$(fresh p-kdebrev)"; echo "r292-7.3.0-sky1-ncz-20261023" > "$F/assets/kernel/mainline.release"
printf '# packaging revision\nr293\n' > "$F/assets/kernel/mainline.deb-revision"
expect_rc "staged r292 + deb-revision r293 + manifest/ledger r293 passes" 0 bash "$CHK" --root "$F"
if grep -q "OK kernel-revision: r293 .*mainline.deb-revision.*r292" <<<"$LAST"; then ok "  OK line names the packaging revision and the staged release"
else bad "  OK line lacks the revision sources" "$LAST"; fi
F="$(fresh n-kdebrev-ahead)"; printf 'r294\n' > "$F/assets/kernel/mainline.deb-revision"
expect_rc "deb-revision r294 with the manifest at r293 FAILS" 1 bash "$CHK" --root "$F"; names_rule kernel-revision
F="$(fresh n-kdebrev-down)"; echo "r294-7.3.0-sky1-ncz-20261101" > "$F/assets/kernel/mainline.release"
printf 'r293\n' > "$F/assets/kernel/mainline.deb-revision"
expect_rc "deb-revision r293 older than the staged r294 release FAILS" 1 bash "$CHK" --root "$F"; names_rule kernel-revision
if grep -q "older than the staged release" <<<"$LAST"; then ok "  finding names the downgrade"; else bad "  downgrade not named" "$LAST"; fi
F="$(fresh n-kdebrev-bad)"; printf '293\n' > "$F/assets/kernel/mainline.deb-revision"
expect_rc "a malformed deb-revision FAILS" 1 bash "$CHK" --root "$F"; names_rule kernel-revision
F="$(fresh n-kdebrev-empty)"; printf '# nothing\n' > "$F/assets/kernel/mainline.deb-revision"
expect_rc "an empty deb-revision FAILS (present but says nothing)" 1 bash "$CHK" --root "$F"; names_rule kernel-revision

echo "=== 2f. tracked-debs ==="
F="$(fresh n-ss)"
sed -i 's/^ncz-screensavers\t0\.8\.19/ncz-screensavers\t0.8.18/' "$F/manifests/ncz-packages.tsv"
expect_rc "ncz-screensavers 0.8.19 debs with 0.8.18 ledger rows only FAIL" 1 bash "$CHK" --root "$F"; names_rule tracked-debs
if grep -q "ncz-screensavers_0.8.19_amd64.deb" <<<"$LAST"; then ok "  finding names the deb"; else bad "  deb not named" "$LAST"; fi
F="$(fresh n-unl)"; printf 'x' > "$F/assets/screensaver/amd64/ncz-stray_1.0_amd64.deb"; git -C "$F" add -- assets
expect_rc "a tracked deb with no ledger row FAILS" 1 bash "$CHK" --root "$F"; names_rule tracked-debs
# Review 2026-11-01 (DeepSeek item 1, "the rule never sees debs in
# subdirectories"): did NOT hold on the base -- a plain git pathspec '*'
# matches across '/', so 'assets/*.deb' already listed assets/<x>/<y>/*.deb
# (the n-unl case above).  Pinned here at depth >1 (the assets/kernel/** shape).
# What DID hold: the listing obeyed GIT_GLOB_PATHSPECS / GIT_LITERAL_PATHSPECS
# from the caller's environment, under which 'assets/*.deb' matches no
# subdirectory deb (glob: '*' stops at '/') or nothing at all (literal), and the
# rule then reported OK on zero debs.
F="$(fresh n-deep)"; mkdir -p "$F/assets/kernel/a/b"
printf 'x' > "$F/assets/kernel/a/b/linux-stray_1.0_arm64.deb"; git -C "$F" add -- assets
expect_rc "a tracked deb two directories down with no ledger row FAILS" 1 bash "$CHK" --root "$F"; names_rule tracked-debs
if grep -q "assets/kernel/a/b/linux-stray_1.0_arm64.deb: no linux-stray" <<<"$LAST"; then
    ok "  finding names the nested deb"; else bad "  nested deb not named" "$LAST"; fi
F="$(fresh n-unl-env)"; printf 'x' > "$F/assets/screensaver/amd64/ncz-stray_1.0_amd64.deb"; git -C "$F" add -- assets
for v in GIT_GLOB_PATHSPECS GIT_LITERAL_PATHSPECS; do
    expect_rc "a subdirectory deb with no ledger row FAILS under $v=1" 1 env "$v=1" bash "$CHK" --root "$F"; names_rule tracked-debs
    if grep -q "ncz-stray_1.0_amd64.deb: no ncz-stray" <<<"$LAST"; then
        ok "  finding names the deb under $v=1"; else bad "  deb not named under $v=1" "$LAST"; fi
done
F="$(fresh n-untracked)"; printf 'x' > "$F/assets/screensaver/amd64/ncz-stray_1.0_amd64.deb"
expect_rc "an UNtracked stray deb is not judged (build-inputs rules cover staged files)" 0 bash "$CHK" --root "$F"
F="$(fresh n-sssha)"; printf 'rebuilt' > "$F/assets/screensaver/arm64/ncz-screensavers_0.8.19_arm64.deb"
expect_rc "a tracked deb whose bytes differ from its row FAILS" 1 bash "$CHK" --root "$F"; names_rule tracked-debs
expect_rc "  ... and --arch amd64 does not judge the arm64 deb" 0 bash "$CHK" --root "$F" --arch amd64
F="$(fresh n-vend)"; printf 'other' > "$F/assets/nvidia/cuda-keyring_1.1-1_all.deb"
expect_rc "a vendor deb whose bytes differ from vendor-debs.tsv FAILS" 1 bash "$CHK" --root "$F"; names_rule tracked-debs
expect_rc "  ... an Architecture: all deb is judged for every arch" 1 bash "$CHK" --root "$F" --arch arm64

# --- 3. the real tree ------------------------------------------------------
# KNOWN_FAIL is the rule column of manifests/pin-coherence-known-fail.tsv,
# the same list build-image.sh preflight reads (each row gives the owner, the
# exact fix and why a commit alone cannot fix it).  A listed rule that fails is
# reported XFAIL (and does not fail the suite); a listed rule that PASSES fails
# the suite, so the row is removed as soon as the defect is fixed.  A rule
# that fails and is NOT listed fails the suite.
KNOWN_FAIL="$(awk -F'\t' '$1 !~ /^(#|$)/ {print $1}' "$ROOT/manifests/pin-coherence-known-fail.tsv" | tr '\n' ' ')"
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
