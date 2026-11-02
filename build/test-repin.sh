#!/bin/bash
# test-repin.sh -- fixtures for build/repin.sh and for the rule that
# `--substrate refresh` never edits a tracked file (docs/BUILD-STABILITY.md,
# measure M2, failure classes C1 and C7).
#
# A re-pin moves one input (the substrate netinst + the snapshot derived from
# it) that several committed files depend on.  Two arches resolving the SAME
# snapshot, one commit, or nothing: an arch that fails leaves the clone
# byte-identical.
#
# Everything here is synthetic.  No real re-pin is performed:
#   * a fixture REPO (git-initialised, a synthetic pin, the tracked pin set) is
#     driven through build/repin.sh --repo DIR with the two network/measure
#     steps stubbed by fixture commands (--refresh-cmd/--classify-cmd, or
#     NCZ_REPIN_REFRESH_CMD / NCZ_REPIN_CLASSIFY_CMD), exactly the way
#     build/test-build-image.sh stubs a stage with NCZ_TEST_STAGE_CMD.  The
#     classify stub is this file re-invoked as `--stub-classify`.
#   * build-image.sh is driven on a throwaway COPY of this checkout that keeps
#     this repo's committed history (cp -a, so .git comes along) with
#     NCZ_TEST_STAGE_CMD stubbing every stage that needs a host, so the real
#     preflight and the real refresh-substrate stage run.
#
# Cases:
#   1. positive: both arches move, base.pin/release.conf/forky-snapshot.tsv/
#      determinism.pin/sid-exceptions.tsv change together, the stale rootfs
#      rows are listed, --commit leaves exactly ONE commit and exit 0.
#   2. negative: the arm64 stub fails -> rc 1, no tracked file changes
#      (git status --porcelain empty), no commit.
#   3. negative: an unreviewed NEW class-C udeb is refused (rc 1, no write)
#      without --accept-new-exceptions; with the flag it is written with
#      review_by + first_seen + snapshot.
#   4. negative: the arches resolve to different snapshots -> rc 1, no write.
#   5. negative: a stale build-inputs rootfs row refuses the re-pin; a staged
#      rebuild (--build-inputs-dir) lets it through and --defer-build-inputs
#      writes nothing AND reports the re-pin incomplete (rc 1, not 0).
#   6. --substrate refresh on a stale pin (build-image.sh, real stage):
#      fails, names build/repin.sh, git status --porcelain EMPTY, and no
#      candidate pin written into the tree.
#   7. the same stage on a FRESH pin verifies and leaves the tree untouched.
#
# Usage: bash build/test-repin.sh        Exit 0 = all cases pass.
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# The fixture repo overrides ROOT inside the stubs below, so the stub commands
# that re-enter THIS script must use its absolute path captured here.
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
REPIN="$ROOT/build/repin.sh"
BIN="$ROOT/build/build-image.sh"
# --- the suite-digest stub (this file, re-invoked) -------------------------
# pin-snapshot-suites.py fetches each declared suite's InRelease from
# snapshot.debian.org and gpgv-verifies it: a network + Debian-key dependency a
# fixture cannot have.  The stub records the SAME fields the real script records
# (the trust file's digests/size for the pinned snapshot), so the pin-dependent
# file moves exactly as a real re-pin moves it.
if [ "${1:-}" = "--stub-suite-digests" ]; then
    shift
    snap=""
    while [ $# -gt 0 ]; do case "$1" in --snapshot) snap="$2"; shift 2 ;; *) shift ;; esac; done
    [ -n "$snap" ] || { echo "stub suite-digests: --snapshot missing" >&2; exit 2; }
    # refresh-substrate.sh cds to ITS repo root before running this command
    # (ROOT=<worktree>), so resolve the trust file against that root, not the
    # caller's incidental cwd.
    sroot="${STUB_SUITE_REPO:-${NCZ_REPIN_WORKTREE:-$PWD}}"
    tf="$sroot/manifests/forky-snapshot.tsv"
    [ -f "$tf" ] || { echo "stub suite-digests: $tf missing" >&2; exit 2; }
    sha="$(printf 'digest-at-%s' "$snap" | sha256sum | awk '{print $1}')"
    tmp="$tf.stub.$$"
    { grep -v '^inrelease_sha256\|^inrelease_size\|^di_inrelease_sha256\|^di_inrelease_size' "$tf"
      printf 'inrelease_sha256\t%s\ninrelease_size\t1000\n' "$sha"
      printf 'di_inrelease_sha256\t%s\ndi_inrelease_size\t2000\n' "$sha"
    } > "$tmp"
    mv -f "$tmp" "$tf"
    echo "stub suite-digests: recorded the digests for $snap"
    exit 0
fi

# --- the classify stub (this file, re-invoked) -----------------------------
# A fixture classifier: it appends STUB_NEW_ROW_FILE (once) to the --ledger
# file, creating it WITH the ledger header when it does not exist, so the file
# is always well formed.  STUB_CLASSIFY_FAIL_ARCH makes one arch fail; the
# failure is named on stderr exactly like the real classifier's review lines.
if [ "${1:-}" = "--stub-classify" ]; then
    shift
    arch=""; ledger=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --arch) arch="$2"; shift 2 ;;
            --ledger) ledger="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    [ -n "$ledger" ] || { echo "stub classify: --ledger missing" >&2; exit 2; }
    if [ -n "${STUB_CLASSIFY_FAIL_ARCH:-}" ] && [ "$arch" = "$STUB_CLASSIFY_FAIL_ARCH" ]; then
        echo "stub classify: $arch: pinned snapshot does not authorize the substrate" >&2
        exit 3
    fi
    if [ -n "${STUB_NEW_ROW_FILE:-}" ] && [ -f "$STUB_NEW_ROW_FILE" ]; then
        if [ ! -s "$ledger" ]; then
            {
                printf '# columns (TAB): name version arch sha256 class forky_version gap reason\n'
                printf '#  first_seen snapshot owner_action review_by tracking_url\n'
            } > "$ledger"
        fi
        awk -F'\t' -v a="$arch" '$3==a || $3=="all"' "$STUB_NEW_ROW_FILE" >> "$ledger"
        echo "stub classify: $arch: wrote 1 new row"
    else
        echo "stub classify: $arch: no new rows"
    fi
    exit 0
fi

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$*" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /' >&2; }
LAST=""
expect_rc() {  # label want-rc cmd...
    local label="$1" want="$2" rc=0; shift 2
    LAST="$("$@" 2>&1)" || rc=$?
    if [ "$rc" = "$want" ]; then ok "$label (rc=$rc)"; else bad "$label: rc=$want wanted, got $rc" "$LAST"; fi
}
for t in git sha256sum date sed awk; do
    command -v "$t" >/dev/null 2>&1 || { echo "FAIL: required test tool not available: $t" >&2; exit 1; }
done
# early, explicit: a missing or non-executable script must not surface as 30
# confusing downstream failures
for f in "$REPIN" "$BIN"; do
    [ -f "$f" ] || { echo "FAIL: $f is missing" >&2; exit 1; }
    [ -x "$f" ] || { echo "FAIL: $f is not executable (chmod +x)" >&2; exit 1; }
done

T="$(mktemp -d "${TMPDIR:-$HOME}/.repin-test.XXXXXX")"; trap 'rm -rf "$T"' EXIT
sha() { sha256sum "$1" | awk '{print $1}'; }
status_of() { git -C "$1" status --porcelain; }

# the synthetic pin the fixture repo starts at, and the substrate it names
P0=20300101T000000Z
P1=20450101T000000Z          # what the refresh stub "fetches"
# portable "tomorrow" (no GNU date -d): a fixed date far in the future would be
# wrong once the test is run from another base year, so derive it from `date`
SHA_A0="$(printf '1%.0s' {1..64})"; SHA_R0="$(printf '2%.0s' {1..64})"
SHA_A1="$(printf '3%.0s' {1..64})"; SHA_R1="$(printf '4%.0s' {1..64})"
if date -u -v+1d '+%s' >/dev/null 2>&1; then                 # BSD/macOS
    PINNOW="$(date -u -v+1d '+%a, %d %b %Y %H:%M:%S UTC')"
else                                                          # GNU
    PINNOW="$(date -u -d @$(( $(date -u +%s) + 86400 )) '+%a, %d %b %Y %H:%M:%S UTC')"
fi

# --- the refresh stub ------------------------------------------------------
# It replaces build/refresh-substrate.sh's two network actions (signed-manifest
# fetch + substrate measurement) with a deterministic fixture: it replaces the
# arch's row of manifests/base.pin (never appends -- base.pin has ONE row per
# arch), with that arch's OWN substrate sha (SHA_A1 for amd64, SHA_R1 for
# arm64), so the positive test can tell the two arches apart.
write_stub() {  # dir -- a tree of stub commands
    local s="$1"; mkdir -p "$s"
    cat > "$s/refresh" <<'STUB'
#!/bin/bash
# stub: repin refresh --arch A --iso FILE [--no-fetch]
set -uo pipefail
# repin.sh runs this stub with cwd = the SCRATCH TREE it is filling; the
# fixture repo is only the source of the committed pin.  Writing the new row to
# the scratch base.pin (never back into the fixture) is what makes the fixture
# stay clean while the re-pin is proven.
ROOT="$PWD"
: "${REPIN_STUB_REPO:?REPIN_STUB_REPO must name the fixture repo}"
arch=""; SNAP="${STUB_SNAP:?STUB_SNAP must be set}"
while [ $# -gt 0 ]; do case "$1" in --arch) arch="$2"; shift 2 ;; *) shift ;; esac; done
[ -n "$arch" ] || { echo "stub refresh: --arch missing" >&2; exit 2; }
if [ -n "${STUB_FAIL_ARCH:-}" ] && [ "$arch" = "$STUB_FAIL_ARCH" ]; then
    echo "stub refresh: $arch: signature verification failed (fixture)" >&2
    exit 2
fi
[ -n "${STUB_SNAP_OVERRIDE_A64:-}" ] && [ "$arch" = arm64 ] && SNAP="$STUB_SNAP_OVERRIDE_A64"
case "$arch" in
    amd64) sha="${STUB_SHA_AMD64:-$(printf '3%.0s' {1..64})}" ;;
    arm64) sha="${STUB_SHA_ARM64:-$(printf '4%.0s' {1..64})}" ;;
    *) echo "stub refresh: unknown arch $arch" >&2; exit 2 ;;
esac
row="$(printf '%s\t%s\t%s\t%s\t100.0\t%s' "$arch" "$sha" \
    "${STUB_DATE:?STUB_DATE must be set}" "$SNAP" "https://example.invalid/$arch.iso")"
pin="$ROOT/manifests/base.pin"
tmp="$pin.stub.$$"
{ awk -F'\t' -v a="$arch" 'BEGIN{OFS="\t"} $1==a{next} {print}' "$pin"; printf '%s\n' "$row"; } > "$tmp"
mv -f "$tmp" "$pin"
echo "[substrate] stub refreshed $arch -> $SNAP ($sha)"
STUB
    chmod +x "$s/refresh"
}

# a brand-new class-C udeb row (TAB separated, ledger schema)
new_row_c() {  # file
    printf '%s\t%s\t%s\t%s\tC\tnone\tnone\tforky lacks %s; new in this substrate\t%s\t%s\twait\t%s\thttps://tracker.debian.org/pkg/%s\n' \
        "$1" "2.5-1" "amd64" "$SHA_A1" "$1" "2030-01-01" "$P1" "2030-01-31" "$1"
}

# --- the fixture repo ------------------------------------------------------
mk_repo() {  # dir
    local d="$1"
    mkdir -p "$d/build/lib" "$d/build/testdata/forky-snapshot" "$d/manifests"
    cp "$ROOT/build/lib/reproducible.py" "$ROOT/build/lib/ncz-site.sh" "$d/build/lib/"
    printf 'NCZ_BASE_MIRROR_SNAPSHOT="%s"\nNCZ_BASE_MIRROR_SNAPSHOT_MAX_AGE_DAYS="14"\nNCZ_BASE_CODENAME="forky"\n' "$P0" \
        > "$d/release.conf"
    {
        printf '# arch\tsubstrate_sha256\tsubstrate_date\tsnapshot\tcoverage_pct\tsource_url\n'
        printf 'amd64\t%s\t%s\t%s\t100.0\thttps://example.invalid/amd64.iso\n' "$SHA_A0" "$PINNOW" "$P0"
        printf 'arm64\t%s\t%s\t%s\t100.0\thttps://example.invalid/arm64.iso\n' "$SHA_R0" "$PINNOW" "$P0"
    } > "$d/manifests/base.pin"
    {
        printf '# arch\tdest\tsha256\tsize\tnote\n'
        printf 'amd64\tassets/mgmt/ncz-mgmt-rootfs.tar.zst\t%s\t10\tmgmt rootfs (rebuilt 2030-01-01 at pinned snapshot %s)\n' "$SHA_A0" "$P0"
        printf 'arm64\tassets/rescue/rescue-rootfs-arm64.tar.zst\t%s\t10\trescue rootfs (rebuilt 2030-01-01 at pinned snapshot %s)\n' "$SHA_R0" "$P0"
    } > "$d/manifests/build-inputs.tsv"
    printf 'vendor-repos fixture\n' > "$d/manifests/vendor-repos.tsv"
    printf 'ncz-packages fixture\n' > "$d/manifests/ncz-packages.tsv"
    printf 'vendor-debs fixture\n' > "$d/manifests/vendor-debs.tsv"
    # the trust file MUST declare the committed keyring and suites: the real
    # pin-snapshot-suites.py refuses a tree without them (a re-pin records the
    # signed digests of every declared suite).
    {
        printf 'snapshot\t%s\ncodename\tforky\n' "$P0"
        printf 'inrelease_path\tdists/forky/InRelease\n'
        printf 'di_suite\tsid\ndi_inrelease_path\tdists/sid/InRelease\n'
        printf 'keyring\tmanifests/keys/debian-archive-keyring.gpg\n'
    } > "$d/manifests/forky-snapshot.tsv"
    mkdir -p "$d/manifests/keys"
    : > "$d/manifests/keys/debian-archive-keyring.gpg"
    printf 'determinism fixture\n' > "$d/manifests/determinism.pin"
    printf 'sing-bytes' > "$d/build/testdata/forky-snapshot/InRelease"
    {
        printf '# columns (TAB): name version arch sha256 class forky_version gap reason\n'
        printf '#  first_seen snapshot owner_action review_by tracking_url\n'
        printf 'keep-udeb\t1.0-1\tall\t%s\tB\t0.9-1\tsmall\tsmall gap\t2029-12-01\t%s\trebuild\t2030-02-01\thttps://example.invalid/k\n' \
            "$SHA_A0" "$P0"
    } > "$d/manifests/sid-exceptions.tsv"
    git -C "$d" init -q
    git -C "$d" add -- release.conf manifests build
    git -C "$d" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm "fixture base"
}
fresh() { rm -rf "${T:?}/$1"; mk_repo "$T/$1"; printf '%s' "$T/$1"; }

STUBS="$T/stubs"; write_stub "$STUBS"

# a fixture substrate ISO (the content is irrelevant: the stub IS the fetch)
fake_iso() {  # arch -> path
    printf 'fixture-netinst-%s' "$1" > "$T/$1.iso"; printf '%s' "$T/$1.iso"
}

# run repin against a fixture repo with the stubs.  --classify-cmd is ONE
# command string, so the stub is a tiny wrapper next to the refresh stub.
cat > "$STUBS/classify" <<WRAP
#!/bin/bash
exec bash "$SELF" --stub-classify "\$@"
WRAP
chmod +x "$STUBS/classify"

repin() {  # repo args...
    local r="$1"; shift
    env GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
        GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
        REPIN_STUB_REPO="$r" STUB_DATE="$PINNOW" STUB_SNAP="$P1" \
        NCZ_REPIN_WORK_ROOT="$T/work" \
        NCZ_SUITE_DIGESTS_CMD="bash '$SELF' --stub-suite-digests" \
        NCZ_REPIN_FIXTURE_CMD="true" \
        bash "$REPIN" --repo "$r" --refresh-cmd "$STUBS/refresh" \
        --classify-cmd "bash '$STUBS/classify'" --skip-gates "$@"
}

new_pin_of() { sed -n 's/^NCZ_BASE_MIRROR_SNAPSHOT="\(.*\)"/\1/p' "$1/release.conf"; }

echo "-- smoke --"
F="$(fresh smoke)"; ISO_A="$(fake_iso amd64)"; ISO_R="$(fake_iso arm64)"
repin "$F" --arch both --iso-amd64 "$ISO_A" --iso-arm64 "$ISO_R"; echo "rc=$?"
git -C "$F" status --porcelain; cat "$F/manifests/base.pin" "$F/release.conf"
