#!/bin/bash
# gen-base-pin.sh -- generate manifests/base.pin, the single committed pin for
# the NCZ-OS image build (docs/IMAGE-BUILD-PROCESS.md, "Inputs and pins").
#
# base.pin is GENERATED, never hand-edited: it aggregates the authoritative
# sources into one file that the build hashes.  The determinism contract is
# "same git commit + same base.pin => bit-identical artifacts", so the pin
# digest (build/lib/reproducible.py pin-digest) is the root that seeds every
# derived UUID and SOURCE_DATE_EPOCH.
#
# It deliberately contains NO timestamps and NO git commit of its own: the
# commit SHA is combined with base.pin at run time, so this file only changes
# when a pin actually changes.
#
#   build/gen-base-pin.sh            # write manifests/base.pin
#   build/gen-base-pin.sh --check    # exit 1 if the file is stale (preflight)
#   build/gen-base-pin.sh --print    # write to stdout
#
# Sources (all committed):
#   release.conf                    NCZ_BASE_MIRROR_SNAPSHOT, NCZ_BASE_CODENAME
#   Makefile                        SUBSTRATE_SHA per arch (print-substrate-sha)
#   assets/singularity/upstream-pins.tsv   superproject "." commit
#   manifests/*.tsv                 sha256 of each ledger (content pin)
#   manifests/singularity-payload.tsv      OPTIONAL prebuilt payload shas
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/manifests/base.pin"
MODE=write
case "${1:-}" in
    --check) MODE=check ;;
    --print) MODE=print ;;
    "") : ;;
    *) echo "gen-base-pin.sh: unknown argument: $1" >&2; exit 2 ;;
esac

PY="$ROOT/build/lib/reproducible.py"
raw_sha_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
# A missing core manifest is a hard error: a pin that silently omits an
# authoritative source would look valid but not pin it.
pin_manifest_sha() {
    local f="$1" s
    s="$(raw_sha_of "$ROOT/$f" || true)"
    [ -n "$s" ] || { echo "gen-base-pin.sh: required manifest missing: $f" >&2; exit 1; }
    printf '%s\n' "$s"
}

# --- snapshot -------------------------------------------------------------
# shellcheck disable=SC1091
. "$ROOT/release.conf"
SNAP="${NCZ_BASE_MIRROR_SNAPSHOT:?release.conf has no NCZ_BASE_MIRROR_SNAPSHOT}"
CODENAME="${NCZ_BASE_CODENAME:-forky}"

# --- substrate shas from the Makefile (one source of truth) ---------------
substrate_sha_of() {
    make -C "$ROOT" --no-print-directory -s print-substrate-sha ARCH="$1" 2>/dev/null \
        | tr -d '[:space:]'
}
SUB_AMD64="$(substrate_sha_of amd64)"
SUB_ARM64="$(substrate_sha_of arm64)"
[ -n "$SUB_AMD64" ] || { echo "gen-base-pin.sh: no vendor substrate pin for amd64" >&2; exit 1; }
[ -n "$SUB_ARM64" ] || { echo "gen-base-pin.sh: no vendor substrate pin for arm64" >&2; exit 1; }

# NOTE: the substrate *filename* is deliberately NOT recorded here.  The pinned
# ISO is identified by its sha256; the local file name depends on which ARGONAS
# cache a host happens to mount, so recording it would make base.pin differ
# from host to host (found 2026-10-10: `gen-base-pin.sh --check` passed on a
# dev box with no cache mounted and failed on a build host with it mounted).
# base.pin must be a pure function of the reviewed pins, not of host state.

# --- singularity superproject upstream pin --------------------------------
SING_PIN=""
if [ -f "$ROOT/assets/singularity/upstream-pins.tsv" ]; then
    SING_PIN="$(awk -F'\t' '$1=="." {print $4; exit}' "$ROOT/assets/singularity/upstream-pins.tsv")"
fi

# --- manifest content pins ------------------------------------------------
BUILD_INPUTS_SHA="$(pin_manifest_sha manifests/build-inputs.tsv)"
VENDOR_DEBS_SHA="$(pin_manifest_sha manifests/vendor-debs.tsv)"
NCZ_PACKAGES_SHA="$(pin_manifest_sha manifests/ncz-packages.tsv)"
VENDOR_REPOS_SHA="$(pin_manifest_sha manifests/vendor-repos.tsv)"

# optional prebuilt singularity payload rows:
#   arch<TAB>sha256<TAB>source_revision
SING_PAYLOAD_AMD64=""; SING_PAYLOAD_ARM64=""
if [ -f "$ROOT/manifests/singularity-payload.tsv" ]; then
    SING_PAYLOAD_AMD64="$(awk -F'\t' '$1=="amd64"{print $2; exit}' "$ROOT/manifests/singularity-payload.tsv")"
    SING_PAYLOAD_ARM64="$(awk -F'\t' '$1=="arm64"{print $2; exit}' "$ROOT/manifests/singularity-payload.tsv")"
fi

# --- snapshot epoch -------------------------------------------------------
SNAP_EPOCH="$(python3 -I "$PY" snapshot-epoch "$SNAP")"

# --- emit -----------------------------------------------------------------
emit() {
    printf '# manifests/base.pin -- NCZ-OS image build input pin (GENERATED).\n'
    printf '#\n'
    printf '# Do NOT hand-edit.  Regenerate with `build/gen-base-pin.sh` after a\n'
    printf '# reviewed change to a source pin, and commit it.  The build hashes this\n'
    printf '# file (build/lib/reproducible.py pin-digest); that digest is the determinism\n'
    printf '# root for every derived UUID and for SOURCE_DATE_EPOCH.  No wall-clock\n'
    printf '# timestamps and no git commit of its own -- see docs/IMAGE-BUILD-PROCESS.md.\n'
    printf '#\n'
    printf '# Source of each row is named in the comment; the authority is the source,\n'
    printf '# not this file.\n'
    printf 'base_codename\t%s\n' "$CODENAME"
    printf 'snapshot\t%s\n' "$SNAP"
    printf 'snapshot_epoch\t%s\n' "$SNAP_EPOCH"
    printf 'substrate_sha256_amd64\t%s\n' "$SUB_AMD64"
    printf 'substrate_sha256_arm64\t%s\n' "$SUB_ARM64"
    [ -n "$SING_PIN" ] && printf 'singularity_upstream_pin\t%s\n' "$SING_PIN"
    [ -n "$SING_PAYLOAD_AMD64" ] && printf 'singularity_payload_sha256_amd64\t%s\n' "$SING_PAYLOAD_AMD64"
    [ -n "$SING_PAYLOAD_ARM64" ] && printf 'singularity_payload_sha256_arm64\t%s\n' "$SING_PAYLOAD_ARM64"
    [ -n "$BUILD_INPUTS_SHA" ] && printf 'manifest_build_inputs_sha256\t%s\n' "$BUILD_INPUTS_SHA"
    [ -n "$VENDOR_DEBS_SHA" ] && printf 'manifest_vendor_debs_sha256\t%s\n' "$VENDOR_DEBS_SHA"
    [ -n "$NCZ_PACKAGES_SHA" ] && printf 'manifest_ncz_packages_sha256\t%s\n' "$NCZ_PACKAGES_SHA"
    [ -n "$VENDOR_REPOS_SHA" ] && printf 'manifest_vendor_repos_sha256\t%s\n' "$VENDOR_REPOS_SHA"
    true
}

# Scratch goes in the git dir, never a tmpfs and never the tracked tree
# (docs + scratch-and-cleanup policy).
GITDIR="$(git -C "$ROOT" rev-parse --git-dir 2>/dev/null || echo "$ROOT/.git")"
case "$GITDIR" in /*) ;; *) GITDIR="$ROOT/$GITDIR" ;; esac
TMP="$(mktemp "$GITDIR/ncz-base-pin.XXXXXX")"
trap 'rm -f "$TMP" "$TMP.canon" "$TMP.diff"' EXIT
emit > "$TMP"
# canonicalise (sort rows, drop comments, stable trailing newline)
python3 -I "$PY" canonical "$TMP" > "$TMP.canon"

case "$MODE" in
    print)
        cat "$TMP.canon" ;;
    write)
        cp -f "$TMP.canon" "$OUT"
        echo "[base-pin] wrote $OUT"
        python3 -I "$PY" pin-digest "$OUT" | sed 's/^/[base-pin] digest /' ;;
    check)
        if [ ! -f "$OUT" ]; then echo "[base-pin] FAIL: $OUT missing (run build/gen-base-pin.sh)" >&2; exit 1; fi
        if ! diff -u "$OUT" "$TMP.canon" > "$TMP.diff" 2>&1; then
            echo "[base-pin] FAIL: $OUT is stale vs the authoritative pins:" >&2
            cat "$TMP.diff" >&2
            exit 1
        fi
        echo "[base-pin] OK: $OUT matches the authoritative pins" ;;
esac
