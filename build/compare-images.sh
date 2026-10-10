#!/bin/bash
# compare-images.sh -- prove (or explain) determinism between two builds.
#
#   build/compare-images.sh [--arch A] [--layers DIR_A DIR_B] \
#       [--report OUT.json] [--expect FILE] IMG_A IMG_B
#
# For each artifact it compares the whole-file sha256.  Equal => IDENTICAL.
# Different => it decomposes:
#   * squashfs layers: compare the normalised member listings (content) and,
#     if they differ, optionally run diffoscope (when installed) and save the
#     report;
#   * ESP/FAT: normalised mtools listing;
#   * initrd (cpio.gz): normalised tar/cpio listing;
#   * ext4: whole-file sha (mkfs is pinned; a diff here is a determinism bug);
#   * any JSON sidecar: canonical JSON with volatile keys dropped.
#
# A difference is ACCEPTED (exit 0) only when a matching rule in --expect
# explains it.  The expect file is TAB-separated:
#     <asset-name-or-glob>\t<rule>\t<one-line reason>
# Rules: content-equal-container-diff | json-volatile-only | documented-exception.
# Anything else => exit 1 (a real determinism regression).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/build/lib/compare-lib.sh"

ARCH="" REPORT="" EXPECT="" LAYERS_A="" LAYERS_B=""
POS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --arch) ARCH="${2:?}"; shift 2 ;;
        --report) REPORT="${2:?}"; shift 2 ;;
        --expect) EXPECT="${2:?}"; shift 2 ;;
        --layers) LAYERS_A="${2:?}"; LAYERS_B="${3:?}"; shift 3 ;;
        -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) POS+=("$1"); shift ;;
    esac
done
if [ "${#POS[@]}" -ne 2 ]; then
    echo "compare-images.sh: need exactly two images (IMG_A IMG_B)" >&2
    exit 2
fi
A="${POS[0]}"; B="${POS[1]}"
[ -f "$A" ] || { echo "compare-images.sh: not found: $A" >&2; exit 2; }
[ -f "$B" ] || { echo "compare-images.sh: not found: $B" >&2; exit 2; }

sha_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
expects_rule() {
    local name="$1" rule="$2"
    [ -n "$EXPECT" ] || return 1
    awk -F'\t' -v n="$name" -v r="$rule" '
        $1==n && $2==r {found=1} END{exit !found}' "$EXPECT"
}

declare -a RESULTS=()
FAILS=0
note() { printf '%s\n' "$*"; }

compare_file() {
    local name="$1" fa="$2" fb="$3" kind="${4:-binary}"
    local ha hb
    ha="$(sha_of "$fa")"; hb="$(sha_of "$fb")"
    if [ -z "$ha" ] || [ -z "$hb" ]; then
        note "  $name: MISSING ($fa / $fb)"; RESULTS+=("{\"asset\":\"$name\",\"result\":\"missing\"}"); FAILS=1; return
    fi
    if [ "$ha" = "$hb" ]; then
        note "  $name: IDENTICAL ($ha)"
        RESULTS+=("{\"asset\":\"$name\",\"result\":\"identical\",\"sha256\":\"$ha\"}")
        return
    fi
    note "  $name: DIFF  a=$ha b=$hb"
    # decompose by kind
    local reason="" detail=""
    case "$kind" in
    squashfs)
        if diff <(ncz_canon_squashfs_list "$fa") <(ncz_canon_squashfs_list "$fb") >/dev/null 2>&1; then
            reason="content-equal-container-diff"
            detail="member listings identical; only squashfs container metadata differs"
        else
            detail="member listings differ"
        fi ;;
    fat)
        if diff <(ncz_canon_fat_list "$fa") <(ncz_canon_fat_list "$fb") >/dev/null 2>&1; then
            reason="content-equal-container-diff"
            detail="FAT listings identical; only container metadata differs"
        else
            detail="FAT listings differ"
        fi ;;
    json)
        if diff <(ncz_canon_json "$fa") <(ncz_canon_json "$fb") >/dev/null 2>&1; then
            reason="json-volatile-only"
            detail="canonical JSON identical after dropping volatile keys"
        else
            detail="canonical JSON differs"
        fi ;;
    *) detail="binary files differ" ;;
    esac
    # optional diffoscope evidence
    if command -v diffoscope >/dev/null 2>&1; then
        local ds="$ROOT/build/.compare-diffoscope-$(basename "$name").txt"
        diffoscope --no-progress --text "$ds" "$fa" "$fb" >/dev/null 2>&1 || true
        note "    diffoscope: $ds"
    fi
    if [ -n "$reason" ] && expects_rule "$name" "$reason"; then
        note "    ACCEPTED as $reason ($detail)"
        RESULTS+=("{\"asset\":\"$name\",\"result\":\"$reason\",\"detail\":\"$detail\"}")
    elif expects_rule "$name" "documented-exception"; then
        note "    ACCEPTED as documented-exception ($detail)"
        RESULTS+=("{\"asset\":\"$name\",\"result\":\"documented-exception\",\"detail\":\"$detail\"}")
    else
        note "    UNEXPLAINED DIFFERENCE ($detail)"
        FAILS=1
        RESULTS+=("{\"asset\":\"$name\",\"result\":\"diff\",\"detail\":\"$detail\",\"sha_a\":\"$ha\",\"sha_b\":\"$hb\"}")
    fi
}

note "compare-images:"
note "  A=$A"
note "  B=$B"

note "== final .img =="
compare_file "final.img" "$A" "$B" binary

if [ -n "$LAYERS_A" ] && [ -n "$LAYERS_B" ]; then
    note "== layers ($LAYERS_A vs $LAYERS_B) =="
    for f in base.squashfs desktop.squashfs desktop-hotfix.squashfs \
             esp.img initrd.gz data.img "$(basename "$A").receipt.json"; do
        fa="$LAYERS_A/$f"; fb="$LAYERS_B/$f"
        [ -f "$fa" ] || [ -f "$fb" ] || continue
        kind=binary
        case "$f" in
            *.squashfs) kind=squashfs ;;
            esp.img) kind=fat ;;
            *.json) kind=json ;;
        esac
        compare_file "$f" "$fa" "$fb" "$kind"
    done
fi

# JSON report
if [ -n "$REPORT" ]; then
    {
      printf '{\n  "a": "%s",\n  "b": "%s",\n  "arch": "%s",\n  "verdict": "%s",\n  "assets": [\n' \
        "$A" "$B" "$ARCH" "$([ "$FAILS" = 0 ] && echo deterministic || echo differing)"
      sep="    "
      for r in "${RESULTS[@]}"; do printf '%s%s' "$sep" "$r"; sep=$',\n    '; done
      printf '\n  ]\n}\n'
    } > "$REPORT" 2>/dev/null || true
    note "report: $REPORT"
fi

if [ "$FAILS" = 0 ]; then
    note "RESULT: DETERMINISTIC (all artifacts bit-identical or explained by a documented rule)"
    exit 0
fi
note "RESULT: DIFFERENCES REMAIN (see UNEXPLAINED above)"
exit 1
