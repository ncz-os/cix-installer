#!/bin/bash
# test-classify-sid-exceptions-ledger.sh -- a REVIEWED ledger row whose
# package drifted to a new VERSION is new sid content and must be reported as
# such.
#
# build/classify-sid-exceptions.py merges the committed ledger against the
# substrate it just classified.  The ledger's identity is (name, version, arch)
# and the row it carries is looked up BY that identity, so a row whose version
# moved in the new substrate matches nothing: it falls to the "arch:all row this
# substrate does not carry" path (r is None) and is reported as NEW.  The
# `why` text must name the drift (version OLD -> NEW) so the human review knows
# what changed; naming only "new to the ledger" hides the single fact the
# reviewer needs.
#
# Offline: the pinned snapshot's indexes and the netinst's /dists indexes are
# fixture files (the classifier reads its index cache before it fetches), the
# ISO itself is a xorriso-built fixture.
#
# Cases:
#   1. a ledger row whose package moved 1.20.0 -> 1.22.6 is NEW and reports
#      "version 1.20.0 -> 1.22.6" (regression: the check compared the ledger
#      version against itself, so a version drift was never named).
#   2. an UNCHANGED row that is re-chained to the new pin is not NEW (no
#      over-reporting: the drift check must not fire on an identical version).
#   3. --require-accepted fails closed (rc 4) on the drift and writes nothing.
#
# Run: bash build/test-classify-sid-exceptions-ledger.sh
# Exit 0 = all cases pass.
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
CLASSIFY="$ROOT/build/classify-sid-exceptions.py"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$*" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /' >&2; }
expect_rc() {  # label want-rc cmd...
    local label="$1" want="$2" rc=0; shift 2
    LAST="$("$@" 2>&1)" || rc=$?
    if [ "$rc" = "$want" ]; then ok "$label (rc=$rc)"; else bad "$label: rc=$want wanted, got $rc" "$LAST"; fi
}

for t in python3 xorriso sha256sum; do
    command -v "$t" >/dev/null 2>&1 || { echo "SKIP: required test tool not available: $t" >&2; exit 0; }
done
[ -f "$CLASSIFY" ] || { echo "FAIL: $CLASSIFY is missing" >&2; exit 1; }

T="$(mktemp -d "${TMPDIR:-$HOME}/.classify-ledger-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
SNAP=20300101T000000Z
SHA_A="$(printf 'a%.0s' {1..64})"
SHA_B="$(printf 'b%.0s' {1..64})"

# One Packages stanza (the fields the classifier reads).
stanza() {  # name version arch sha
    printf 'Package: %s\nVersion: %s\nArchitecture: %s\nFilename: pool/%s.deb\nSHA256: %s\nSize: 1\n\n' \
        "$1" "$2" "$3" "$1" "$4"
}

# --- the fixture: a netinst carrying dpkg-udeb 1.22.6 and nano-udeb 9.3-1 ----
# The classifier caches snapshot indexes in --scratch (see load_snapshot_index),
# and `fetch` re-downloads whenever a cache file is missing OR zero-byte.  So
# every index the classifier probes is seeded NON-EMPTY here, or this test
# would quietly reach snapshot.debian.org and stop being hermetic.
mk_fixture() {  # dir
    local d="$1" comp a ext base
    mkdir -p "$d/tree/dists/forky/main/binary-amd64" \
             "$d/tree/dists/forky/main/binary-all" \
             "$d/tree/dists/forky/main/debian-installer/binary-amd64" \
             "$d/tree/dists/forky/main/debian-installer/binary-all" \
             "$d/scratch"
    # 1) Placeholder every probed index (forky + sid, all components, both
    #    arches, all three extensions).  '/' is flattened to '_' in cache names.
    for comp in main contrib non-free non-free-firmware main/debian-installer; do
        for a in amd64 all; do
            for ext in "" .gz .xz; do
                for base in forky sid; do
                    base="$d/scratch/${SNAP}_${base}_${comp//\//_}_binary-${a}_Packages$ext"
                    printf 'Package: fixture-placeholder\nVersion: 0\nArchitecture: armhf\n\n' \
                        > "$base"
                done
            done
        done
    done
    # 2) The real forky index: neither package is at the substrate's version,
    #    so neither is a class-A identity -> both need a sid exception (B/C).
    local forky_pkg="$d/scratch/${SNAP}_forky_main_binary-amd64_Packages"
    { stanza dpkg-udeb 1.18.0 amd64 "$SHA_A"; } > "$forky_pkg"
    gzip -c "$forky_pkg" > "$forky_pkg.gz"
    xz -c "$forky_pkg" > "$forky_pkg.xz"
    # 3) The real sid d-i index: the substrate's own versions.  Sourced from the
    #    fixture tree (never from a cache path, which may already hold a
    #    download).
    local sid_pkg="$d/tree/dists/forky/main/debian-installer/binary-amd64/Packages"
    { stanza dpkg-udeb 1.22.6 amd64 "$SHA_A"; stanza nano-udeb 9.3-1 amd64 "$SHA_B"; } \
        > "$sid_pkg"
    base="$d/scratch/${SNAP}_sid_main_debian-installer_binary-amd64_Packages"
    cp "$sid_pkg" "$base"
    gzip -c "$sid_pkg" > "$base.gz"
    xz -c "$sid_pkg" > "$base.xz"
    # 4) The ISO's d-i + plain indexes.  The plain (non-d-i) ones stay EMPTY:
    #    the classifier unions EVERY /dists/forky index into the substrate
    #    identity set, so a package there would need its own authorization.  The
    #    subject of this test is the d-i (udeb) identities only.
    : > "$d/tree/dists/forky/main/debian-installer/binary-all/Packages"
    : > "$d/tree/dists/forky/main/binary-amd64/Packages"
    : > "$d/tree/dists/forky/main/binary-all/Packages"
    xorriso -as mkisofs -quiet -o "$d/fixture.iso" "$d/tree" >/dev/null 2>&1 \
        || { echo "FAIL: could not build the fixture ISO" >&2; exit 1; }
    # 5) Fail closed on a non-hermetic fixture instead of silently passing.
    for base in "$d"/scratch/*; do
        [ -s "$base" ] || { echo "FAIL: empty fixture slot $(basename "$base")" >&2; exit 1; }
    done
    xz -dc "$d/scratch/${SNAP}_sid_main_debian-installer_binary-amd64_Packages.xz" \
        | grep -q '^Package: dpkg-udeb' \
        || { echo "FAIL: sid d-i fixture index was not seeded" >&2; exit 1; }
}

# The committed ledger, written at the OLD pin with dpkg-udeb at the OLD version.
mk_ledger() {  # file dpkg-version nano-version
    {
        printf '# columns (TAB): name version arch sha256 class forky_version gap reason\n'
        printf '#  first_seen snapshot owner_action review_by tracking_url\n'
        printf 'dpkg-udeb\t%s\tamd64\t%s\tC\tnone\tnone\tforky lacks it\t2029-12-01\t%s\twait\t2030-02-01\thttps://example.invalid/dpkg\n' \
            "$2" "$SHA_A" "$SNAP"
        printf 'nano-udeb\t%s\tamd64\t%s\tC\tnone\tnone\tforky lacks it\t2029-12-01\t%s\twait\t2030-02-01\thttps://example.invalid/nano\n' \
            "$3" "$SHA_B" "$SNAP"
    } > "$1"
}

run_classify() {  # fixture-dir ledger [extra args...]
    local d="$1" ledger="$2"; shift 2
    # --scratch gets its OWN directory: the classifier writes the snapshot index
    # cache AND its `iso_<component>_binary-<arch>.<ext>` ISO extracts into the
    # same scratch dir, and the two sanitize to the same name for the d-i
    # component (main/debian-installer/binary-amd64).  Separate dirs keep the
    # fixture's forky cache from being overwritten by the ISO's d-i index.
    mkdir -p "$d/scratch"
    python3 -I "$CLASSIFY" --arch amd64 --iso "$d/fixture.iso" --snapshot "$SNAP" \
        --scratch "$d/scratch" --ledger "$ledger" "$@"
}

F="$T/fx"; mk_fixture "$F"

echo "== a ledger row whose VERSION drifted is NEW and names the drift =="
L="$T/ledger.tsv"; mk_ledger "$L" 1.20.0 9.3-1
before="$(sha256sum "$L" | awk '{print $1}')"
out="$(run_classify "$F" "$L" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "classify runs on the fixture (rc=0)" || bad "classify failed (rc=$rc)" "$out"
printf '%s\n' "$out" | grep -q 'NEW sid exception needs a human review: dpkg-udeb' \
    && ok "the drifted row is reported for review" || bad "the drifted row was not reported" "$out"
printf '%s\n' "$out" | grep -q 'version 1.20.0 -> 1.22.6' \
    && ok "the report names the version drift (1.20.0 -> 1.22.6)" \
    || bad "the report does not name the version drift" "$out"
printf '%s\n' "$out" | grep -q 'NEW sid exception needs a human review: nano-udeb' \
    && bad "an unchanged row was reported as NEW (over-reporting)" "$out" \
    || ok "the unchanged row (9.3-1) is not reported as NEW"
# Without --accept-new-exceptions the unreviewed drift must NOT reach the
# ledger; the classifier drops that (name, arch) row entirely and keeps the
# unchanged one.
if grep -qP '^dpkg-udeb\t' "$L"; then
    bad "the unreviewed drift was written into the ledger" "$(cat "$L")"
else
    ok "the unreviewed drift is not written without --accept-new-exceptions"
fi
grep -qP '^nano-udeb\t9\.3-1\t' "$L" \
    && ok "the unchanged row is carried through untouched" \
    || bad "the unchanged row was dropped from the ledger" "$(cat "$L")"

echo "== the same ledger is accepted with --accept-new-exceptions =="
out="$(run_classify "$F" "$L" --accept-new-exceptions 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "accepted run succeeds (rc=0)" || bad "accepted run failed (rc=$rc)" "$out"
grep -q '^dpkg-udeb	1.22.6	amd64' "$L" \
    && ok "the accepted ledger carries the NEW version (1.22.6)" \
    || bad "the accepted ledger still carries the old version" "$(cat "$L")"

echo "== --require-accepted fails closed on the drift and writes nothing =="
L2="$T/ledger2.tsv"; mk_ledger "$L2" 1.20.0 9.3-1
before="$(sha256sum "$L2" | awk '{print $1}')"
expect_rc "--require-accepted refuses an unreviewed version drift" 4 \
    run_classify "$F" "$L2" --require-accepted
[ "$(sha256sum "$L2" | awk '{print $1}')" = "$before" ] \
    && ok "nothing was written on the refusal" || bad "the ledger was written on a refusal"
printf '%s\n' "$LAST" | grep -q 'version 1.20.0 -> 1.22.6' \
    && ok "the refusal names the version drift" || bad "the refusal hides the drift" "$LAST"

echo "-- results --"
printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || { echo "FAIL: $FAIL case(s) failed" >&2; exit 1; }
exit 0
