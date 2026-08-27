# Supported platform firmware — CIX Sky1 boards

**Policy (operator, 2026-08-22): NCZ-OS supports Radxa Orion EFI 1.3.1 and
higher. Older firmware is out of scope.**

This is a support boundary, not a kernel limitation. It exists because platform
firmware — not the kernel — decides which hardware Linux is even told about on
Sky1, and we are not going to carry kernel workarounds for firmware that
under-describes the SoC.

## The evidence behind the floor

Measured on an Orion O6 on 2026-08-18, same board, two firmware versions:

| EFI     | USB controllers enumerated                    |
|---------|-----------------------------------------------|
| 1.2.4   | 8 — `CIXH2030:00` and `:02` **absent**        |
| 1.3.1   | 10 — `CIXH2030:00`–`:09` all present          |

Same kernel, same board, same cabling. Under 1.2.4 the Microchip USB5806 hub
that 1.3.1 enumerates was missing entirely and devices sat directly on root
ports.

The operative conclusion, recorded at the time:

> EFI version changes ACPI enumeration, which is why "revert the EFI" changes
> symptoms without fixing anything.

That is the whole reason for this document. Chasing enumeration bugs across
firmware versions produces changing symptoms and no fix, and it burns time that
looks like kernel debugging but is not.

## What this does NOT cover

**Vendor firmware numbering is per-vendor.** "1.3.1" is a Radxa Orion EFI
version. It says nothing about other Sky1 boards:

| Board                     | Firmware string seen        | Status |
|---------------------------|-----------------------------|--------|
| Radxa Orion O6 / O6N      | EFI 1.2.4 / 1.3.1           | floor = 1.3.1 |
| Minisforum MS-R1 (P1WSB)  | `BIOS 1.0`, dated 03/12/2026 | vendor's own numbering — needs a Minisforum update, NOT "1.3.1" |
| Orange Pi 6 / 6 Plus      | not yet measured            | measure on arrival |

MS-R1 `BIOS 1.0` shows the same *shape* as the old Orion EFI — 8 of 10 USB
controllers usable — and has two independent ACPI gaps traced to it:

1. `CIXH2031:00` and `:01` bind `cdns-usbssp` but their
   `usb_role/.../role` never leaves `none`, so no xHCI host is created and both
   USB-C ports are dead. O6N, by contrast, exposes one role switch reading
   `host` and gets all ten controllers.
2. NPU cores `CRE0/1/2` exist in the ACPI namespace but the firmware omits
   `_HID "CIXH4010"`, so no platform devices are created. That is what made
   `sky1_npu_probe()` call `pm_runtime_enable(NULL)` and panic the boot until
   the driver was taught to guard it.

Both are firmware under-description, not kernel defects. Try a vendor firmware
update before writing kernel code for either.

## Practical checks

    # firmware identity
    cat /sys/class/dmi/id/bios_version /sys/class/dmi/id/bios_date \
        /sys/class/dmi/id/board_name

    # how many USB controllers did firmware actually describe?
    ls -d /sys/bus/platform/devices/CIXH2030:* | wc -l    # expect 10
    # ...and how many became xHCI hosts?
    ls -d /sys/bus/platform/devices/CIXH2031:*/xhci-hcd.*.auto 2>/dev/null | wc -l

A count below 10 on the first command, or a gap between the two, means the
platform firmware is the thing to fix.

## A warning about hardcoded controller indices

Because ACPI enumeration shifts with firmware version, **any patch or script
that hardcodes a controller index is fragile by construction.** The index-to-
connector mapping is not stable across firmware.

`patches-7.2/0174-usb-cdns3-sky1-strap-host-only-controllers-as-host.patch`
does exactly this (`data->id == U3_TYPEC_DRD_ID ? MODE_STRAP_OTG :
MODE_STRAP_HOST`, with `U3_TYPEC_DRD_ID = 0`) and additionally assumes a single
DRD port. That assumption holds only on O6N. MS-R1, Orange Pi 6 and Orange Pi 6
Plus each have **two** USB-C ports. Prefer deriving host-vs-DRD from the
firmware description — does this controller have a role-switch/typec companion?
— over an index.

Note also that `_UPC`/`_PLD` are absent on every Sky1 board measured so far:
`connect_type` reads `unknown` for all ports on both MS-R1 and O6N, so the OS
cannot distinguish internal from case-accessible connectors on any of them.
