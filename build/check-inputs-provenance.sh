#!/bin/bash
# check-inputs-provenance.sh -- the PREDICTIVE provenance gate over the BUILD
# INPUTS (docs/BUILD-STABILITY.md M1, the stage-25 `provenance-predict` stage).
#
# Every byte that stage 80 authorizes is authorized HERE from the inputs, before
# the 13-minute offline mirror and hours before any layer or image exists.  It is
# a thin driver over build/forky-provenance.py, and it calls the SAME helpers the
# finished-image scan calls (safe_extract_zst + scan_rootfs for a rootfs tarball,
# authorize_pool + _scan_initrd for the substrate ISO, scan_debs for a deb
# directory), so the early and the final gate cannot reach different verdicts.
# Nothing here reimplements a verdict rule.
#
# Usage: build/check-inputs-provenance.sh --arch amd64|arm64 [OPTIONS]
#
#   --root DIR          the tree to check (default: this checkout)
#   --work DIR          scratch for the extraction (default: $TMPDIR, NEVER tmpfs
#                       -- a substrate ISO and a rootfs tarball are extracted)
#   --index-dir DIR     the verified snapshot index (default: DIR/ncz-inputs-index)
#   --fetch-index       allow the index to be fetched from snapshot.debian.org
#   --receipt FILE      a pre-build payload receipt (authorizes the freshly built
#                       timestamped singularity deb), as stage 50 passes
#   --substrate-iso F   the pinned installer substrate ISO (default:
#                       downloads/debian-testing-$ARCH-netinst.iso when present)
#   --iso-listing F     an `xorriso -find / -exec lsdl` manifest for that ISO (verified against
#                       the ISO's own directory records; needs no xorriso)
#   --iso-evidence DIR  WRITE that manifest into DIR on a host that has xorriso,
#                       then scan with it (this is how a host without xorriso can
#                       still check the substrate)
#   --no-substrate      skip the substrate ISO part (it is not staged)
#   --no-rootfs         skip the prebuilt rootfs tarballs
#   --deb-dir DIR       check this deb directory as well (repeatable); the
#                       standard set below is always checked
#   --exclude PATH      do not check PATH (repeatable; PATH may be relative to
#                       --root or absolute)
#   --quiet             only the FAIL lines
#   --report FILE       append every finding line the verifier printed
#
# Standard inputs checked (each one only when it exists; see the script body):
#   the staged deb dirs   assets/cix-debs, assets/ncz-debs, assets/vendor-debs,
#                         assets/screensaver/$ARCH, downloads/vendor-debs
#   the rootfs tarballs   assets/mgmt/ncz-mgmt-rootfs.tar.zst,
#                         assets/rescue/rescue-rootfs-$ARCH.tar.zst
#   the substrate         the pinned ISO's /cdrom pool and installer initrd
#
# Exit 0 clean, 1 findings, 2 usage / tool error.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ARCH=""; WORK=""; INDEX_DIR=""; FETCH=(); RECEIPT=(); ISO=""; ISO_SET=""
LISTING=""; EVIDENCE=""; DO_SUBSTRATE=1; DO_ROOTFS=1; QUIET=""
DEB_DIRS=(); EXCLUDES=(); REPORT=""

die2() { echo "check-inputs-provenance.sh: $*" >&2; exit 2; }
while [ $# -gt 0 ]; do
    case "$1" in
        --arch)           ARCH="${2:?--arch needs amd64|arm64}"; shift 2 ;;
        --root)           ROOT="${2:?--root needs a directory}"; shift 2 ;;
        --work)           WORK="${2:?--work needs a directory}"; shift 2 ;;
        --index-dir)      INDEX_DIR="${2:?--index-dir needs a directory}"; shift 2 ;;
        --fetch-index)    FETCH=(--fetch-index); shift ;;
        --receipt)        RECEIPT+=(--receipt "${2:?--receipt needs a file}"); shift 2 ;;
        --substrate-iso)  ISO="${2:?--substrate-iso needs a file}"; ISO_SET=1; shift 2 ;;
        --iso-listing)    LISTING="${2:?--iso-listing needs a file}"; shift 2 ;;
        --iso-evidence)   EVIDENCE="${2:?--iso-evidence needs a directory}"; shift 2 ;;
        --no-substrate)   DO_SUBSTRATE=0; shift ;;
        --no-rootfs)      DO_ROOTFS=0; shift ;;
        --deb-dir)        DEB_DIRS+=("${2:?--deb-dir needs a directory}"); shift 2 ;;
        --exclude)        EXCLUDES+=("${2:?--exclude needs a path}"); shift 2 ;;
        --quiet)          QUIET=1; shift ;;
        --report)         REPORT="${2:?--report needs a file}"; shift 2 ;;
        -h|--help)        sed -n '2,50p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) die2 "unknown argument: $1 (see --help)" ;;
    esac
done
case "$ARCH" in
    amd64|arm64) ;;
    "") die2 "--arch amd64|arm64 is required" ;;
    *) die2 "bad --arch '$ARCH' (expected amd64|arm64)"
esac
[ -d "$ROOT" ] || die2 "no such --root: $ROOT"
[ -x "$HERE/forky-provenance.py" ] || die2 "missing $HERE/forky-provenance.py"
for t in python3; do
    command -v "$t" >/dev/null 2>&1 || die2 "required tool not found: $t"
done
[ -n "$LISTING" ] && [ -z "$ISO_SET" ] && die2 "--iso-listing needs --substrate-iso"
[ -n "$LISTING" ] && [ -z "$EVIDENCE" ] && [ ! -f "$LISTING" ] && \
    die2 "no such --iso-listing file: $LISTING"

# Scratch: extraction needs real disk, never tmpfs.  Default under $TMPDIR (the
# caller picks a run-dir TMPDIR that lives on the build disk).
if [ -z "$WORK" ]; then
    WORK="${TMPDIR:-/var/tmp}/ncz-inputs-prov-$ARCH.$$"
fi
mkdir -p "$WORK" || die2 "cannot create --work: $WORK"
if [ -z "$INDEX_DIR" ]; then
    INDEX_DIR="$ROOT/ncz-inputs-index"
fi
mkdir -p "$INDEX_DIR" || die2 "cannot create --index-dir: $INDEX_DIR"

is_excluded() {  # path -- the caller said this input is out of scope
    local p="$1" x
    for x in "${EXCLUDES[@]+"${EXCLUDES[@]}"}"; do
        case "$x" in /*) [ "$p" = "$x" ] && return 0 ;; esac
        [ "$p" = "$ROOT/$x" ] && return 0
        [ "$p" = "$x" ] && return 0
    done
    return 1
}

FAILS=0
LOGF="$WORK/forky-provenance.log"
# Run the SAME verifier the final gate runs, with the input modes.  Its FAIL
# lines are the findings; its exit status is authoritative (it fails closed on a
# missing index or an unreadable input).
run_scan() {
    local label="$1"; shift
    local rc=0
    local -a base=(-I "$HERE/forky-provenance.py" --root-dir "$ROOT" "$@")
    # --root-dir is mandatory here: without it the verifier falls back to ITS
    # own checkout and would verify against a trust root the caller never named.
    # --ubuntu-only is the one mode that needs no verified index; every real scan
    # gets the index the caller resolved (the same trust root stage 80 uses).
    case " $* " in *" --ubuntu-only "*) ;; *) base+=(--index-dir "$INDEX_DIR") ;; esac
    python3 "${base[@]}" ${FETCH[@]+"${FETCH[@]}"} >"$LOGF" 2>&1 || rc=$?
    if [ -n "$QUIET" ]; then
        grep -E '^(FAIL|== )' "$LOGF" >&2 || true
    else
        sed "s/^/[$label] /" "$LOGF" >&2
    fi
    if [ "$rc" != 0 ]; then
        FAILS=$((FAILS + 1))
        echo "[provenance-predict] FAIL: $label (rc=$rc) -- see $LOGF" >&2
        if [ -n "$REPORT" ]; then
            # One finding per line, verbatim from the verifier (its "FAIL" rows
            # are the same rows stage 80 prints for the same bytes).
            grep '^FAIL' "$LOGF" >> "$REPORT" 2>/dev/null || true
        fi
    else
        [ -n "$QUIET" ] || echo "[provenance-predict] ok: $label" >&2
    fi
    return "$rc"
}

[ -n "$REPORT" ] && : > "$REPORT"

# ---- 1. the staged deb directories -----------------------------------------
# The same dirs stage_provenance_inputs() checks, PLUS assets/screensaver/$ARCH
# (the 0.8.19 debs A2 only found at stage 80).  A directory that is absent is
# simply not part of this build's inputs; a directory that exists but holds no
# .deb/.udeb is an input defect stage 80 would report, so it is reported here.
declare -A SEEN_DIR=()
DEBARGS=()
for d in "$ROOT/assets/cix-debs" "$ROOT/assets/ncz-debs" "$ROOT/assets/vendor-debs" \
         "$ROOT/assets/screensaver/$ARCH" "$ROOT/downloads/vendor-debs" \
         ${DEB_DIRS[@]+"${DEB_DIRS[@]}"}; do
    [ -d "$d" ] || continue
    [ -n "${SEEN_DIR[$d]:-}" ] && continue
    SEEN_DIR[$d]=1
    is_excluded "$d" && continue
    ls "$d"/*.deb >/dev/null 2>&1 || ls "$d"/*.udeb >/dev/null 2>&1 || continue
    DEBARGS+=(--debs "$d")
done
if [ "${#DEBARGS[@]}" -gt 0 ]; then
    run_scan "staged debs (${#DEBARGS[@]} dir(s))" "${DEBARGS[@]}" \
        ${RECEIPT[@]+"${RECEIPT[@]}"}
else
    [ -n "$QUIET" ] || echo "[provenance-predict] note: no staged deb directory to check" >&2
fi

# ---- 2. the prebuilt rootfs tarballs ---------------------------------------
# Extracted with safe_extract_zst() and scanned with scan_rootfs() -- exactly
# what scan_image() does to the ones it finds in /ncz-payload.  A missing
# tarball is NOT an input defect here (the arch/variant may not carry it); a
# tarball that exists and fails is.
TARARGS=()
if [ "$DO_ROOTFS" = 1 ]; then
    for tb in "$ROOT/assets/mgmt/ncz-mgmt-rootfs.tar.zst" \
              "$ROOT/assets/rescue/rescue-rootfs-$ARCH.tar.zst"; do
        [ -f "$tb" ] || continue
        is_excluded "$tb" && continue
        TARARGS+=(--rootfs-tar "$tb")
    done
fi
if [ "${#TARARGS[@]}" -gt 0 ]; then
    run_scan "input rootfs tarballs (${#TARARGS[@]})" "${TARARGS[@]}" --work "$WORK"
else
    [ -n "$QUIET" ] || echo "[provenance-predict] note: no prebuilt rootfs tarball staged" >&2
fi

# ---- 3. the pinned installer substrate ------------------------------------
# Its /cdrom pool udebs against the pinned snapshot + manifests/sid-exceptions.tsv,
# and its installer initrd's udebs + dpkg status with the same _scan_initrd() the
# finished-image ESP path uses.  No mount, no root, and no xorriso: the ISO's
# own ECMA-119 directory records are read (an optional --iso-listing is verified
# against them first).  A substrate that is not staged is stage 10's failure to
# report, not a provenance finding -- but an ISO that IS staged and carries an
# unauthorized udeb is exactly the C3 failure this stage exists to stop.
if [ "$DO_SUBSTRATE" = 1 ] && [ -z "$ISO_SET" ]; then
    cand="$ROOT/downloads/debian-testing-$ARCH-netinst.iso"
    [ -f "$cand" ] && ISO="$cand"
fi
if [ "$DO_SUBSTRATE" = 1 ] && [ -n "$ISO" ] && ! is_excluded "$ISO"; then
    if [ ! -f "$ISO" ]; then
        FAILS=$((FAILS + 1))
        echo "[provenance-predict] FAIL: --substrate-iso $ISO does not exist" >&2
    else
        IARGS=(--substrate-iso "$ISO")
        if [ -n "$EVIDENCE" ]; then
            mkdir -p "$EVIDENCE" || die2 "cannot create --iso-evidence: $EVIDENCE"
            # Only a host with xorriso can WRITE the manifest; without it the
            # scan proceeds on the ISO's own directory records.
            if command -v xorriso >/dev/null 2>&1; then
                # Evidence only: this run WRITES the manifest, it does not
                # produce a verdict (the scan below does, with the verified
                # index).  Its exit status is ignored, and because run_scan()
                # bumps FAILS on a non-zero rc, restore the counter around it
                # unconditionally -- decrementing after the fact would drive
                # FAILS negative on success and mask a real failure.  run_scan()
                # also appends the run's FAIL rows to --report, so the report
                # must be restored with the counter: an evidence-only finding
                # left in the report would contradict the verdict this stage
                # returns (the report would list a finding FAILS never counted).
                _f_before="$FAILS"
                _rep_before=""
                [ -n "$REPORT" ] && _rep_before="$(cat "$REPORT" 2>/dev/null)"
                run_scan "iso evidence $(basename "$ISO")" --substrate-iso "$ISO" \
                    --iso-evidence "$EVIDENCE" --work "$WORK" --ubuntu-only || true
                FAILS="$_f_before"
                if [ -n "$REPORT" ]; then
                    printf '%s' "$_rep_before" > "$REPORT"
                    [ -n "$_rep_before" ] && printf '\n' >> "$REPORT"
                fi
                [ -f "$EVIDENCE/iso-listing.txt" ] && IARGS+=(--iso-listing "$EVIDENCE/iso-listing.txt")
            else
                [ -n "$QUIET" ] || echo "[provenance-predict] note: no xorriso on this host; the substrate is scanned from the ISO's own directory records" >&2
            fi
        elif [ -n "$LISTING" ]; then
            IARGS+=(--iso-listing "$LISTING")
        fi
        run_scan "substrate ISO $(basename "$ISO")" "${IARGS[@]}" --work "$WORK"
    fi
elif [ "$DO_SUBSTRATE" = 1 ]; then
    [ -n "$QUIET" ] || echo "[provenance-predict] note: no pinned substrate ISO staged; skipping the substrate part" >&2
fi

if [ "$FAILS" != 0 ]; then
    echo "[provenance-predict] $FAILS input check(s) FAILED for $ARCH (logs: $WORK)" >&2
    exit 1
fi
[ -n "$QUIET" ] || echo "[provenance-predict] all input provenance checks passed for $ARCH" >&2
exit 0
