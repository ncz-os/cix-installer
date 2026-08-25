#!/usr/bin/env bash
# Hard-fail preflight for declared ISO components.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== preflight-sbom-check ==="
bash "$REPO/build/verify-assets.sh"
bash "$REPO/build/verify-packages.sh"
bash "$REPO/build/verify-udebs.sh"
bash "$REPO/build/verify-dkms-modules.sh"
echo "preflight-sbom-check: PASS"
