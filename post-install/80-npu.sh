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
INSTALLER_META=/usr/local/lib/cix-installer
SSDT_AML="$ASSETS/sky1-firmware/ssdt-npu-cre-hid.aml"

if [ ! -f "$SSDT_AML" ]; then
    echo "[80] WARN: ssdt-npu-cre-hid.aml not found, skipping NPU SSDT deployment"
    exit 0
fi

# take79: prepend SSDT to EVERY installed kernel's initrd (LTS + NEXT both)
# so a switch between boot entries doesn't lose NPU enumeration. Read KVER
# sidecars dropped by 10-our-kernel.sh; never fall back to `uname -r`
# because that is the INSTALLER kernel (LTS d-i environment), not the
# target NEXT runtime kernel.
# Prior bug: KVER fallback to uname -r resulted in SSDT prepended only to
# the LTS initrd; NEXT was the actual boot target → CIXH4010:00/01/02
# unenumerated → /dev/aipu missing → embedkit npu-cix adapter dead.
KVERS=()
for sidecar in KVER_NEXT KVER_LTS; do
    [ -f "$INSTALLER_META/$sidecar" ] || continue
    v=$(cat "$INSTALLER_META/$sidecar" 2>/dev/null || true)
    [ -n "$v" ] && KVERS+=("$v")
done
if [ "${#KVERS[@]}" -eq 0 ]; then
    echo "[80] ERROR: no KVER sidecars found in $INSTALLER_META"
    exit 1
fi

echo "[80] Deploying SSDT overlay for NPU CRE ACPI enumeration (BIOS v1.0 workaround)"
echo "[80] SSDT: $SSDT_AML"
echo "[80] target kernels: ${KVERS[*]}"

# Create ACPI override cpio
TMPDIR=$(mktemp -d)
mkdir -p "$TMPDIR/kernel/firmware/acpi"
cp "$SSDT_AML" "$TMPDIR/kernel/firmware/acpi/ssdt-npu-cre-hid.aml"
(cd "$TMPDIR" && find kernel/ | cpio -H newc -o 2>/dev/null > /tmp/acpi-npu-override.cpio)

# Prepend to every installed kernel's initrd
for KVER in "${KVERS[@]}"; do
    INITRD="/boot/initrd.img-${KVER}"
    if [ ! -f "$INITRD" ]; then
        echo "[80] WARN: initrd not found at $INITRD (kernel $KVER skipped)"
        continue
    fi
    # Idempotency: skip if already prepended (look for our SSDT signature
    # in the leading microcode/early-cpio region).
    if cpio -i -t < "$INITRD" 2>/dev/null | grep -q "ssdt-npu-cre-hid.aml"; then
        echo "[80] SSDT already present in initrd ${INITRD} — skipping"
        continue
    fi
    cat /tmp/acpi-npu-override.cpio "$INITRD" > "${INITRD}.acpi"
    mv "${INITRD}.acpi" "$INITRD"
    cp "$INITRD" "/boot/efi/initrd-${KVER}.img" 2>/dev/null || true
    cp "$INITRD" "/boot/efi/initrd.img-${KVER}" 2>/dev/null || true
    echo "[80] SSDT prepended to initrd for kernel ${KVER}"
done

rm -rf "$TMPDIR" /tmp/acpi-npu-override.cpio
echo "[80] NPU SSDT overlay deployed to ${#KVERS[@]} kernel(s)"
