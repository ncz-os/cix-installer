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

# --- real SBOM verification against a BUILT tree (not a hand-maintained
# manifest-vs-manifest check like verify-packages.sh above) -------------
#
# Everything before this point checks that our own declared intent is
# internally consistent (manifests agree with sbom/expected-packages.txt,
# staged .debs agree with local build output). None of it looks at an
# actual built rootfs. This section does: it generates a real SPDX 2.3
# document from a built tree's own dpkg database and checks (a) every
# manifest-declared package actually made it into the build, and (b)
# every installed package's version against what's currently available
# from the tree's own configured mirror (a live check, not a cached
# baseline that itself needs updating).
#
# Deliberately decoupled from any specific build_layer() implementation:
# the caller supplies tree paths via SBOM_TREE_<ROLE> env vars (whichever
# script produced base.squashfs's staging tree, desktop's overlay upperdir,
# etc. -- debootstrap+mount today, a containerized mkosi build in flight
# on a parallel branch, or something else later) rather than this script
# assuming one hardcoded path convention. A tree is checked only if its
# env var is set and the directory exists; this section is a no-op
# (prints a note, does not fail) when called pre-build or by a caller that
# has not wired the env vars yet -- it graduates from optional to load-
# bearing once whichever build_layer() replacement is finished wires it in.
sbom_check_tree() {
    local role="$1" tree="$2"; shift 2
    local manifests=("$@")
    [ -n "$tree" ] || return 0
    [ -d "$tree" ] || { echo "preflight-sbom-check: WARNING: SBOM_TREE_${role^^} set to '$tree' but not a directory -- skipping" >&2; return 0; }
    echo "--- SBOM check: $role ($tree) ---"
    local spdx="$REPO/build/sbom-out/${role}.spdx.json"
    mkdir -p "$(dirname "$spdx")"
    python3 "$REPO/build/gen-spdx-sbom.py" --tree "$tree" --name "ncz-os-${role}" --out "$spdx"
    local margs=()
    for m in "${manifests[@]}"; do margs+=(--manifest "$REPO/$m"); done
    python3 "$REPO/build/verify-sbom-against-manifests.py" \
        --spdx "$spdx" --tree "$tree" "${margs[@]}" \
        --stale-allowlist "$REPO/sbom/stale-allowlist.txt"
}

if [ -n "${SBOM_TREE_BASE:-}${SBOM_TREE_DESKTOP:-}" ]; then
    sbom_check_tree base "${SBOM_TREE_BASE:-}" manifests/installer-base.pkgs
    # desktop.pkgs ONLY, not installer-base.pkgs: SBOM_TREE_DESKTOP is the
    # role delta's own tree (an mkosi Overlay=yes upperdir, or the
    # equivalent unsquashed upperdir from the debootstrap+mount path).
    # var/lib/dpkg/status itself is correctly the full MERGED package list
    # (build-role-delta-mkosi.sh's save/restore hooks exist specifically
    # to guarantee this, countering mkosi's dedup pass -- verified for
    # real, 2026-09-14: a full-scale delta build's status carried 1679
    # merged entries against a 320-package base, not just the 191 new
    # ones), so the missing-package check alone would not actually
    # false-positive on base-only packages here. But var/lib/dpkg/info/
    # <pkg>.md5sums and usr/share/doc/<pkg>/copyright for a BASE-only
    # package genuinely do live only in base's own tree, not copied into
    # the delta's upperdir just because it happens to share a merged
    # status file -- gen-spdx-sbom.py degrades those to
    # packageVerificationCode=absent / license=NOASSERTION gracefully
    # (no crash, no false failure), but that's strictly worse SBOM
    # fidelity for no benefit, since base packages are already checked in
    # full via SBOM_TREE_BASE above. Scoping each role's check to only
    # its OWN manifest avoids leaning on that merged-status behavior at
    # all (caught in zoder review, 2026-09-14, though its predicted
    # consequence -- missing-package false positives -- does not actually
    # reproduce against this pipeline's real save/restore-hook behavior).
    sbom_check_tree desktop "${SBOM_TREE_DESKTOP:-}" manifests/desktop.pkgs
else
    echo "preflight-sbom-check: SBOM_TREE_BASE/SBOM_TREE_DESKTOP not set -- skipping real-tree SBOM verification (manifest-only checks above still ran)" >&2
fi

echo "preflight-sbom-check: PASS"
