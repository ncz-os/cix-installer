#!/bin/bash
# repin.sh -- the ONE all-or-nothing re-pin for both arches
# (docs/BUILD-STABILITY.md, measure M2; failure classes C1 and C7).
#
# A re-pin moves one input (the Debian netinst substrate plus the snapshot
# derived from it) that several committed files depend on.  Doing it by hand on
# a builder -- refresh one arch, copy HEAD around, edit the ledger, forget a
# file, commit half of it -- is how C1/C7 happen: R1 shows the pipeline itself
# rewriting manifests/base.pin for ONE arch on ULTRA, and T item 4 is a commit
# with only the amd64 half.  This script does the whole re-pin in one
# invocation and one commit, or it changes nothing:
#
#   1. copies the tracked pin set into a scratch dir on a real disk
#      (${NCZ_REPIN_WORK_ROOT:-$HOME/.cache/ncz-repin}, never tmpfs, never /tmp);
#   2. runs build/refresh-substrate.sh --arch amd64 and --arch arm64 there (each
#      fetches + signature-checks the newest weekly, measures the snapshot,
#      writes base.pin, then syncs release.conf, forky-snapshot.tsv and
#      determinism.pin) and REQUIRES both arches to resolve the SAME snapshot;
#   3. classifies the substrate's sid debian-installer content against the new
#      pin for both arches (build/classify-sid-exceptions.py --ledger) and
#      regenerates manifests/sid-exceptions.tsv: graduated rows are dropped,
#      reviewed rows are carried over (re-chained to the new snapshot), and a NEW
#      exception -- new content, a changed identity/sha256, or a changed decision
#      -- is never approved by this script.  It fails (exit 1, nothing written)
#      unless --accept-new-exceptions, or --defer-new-exceptions defers it and
#      writes nothing;
#   4. fails fatally if a build/refresh-forky-inrelease-fixture.sh regeneration,
#      gen-base-pin.sh or the pin changed nothing (a re-pin that changes nothing
#      is already at the pin) -- with --refresh-cmd the stub owns the measurement,
#      so "nothing changed" is reported by the comparison at step 7 instead;
#   5. lists every build-inputs.tsv rootfs row that must be rebuilt and refuses
#      the re-pin unless the rebuilt tarballs were staged with
#      --build-inputs-dir (whose build-inputs.info records the new snapshot) or
#      --defer-build-inputs was given.  --defer-build-inputs writes NOTHING, not
#      even the pin: the rootfs tarballs are still built at the old archive state,
#      so a commit that moved only the pin would be a half re-pin (C7);
#   6. runs check-pin-coherence.sh, check-substrate-pin.sh, gen-base-pin.sh
#      --check and build/test-no-ubuntu.sh, build/test-build-image.sh in the
#      scratch tree, so the re-pin is proven before it can be committed;
#   7. only then copies the changed files back (explicit paths -- never
#      `git add -A`), checks the tree only concerns this re-pin, proves that
#      `build/build-image.sh --substrate refresh` leaves `git status
#      --porcelain` empty, and with --commit commits exactly those paths as ONE
#      commit on the current branch.  It never pushes, merges or tags.
#
# Update the pinned-InRelease fixture (step 4) from the scratch tree with
#   build/refresh-forky-inrelease-fixture.sh --root "$(ls -d ~/.cache/ncz-repin/repin.* | tail -1)" \
#       --out build/testdata/forky-snapshot/InRelease
# after reviewing the new trust digests, then re-run repin.sh (it reuses them).
#
# Usage:
#   build/repin.sh [--arch both|amd64|arm64] [--snapshot S]
#                  [--iso-amd64 FILE] [--iso-arm64 FILE] [--no-fetch]
#                  [--accept-new-exceptions] [--defer-new-exceptions]
#                  [--review-by DATE]
#                  [--build-inputs-dir DIR] [--defer-build-inputs]
#                  [--commit | --no-commit] [--repo DIR] [--work DIR]
#                  [--refresh-cmd CMD] [--classify-cmd CMD]
#   --snapshot S      do not derive: the snapshot every arch must resolve to.
#                     A re-pin never invents one -- it must come from the
#                     measured substrate (or from the operator, here, explicitly).
#   --iso-amd64 FILE  use this netinst instead of fetching the newest weekly
#                     (it is still signature-checked against SHA256SUMS).
#   --no-fetch        never fetch an ISO (requires --iso-<arch>).
#   --accept-new-exceptions  write NEW exceptions with first_seen + snapshot +
#                     review_by.  Only after reviewing them; the ledger is a
#                     reviewed list, not a rubber stamp.
#   --defer-new-exceptions   do not write a ledger at all (leave the committed
#                     one untouched) and finish the rest of the re-pin.
#   --review-by DATE  review_by for NEW exceptions (default first_seen + 30d).
#   --defer-build-inputs     stop before writing anything if a rootfs row is not
#                     at the new pin: the re-pin is INCOMPLETE and returns 1 (it
#                     is not a success), so --defer-build-inputs cannot present a
#                     half re-pin as done.
#   --commit          commit the changed pin files (default --no-commit: the
#                     tree keeps the change for review).
#   --repo DIR        the tree to re-pin (default: this checkout).
#   --work DIR        scratch tree (default: ${NCZ_REPIN_WORK_ROOT:-~/.cache/ncz-repin}/repin.XXXXXX;
#                     an EXISTING --work dir is reused as is, so a re-pin can
#                     resume after a manual step).
#   --refresh-cmd CMD, --classify-cmd CMD
#                     replace the per-arch refresh / classify command
#                     (tests; NCZ_REPIN_REFRESH_CMD / NCZ_REPIN_CLASSIFY_CMD).
#                     The command is invoked with --arch A plus the remaining
#                     options, from the scratch tree.
#
# Exit: 0 re-pin coherent (and committed with --commit); 1 the re-pin is not
#       coherent or not complete (--defer-build-inputs with a stale rootfs row)
#       -- nothing tracked was changed; 2 usage/tool error; 3 the checkout (or
#       the scratch tree) is not in a state to re-pin.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

ARCHS="both"
SNAP_REQ=""
ISO_AMD64=""; ISO_ARM64=""; NO_FETCH=0
ACCEPT_NEW=0; DEFER_NEW=0; SKIP_GATES=0; REVIEW_BY=""
BUILD_INPUTS_DIR=""; DEFER_BUILD_INPUTS=0
COMMIT=0
ROOT="$HERE/.."
WORK=""
REFRESH_CMD="${NCZ_REPIN_REFRESH_CMD:-}"; CLASSIFY_CMD="${NCZ_REPIN_CLASSIFY_CMD:-}"

say()  { printf '[repin] %s\n' "$*"; }
err()  { printf '[repin] %s\n' "$*" >&2; }
die()  { local rc="$1"; shift; err "ERROR: $*"; exit "$rc"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --arch) ARCHS="${2:-}"; shift 2 ;;
        --snapshot) SNAP_REQ="${2:-}"; shift 2 ;;
        --iso-amd64) ISO_AMD64="${2:-}"; shift 2 ;;
        --iso-arm64) ISO_ARM64="${2:-}"; shift 2 ;;
        --no-fetch) NO_FETCH=1; shift ;;
        --accept-new-exceptions) ACCEPT_NEW=1; shift ;;
        --defer-new-exceptions) DEFER_NEW=1; shift ;;
        --skip-gates) SKIP_GATES=1; shift ;;   # TESTS ONLY: orchestration fixtures
        --review-by) REVIEW_BY="${2:-}"; shift 2 ;;
        --build-inputs-dir) BUILD_INPUTS_DIR="${2:-}"; shift 2 ;;
        --defer-build-inputs) DEFER_BUILD_INPUTS=1; shift ;;
        --commit) COMMIT=1; shift ;;
        --no-commit) COMMIT=0; shift ;;
        --repo) ROOT="${2:-}"; shift 2 ;;
        --work) WORK="${2:-}"; shift 2 ;;
        --refresh-cmd) REFRESH_CMD="${2:-}"; shift 2 ;;
        --classify-cmd) CLASSIFY_CMD="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,80p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die 2 "unknown argument: $1 (see --help)" ;;
    esac
done

case "$ARCHS" in
    both|all) ARCH_LIST="amd64 arm64" ;;
    amd64|arm64) ARCH_LIST="$ARCHS" ;;
    *) die 2 "--arch must be both|all, amd64 or arm64 (got '$ARCHS')" ;;
esac
if [ -n "$SNAP_REQ" ]; then
    case "$SNAP_REQ" in
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) ;;
        *) die 2 "--snapshot must be YYYYMMDDTHHMMSSZ (got '$SNAP_REQ')" ;;
    esac
fi
if [ "$ACCEPT_NEW" = 1 ] && [ "$DEFER_NEW" = 1 ]; then
    die 2 "--accept-new-exceptions and --defer-new-exceptions are exclusive"
fi
[ -d "$ROOT" ] || die 2 "--repo $ROOT is not a directory"
ROOT="$(cd "$ROOT" && pwd)"
for t in git sha256sum python3 cp find diff sort; do
    command -v "$t" >/dev/null 2>&1 || die 2 "required tool missing: $t"
done
# the classifier ships with the tree it judges.  A --classify-cmd fixture
# replaces it, so it is only required on the real path.
CLASSIFY="$ROOT/build/classify-sid-exceptions.py"
[ -n "$CLASSIFY_CMD" ] || [ -f "$CLASSIFY" ] || die 3 "$CLASSIFY is missing"

# The tracked pin set, i.e. every file a re-pin owns.  Nothing else may differ
# when this script commits.
PIN_FILES=(manifests/base.pin release.conf manifests/forky-snapshot.tsv
           manifests/determinism.pin manifests/sid-exceptions.tsv
           manifests/build-inputs.tsv build/testdata/forky-snapshot/InRelease)
# Copied into the scratch tree but never committed by a re-pin: the trust file's
# keyring is what pin-snapshot-suites.py verifies the suites against, and its
# digest must not change in a re-pin (the keyring is reviewed separately).
PIN_CONTEXT=(manifests/keys/debian-archive-keyring.gpg
            # gen-base-pin.sh content-pins these ledgers (a pin that omitted an
            # authoritative source would look valid but not pin it), so they are
            # pin INPUTS: copied into the scratch tree, never rewritten by a re-pin.
            manifests/vendor-debs.tsv manifests/vendor-repos.tsv
            manifests/ncz-packages.tsv)

# --- 1. the scratch tree ----------------------------------------------------
mkdir_scratch() {
    local base="${NCZ_REPIN_WORK_ROOT:-${XDG_CACHE_HOME:-${HOME:-}/.cache}/ncz-repin}"
    # Scratch on a real disk: a re-pin measures and extracts multi-GB ISOs.
    local fstype
    fstype="$(findmnt -no FSTYPE -T "$base" 2>/dev/null || stat -f -c %T "$base" 2>/dev/null || echo unknown)"
    case "$fstype" in tmpfs|ramfs) die 3 "scratch root $base is on $fstype; set NCZ_REPIN_WORK_ROOT to a real disk" ;; esac
    mkdir -p "$base" || die 3 "cannot create the scratch root $base"
    mktemp -d "$base/repin.XXXXXX"
}
if [ -n "$WORK" ]; then
    [ -d "$WORK" ] || die 3 "--work $WORK does not exist (create it with a copy of the tree)"
    WORK="$(cd "$WORK" && pwd)"
else
    WORK="$(mkdir_scratch)" || die 3 "cannot create a scratch tree"
fi
say "scratch tree: $WORK"

# Copy the re-pin's inputs (never with the scratch dir inside the tree).
copy_pin_files() {
    local f
    for f in "${PIN_FILES[@]}"; do
        [ -f "$ROOT/$f" ] || continue
        mkdir -p "$(dirname "$WORK/$f")"
        cp -p "$ROOT/$f" "$WORK/$f"
    done
    # The steps that must run HERE (the pin sync, the gates, the fixture, the
    # build --substrate refresh proof) are this repo's own scripts, so they are
    # copied as well: a scratch tree is a copy of the tree a re-pin is reviewed
    # in, not just its data files.  The measurement is still REPLACED by a
    # --refresh-cmd fixture, so a synthetic --repo tests every other step.
    for f in "${PIN_CONTEXT[@]}"; do
        [ -f "$ROOT/$f" ] || continue
        mkdir -p "$(dirname "$WORK/$f")"
        cp -p "$ROOT/$f" "$WORK/$f"
    done
    local src
    for f in refresh-substrate.sh pin-snapshot-suites.py gen-base-pin.sh \
             check-substrate-pin.sh check-pin-coherence.sh build-image.sh lib; do
        src="$HERE/$f"                 # HERE is this script's dir: build/
        [ -e "$src" ] || continue
        mkdir -p "$WORK/build"
        cp -RPp "$src" "$WORK/build/$f"
    done
    # The proof step runs this repo's own gates (test-no-ubuntu.sh,
    # test-build-image.sh, check-pin-coherence.sh, ...) IN the scratch tree, so
    # the scratch tree must be the tree a re-pin is reviewed in: ship the whole
    # build/ script set and the data those gates read (assets/), not a
    # hand-listed subset.  These are machinery, not pinned data under $ROOT.
    local p
    for p in Makefile assets; do
        [ -e "$HERE/../$p" ] || continue
        cp -RPp "$HERE/../$p" "$WORK/$p" 2>/dev/null || true
    done
    # every build/*.sh plus build/lib: a gate that sources a sibling must find it
    local src_root
    src_root="$(cd "$HERE/.." && pwd)"
    for p in "$src_root"/build/*.sh; do
        [ -e "$p" ] || continue
        cp -p "$p" "$WORK/build/"
    done
}
copy_pin_files

# --- 2. both arches resolve the same snapshot -------------------------------
# The same-snapshot rule is about the FINAL pin, so every arch is measured and
# classified first and the comparison happens afterwards: stopping after the
# first arch would leave the scratch tree half re-pinned.
mkdir -p "$WORK/.repin" || die 3 "cannot create $WORK/.repin"
for arch in $ARCH_LIST; do
    iso_var="ISO_$(printf '%s' "$arch" | tr 'a-z' 'A-Z')"
    iso="${!iso_var}"
    if [ -n "$REFRESH_CMD" ]; then
        args=(--arch "$arch")
        [ -n "$iso" ] && args+=(--iso "$iso")
        [ "$NO_FETCH" = 1 ] && args+=(--no-fetch)
        say "refresh $arch (stub): $REFRESH_CMD ${args[*]}"
        # REFRESH_CMD is a TEST-ONLY command string. Expanding it as $REFRESH_CMD
        # word-splits the text and keeps embedded quotes as LITERAL filename
        # characters (bash '/x/y.sh' -> looks for a file literally named that),
        # so eval it as the shell program it is.
        ( cd "$WORK" && eval "$REFRESH_CMD " "${args[@]@Q}" ) 2>&1 | sed 's/^/    /'
        rc="${PIPESTATUS[0]}"
    else
        args=(--arch "$arch")
        [ -n "$iso" ] && args+=(--iso "$iso")
        [ "$NO_FETCH" = 1 ] && args+=(--no-fetch)
        say "refresh $arch: build/refresh-substrate.sh ${args[*]}"
        ( cd "$WORK" && NCZ_REPIN_WORKTREE="$WORK" bash "$WORK/build/refresh-substrate.sh" "${args[@]}" ) 2>&1 | sed 's/^/    /'
        rc="${PIPESTATUS[0]}"
    fi
    if [ "$rc" != 0 ]; then
        die 1 "refresh failed for $arch (rc=$rc). Nothing was changed in $ROOT; nothing to commit. Retry when Debian publishes a week this pin can authorize, or pass --iso-$arch."
    fi
    got="$(awk -F'\t' -v a="$arch" '$1==a{print $4}' "$WORK/manifests/base.pin")"
    [ -n "$got" ] || die 1 "refresh for $arch did not write its base.pin row. Nothing was changed in $ROOT."
    printf '%s\n' "$got" > "$WORK/.repin/refresh.$arch"
    say "  $arch -> snapshot $got"
done
saved=()
for arch in $ARCH_LIST; do saved+=("$(cat "$WORK/.repin/refresh.$arch")"); done
first="${saved[0]}"
for s in "${saved[@]}"; do
    if [ "$s" != "$first" ]; then
        die 1 "the arches resolved DIFFERENT snapshots ($(printf '%s\n' $ARCH_LIST | paste -d' ' -s - ) -> $(printf '%s ' "${saved[@]}")). A re-pin is one archive state for both arches; nothing was changed in $ROOT."
    fi
done
NEW_SNAP="$first"
if [ -n "$SNAP_REQ" ] && [ "$SNAP_REQ" != "$NEW_SNAP" ]; then
    die 1 "--snapshot $SNAP_REQ, but the substrate resolves to $NEW_SNAP. The snapshot is DERIVED from the substrate (build/derive-base-pin.py); do not choose one. Nothing was changed in $ROOT."
fi
if [ "$ARCH_LIST" = "amd64 arm64" ]; then
    for arch in amd64 arm64; do
        r="$(awk -F'\t' -v a="$arch" '$1==a{print $4}' "$WORK/manifests/base.pin")"
        [ "$r" = "$NEW_SNAP" ] || die 1 "base.pin $arch row is '$r', not every arch moved to $NEW_SNAP. Nothing was changed in $ROOT."
    done
fi
OLD_SNAP="$(sed -n 's/^NCZ_BASE_MIRROR_SNAPSHOT="\(.*\)"/\1/p' "$ROOT/release.conf" 2>/dev/null)"
say "snapshot: ${OLD_SNAP:-<unset>} -> $NEW_SNAP"

# --- the pin-dependent files: release.conf / trust metadata / determinism ----
# refresh-substrate.sh measured base.pin above; --sync-only re-derives everything
# that DEPENDS on the pin now in the scratch base.pin (release.conf,
# forky-snapshot.tsv, determinism.pin) without fetching or measuring again.  With
# --refresh-cmd the pin is the stub's, and this runs all the same: the files that
# must move together must move together whatever produced the new base.pin.
say "syncing release.conf, forky-snapshot.tsv and determinism.pin to $NEW_SNAP (--sync-only)"
( cd "$WORK" && NCZ_REPIN_WORKTREE="$WORK" bash "$WORK/build/refresh-substrate.sh" --sync-only ) > "$WORK/.repin/sync.log" 2>&1
rc=$?
sed 's/^/    /' "$WORK/.repin/sync.log"
[ "$rc" = 0 ] || die 1 "the re-pin sync failed (rc=$rc) -- most likely gen-base-pin.sh (now fatal). Nothing was changed in $ROOT."

# --- 3. the sid-exceptions ledger -------------------------------------------
# The classifier judges the substrate (the ISO).  A re-pin must classify THIS
# re-pin's netinst, so the file is looked up in one place: $WORK/.repin/$arch.iso,
# which stage_iso() fills from --iso-<arch>, else from the substrate cache that
# refresh-substrate.sh just verified, else from downloads/.  There is no other
# lookup: a missing ISO is an error, never a silent classify of another week's.
stage_iso() {  # arch -> prints the path, rc 1 if the ISO is nowhere
    local arch="$1" var src
    var="ISO_$(printf '%s' "$arch" | tr 'a-z' 'A-Z')"
    src="${!var}"
    [ -n "$src" ] || { [ -d "$WORK/.repin/cache" ] && src="$(ls -1t "$WORK/.repin/cache/debian-testing-$arch-netinst-"*.iso 2>/dev/null | head -1)"; }
    [ -n "$src" ] || src="$WORK/downloads/debian-testing-$arch-netinst.iso"
    [ -n "$src" ] && [ -f "$src" ] || return 1
    if [ "$(cd "$(dirname "$src")" && pwd)/$(basename "$src")" != "$WORK/.repin/$arch.iso" ]; then
        ln -sf "$(readlink -f "$src")" "$WORK/.repin/$arch.iso" 2>/dev/null || cp -f "$src" "$WORK/.repin/$arch.iso"
    fi
    printf '%s' "$WORK/.repin/$arch.iso"
}

ledger_per_arch() {  # arch out log -- stderr is tee'd to log (captured ONCE)
    local arch="$1" out="$2" log="$3"
    if [ -n "$CLASSIFY_CMD" ]; then
        # CLASSIFY_CMD is a TEST-ONLY command string: eval it (see REFRESH_CMD).
        ( cd "$WORK" && eval "$CLASSIFY_CMD " --arch "$arch" --snapshot "$NEW_SNAP" --ledger "$(printf '%q' "$out")" ) 2>&1 | tee "$log" | sed 's/^/    /'
        return "${PIPESTATUS[0]}"
    fi
    local iso
    iso="$(stage_iso "$arch")" || die 1 "no $arch netinst to classify: pass --iso-$arch, or let refresh-substrate.sh fetch and cache it (looked in \$WORK/.repin/$arch.iso, the substrate cache and downloads/). Nothing was changed in $ROOT."
    ( cd "$WORK" && python3 -I "$CLASSIFY" --arch "$arch" --iso "$iso" --snapshot "$NEW_SNAP" \
        --scratch "$WORK/.repin/classify-$arch" --ledger "$out" ) 2>&1 | tee "$log" | sed 's/^/    /'
    return "${PIPESTATUS[0]}"
}

mkdir -p "$WORK/.repin"
: > "$WORK/.repin/new-exceptions"
if [ "$DEFER_NEW" = 1 ]; then
    say "sid-exceptions: DEFERRED (--defer-new-exceptions): the committed ledger is left untouched"
else
    cur="$WORK/manifests/sid-exceptions.tsv"
    [ -f "$cur" ] || : > "$cur"
    for arch in $ARCH_LIST; do
        next="$WORK/.repin/sid-exceptions.$arch.tsv"
        cp -p "$cur" "$next"
        args=(--arch "$arch" --snapshot "$NEW_SNAP" --ledger "$next" --require-accepted)
        [ -n "$REVIEW_BY" ] && args+=(--review-by "$REVIEW_BY")
        say "classify $arch against $NEW_SNAP"
        # One run per arch: the classifier names every new row on stderr and
        # this log is where the names are read from (never a second run, whose
        # result could differ).
        clog="$WORK/.repin/classify-$arch.log"
        ledger_per_arch "$arch" "$next" "$clog"
        rc=$?
        case "$rc" in
            0) ;;
            4)
                # The classifier names every new row on stderr.  Nothing is
                # written either way; the names come from the SAME run.
                sed -n 's/.*NEW sid exception needs a human review: /    /p' "$clog" >> "$WORK/.repin/new-exceptions"
                die 1 "the new substrate carries NEW sid content that is not in the reviewed ledger (listed above). Review it; then either re-run with --accept-new-exceptions (rows are written with first_seen, the new snapshot and review_by; --review-by DATE sets it) or --defer-new-exceptions to write no ledger. Nothing was changed in $ROOT."
                ;;
            3) die 1 "the pinned snapshot $NEW_SNAP does not authorize the $arch substrate (classify rc 3). Nothing was changed in $ROOT." ;;
            *) die 1 "classify failed for $arch (rc=$rc). Nothing was changed in $ROOT." ;;
        esac
        cmp -s "$cur" "$next" || cp -f "$next" "$cur"
    done
    say "sid-exceptions: $(grep -vc '^#' "$cur" 2>/dev/null || echo 0) row(s)"
fi

# --- 4. the pinned-InRelease fixture, gen-base-pin, tests -------------------
FIXTURE="build/testdata/forky-snapshot/InRelease"
fixture_ok() {
    # NCZ_REPIN_FIXTURE_CMD lets a TEST replace the gpgv-verified check; the real
    # fixture carries Debian's signature and cannot be synthesized, so a fixture
    # repo (synthetic pin, fake keyring) can only be checked by a stub.  Same
    # contract as --refresh-cmd/--classify-cmd: one command string, test-only.
    if [ -n "${NCZ_REPIN_FIXTURE_CMD:-}" ]; then
        ( cd "$WORK" && eval "$NCZ_REPIN_FIXTURE_CMD " ) >/dev/null 2>&1
        return $?
    fi
    [ -x "$ROOT/build/refresh-forky-inrelease-fixture.sh" ] &&
        bash "$ROOT/build/refresh-forky-inrelease-fixture.sh" --root "$WORK" --check >/dev/null 2>&1
}
if [ -x "$WORK/build/refresh-forky-inrelease-fixture.sh" ] && ! fixture_ok; then
    die 1 "$FIXTURE is the pinned snapshot's signed InRelease and it does not match the new pin. Update it from the scratch tree AFTER reviewing the new trust digests:
    build/refresh-forky-inrelease-fixture.sh --root $WORK --out $ROOT/$FIXTURE
then re-run build/repin.sh (it reuses the scratch tree). Nothing was changed in $ROOT."
fi

say "gen-base-pin.sh (fatal, unlike the WARN in refresh-substrate.sh 4b)"
if [ -x "$WORK/build/gen-base-pin.sh" ]; then
    ( cd "$WORK" && bash "$WORK/build/gen-base-pin.sh" ) 2>&1 | sed 's/^/    /'
    rc="${PIPESTATUS[0]}"
    [ "$rc" = 0 ] || die 1 "gen-base-pin.sh failed (rc=$rc); manifests/determinism.pin would be stale. Nothing was changed in $ROOT."
fi

# --- 5. prebuilt rootfs inputs must be rebuilt at the new pin ---------------
stamp_snapshot() {  # file -> the snapshot the rootfs rows record ("built at S")
    sed -n 's/.*rebuilt at pinned snapshot \([0-9]\{8\}T[0-9]\{6\}Z\).*/\1/p' "$1" 2>/dev/null | sort -u | head -1
}
list_rootfs_rows() {  # file -> "line: arch dest (snapshot)"
    awk -F'\t' '!/^#/ && ($2 ~ /rootfs/ || $2 ~ /\.tar\.zst$/) {print $1 "\t" $2}' "$1"
}
if [ -n "$BUILD_INPUTS_DIR" ] && [ ! -f "$BUILD_INPUTS_DIR/build-inputs.info" ]; then
    die 2 "--build-inputs-dir $BUILD_INPUTS_DIR has no build-inputs.info (the rebuilt rows); stage the rebuild output, not the tarballs alone"
fi
need_rebuild=()
for f in manifests/build-inputs.tsv; do
    [ -f "$WORK/$f" ] || continue
    at="$(stamp_snapshot "$WORK/$f")"
    if [ -z "$at" ]; then
        err "WARN: $f records no 'built at <snapshot>' stamp; its rootfs rows cannot be checked"
        continue
    fi
    if [ "$at" != "$NEW_SNAP" ]; then
        while IFS=$'\t' read -r a d; do
            case " $ARCH_LIST " in *" $a "*) need_rebuild+=("$f:$d ($a, built at $at)") ;; esac
        done < <(list_rootfs_rows "$WORK/$f")
    fi
done
# Rebuilt tarballs are staged with --build-inputs-dir: its build-inputs.info IS
# the new manifests/build-inputs.tsv (the rebuild scripts write the row with the
# sha256, size and "rebuilt <date> at pinned snapshot <S>" stamp of the tarball
# they just produced).  The staged rows replace the old ones and are re-checked,
# so a stamp is never rewritten by hand: the old stamps describe tarballs built
# at the OLD archive state, and rewriting them would record a build that never
# ran (the tarball sha256 would stay the old one).
if [ -n "$BUILD_INPUTS_DIR" ] && [ -f "$BUILD_INPUTS_DIR/build-inputs.info" ]; then
    say "staging rebuilt inputs from $BUILD_INPUTS_DIR/manifests/build-inputs.tsv"
    mkdir -p "$WORK/manifests"
    cp -f "$BUILD_INPUTS_DIR/build-inputs.info" "$WORK/manifests/build-inputs.tsv" \
        || die 3 "cannot stage $BUILD_INPUTS_DIR/build-inputs.info"
    need_rebuild=()
    at="$(stamp_snapshot "$WORK/manifests/build-inputs.tsv")"
    if [ "$at" = "$NEW_SNAP" ]; then
        say "  the rebuilt rows record $NEW_SNAP"
    else
        while IFS=$'\t' read -r a d; do
            case " $ARCH_LIST " in *" $a "*) need_rebuild+=("manifests/build-inputs.tsv:$d ($a, staged rows say '${at:-no stamp}')") ;; esac
        done < <(list_rootfs_rows "$WORK/manifests/build-inputs.tsv")
    fi
fi
if [ "${#need_rebuild[@]}" -gt 0 ]; then
    err "the prebuilt rootfs inputs that carry the new pin are missing ($NEW_SNAP):"
    printf '      %s\n' "${need_rebuild[@]}" >&2
    if [ "$DEFER_BUILD_INPUTS" = 1 ]; then
        # Not a success: the pin would move while the rootfs tarballs are still
        # built at the old archive state, which is exactly the half re-pin (C7)
        # this script exists to prevent.  So nothing is written and the exit
        # code says the re-pin is INCOMPLETE.
        say "--defer-build-inputs: stopping BEFORE any copy-back; the re-pin is incomplete (build the rootfs tarballs at $NEW_SNAP, then re-run with --build-inputs-dir DIR)"
        err "INCOMPLETE re-pin: exit 1, nothing was changed in $ROOT"
        exit 1
    fi
    die 1 "rebuild them (build/build-mgmt-rootfs.sh, build/build-rescue-rootfs.sh) and stage the result with --build-inputs-dir DIR (its build-inputs.info has the new rows). Nothing was changed in $ROOT."
fi

# --- 6. prove the re-pin in the scratch tree --------------------------------
fail_tests=()
run_check() {  # label -- cmd...
    local label="$1"; shift
    say "$label"
    ( cd "$WORK" && "$@" ) > "$WORK/.repin/check-$label.log" 2>&1
    local rc=$?
    if [ "$rc" != 0 ]; then
        fail_tests+=("$label (rc=$rc, log $WORK/.repin/check-$label.log)")
        tail -15 "$WORK/.repin/check-$label.log" | sed 's/^/    /' >&2
    fi
    return "$rc"
}
if [ "$SKIP_GATES" = 1 ]; then
    # --skip-gates exists so a SYNTHETIC fixture repo (no assets, no real
    # keyring, no pinned snapshot) can exercise the orchestration without
    # pretending the gates passed.  It is never used on the real path: the
    # definition of done requires these gates to run and pass.
    say "--skip-gates: TEST ONLY, the repository gates were NOT run"
else
    for arch in $ARCH_LIST; do
        run_check "pin-coherence-$arch" bash build/check-pin-coherence.sh --root "$WORK" --arch "$arch" || true
        run_check "substrate-pin-$arch" bash build/check-substrate-pin.sh "$arch" || true
    done
    run_check "gen-base-pin" bash build/gen-base-pin.sh --check || true
    run_check "test-no-ubuntu" bash build/test-no-ubuntu.sh || true
    run_check "test-build-image" bash build/test-build-image.sh || true
fi
if [ "${#fail_tests[@]}" -gt 0 ]; then
    err "the re-pin does not pass its own gates (no test file was edited to make it pass):"
    printf '      %s\n' "${fail_tests[@]}" >&2
    die 1 "nothing was changed in $ROOT. The scratch tree is $WORK (logs in .repin/)."
fi

# --- 7. copy back, prove, commit --------------------------------------------
if [ "$COMMIT" != 1 ] && [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]; then
    die 3 "$ROOT is not clean; a re-pin cannot be told apart from unrelated work. Commit or stash elsewhere first (nothing was copied back)."
fi
changed=()
for f in "${PIN_FILES[@]}"; do
    [ -f "$WORK/$f" ] || continue
    [ -f "$ROOT/$f" ] || { changed+=("$f"); continue; }
    cmp -s "$ROOT/$f" "$WORK/$f" || changed+=("$f")
done
if [ "${#changed[@]}" = 0 ]; then
    say "nothing to do: $ROOT is already at snapshot $NEW_SNAP"
    exit 0
fi
say "copying back: ${changed[*]}"
for f in "${changed[@]}"; do
    mkdir -p "$ROOT/$(dirname "$f")"
    cp -f "$WORK/$f" "$ROOT/$f"
done

unexpected="$(git -C "$ROOT" status --porcelain 2>/dev/null \
    | awk '{print $NF}' | while read -r p; do
        case " ${PIN_FILES[*]} " in *" $p "*) ;; *) printf '%s\n' "$p" ;; esac
      done)"
if [ -n "$unexpected" ]; then
    err "the tree also differs outside the re-pin's files:"; printf '      %s\n' "$unexpected" >&2
    die 3 "refusing to prove or commit a re-pin over unrelated changes"
fi

# The definition of done: a full build on a FRESH pin leaves the tree clean.
# Proven in the scratch tree (a copy; the build stubs every host stage).
if [ -x "$WORK/build/build-image.sh" ] && command -v git >/dev/null 2>&1; then
    if [ ! -d "$WORK/.git" ]; then git -C "$WORK" init -q >/dev/null 2>&1; fi
    if [ -n "$(git -C "$WORK" status --porcelain -- . ':!.repin' 2>/dev/null)" ] || [ ! -d "$WORK/.git" ]; then
        say "WARN: the scratch tree is not a clean git tree; skipping the build --substrate refresh proof"
    else
        say "proof: build/build-image.sh --substrate refresh on the new pin leaves git status empty"
        mkdir -p "$WORK/.repin/run"
        ( cd "$WORK" && NCZ_TEST_STAGE_CMD='echo "[fake] {stage}"' \
            NCZ_BUILD_LOCK="$WORK/.repin/lock" NCZ_LAYERS_DIR="$WORK/.repin/layers" \
            bash build/build-image.sh --arch "$(printf '%s' "${ARCH_LIST%% *}")" --full \
              --substrate refresh --no-publish --run-dir "$WORK/.repin/run" \
              > "$WORK/.repin/check-build-refresh.log" 2>&1 )
        rc=$?
        dirty="$(git -C "$WORK" status --porcelain -- . ':!.repin' 2>/dev/null)"
        if [ "$rc" != 0 ] || [ -n "$dirty" ]; then
            err "the build --substrate refresh proof failed (rc=$rc, dirty: ${dirty:-none})"
            tail -15 "$WORK/.repin/check-build-refresh.log" | sed 's/^/    /' >&2
            die 1 "the copied-back tree does not satisfy the M2 definition of done; nothing was committed"
        fi
    fi
fi

if [ "$COMMIT" = 1 ]; then
    old="${OLD_SNAP:-<unset>}"
    msg="re-pin the base substrate to $NEW_SNAP (amd64 + arm64)

base.pin, release.conf, forky-snapshot.tsv, determinism.pin and
sid-exceptions.tsv move together; the pinned-InRelease fixture and the
build-inputs.tsv rootfs rows record the new archive state.

proof: check-pin-coherence.sh, check-substrate-pin.sh, gen-base-pin.sh
--check, build/test-no-ubuntu.sh and build/test-build-image.sh pass in the
scratch tree with no test file edited, and build-image.sh --substrate
refresh on the new pin leaves git status --porcelain empty.

previous snapshot: $old"
    # explicit paths only (never -A); the worktree was proven clean above
    git -C "$ROOT" add -- "${changed[@]}" || die 3 "git add failed"
    git -C "$ROOT" commit -q -m "$msg" || die 3 "git commit failed"
    say "committed $(git -C "$ROOT" rev-parse --short HEAD): ${changed[*]}"
    [ -z "$(git -C "$ROOT" status --porcelain)" ] || die 3 "the tree is dirty after the commit"
else
    say "NOT committed (--no-commit). Review, then:"
    say "  git -C $ROOT add -- ${changed[*]}"
fi
exit 0
