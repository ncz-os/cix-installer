#!/bin/bash
# 81-npu-module.sh — install OOT aipu.ko (cix-npu-kmd) for Sky1 BSP NEXT kernel
#
# The 7.0.9-cix-sky1-next BSP kernel runs the Armchina Zhouyi V3 NPU
# driver as an out-of-tree module. The .ko is built externally via Yocto
# (recipe: meta-cix/recipes-kernel/cix-modules/cix-npu-kmd_1.0.bb against
# linux-cix-sky1-next 7.0.9) — its vermagic must match the running kernel
# exactly, so the asset is version-suffixed.
#
# 80-npu.sh handles ACPI enumeration (SSDT overlay for CRE_HID).
# This hook handles the module placement that 80-npu.sh assumes is done.
#
# Outcome on success:
#   /usr/lib/modules/$KVER_NEXT/extra/cix/aipu.ko
#   /usr/lib/modules/$KVER_NEXT/modules.dep refreshed (depmod)
#
# Validated on cixmini .66 with kernel 7.0.9-cix-sky1-next: probe binds
# to ACPI CIXH4000:00, /dev/aipu created, Zhouyi V3 detected (1 partition
# / 1 cluster / 3 cores / 4 TECs). devfreq disabled (BIOS v1.0 ACPI lacks
# 'perf' power domain).
#
# Reference: MNEMOS mem_1779553642119_d2777a (runtime success).

set -euo pipefail
echo "[81] NPU OOT module install (aipu.ko)"

ASSETS=/usr/local/lib/cix-installer/assets
INSTALLER_META=/usr/local/lib/cix-installer

# Read KVER_NEXT sidecar dropped by 10-our-kernel.sh. NEXT kernel is the
# only one that uses the OOT module — LTS 6.18 has a different .ko shipped
# in its modules-cixmini.tgz tarball.
if [ ! -f "$INSTALLER_META/KVER_NEXT" ]; then
    echo "[81] no KVER_NEXT sidecar — NEXT kernel not installed, skipping aipu.ko"
    exit 0
fi
KVER_NEXT=$(cat "$INSTALLER_META/KVER_NEXT")
if [ -z "$KVER_NEXT" ]; then
    echo "[81] KVER_NEXT empty — skipping"
    exit 0
fi

# Asset is named with the kernel version it was built against. If a future
# release bumps NEXT past 7.0.9, the asset must be rebuilt + renamed.
KO_ASSET="$ASSETS/npu/aipu-${KVER_NEXT}.ko"
if [ ! -f "$KO_ASSET" ]; then
    echo "[81] WARN: $KO_ASSET not found"
    echo "[81]       Expected build artifact for kernel $KVER_NEXT"
    ls "$ASSETS/npu/" 2>/dev/null | head
    echo "[81] skipping aipu.ko install — NPU will fall back to in-tree probe (likely fail)"
    exit 0
fi

# Verify vermagic matches the target kernel before install. Mismatch is
# fatal at insmod time, so catch it here instead of leaving a broken
# /dev/aipu missing situation after boot.
ASSET_VERMAGIC=$(strings "$KO_ASSET" | grep '^vermagic=' | head -1 | sed 's/^vermagic=//' | awk '{print $1}')
if [ "$ASSET_VERMAGIC" != "$KVER_NEXT" ]; then
    echo "[81] ERROR: vermagic mismatch — asset has '$ASSET_VERMAGIC', kernel is '$KVER_NEXT'"
    echo "[81]        rebuild the cix-npu-kmd recipe against the correct kernel-source"
    exit 1
fi

# Drop into /usr/lib/modules/$KVER/extra/cix/ (usrmerge-aware path; matches
# the namespace used by 10-our-kernel.sh's modules-cixmini.tgz extraction
# and the FILES manifest in cix-npu-kmd_1.0.bb).
TARGET_DIR="/usr/lib/modules/${KVER_NEXT}/extra/cix"
mkdir -p "$TARGET_DIR"
install -m 0644 "$KO_ASSET" "$TARGET_DIR/aipu.ko"
echo "[81] installed aipu.ko → $TARGET_DIR/aipu.ko ($(stat -c %s "$TARGET_DIR/aipu.ko") bytes)"

# Refresh modules.dep so modprobe + autoload can find it.
depmod "$KVER_NEXT"
echo "[81] depmod $KVER_NEXT refreshed"

# Verify modinfo + alias presence
if command -v modinfo >/dev/null 2>&1; then
    modinfo -k "$KVER_NEXT" aipu 2>/dev/null | head -5 || \
        echo "[81] WARN: modinfo lookup for aipu failed — check module path"
fi

echo "[81] NPU OOT module install complete"
