#!/usr/bin/env bash
# build-npu-ssdt.sh — compile the NPU ACPI SSDT override and pack the early-CPIO.
#
# WHY THIS EXISTS
# ---------------
# Minisforum's MS-R1 factory BIOS omits the _HID="CIXH4010" on the Sky1 NPU
# compute cores (\_SB_.NPU0.CRE0/CRE1/CRE2), so Linux never enumerates them and
# the NPU is invisible. The fix is an ACPI SSDT override injected through the
# kernel's early-initramfs mechanism: a CPIO archive containing
# kernel/firmware/acpi/<table>.aml, prepended to the real initrd.
# post-install/80-npu.sh does the prepend, board-gated by should_apply_npu_ssdt()
# (O6/O6N expose the _HID natively and are correctly skipped).
#
# assets/npu/ is a gitignored blob dir and NOTHING had ever produced the CPIO,
# so 80-npu.sh warned "SSDT CPIO missing ... NPU cores may not enumerate on
# MS-R1" on every build. The compiled .aml existed only as a binary left over on
# an installed board. The ASL source is now committed next to this script, so
# the blob is reproducible from source instead of being an unexplained binary.
#
# Requires: iasl (Debian/Ubuntu: acpica-tools), cpio.
#
# Usage:  build/build-npu-ssdt.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO/assets/npu/ssdt-npucre.asl"
OUT="$REPO/assets/npu/npu-acpi-override.cpio"
TABLE=ssdt-npucre.aml

# GNU-coreutils dependent: `sort -z`, `stat -c` and `sha256sum` are not BSD/
# macOS spellings, and macOS has no cpio-with-newc by default. Every NCZ
# build host is Linux, so require the GNU tools explicitly rather than
# silently producing a differently-packed archive on a dev laptop.
for t in iasl cpio sort stat sha256sum find; do
    command -v "$t" >/dev/null 2>&1 \
        || { echo "ERROR: missing tool: $t (Debian: apt install acpica-tools cpio coreutils findutils)" >&2; exit 1; }
done
printf '' | sort -z >/dev/null 2>&1 \
    || { echo "ERROR: this script needs GNU sort (sort -z). Run it on a Linux build host." >&2; exit 1; }
stat -c%s "$0" >/dev/null 2>&1 \
    || { echo "ERROR: this script needs GNU stat (stat -c). Run it on a Linux build host." >&2; exit 1; }
[ -f "$SRC" ] || { echo "ERROR: ASL source not found: $SRC" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "[ssdt] compiling $(basename "$SRC")"
cp "$SRC" "$WORK/"
( cd "$WORK" && iasl -p "${TABLE%.aml}" "$(basename "$SRC")" ) | sed 's/^/    /'
[ -s "$WORK/$TABLE" ] || { echo "ERROR: iasl produced no $TABLE" >&2; exit 1; }

# The kernel's early-CPIO ACPI-override loader looks for exactly this path.
mkdir -p "$WORK/root/kernel/firmware/acpi"
cp "$WORK/$TABLE" "$WORK/root/kernel/firmware/acpi/$TABLE"

echo "[ssdt] packing early-CPIO (newc, uid/gid 0)"
( cd "$WORK/root" && find kernel -print0 | LC_ALL=C sort -z \
    | cpio --null -o -H newc --owner=0:0 --quiet ) > "$WORK/out.cpio"

# The kernel only inspects tables in this archive before the real initramfs is
# unpacked; it must NOT be compressed.
mkdir -p "$(dirname "$OUT")"
mv "$WORK/out.cpio" "$OUT"
chmod 0644 "$OUT"

echo ""
echo "[ssdt] wrote $OUT ($(stat -c%s "$OUT") bytes)"
echo "[ssdt] contents:"
cpio -itv < "$OUT" 2>/dev/null | sed 's/^/    /'
echo "[ssdt] table sha256: $(sha256sum "$WORK/$TABLE" | cut -d' ' -f1)"
echo ""
echo "post-install/80-npu.sh prepends this to /boot/initrd.img-\$KVER on boards"
echo "whose firmware does not already expose the CIXH4010 _HID."
