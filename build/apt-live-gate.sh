#!/bin/bash
# apt-live-gate.sh [DEFAULT_MODE] -- read-only check that the LIVE NCZ repos satisfy the NCZ/Debian separation
# policy (no Debian-named package published outside the allowlist; R2 Origin NCZ-OS).
#
# Mode (first of: $NCZ_APT_LIVE_GATE, DEFAULT_MODE, fail):
#   fail  a violation exits 1         (ship / publish gate: build/ship-image.sh)
#   warn  a violation is reported, exit 0   (build preflight: build/preflight-sbom-check.sh)
#   skip  not run
# check-ncz-repo-policy.sh --live exits 0 with "SKIP" when the indexes are unreachable.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
MODE="${NCZ_APT_LIVE_GATE:-${1:-fail}}"
case "$MODE" in
    skip) echo "apt-live-gate: skipped (NCZ_APT_LIVE_GATE=skip)"; exit 0 ;;
    warn|fail) ;;
    *) echo "apt-live-gate: unknown mode '$MODE' (fail|warn|skip)" >&2; exit 2 ;;
esac
if bash "$HERE/check-ncz-repo-policy.sh" --live; then
    exit 0
fi
if [ "$MODE" = warn ]; then
    echo "apt-live-gate: WARN the live NCZ repos violate the separation policy (build continues; the SHIP gate will refuse)" >&2
    exit 0
fi
echo "apt-live-gate: FAIL the live NCZ repos violate the separation policy (docs/APT-SEPARATION.md runbook step 2)" >&2
exit 1
