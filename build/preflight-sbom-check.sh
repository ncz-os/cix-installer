#!/usr/bin/env bash
# Hard-fail preflight for declared ISO components.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== preflight-sbom-check ==="
bash "$REPO/build/verify-assets.sh"
bash "$REPO/build/verify-packages.sh"
if compgen -G "$REPO/build/kernel-debs/*.deb" >/dev/null || \
   compgen -G "$REPO/build/sinty-out/*.deb" >/dev/null; then
    args=(--pool "$REPO/build/forky-vendor-mirror/pool" --label "forky-vendor-mirror")
    if [ -d "$REPO/build/sinty-out" ]; then
        args+=(--debs-dir "$REPO/build/sinty-out")
    fi
    bash "$REPO/build/verify-local-package-versions.sh" "${args[@]}"
fi
if [ -d "$REPO/build/forky-mirror" ]; then
    bash "$REPO/build/verify-offline-mirror-seeds.sh" \
        --mirror "$REPO/build/forky-mirror" \
        --label "forky-mirror"
fi
bash "$REPO/build/verify-udebs.sh"
bash "$REPO/build/verify-dkms-modules.sh"
echo "preflight-sbom-check: PASS"
