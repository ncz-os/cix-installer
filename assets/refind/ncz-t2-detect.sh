#!/bin/bash
# ncz-t2-detect.sh -- target-machine Apple T2 detection for the amd64 rEFInd
# refresh script.
#
# SOURCE this file, do not execute it: assets/refind/ncz-refind-refresh-amd64.sh
# sources it from $INSTALLER_META/assets/refind/ so the amd64 EDGE boot entry
# can enable pcie_ports=compat on real T2 Macs ONLY (operator directive
# 2026-10-05). The amd64 image ships ONE unified x86 kernel family for T2 Macs
# and ordinary PCs, so this decision must be made ON THE TARGET MACHINE at
# entry-generation time. An image-build-time constant is not acceptable: the
# same ISO installs onto a generic workstation/server, where pcie_ports=compat
# would needlessly switch off the native AER / PME / PCIe-hotplug port services.
#
# Detection is DMI-based and fails CLOSED (undeterminable => not T2):
#   sys_vendor is "Apple Inc." (or the legacy "Apple Computer, Inc.")
#   AND product_name is one of the known T2 model identifiers, 2018-2020:
#     MacBookPro15,1-4, MacBookPro16,1-4,
#     MacBookAir8,1-2, MacBookAir9,1,
#     iMac19,1-2, iMac20,1-2, iMacPro1,1,
#     Macmini8,1, MacPro7,1.
#   Source: T2 Linux wiki "Introduction" -> the list of devices with the T2
#   chip (https://wiki.t2linux.org/, linking Apple support HT208862), and the
#   model-name match the upstream "Add Apple T2 NHI device links" series uses.
#   post-install/lib/hw-detect.sh's DMI fallback uses the same identifier set
#   (kept in step 2026-10-05); the amd64-kernel-t2 repo's ncz-t2-debug-stage is
#   a separate source of truth and does not consume this file.
#
#   DMI ALONE cannot prove the bridge is present, so the product list is the
#   gate: a pre-T2 Intel Mac, a VM, or a non-Apple machine all fail closed.
#
# The DMI root is overridable for tests via NCZ_DMI_ROOT, pointing at a fake
# /sys/class/dmi/id tree (see build/test-amd64-edge-compat.sh).
#
# ncz_t2_pci_bridge_present() is a belt-and-braces secondary probe: it scans
# /sys/bus/pci/devices for the Apple T2 bridge [106b:1801] or the T2 NHI
# [106b:2005] using pure sysfs reads (no lspci, no pciutils). It is ADVISORY
# only -- used in the human-readable detail log, never as a gate -- because a
# genuine DMI T2 identity must never be suppressed by an early-boot PCI scan
# that has not enumerated the bridge yet, and a stray device must never promote
# a non-T2 machine.

# ncz_dmi_read <root> <file> -- echo the trimmed value, or return 1 if the
# file is missing/empty/unreadable (so the caller fails closed).
ncz_dmi_read() {
    local root="$1" file="$2" val
    [ -r "$root/$file" ] || return 1
    val="$(cat "$root/$file" 2>/dev/null)" || return 1
    [ -n "$val" ] || return 1
    printf '%s' "$val"
}

# ncz_is_t2_hardware -- returns 0 for a known Apple T2 Mac, 1 otherwise.
ncz_is_t2_hardware() {
    local root="${NCZ_DMI_ROOT:-/sys/class/dmi/id}"
    local vendor product
    vendor="$(ncz_dmi_read "$root" sys_vendor)" || return 1
    product="$(ncz_dmi_read "$root" product_name)" || return 1

    case "$vendor" in
        "Apple Inc."|"Apple Computer, Inc.") ;;
        *) return 1 ;;
    esac

    case "$product" in
        MacBookPro15,[1-4]|MacBookPro16,[1-4]|\
        MacBookAir8,[12]|MacBookAir9,1|\
        iMac19,[12]|iMac20,[12]|iMacPro1,1|\
        Macmini8,1|MacPro7,1)
            return 0 ;;
    esac
    return 1
}

# ncz_t2_pci_bridge_present -- advisory: 0 if a T2 PCI bridge/NHI is visible.
ncz_t2_pci_bridge_present() {
    local d
    for d in /sys/bus/pci/devices/*; do
        [ -r "$d/vendor" ] || continue
        case "$(cat "$d/vendor" 2>/dev/null):$(cat "$d/device" 2>/dev/null)" in
            0x106b:0x1801|0x106b:0x2005) return 0 ;;
        esac
    done
    return 1
}

# ncz_t2_detect_detail -- human-readable one-liner; diagnostic/logging only,
# never parsed. Format may change freely.
ncz_t2_detect_detail() {
    local root="${NCZ_DMI_ROOT:-/sys/class/dmi/id}"
    local vendor product
    vendor="$(ncz_dmi_read "$root" sys_vendor 2>/dev/null)" || vendor="?"
    product="$(ncz_dmi_read "$root" product_name 2>/dev/null)" || product="?"
    if ncz_is_t2_hardware; then
        if ncz_t2_pci_bridge_present; then
            printf 'DMI: sys_vendor=%s product_name=%s (T2 PCI bridge present)' "$vendor" "$product"
        else
            printf 'DMI: sys_vendor=%s product_name=%s (no T2 PCI bridge seen; advisory only)' "$vendor" "$product"
        fi
    else
        printf 'DMI: sys_vendor=%s product_name=%s (not a known T2 model)' "$vendor" "$product"
    fi
}
