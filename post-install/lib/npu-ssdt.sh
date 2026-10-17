#!/bin/sh
# npu-ssdt.sh — decide whether the MS-R1 NPU ACPI SSDT override is required
# on THIS boot / THIS install target, and build the early-CPIO that carries it.
#
# WHY THIS EXISTS (MS-R1, 2026-10-17)
# -----------------------------------
# Minisforum's MS-R1 firmware does not describe the Sky1 NPU compute cores
# (\_SB_.NPU0.CRE0/CRE1/CRE2 have no _HID), so aipu probes
#   "only 0 of 3 NPU cores usable - disabling NPU"
# on both r289 and r290. assets/npu/ssdt-npucre.asl adds the missing
# _HID="CIXH4010". The image shipped that .asl (and, historically, a
# pre-compiled CPIO blob), but NOTHING made the initrd actually contain it, so
# it never loaded.
#
# Radxa Orion O6/O6N firmware is correct: the cores already enumerate, and
# force-loading a second SSDT that redefines the same ACPI named objects risks
# AE_ALREADY_EXISTS. So this decision is DMI-gated exactly like
# ncz_efi_rt_workaround() (build/70-bootloader.sh, assets/refind/
# ncz-refind-refresh.sh): known-good boards are checked FIRST and always win.
#
# The SAME decision has to be made in two very different contexts, which is why
# it lives in one sourced file instead of being restated per consumer:
#   1. install time (post-install/80-npu.sh runs inside the d-i chroot, with
#      /sys bind-mounted, so DMI + /sys/bus/acpi reflect the real board), and
#   2. every initrd rebuild AFTER the install (the dracut module
#      assets/dracut/modules.d/91ncz-npu-ssdt and the initramfs-tools hook
#      assets/initramfs/hooks/ncz-npu-ssdt run on the installed system,
#      including for a kernel upgrade over OTA).
# A config file baked at install time would be wrong on the second context: the
# same /boot can move between boards, and an image built on an O6N must still
# enable the override when it is later installed on an MS-R1.
#
# Public API (POSIX sh):
#   ncz_npu_ssdt_decision [INSTALLER_META]
#       Prints exactly one of: apply | skip
#         apply  — this is an MS-R1-class board that needs the override
#         skip   — every other case (O6/O6N, unknown board, unreadable DMI)
#       Diagnostics go to stderr. Never fails; an unreadable DMI is a SKIP, not
#       an apply: injecting an SSDT for \_SB.CRE0..2 on a board whose firmware
#       does not have that scope is itself a boot risk, unlike efi=noruntime
#       (which fails safe by losing only the RTC).
#
#   ncz_npu_ssdt_build_early_cpio <out.cpio> [INSTALLER_META]
#       Build an UNCOMPRESSED newc CPIO containing exactly
#       kernel/firmware/acpi/ssdt-npucre.aml, which is the layout the kernel's
#       CONFIG_ACPI_TABLE_UPGRADE loader scans for. Exit 0 = written, 1 = could
#       not build (missing source, no cpio, ...), 2 = source is not an .aml.
#       The caller decides what a failure means; this function never exits.
#
# Priority for the decision:
#   0. operator override  $META/NPU_SSDT = force|apply|on|1 | skip|off|0
#   1. functional ACPI check (authoritative, board-agnostic):
#        >=3 CIXH4010:* cores already enumerate -> firmware OK   -> skip
#        CIXH4000:00 present with <3 cores       -> MS-R1-class  -> apply
#   2. DMI:
#        product_name / product_family match MS-R1, or sys_vendor /
#        board_vendor "Micro Computer (HK)"                       -> apply
#        Radxa / Orion / Orange Pi (checked first: allow-list wins) -> skip
#   3. anything else                                            -> skip

# shellcheck shell=sh

# ncz_npu_ssdt_aml_name — the table name the kernel expects under
# kernel/firmware/acpi/ in the early CPIO. Must match build/build-npu-ssdt.sh.
ncz_npu_ssdt_aml_name() {
    printf '%s' ssdt-npucre.aml
}

# ncz_dmi_read <sys-class-dmi-root> <attribute> -> value on stdout
ncz_dmi_read() {
    _ncz_dmi_root=${1%/}
    [ -r "$_ncz_dmi_root/$2" ] || return 0
    tr -d '\000' < "$_ncz_dmi_root/$2" 2>/dev/null | tr -d '\r\n' || true
}

# ncz_npu_ssdt_is_msr1 <product_name> <product_family> <sys_vendor> <board_vendor>
# Exit 0 = MS-R1-class (needs the override). Known-good boards win.
ncz_npu_ssdt_is_msr1() {
    _pn=$1; _pf=$2; _sv=$3; _bv=$4
    # Allow-list first: a board whose firmware is known-correct keeps it that
    # way even if a vendor string would otherwise match the MS-R1 rules.
    case "$_pn" in
        *"Orion O6"*|*"Orange Pi 6"*|*"OrangePi 6"*) return 1 ;;
    esac
    case "$_sv$_bv" in
        *Radxa*|*Xunlong*) return 1 ;;
    esac
    case "$_pn" in
        MS-R1*) return 0 ;;
    esac
    case "$_pf" in
        MS-R1*) return 0 ;;
    esac
    case "$_sv" in
        *"Micro Computer (HK)"*) return 0 ;;
    esac
    return 1
}

# ncz_npu_ssdt_core_count <acpi-devices-dir> -> number of CIXH4010:* cores
ncz_npu_ssdt_core_count() {
    _dir=${1%/}
    _n=0
    for _d in "$_dir"/CIXH4010:*; do
        [ -e "$_d" ] || continue          # unmatched glob stays literal
        _n=$((_n + 1))
    done
    printf '%s' "$_n"
}

# ncz_npu_ssdt_decision [INSTALLER_META]
ncz_npu_ssdt_decision() {
    _meta=${1:-/usr/local/lib/cix-installer}
    _sys=${NCZ_SYS_ROOT:-/sys}

    # 0. Explicit operator override.
    if [ -f "$_meta/NPU_SSDT" ]; then
        case "$(tr -d ' \t\r\n' < "$_meta/NPU_SSDT" 2>/dev/null)" in
            force|apply|on|1) echo "NPU SSDT: forced ON by $_meta/NPU_SSDT" >&2; echo apply; return 0 ;;
            skip|off|0)       echo "NPU SSDT: forced OFF by $_meta/NPU_SSDT" >&2; echo skip; return 0 ;;
        esac
    fi

    # 1. Known-GOOD boards win before any functional signal. A transient or
    #    partially-probed /sys/bus/acpi view (early boot, partial enumeration,
    #    a hidden CIXH4000) must never turn a Radxa/Orange-Pi board into an
    #    "MS-R1-class" one: the allow-list is authoritative because those
    #    vendors' firmware is known to describe the cores correctly.
    _pn=$(ncz_dmi_read "$_sys/class/dmi/id" product_name)
    _pf=$(ncz_dmi_read "$_sys/class/dmi/id" product_family)
    _sv=$(ncz_dmi_read "$_sys/class/dmi/id" sys_vendor)
    _bv=$(ncz_dmi_read "$_sys/class/dmi/id" board_vendor)
    case "$_pn" in
        *"Orion O6"*|*"Orange Pi 6"*|*"OrangePi 6"*)
            echo "NPU SSDT: DMI '$_pn' is a known-good board (native _HID) -- skip" >&2
            echo skip; return 0 ;;
    esac
    case "$_sv$_bv" in
        *Radxa*|*Xunlong*)
            echo "NPU SSDT: DMI '$_sv' is a known-good vendor (native _HID) -- skip" >&2
            echo skip; return 0 ;;
    esac

    # 2. Functional ACPI check -- what the firmware actually described.
    if [ -d "$_sys/bus/acpi/devices" ]; then
        _cores=$(ncz_npu_ssdt_core_count "$_sys/bus/acpi/devices")
        if [ "$_cores" -ge 3 ]; then
            echo "NPU SSDT: $_cores CIXH4010:* cores enumerate natively (>=3) -- skip (firmware OK)" >&2
            echo skip; return 0
        fi
        if [ -e "$_sys/bus/acpi/devices/CIXH4000:00" ]; then
            # The device is there but the cores are not: the MS-R1 _HID gap.
            # Only a board that is not on the allow-list above can get here.
            echo "NPU SSDT: NPU device present, cores incomplete ($_cores/3) -- apply (MS-R1-class _HID gap)" >&2
            echo apply; return 0
        fi
    else
        echo "NPU SSDT: $_sys/bus/acpi unavailable -- falling back to DMI" >&2
    fi

    # 3. DMI match for the board that actually has this defect.
    if ncz_npu_ssdt_is_msr1 "$_pn" "$_pf" "$_sv" "$_bv"; then
        echo "NPU SSDT: DMI '$_pn'/'$_pf'/'$_sv' is MS-R1-class -- apply" >&2
        echo apply; return 0
    fi
    if [ -n "$_pn$_pf$_sv$_bv" ]; then
        echo "NPU SSDT: DMI '$_pn' is not MS-R1-class -- skip" >&2
    else
        echo "NPU SSDT: DMI unreadable and no CIX NPU ACPI signal -- skip" >&2
    fi
    echo skip; return 0
}

# ncz_npu_ssdt_meta — installer meta dir, with the CD-ROM payload as fallback.
# Same precedence post-install/80-npu.sh and 94-dracut-config.sh use.
ncz_npu_ssdt_meta() {
    # NCZ_NPU_SSDT_META overrides the search: a test seam for
    # build/test-npu-ssdt-delivery.sh, and an escape hatch for an operator
    # running a hook by hand against an unpacked payload. Unset in production.
    if [ -n "${NCZ_NPU_SSDT_META:-}" ]; then
        printf '%s' "$NCZ_NPU_SSDT_META"
        return 0
    fi
    if [ -d /usr/local/lib/cix-installer ]; then
        printf '%s' /usr/local/lib/cix-installer
    elif [ -d /cdrom/ncz-payload ]; then
        printf '%s' /cdrom/ncz-payload
    else
        printf '%s' /usr/local/lib/cix-installer
    fi
}

# ncz_npu_ssdt_build_early_cpio <out.cpio> [INSTALLER_META]
#
# WHY THIS FUNCTION EXISTS
# ------------------------
# The kernel's CONFIG_ACPI_TABLE_UPGRADE loader reads uncompressed CPIO
# archives stacked in front of the real initramfs and instaloads every
# kernel/firmware/acpi/*.aml it finds there, before any driver probes. Nothing
# else works: an .aml left on the filesystem is never read, and a compressed
# archive is skipped (the loader only unpacks the first, uncompressed member).
#
# This is the ONE place that builds that archive, and it builds it from the
# .aml payload staged at $META/assets/npu/ssdt-npucre.aml — compiled from the
# committed .asl at build time by build/build-npu-ssdt.sh, never committed as a
# binary. Both the dracut module and the initramfs-tools hook call it on every
# initrd rebuild, so the override survives a kernel upgrade that regenerates
# the initramfs from scratch (which is exactly how MS-R1 lost its NPU before).
#
# Deliberately does NOT read the pre-built npu-acpi-override.cpio blob: that
# file is a build-host convenience for the 80-npu.sh install-time prepend, not
# a target-side dependency, so a stale blob cannot win over a fresh build here.
ncz_npu_ssdt_build_early_cpio() {
    _nz_out=$1
    _nz_meta=${2:-$(ncz_npu_ssdt_meta)}
    _nz_aml_name=$(ncz_npu_ssdt_aml_name)
    _nz_src="$_nz_meta/assets/npu/$_nz_aml_name"

    [ -n "$_nz_out" ] || return 1
    if [ ! -s "$_nz_src" ]; then
        echo "NPU SSDT: no staged table at $_nz_src -- cannot build early CPIO" >&2
        return 1
    fi
    command -v cpio >/dev/null 2>&1 || {
        echo "NPU SSDT: cpio not installed -- cannot build early CPIO" >&2
        return 1
    }

    # A CPIO whose payload is not an ACPI table is worse than no CPIO: the
    # kernel parses it and either ignores the entry or fails the table load,
    # and nothing says so. Check the header signature before packing.
    _nz_sig=$(dd if="$_nz_src" bs=4 count=1 2>/dev/null | tr -d '\000')
    case "$_nz_sig" in
        SSDT|DSDT|APIC|FACP|OEMx) ;;
        *)
            echo "NPU SSDT: $_nz_src is not an ACPI table (sig '$_nz_sig') -- refusing" >&2
            return 2
            ;;
    esac

    _nz_work=$(mktemp -d "${TMPDIR:-/tmp}/ncz-npu-ssdt.XXXXXX") || return 1
    # shellcheck disable=SC2064
    trap 'rm -rf "$_nz_work"' EXIT INT TERM HUP

    mkdir -p "$_nz_work/root/kernel/firmware/acpi"
    cp "$_nz_src" "$_nz_work/root/kernel/firmware/acpi/$_nz_aml_name" || return 1
    # Reproducible: GNU cpio embeds each entry's mtime, so pin them to epoch 0
    # and the same input always yields a byte-identical archive. That is what
    # lets the test suite compare two builds, and what stops an idempotency
    # check based on a hash from churning on every rebuild.
    find "$_nz_work/root" -exec touch -h -d @0 {} + 2>/dev/null || true

    _nz_outdir=$(dirname "$_nz_out")
    mkdir -p "$_nz_outdir" || return 1
    ( cd "$_nz_work/root" && find kernel -print0 | LC_ALL=C sort -z \
        | cpio --null -o -H newc --owner=0:0 --reproducible --quiet ) > "$_nz_out.tmp" || {
        rm -f "$_nz_out.tmp"
        echo "NPU SSDT: cpio packing failed" >&2
        return 1
    }
    [ -s "$_nz_out.tmp" ] || { rm -f "$_nz_out.tmp"; return 1; }
    mv -f "$_nz_out.tmp" "$_nz_out" || return 1
    chmod 0644 "$_nz_out" 2>/dev/null || true

    # The kernel only scans uncompressed newc; a compressed archive here is
    # silently ignored, which is the exact regression this replaces.
    _nz_magic=$(head -c 6 "$_nz_out" 2>/dev/null)
    if [ "$_nz_magic" != "070701" ]; then
        echo "NPU SSDT: $_nz_out is not newc (magic '$_nz_magic') -- refusing" >&2
        rm -f "$_nz_out"
        return 1
    fi

    trap - EXIT INT TERM HUP
    rm -rf "$_nz_work"
    echo "NPU SSDT: wrote $_nz_out (early CPIO, kernel/firmware/acpi/$_nz_aml_name, $(wc -c < "$_nz_out") bytes)" >&2
    return 0
}
