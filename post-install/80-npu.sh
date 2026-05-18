#!/bin/bash
# 80-npu.sh — deploy SSDT overlay to enable NPU ACPI enumeration on BIOS v1.0
#
# CIX BIOS v1.0 ships CRE0/CRE1/CRE2 (NPU cores under NPU0/CIXH4000) as
# _ADR-only devices without _HID. This SSDT overlay injects _HID=CIXH4010
# and _STA=0xF so Linux can enumerate them as platform devices, enabling
# bus_find_device_by_fwnode() in sky1_npu_probe() to locate the core devices.
#
# The SSDT is prepended to initrd as a cpio archive at kernel/firmware/acpi/
# which the Linux kernel loads as an ACPI table override before ACPI scan.
#
# NOTE: NPU still requires BIOS v1.2 for full SCMI DVFS support.
#       This fix enables ACPI enumeration; hardware power-on needs SCMI.

set -euo pipefail
echo "[80] NPU SSDT overlay deployment"

ASSETS=/usr/local/lib/cix-installer/assets
SSDT_AML="$ASSETS/sky1-firmware/ssdt-npu-cre-hid.aml"
KVER=$(cat "$ASSETS/kernel/next/KVER" 2>/dev/null || uname -r)

if [ ! -f "$SSDT_AML" ]; then
    echo "[80] WARN: ssdt-npu-cre-hid.aml not found, skipping NPU SSDT deployment"
    exit 0
fi

echo "[80] Deploying SSDT overlay for NPU CRE ACPI enumeration (BIOS v1.0 workaround)"
echo "[80] SSDT: $SSDT_AML → kernel/firmware/acpi/"

# Create ACPI override cpio
TMPDIR=$(mktemp -d)
mkdir -p "$TMPDIR/kernel/firmware/acpi"
cp "$SSDT_AML" "$TMPDIR/kernel/firmware/acpi/ssdt-npu-cre-hid.aml"
(cd "$TMPDIR" && find kernel/ | cpio -H newc -o 2>/dev/null > /tmp/acpi-npu-override.cpio)

# Prepend to initrd
INITRD="/boot/initrd.img-${KVER}"
if [ -f "$INITRD" ]; then
    cat /tmp/acpi-npu-override.cpio "$INITRD" > "${INITRD}.acpi"
    mv "${INITRD}.acpi" "$INITRD"
    cp "$INITRD" "/boot/efi/initrd-${KVER}.img"
    echo "[80] SSDT prepended to initrd for kernel ${KVER}"
else
    echo "[80] WARN: initrd not found at $INITRD"
fi

rm -rf "$TMPDIR" /tmp/acpi-npu-override.cpio
echo "[80] NPU SSDT overlay deployed"
