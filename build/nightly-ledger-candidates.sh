#!/bin/bash
# nightly-ledger-candidates.sh -- emit the CURRENT nightly run's
# ledger-candidates.tsv from the debs it just built.
#
# WHY: manifests/ncz-packages.tsv is a REVIEWED ledger (exact
# name/version/arch/sha256 + recipe + source revision).  A nightly canary
# rebuilds every NCZ component from upstream HEAD, so the versions and bytes
# change every night and must NOT be written into the reviewed ledger.  Instead
# the run records auto-generated CANDIDATE rows here; the provenance gate
# (build/check-forky-provenance.sh --ledger-mode nightly --ledger-candidates
# <this file>) accepts a package from this file ONLY when the sha256 of the bytes
# scanned matches the candidate sha256.  Release mode never reads this file.
#
# SCHEMA (TAB; header lines start with '#'):
#   name  version  arch  sha256  recipe  source_revision  note
#   resolved_source_shas  build_run_id  status
# `status` is always `candidate`.  `source_revision` and `recipe` are the
# canonical build recipe + resolved upstream revision from the run's component
# provenance file (see --provenance).  A deb with no provenance row is SKIPPED
# with a warning (its provenance will hard-fail later -- never invented here).
#
# Usage:
#   build/nightly-ledger-candidates.sh --run-id ID --out FILE \
#       --provenance FILE [--deb-file DEB ...] [--deb-dir DIR ...]
#
# --provenance FILE columns (TAB):
#   output_deb  recipe  source_revision  resolved_source_shas
# (output_deb may be an absolute path or a bare basename; matched by basename.)
#
# Exit 0 ok (even if some debs were skipped -- the count is reported and the
# caller decides), 2 usage/tooling error.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

RUN_ID=""; OUT=""; PROV=""
DEB_FILES=(); DEB_DIRS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --run-id) RUN_ID="${2:?}"; shift 2 ;;
        --out) OUT="${2:?}"; shift 2 ;;
        --provenance) PROV="${2:?}"; shift 2 ;;
        --deb-file) DEB_FILES+=("${2:?}"); shift 2 ;;
        --deb-dir) DEB_DIRS+=("${2:?}"); shift 2 ;;
        -h|--help) sed -n '2,42p' "$0"; exit 0 ;;
        *) echo "nightly-ledger-candidates: unknown arg: $1" >&2; exit 2 ;;
    esac
done
[ -n "$RUN_ID" ] || { echo "nightly-ledger-candidates: --run-id required" >&2; exit 2; }
[ -n "$OUT" ]    || { echo "nightly-ledger-candidates: --out required" >&2; exit 2; }
[ -n "$PROV" ]   || { echo "nightly-ledger-candidates: --provenance required" >&2; exit 2; }
[ -f "$PROV" ]   || { echo "nightly-ledger-candidates: no such provenance file: $PROV" >&2; exit 2; }

command -v sha256sum >/dev/null 2>&1 || { echo "nightly-ledger-candidates: sha256sum not found" >&2; exit 2; }
HAVE_DPKGDEB=0; command -v dpkg-deb >/dev/null 2>&1 && HAVE_DPKGDEB=1

# ---- provenance map: basename -> "recipe<TAB>source_revision<TAB>shas" --------
declare -A PROV_RECIPE PROV_REV PROV_SHAS
while IFS=$'\t' read -r d recipe rev shas || [ -n "${d:-}" ]; do
    [ -z "$d" ] && continue
    case "$d" in \#*) continue ;; esac
    b="$(basename "$d")"
    PROV_RECIPE["$b"]="$recipe"; PROV_REV["$b"]="$rev"; PROV_SHAS["$b"]="${shas:-}"
done < "$PROV"

identity_of() { # deb -> "name<TAB>version<TAB>arch" (control when possible, else filename)
    local f="$1" base n v a
    base="$(basename "$f")"; base="${base%.deb}"; base="${base%.udeb}"
    if [ "$HAVE_DPKGDEB" = 1 ]; then
        n="$(dpkg-deb -f "$f" Package 2>/dev/null || true)"
        v="$(dpkg-deb -f "$f" Version 2>/dev/null || true)"
        a="$(dpkg-deb -f "$f" Architecture 2>/dev/null || true)"
        if [ -n "$n" ] && [ -n "$v" ] && [ -n "$a" ]; then
            printf '%s\t%s\t%s\n' "$n" "$v" "$a"; return 0
        fi
    fi
    # filename fallback: <name>_<version>_<arch> (Debian names/versions never
    # contain '_', so the last two underscores are the version/arch boundary)
    a="${base##*_}"; v="${base%_*}"; v="${v##*_}"; n="${base%%_*}"
    printf '%s\t%s\t%s\n' "$n" "$v" "$a"
}

mkdir -p "$(dirname "$OUT")"
total=0; skipped=0; seen_file="$(mktemp "${TMPDIR:-/tmp}/ncz-cand.XXXXXX")"
trap 'rm -f "$seen_file"' EXIT

emit_one() { # deb
    local f="$1" base id name ver arch sha recipe rev
    [ -f "$f" ] || return 0
    base="$(basename "$f")"
    # de-dup (a deb can be named by --deb-file AND found via --deb-dir)
    grep -qxF "$base" "$seen_file" 2>/dev/null && return 0
    printf '%s\n' "$base" >> "$seen_file"
    if [ -z "${PROV_RECIPE[$base]:-}" ] || [ -z "${PROV_REV[$base]:-}" ]; then
        echo "nightly-ledger-candidates: SKIP $base (no provenance row -- recipe/source_revision unknown)" >&2
        skipped=$((skipped + 1)); return 0
    fi
    recipe="${PROV_RECIPE[$base]}"; rev="${PROV_REV[$base]}"
    id="$(identity_of "$f")"
    name="$(printf '%s' "$id" | cut -f1)"
    ver="$(printf '%s' "$id"  | cut -f2)"
    arch="$(printf '%s' "$id" | cut -f3)"
    [ -n "$name" ] && [ -n "$ver" ] && [ -n "$arch" ] || { echo "nightly-ledger-candidates: SKIP $base (unparseable identity)" >&2; skipped=$((skipped+1)); return 0; }
    sha="$(sha256sum "$f" | awk '{print $1}')"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\tcandidate\n' \
        "$name" "$ver" "$arch" "$sha" "$recipe" "$rev" \
        "auto-generated by nightly canary (run $RUN_ID)" "${PROV_SHAS[$base]:-}" "$RUN_ID"
    total=$((total + 1))
}

{
    printf '# nightly-ledger-candidates.tsv -- run %s -- AUTO-GENERATED, status=candidate.\n' "$RUN_ID"
    printf '# NOT the reviewed ledger. Promote reviewed rows with build/promote-ledger-candidates.sh.\n'
    printf '# Columns (TAB): name\tversion\tarch\tsha256\trecipe\tsource_revision\tnote\tresolved_source_shas\tbuild_run_id\tstatus\n'
    for f in "${DEB_FILES[@]}"; do emit_one "$f"; done
    for d in "${DEB_DIRS[@]}"; do
        [ -d "$d" ] || continue
        while IFS= read -r -d '' f; do emit_one "$f"; done < <(find "$d" -maxdepth 1 -type f \( -name '*.deb' -o -name '*.udeb' \) -print0)
    done
} > "$OUT"

echo "nightly-ledger-candidates: wrote $total candidate row(s) to $OUT (skipped $skipped)"
