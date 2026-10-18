#!/bin/sh
# shellcheck shell=sh disable=SC3043
# 91ncz-npu-ssdt/module-setup.sh — deliver the MS-R1 NPU ACPI SSDT override
# into the initrd as an uncompressed early CPIO.
#
# WHY A DRACUT MODULE AND NOT JUST acpi_override=yes
# -------------------------------------------------
# dracut has native ACPI-override support: acpi_override="yes" plus
# acpi_table_dir="<dir of .aml>" makes dracut build the uncompressed early CPIO
# itself. That is the mechanism we WANT, and it is what this module uses when
# the installed dracut has it. But the config-file route alone has two gaps
# this module closes:
#
#   1. acpi_table_dir is dracut-version dependent (the option landed in
#      dracut 050/051; the Red-Hat fork has always had it). On a host whose
#      dracut predates it the setting is silently ignored -- no warning, no
#      error, an initrd without the table and an MS-R1 with "only 0 of 3 NPU
#      cores usable". Instead of trusting a config knob, this module
#      re-checks the RESULT: it confirms the built initrd really carries
#      kernel/firmware/acpi/ssdt-npucre.aml and, if it does not, prepends the
#      archive itself.
#
#   2. The early CPIO must not be compressed. dracut compresses everything
#      else in the image; the kernel's CONFIG_ACPI_TABLE_UPGRADE loader only
#      scans an uncompressed member at the FRONT of the initrd. Handing
#      dracut a directory gets this right, but only if acpi_override is also
#      honoured; the manual prepend below is unconditional in its correctness.
#
# BOARD GATING
# ------------
# The module is installed on every image, so it MUST decide at build time
# whether this board needs the override -- an SSDT that redefines \_SB.NPU0.CRE*
# on a board whose firmware already describes them (Radxa Orion O6/O6N) is an
# AE_ALREADY_EXISTS hazard, not a no-op. It sources the shared decision helper
# and does nothing at all on a "skip" board.
#
# The decision is made on the build host at initrd-build time from
# /sys/class/dmi/id, i.e. the same source ncz_efi_rt_workaround() reads, and is
# re-evaluated on every rebuild. So an initrd rebuilt on an MS-R1 after a
# kernel upgrade regains the override; one rebuilt on an O6N does not get it.
#
# INSTALLED AS: assets/dracut/modules.d/91ncz-npu-ssdt → /usr/lib/dracut/modules.d/

# Shared decision + early-CPIO builder. Installed next to the module by
# post-install/80-npu.sh; the absolute path is a fallback for a hand-run
# `dracut` from an unpacked repo tree.
_ncz_lib=""
for _c in "${NCZ_NPU_SSDT_LIB:-}" \
          /usr/local/lib/cix-installer/post-install/lib/npu-ssdt.sh \
          /cdrom/ncz-payload/post-install/lib/npu-ssdt.sh \
          "$(dirname "$0")/npu-ssdt.sh"; do
    [ -n "$_c" ] && [ -r "$_c" ] && { _ncz_lib="$_c"; break; }
done

_ncz_aml_name=ssdt-npucre.aml

# check() — always claim the module. Whether the override is APPLIED is a
# run-time (initrd-build-time) decision in install(), not a reason to skip
# including the module: a module that is absent cannot report why it did
# nothing, and this board gate is the single most important thing to get right.
check() {
    return 0
}

depends() {
    return 0
}

# install() — stage the table for dracut's native acpi_override path.
install() {
    local meta src dst decision

    decision=skip
    if [ -n "$_ncz_lib" ]; then
        # Source the helper BEFORE asking it anything: ncz_npu_ssdt_meta(),
        # ncz_npu_ssdt_decision() and ncz_npu_ssdt_build_early_cpio() all live
        # there, and sourcing at install() time (not at module load) keeps the
        # module inert when the payload is absent.
        # shellcheck source=/dev/null
        . "$_ncz_lib"
        meta=$(ncz_npu_ssdt_meta)
        decision=$(ncz_npu_ssdt_decision "$meta" 2>/dev/null) || decision=skip
    else
        echo "91ncz-npu-ssdt: WARNING: decision helper not found; not applying the SSDT" >&2
        return 0
    fi

    if [ "$decision" != "apply" ]; then
        echo "91ncz-npu-ssdt: board does not need the NPU SSDT (decision=$decision) -- inactive" >&2
        return 0
    fi

    src="$meta/assets/npu/$_ncz_aml_name"
    if [ ! -s "$src" ]; then
        # Hard-fail rather than silently produce an initrd without the table:
        # on an MS-R1-class board that means a dead NPU after the next kernel
        # upgrade, discovered only when someone tries to use it.
        derror "91ncz-npu-ssdt: $_ncz_aml_name missing at $src -- MS-R1 NPU will be disabled"
        return 1
    fi

    # dracut's native path (dracut >= 050, and every Red-Hat dracut): point it
    # at the directory holding the .aml and let it build the early CPIO.
    # $initdir is provided by the dracut module framework.
    # shellcheck disable=SC2154
    dst="$initdir/usr/share/ncz/acpi"
    mkdir -p "$dst" || { derror "91ncz-npu-ssdt: cannot create $dst"; return 1; }
    cp -f "$src" "$dst/$_ncz_aml_name" || { derror "91ncz-npu-ssdt: cannot copy $src"; return 1; }
    chmod 0644 "$dst/$_ncz_aml_name" 2>/dev/null || true

    # The early CPIO must also land where a fallback prepend can find it after
    # dracut finishes, because install() cannot verify dracut's own output.
    dst="$initdir/usr/share/ncz/acpi-early"
    mkdir -p "$dst" || { derror "91ncz-npu-ssdt: cannot create $dst"; return 1; }
    ncz_npu_ssdt_build_early_cpio "$dst/npu-acpi-override.cpio" "$meta" \
        || { derror "91ncz-npu-ssdt: could not build the early CPIO"; return 1; }

    # Record the decision so the post-build verifier knows an override was
    # expected for THIS image (and can fail loudly if it is absent).
    printf 'apply\n' > "$initdir/usr/share/ncz/acpi-early/decision" 2>/dev/null || true
    return 0
}

# installkernel() — nothing is a kernel module here. The SSDT is data; the
# kernel consumes it from the early CPIO before modules exist.
installkernel() {
    return 0
}
