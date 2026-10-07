#!/bin/bash
# shellcheck disable=SC2015  # ok/bad return 0
# Regression test for the amd64 Intel VA-API gap (MEDUSA UHD 630, 2026-10-05).
#
# On an Intel machine libva probed .../dri/iHD_drv_video.so and
# i965_drv_video.so and found neither: the amd64 desktop offline closure never
# listed the Intel VA-API driver, and post-install/54-gpu-accel.sh only pulls
# it at target-install time after wiring Intel's OpenVINO apt repo (which
# needs the network to be up). The Intel decode path must be in the closure
# itself, on amd64 only.
#
# This is a static manifest test: it asserts the intent (amd64 desktop ships
# intel-media-va-driver; arm64/Sky1 does not) plus the parity-allowlist row and
# the SBOM seed that keep the package from silently disappearing.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PASS=0; FAILS=0
ok() { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAILS=$((FAILS+1)); echo "FAIL $1"; }

AMD="$ROOT/manifests/desktop-amd64.pkgs"
ARM="$ROOT/manifests/desktop.pkgs"
ALLOW="$ROOT/build/arch-parity-allowlist.tsv"
SBOM="$ROOT/sbom/expected-packages-amd64.txt"
HOOK="$ROOT/post-install/54-gpu-accel.sh"

# ---- amd64 desktop closure ships the Intel iHD VA-API driver
grep -qE '^[[:space:]]*intel-media-va-driver([[:space:]]|$)' "$AMD" \
    && ok "desktop-amd64.pkgs ships intel-media-va-driver" \
    || bad "desktop-amd64.pkgs lost intel-media-va-driver (Intel VA-API regresses)"

# ---- arm64/Sky1 must NOT carry it (V4L2 decode; Debian has no arm64 build)
grep -qE '^[[:space:]]*intel-media-va-driver([[:space:]]|$)' "$ARM" \
    && bad "desktop.pkgs (arm64) lists intel-media-va-driver; it is amd64-only" \
    || ok "desktop.pkgs (arm64) does not list intel-media-va-driver"

# ---- parity allowlist row (side + reason) so make parity stays green
awk -F'\t' '$1=="desktop" && $2=="intel-media-va-driver" && $3=="amd64-only" && $4!="" {f=1} END{exit(f?0:1)}' "$ALLOW" \
    && ok "arch-parity-allowlist.tsv has an amd64-only row with a reason" \
    || bad "arch-parity-allowlist.tsv row for intel-media-va-driver is missing/incomplete"

# ---- SBOM seed pins the package so verify-packages.sh fails if it vanishes
grep -qxF 'manifests/desktop-amd64.pkgs:intel-media-va-driver' "$SBOM" \
    && ok "sbom/expected-packages-amd64.txt pins intel-media-va-driver" \
    || bad "sbom/expected-packages-amd64.txt does not pin intel-media-va-driver"

# ---- the target-install hook still asks for it (network path stays intact)
# r201: 54 delegates the Intel install to lib/intel-accel.sh (GPU package set).
INTEL_LIB="$ROOT/post-install/lib/intel-accel.sh"
grep -q 'ncz_intel_accel_install' "$HOOK" && grep -qE '_p="intel-opencl-icd intel-media-va-driver ' "$INTEL_LIB" \
    && ok "post-install/54-gpu-accel.sh (via lib/intel-accel.sh) still installs intel-media-va-driver" \
    || bad "post-install/54-gpu-accel.sh no longer installs intel-media-va-driver"

echo "amd64 intel vaapi test: $PASS passed, $FAILS failed"
[ "$FAILS" = 0 ]
