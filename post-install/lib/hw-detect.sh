#!/bin/bash
# post-install/lib/hw-detect.sh — shared hardware-detection helpers for
# post-install hooks.
#
# SOURCE this file, do not execute it directly: `. "$(dirname
# "$0")/lib/hw-detect.sh"` from a hook that lives directly under
# post-install/ (see 55-t2-firmware.sh for the real calling convention).
# No shared lib directory existed on this project before this file —
# everything else lives as one function per numbered hook (e.g.
# 54-gpu-accel.sh's inline `lspci -nn` PCI-class grep). This file exists
# because T2 detection needed to be reused (and unit-testable on its own)
# rather than re-copy-pasted, per operator directive 2026-09-15.
#
# ---------------------------------------------------------------------------
# is_t2_hardware() -- Apple T2 Mac detection.
# ---------------------------------------------------------------------------
#
# PRIMARY signal: the Apple T2 SMC/bridge PCI device itself.
#   PCI vendor 0x106b is Apple's real, mainline-confirmed vendor ID
#   (`PCI_VENDOR_ID_APPLE`, include/linux/pci_ids.h). Device 0x1801 is the
#   T2 bridge controller's own ID -- t2linux's own out-of-tree kernel
#   patches call it `PCI_DEVICE_ID_APPLE_T2_BRIDGE` (it is NOT in mainline
#   pci_ids.h, it is t2linux's own constant for their own downstream
#   driver work) -- confirmed directly in t2linux's
#   9001-ACPI-x86-Apple-T2-systems-need-early-CPU-offlining.patch on
#   2026-09-14 (see post-install/55-t2-firmware.sh's header for that
#   audit). This is the correct PRIMARY signal because the T2 bridge is the
#   actual physical component apple-bce / apple-firmware-script /
#   apple-t2-audio-config exist to talk to -- if it isn't present, there is
#   no T2 SMC regardless of what chassis the machine is in.
#
#   Verified against REAL T2 hardware 2026-09-15 (read-only oracle check on
#   MEDUSA, a real MacBookPro16,1): `lspci -nn` shows
#     04:00.1 Non-VGA unclassified device [0000]: Apple Inc. T2 Bridge
#             Controller [106b:1801] (rev 01)
#   i.e. the exact bracketed `[106b:1801]` this function greps for is what
#   a real T2 Mac's firmware actually reports -- not just inferred from the
#   patch source.
#
# FALLBACK signal (used ONLY when lspci itself is unavailable to run the
# primary check at all -- pciutils not staged, not a routine second
# opinion): Apple's own DMI identity, narrowed to the known T2-era model
# list. Mainline Linux's own generic Apple-hardware test
# (`x86_apple_machine` in arch/x86/kernel/quirks.c) is exactly
# `dmi_match(DMI_SYS_VENDOR, "Apple Inc.") || dmi_match(DMI_SYS_VENDOR,
# "Apple Computer, Inc.")` -- confirmed by reading that file directly
# 2026-09-15. DMI ALONE cannot prove a T2 bridge is present (pre-T2 Apple
# hardware shares the identical vendor string), so this deliberately
# narrows to the known T2-generation `product_name` values (the same
# model list an upstream "Add Apple T2 NHI device links" patch series
# checks product-name against): MacBookPro15,1-16,4; MacBookAir8,1/8,2/9,1;
# Macmini8,1; MacPro7,1; iMac19,1/19,2; iMac20,1/20,2; iMacPro1,1. The
# iMac19,x pair was added 2026-10-05 to match the T2 Linux wiki model list
# (https://wiki.t2linux.org/, linking Apple support HT208862) and
# assets/refind/ncz-t2-detect.sh, which is the same set used for the amd64
# edge pcie_ports=compat decision; the previous list omitted them.
#
#   Verified against REAL T2 hardware 2026-09-15 (same MEDUSA oracle check):
#   /sys/class/dmi/id/sys_vendor = "Apple Inc.",
#   /sys/class/dmi/id/product_name = "MacBookPro16,1" -- matches this
#   function's DMI fallback pattern exactly.
#
# Fails CLOSED: if neither lspci nor a DMI identity source is available,
# returns 1 (not detected) rather than guessing -- matches the
# fail-closed posture 55-t2-firmware.sh already had for an absent-lspci
# case (it used to skip ALL T2 work outright when lspci was missing; this
# function's DMI fallback is a strict improvement on that, not a behavior
# regression, since it only ever adds a detection path, never removes one).
#
# Returns: 0 = T2 hardware detected, 1 = not detected (or undeterminable).
is_t2_hardware() {
    if command -v lspci >/dev/null 2>&1; then
        lspci -nn 2>/dev/null | grep -qi '\[106b:1801\]' && return 0
        return 1
    fi

    local vendor="" product=""
    if [ -r /sys/class/dmi/id/sys_vendor ]; then
        vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)
        product=$(cat /sys/class/dmi/id/product_name 2>/dev/null)
    elif command -v dmidecode >/dev/null 2>&1; then
        vendor=$(dmidecode -s system-manufacturer 2>/dev/null)
        product=$(dmidecode -s system-product-name 2>/dev/null)
    else
        return 1
    fi

    case "$vendor" in
        "Apple Inc."|"Apple Computer, Inc.") ;;
        *) return 1 ;;
    esac

    case "$product" in
        MacBookPro15,[1-4]|MacBookPro16,[1-4]|MacBookAir8,[12]|MacBookAir9,1|Macmini8,1|MacPro7,1|iMac19,[12]|iMac20,[12]|iMacPro1,1)
            return 0
            ;;
    esac
    return 1
}

# t2_hardware_detail() -- human-readable one-liner describing HOW
# is_t2_hardware's answer was reached. Diagnostic/logging use only; never
# parsed by a caller, format may change freely.
t2_hardware_detail() {
    if command -v lspci >/dev/null 2>&1; then
        if lspci -nn 2>/dev/null | grep -qi '\[106b:1801\]'; then
            echo "PCI probe: [106b:1801] Apple T2 bridge present"
        else
            echo "PCI probe ran, no [106b:1801] Apple T2 bridge found"
        fi
        return
    fi
    if [ -r /sys/class/dmi/id/sys_vendor ]; then
        echo "lspci unavailable -- DMI fallback: sys_vendor='$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)' product_name='$(cat /sys/class/dmi/id/product_name 2>/dev/null)'"
        return
    fi
    if command -v dmidecode >/dev/null 2>&1; then
        echo "lspci unavailable -- dmidecode fallback: manufacturer='$(dmidecode -s system-manufacturer 2>/dev/null)' product='$(dmidecode -s system-product-name 2>/dev/null)'"
        return
    fi
    echo "no PCI or DMI probe available -- cannot verify, treating as not-T2 (fail closed)"
}
