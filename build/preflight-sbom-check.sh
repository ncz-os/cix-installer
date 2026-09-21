#!/usr/bin/env bash
# Hard-fail preflight for declared ISO components.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
NCZ_TARGET_ARCH="${NCZ_TARGET_ARCH:-$(dpkg --print-architecture)}"

# Arch-scoped manifest selection (added 2026-09-15 for the AMD64/forky
# installer line -- see sbom/expected-assets-amd64.txt's header for why
# these are separate files rather than one combined list: AMD64 ships no
# Sky1-only assets/DKMS modules, and vice versa arm64 ships no AMD64
# kernel .debs). Falls back to the original arm64/default filename when
# no arch-specific manifest exists, so arm64 behavior is unchanged.
manifest_for() {
    local base="$1"
    local arch_file="$REPO/sbom/$base-$NCZ_TARGET_ARCH.txt"
    if [ -f "$arch_file" ]; then
        echo "$arch_file"
    else
        echo "$REPO/sbom/$base.txt"
    fi
}

echo "=== preflight-sbom-check (NCZ_TARGET_ARCH=$NCZ_TARGET_ARCH) ==="
bash "$REPO/build/verify-assets.sh" "$(manifest_for expected-assets)"

# verify-assets.sh checks base.squashfs by opaque size+sha256 only -- it
# cannot tell WHY the hash changed (or didn't). Semantic check: does the
# squashfs actually contain every currently-staged kernel, by name.
# See MNEMOS mem_1789997635556_0497ae.
if [ -f "$REPO/assets/squashfs/base.squashfs" ]; then
    bash "$REPO/build/verify-squashfs-kernel-identity.sh" "$REPO/assets/squashfs/base.squashfs"
fi
bash "$REPO/build/verify-packages.sh" "$(manifest_for expected-packages)"
if compgen -G "$REPO/build/kernel-debs/*.deb" >/dev/null || \
   compgen -G "$REPO/build/kernel-debs-$NCZ_TARGET_ARCH/*.deb" >/dev/null || \
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
bash "$REPO/build/verify-udebs.sh" "$(manifest_for expected-udebs)"

# verify-dkms-modules.sh's static_check() asserts fixed Sky1 accelerator
# paths (assets/kernel/{mali,vpu,panthor}/dkms.conf, mali/panthor/aipu/vpu
# registration strings in post-install/8[236].sh) UNCONDITIONALLY -- the
# --manifest flag only feeds its malformed-line loop, not that hardcoded
# comparison. It cannot be made to pass on a real AMD64 tree by swapping
# manifests alone (AMD64 ships no accelerator DKMS modules at all, see
# feedback_cix_drivers_all_dkms_never_intree.md), so gate the whole call
# on arch instead of forcing a Sky1-only check to somehow pass elsewhere.
if [ "$NCZ_TARGET_ARCH" = "arm64" ]; then
    bash "$REPO/build/verify-dkms-modules.sh" --manifest "$(manifest_for expected-dkms-modules)"
else
    echo "verify-dkms-modules: skipped (NCZ_TARGET_ARCH=$NCZ_TARGET_ARCH has no Sky1 accelerator DKMS modules)"
fi
echo "preflight-sbom-check: PASS"
