#!/usr/bin/env bash
# npu-ssdt-gate.sh — refuse to build an ISO that lacks the MS-R1 NPU SSDT
# override early-CPIO.
#
# WHY THIS EXISTS (measured 2026-08-22)
# ------------------------------------
# assets/npu/ is a gitignored blob dir. The ASL source
# (assets/npu/ssdt-npucre.asl) IS committed, but the compiled CPIO
# (assets/npu/npu-acpi-override.cpio) is NOT, and for months NOTHING in the
# build pipeline invoked build-npu-ssdt.sh. The .cpio sat on installed boards
# as an unexplained leftover binary from one earlier install. Every shipped
# ISO went out without it. On the Minisforum MS-R1 that meant no NPU at all
# (factory BIOS omits _HID "CIXH4010" on \_SB.NPU0.CRE0/CRE1/CRE2, so Linux
# never enumerated the cores — and pre-+ncz3 the in-tree sky1_npu_probe
# NULL-deref'd in pm_runtime_enable(NULL) on the missing platforms).
#
# The .asl source, the build helper (build/build-npu-ssdt.sh), and the
# install-time pre-pending logic (post-install/80-npu.sh) are all correct.
# The only thing that was missing was a LOUD FAILURE POINT so that a build
# host without iasl, a build host where someone `rm`'d the blob, or any
# build-npu-ssdt.sh failure couldn't ship an ISO without being noticed.
#
# This gate is that loud failure point. It is a small, standalone script
# (matches the pattern of build/dkms-abi-gate.sh and build/secret-scan-gate.sh)
# so it can be:
#   1. Called inline from build-iso-di.sh's full-mode preflight block
#   2. Run standalone by a build host operator to validate the assets/ tree
#      before kicking off `make iso`
#   3. Invoked by CI / KVM gates if/when those grow to cover this asset
#
# CHECKS (all must pass for exit 0)
# ---------------------------------
#   1. assets/npu/ssdt-npucre.asl exists and is non-empty (the source).
#   2. assets/npu/npu-acpi-override.cpio exists and is non-empty (the blob).
#   3. The CPIO is in newc format (magic "070701" at offset 0) — the kernel
#      only inspects uncompressed early-CPIO archives for ACPI overrides.
#   4. The CPIO contains exactly kernel/firmware/acpi/ssdt-npucre.aml, the
#      path the kernel's early-CPIO ACPI loader looks for.
#   5. iasl is installed (apt: acpica-tools) — required to regenerate the
#      .cpio from the .asl if the blob goes missing on the next build host.
#
# --regen: regenerate the .cpio from the .asl using build-npu-ssdt.sh when
# the blob is missing or invalid. Idempotent and safe to re-run; on a host
# without iasl, --regen is a no-op (the gate's hard-fail below still fires).
#
# Usage: build/npu-ssdt-gate.sh [--regen]
#
# Exit codes:
#   0  PASS — the assets/npu tree is consistent and complete.
#   1  FAIL — at least one check above did not pass; remediation printed.
#   2  USAGE — bad command-line arguments.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ASL="$REPO/assets/npu/ssdt-npucre.asl"
CPIO="$REPO/assets/npu/npu-acpi-override.cpio"
BUILDER="$REPO/build/build-npu-ssdt.sh"
EXPECTED_ENTRY="kernel/firmware/acpi/ssdt-npucre.aml"

REGEN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --regen) REGEN=1; shift ;;
        -h|--help)
            sed -n '2,/^set -uo pipefail$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "npu-ssdt-gate: unknown arg: $1" >&2; exit 2 ;;
    esac
done

ok()    { echo "npu-ssdt-gate: ok: $*"; }
warn()  { echo "npu-ssdt-gate: WARN: $*" >&2; }
fail()  { echo "npu-ssdt-gate: FAIL: $*" >&2; FAILED=1; }
die()   { fail "$@"; exit 1; }

FAILED=0

# --- 1. ASL source present -------------------------------------------------
if [ ! -s "$ASL" ]; then
    die "ASL source missing or empty: $ASL"
    echo "  This file IS committed (see .gitignore: !assets/npu/ssdt-npucre.asl)." >&2
    echo "  If your checkout is missing it, your clone is broken — re-clone." >&2
    exit 1
fi
asl_sha=$(sha256sum "$ASL" | awk '{print $1}')
ok "ASL source present ($(stat -c%s "$ASL") bytes, sha256 ${asl_sha:0:16}…)"

# --- 2. CPIO blob present --------------------------------------------------
# Build-npu-ssdt.sh first; the operator expects that on a host with iasl
# installed the gate can regenerate the blob on demand.
if [ ! -s "$CPIO" ]; then
    if [ "$REGEN" = "1" ] && command -v iasl >/dev/null 2>&1 && [ -x "$BUILDER" ]; then
        echo "npu-ssdt-gate: regenerating $CPIO via build-npu-ssdt.sh"
        if ! bash "$BUILDER"; then
            die "build-npu-ssdt.sh FAILED — see output above"
        fi
    elif [ "$REGEN" = "1" ] && [ ! -x "$BUILDER" ]; then
        die "$BUILDER not executable — chmod +x and re-run, or fix the checkout"
    elif [ "$REGEN" = "1" ] && ! command -v iasl >/dev/null 2>&1; then
        die "iasl not installed (apt install acpica-tools) and no CPIO present"
    fi
fi

if [ ! -s "$CPIO" ]; then
    fail "CPIO blob missing or empty: $CPIO"
    echo "" >&2
    echo "  Remediation:" >&2
    echo "    1. install the build-host dep:  sudo apt install acpica-tools   (provides iasl)" >&2
    echo "    2. regenerate from the committed .asl:  bash build/build-npu-ssdt.sh" >&2
    echo "    3. confirm:  test -s assets/npu/npu-acpi-override.cpio && echo OK" >&2
    echo "  Or pass --regen to this gate." >&2
    echo "" >&2
    echo "  Why this matters: assets/npu/ is gitignored. Without this gate," >&2
    echo "  a fresh clone of the repo will not produce a CPIO at all, and the" >&2
    echo "  resulting ISO installs onto MS-R1 with NO working NPU — the" >&2
    echo "  CIXH4000:00 device shows up, but no CIXH4010:00..02 cores ever" >&2
    echo "  enumerate, so /dev/aipu is absent." >&2
    echo "  See build/build-npu-ssdt.sh + post-install/80-npu.sh." >&2
fi

# --- 3. CPIO is in newc format --------------------------------------------
# The kernel only inspects tables in early-CPIO archives before the real
# initramfs is unpacked; the archive MUST be uncompressed newc. A zstd-compressed
# (or otherwise mangled) blob silently fails to inject — exactly the regression
# that started this task.
if [ "$FAILED" = "0" ]; then
    magic=$(head -c 6 "$CPIO" 2>/dev/null)
    if [ "$magic" != "070701" ]; then
        fail "CPIO magic is '$magic', expected '070701' (newc)."
        echo "  The kernel only inspects uncompressed newc early-CPIO archives." >&2
        echo "  Re-run:  bash build/build-npu-ssdt.sh" >&2
    else
        ok "CPIO is uncompressed newc (magic 070701, $(stat -c%s "$CPIO") bytes)"
    fi
fi

# --- 4. CPIO contains the expected entry ---------------------------------
# The kernel's early-CPIO ACPI-override loader looks for exactly this path.
# Any other content means a stale blob, an accidental overwrite, or someone
# hand-edited the CPIO — all silent regression classes this gate exists to
# catch.
if [ "$FAILED" = "0" ]; then
    if ! cpio -it < "$CPIO" 2>/dev/null | grep -qxF "$EXPECTED_ENTRY"; then
        entries=$(cpio -it < "$CPIO" 2>/dev/null | sed 's/^/      /')
        fail "CPIO does not contain expected entry: $EXPECTED_ENTRY"
        echo "  Contents:" >&2
        printf '%s\n' "$entries" >&2
        echo "  Re-run:  bash build/build-npu-ssdt.sh" >&2
    else
        ok "CPIO contains $EXPECTED_ENTRY"
        # The AML inside the CPIO must be a valid ACPI table — header signature
        # at offset 0 is "SSDT" (or any of the other valid signatures).
        aml_in_cpio_file=$(mktemp)
        # Bash strips trailing NULs from $() output, so we have to write the
        # extracted bytes to a temp file to read 8+ raw bytes back.
        if ! cpio -i --quiet --to-stdout "$EXPECTED_ENTRY" < "$CPIO" 2>/dev/null \
                > "$aml_in_cpio_file"; then
            fail "could not extract $EXPECTED_ENTRY from $CPIO"
            rm -f "$aml_in_cpio_file"
        else
            # Read signature (bytes 0-3) and length (bytes 4-7, little-endian
            # uint32) from the ACPI table header. The length is the entire
            # table including the 36-byte header — the kernel uses it to walk
            # successive tables in a single blob.
            read -r aml_sig aml_len < <(python3 -c '
import sys, struct
hdr = open(sys.argv[1], "rb").read()
if len(hdr) < 8:
    print("BAD 0"); sys.exit(0)
sig = hdr[:4].decode("ascii", "replace")
length = struct.unpack("<I", hdr[4:8])[0]
print(sig, length)
' "$aml_in_cpio_file")
            rm -f "$aml_in_cpio_file"
            case "$aml_sig" in
                SSDT|APIC|DSDT|FACP|HPET|MCFG|SLIC|SLIT|SPCR|BERT|MCHI|EINJ|ERST|HEST|NFIT|PMTT|RASF|SPMI|TPM2|UEFI|XSDT)
                    ok "inner AML signature=$aml_sig length=${aml_len}B"
                    ;;
                *)
                    fail "inner AML signature is '$aml_sig' (4 ASCII bytes), not a recognised ACPI table signature"
                    echo "  Stale or corrupt CPIO — re-run:  bash build/build-npu-ssdt.sh" >&2
                    ;;
            esac
        fi
    fi
fi

# --- 5. iasl available ----------------------------------------------------
# Not strictly required for an existing-assets rebuild, but a future build
# host that loses the CPIO without losing the .asl will need iasl to
# regenerate. WARN, don't fail — the gate only FAILS here if --regen was
# requested and iasl is missing.
if ! command -v iasl >/dev/null 2>&1; then
    if [ "$REGEN" = "1" ]; then
        die "--regen requested but iasl not installed (apt install acpica-tools)"
    else
        warn "iasl not installed (apt install acpica-tools) — blob regeneration will fail if the CPIO is deleted"
    fi
else
    ok "iasl present ($(command -v iasl))"
fi

# --- Summary ---------------------------------------------------------------
if [ "$FAILED" = "1" ]; then
    echo "npu-ssdt-gate: FAIL — see remediations above" >&2
    exit 1
fi
echo "npu-ssdt-gate: PASS"
