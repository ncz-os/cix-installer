#!/bin/bash
# Install the firmware BOM that manifests/firmware.pkgs already puts in the
# offline mirror.
#
# THE GAP THIS CLOSES. firmware.pkgs was consumed only by build-forky-mirror.sh
# and the two verifiers. Nothing ever INSTALLED from it, so a firmware package
# reached the installed system only if some other package happened to depend on
# it. Measured on MEDUSA (MacBookPro16,1) 2026-09-28: firmware-amd-graphics and
# firmware-brcm80211 were present (pulled in as dependencies) while
# firmware-intel-graphics was NOT, /lib/firmware/i915 was EMPTY, and i915
# reported:
#     Direct firmware load for i915/kbl_dmc_ver1_04.bin failed with error -2
# Installing the package supplied 61 i915 files and the kernel then logged
#     Finished loading DMC firmware i915/kbl_dmc_ver1_04.bin (v1.4)
# DMC is the display microcontroller: without it the iGPU cannot enter its
# deep display power states, so this is a real power and thermal cost, not
# cosmetic.
#
# Installing the whole BOM is deliberate. It is described in its own header as
# the COMPLETE architecture-neutral firmware set for the offline closure, every
# package is already in the mirror by construction, and an installer that must
# work on hardware we have not seen should not be guessing which blobs it will
# need. Exclusions belong in firmware-bom.allow, not here.
set -u
BOM=/usr/local/lib/cix-installer/manifests/firmware.pkgs
[ -f "$BOM" ] || BOM=/cdrom/manifests/firmware.pkgs
if [ ! -f "$BOM" ]; then
    echo "[13] firmware BOM not found; skipping"
    exit 0
fi
mapfile -t PKGS < <(grep -hvE '^[[:space:]]*(#|$)' "$BOM" | awk '{print $1}')
[ "${#PKGS[@]}" -gt 0 ] || { echo "[13] firmware BOM empty; skipping"; exit 0; }
echo "[13] installing ${#PKGS[@]} firmware packages from the BOM"
export DEBIAN_FRONTEND=noninteractive
# --no-install-recommends: firmware packages must not drag in extras.
if apt-get install -y --no-install-recommends "${PKGS[@]}"; then
    echo "[13] firmware BOM installed"
else
    # Do not fail the install over firmware: report what is missing and move on.
    echo "[13] WARNING: some firmware packages did not install; checking individually" >&2
    miss=0
    for p in "${PKGS[@]}"; do
        dpkg -s "$p" >/dev/null 2>&1 || { echo "[13]   MISSING: $p" >&2; miss=$((miss+1)); }
    done
    echo "[13] $miss of ${#PKGS[@]} firmware packages missing" >&2
fi
echo "[13] /lib/firmware/i915: $(ls /lib/firmware/i915 2>/dev/null | wc -l) files"
