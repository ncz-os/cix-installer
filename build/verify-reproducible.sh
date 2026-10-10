#!/bin/bash
# verify-reproducible.sh -- SECOND-BUILDER reproducibility verification.
#
# Rebuild the SAME arch from the SAME inputs.lock on a second builder (amd64:
# ACHILLES vs HYDRA/PROTEUS; arm64: same-host-twice on ULTRA until cixmini is
# provisioned -- OPERATOR DECISION D6) and compare the artifacts with
# build/compare-images.sh (+ diffoscope where available), producing a
# normalised report and an attestation.
#
#   build/verify-reproducible.sh --arch amd64|arm64 [--image PATH] \
#       [--inputs-lock PATH] [--run-dir DIR] [--primary ID] [--second ID] \
#       [--dry-run]
#
# A mismatch is a RELEASE BLOCKER.  A rebuild across two DIFFERENT CPU
# microarchitectures (ULTRA Apple Silicon vs cixmini CIX Cortex-A720) is the
# strongest CPU-independence claim; until cixmini exists, arm64 records
# second_builder=pending(cixmini).
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BUILDERS="$ROOT/build/config/builders.tsv"
COMPARE="$ROOT/build/compare-images.sh"
SSH_USER="${NCZ_SSH_USER:-jasonperlow}"   # fleet user; override with NCZ_SSH_USER

ARCH=""; IMAGE=""; INPUTS_LOCK=""; RUN_DIR=""; PRIMARY=""; SECOND=""; DRY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --arch) ARCH="${2:?}"; shift 2 ;;
        --image) IMAGE="${2:?}"; shift 2 ;;
        --inputs-lock) INPUTS_LOCK="${2:?}"; shift 2 ;;
        --run-dir) RUN_DIR="${2:?}"; shift 2 ;;
        --primary) PRIMARY="${2:?}"; shift 2 ;;
        --second) SECOND="${2:?}"; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "verify-reproducible: unknown argument: $1" >&2; exit 2 ;;
    esac
done
case "$ARCH" in amd64|arm64) ;; *) echo "verify-reproducible: --arch amd64|arm64 required" >&2; exit 2 ;; esac

builder_row() { awk -F'\t' -v id="$1" '$1==id{print}' "$BUILDERS" 2>/dev/null | head -1; }
default_primary() { awk -F'\t' -v a="$1" '$3==a && $6=="primary"{print $1; exit}' "$BUILDERS"; }
default_second()  { awk -F'\t' -v a="$1" '$3==a && $6=="second"{print $1; exit}' "$BUILDERS"; }

[ -n "$PRIMARY" ] || PRIMARY="$(default_primary "$ARCH")"
[ -n "$SECOND" ]  || SECOND="$(default_second "$ARCH")"
[ -n "$RUN_DIR" ] || RUN_DIR="$(dirname "${IMAGE:-$ROOT/build/nonexistent}")"
[ -s "$INPUTS_LOCK" ] || INPUTS_LOCK="$RUN_DIR/inputs.lock"

HOSTPRIM="$(builder_row "$PRIMARY" | cut -f2)"
HOSTSEC="$(builder_row "$SECOND" | cut -f2)"
REPORT="$RUN_DIR/reproducible-report.txt"

echo "== verify-reproducible =="
echo "  arch           $ARCH"
echo "  primary        $PRIMARY ($HOSTPRIM)"
echo "  second         ${SECOND:-<none>} ($HOSTSEC)"
echo "  image          ${IMAGE:-<to be built>}"
echo "  inputs.lock    $INPUTS_LOCK"

# The arm64 second builder is cixmini once the operator stabilises it (D6).
SECOND_CLAIM="$SECOND"
if [ "$ARCH" = arm64 ] && { [ -z "$SECOND" ] || [ "$(builder_row "$SECOND" | cut -f6)" = pending ]; }; then
    echo "  NOTE: arm64 second builder is pending(cixmini) -- running SAME-HOST-TWICE on $PRIMARY"
    SECOND_CLAIM="pending(cixmini)"; SECOND="$PRIMARY"
    MODE=same-host-twice
else
    MODE=two-host
fi
echo "  mode           $MODE"
echo "  second claim   $SECOND_CLAIM"

if [ "$DRY" = 1 ]; then
    echo "  dry-run: would rebuild $ARCH on $PRIMARY and $SECOND from $INPUTS_LOCK, then compare with $COMPARE"
    exit 0
fi

[ -s "$INPUTS_LOCK" ] || { echo "verify-reproducible: no inputs.lock at $INPUTS_LOCK (offline reproduction needs one)" >&2; exit 3; }

# --- rebuild on each builder from the SAME inputs.lock (offline, fail-closed) --
build_on() {  # build_on <builder_id> <host> <outdir>
    local id="$1" host="$2" out="$3"
    echo "[verify-reproducible] rebuild on $id ($host) -> $out"
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_USER@$host" \
        "cd \$HOME/Projects/cix-installer-hermetic-20261010 2>/dev/null || cd \$HOME/Projects/cix-installer; \
         TMPDIR=\$HOME/Projects/ncz-repro-$id bash build/build-image.sh --arch $ARCH --full --sources pinned \
            --offline --no-publish --gates provenance --run-dir $out" || return $?
}
mkdir -p "$RUN_DIR/repro"
build_on "$PRIMARY" "$HOSTPRIM" "$RUN_DIR/repro/$PRIMARY" || { echo "verify-reproducible: primary build failed" >&2; exit 1; }
build_on "$SECOND"  "$HOSTSEC"  "$RUN_DIR/repro/$SECOND"  || { echo "verify-reproducible: second build failed" >&2; exit 1; }

img_of() { ls -1 "$1"/ncz-os-"$ARCH"-*.img 2>/dev/null | tail -1; }
IMG_A="$(img_of "$RUN_DIR/repro/$PRIMARY")"
IMG_B="$(img_of "$RUN_DIR/repro/$SECOND")"
[ -n "$IMG_A" ] && [ -n "$IMG_B" ] || { echo "verify-reproducible: could not find built images" >&2; exit 1; }

# --- compare -----------------------------------------------------------------
rc=0
if [ -x "$COMPARE" ]; then
    bash "$COMPARE" "$IMG_A" "$IMG_B" 2>&1 | tee "$REPORT" || rc=1
else
    echo "[verify-reproducible] compare-images.sh missing; falling back to sha256" | tee "$REPORT"
    a="$(sha256sum "$IMG_A" | awk '{print $1}')"; b="$(sha256sum "$IMG_B" | awk '{print $1}')"
    echo "  $PRIMARY $a" | tee -a "$REPORT"; echo "  $SECOND  $b" | tee -a "$REPORT"
    [ "$a" = "$b" ] || rc=1
fi
# diffoscope the remaining differences if present
if command -v diffoscope >/dev/null 2>&1; then
    echo "[verify-reproducible] diffoscope $IMG_A $IMG_B" >> "$REPORT"
    diffoscope --text="$RUN_DIR/repro/diffoscope.txt" "$IMG_A" "$IMG_B" >>"$REPORT" 2>&1 || true
    echo "  diffoscope -> $RUN_DIR/repro/diffoscope.txt" >> "$REPORT"
else
    echo "  (diffoscope not installed; install in a venv under ~/Projects, not system pip)" >> "$REPORT"
fi

VERDICT=$([ "$rc" = 0 ] && echo PASS || echo FAIL)
{
    echo "== verify-reproducible summary =="
    echo "arch=$ARCH mode=$MODE primary=$PRIMARY second=$SECOND second_claim=$SECOND_CLAIM"
    echo "inputs_lock=$INPUTS_LOCK"
    echo "image_a=$IMG_A"
    echo "image_b=$IMG_B"
    echo "verdict=$VERDICT"
} | tee -a "$REPORT"

# --- attestation (unsigned; operator signs) ---------------------------------
if [ -x "$ROOT/build/attest.sh" ]; then
    bash "$ROOT/build/attest.sh" --subject "$IMG_B" --arch "$ARCH" --builder-id "$SECOND" \
        --inputs-lock "$INPUTS_LOCK" --gates "reproducible=$VERDICT" \
        --out "$RUN_DIR/repro/$ARCH.attestation.json" || true
fi
[ "$rc" = 0 ] || { echo "verify-reproducible: MISMATCH -> release blocker (see $REPORT)" >&2; exit 1; }
echo "verify-reproducible: reproducible ($MODE) -- report: $REPORT"
