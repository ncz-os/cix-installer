#!/bin/bash
# test-amd64-t2-detect.sh -- prove the target-machine Apple T2 detection the
# amd64 rEFInd refresh script uses (the rescue accelerator blacklist keeps
# amdgpu on a T2 Mac only) and the t2-dkms hook shares. The amd64 image ships
# ONE unified x86 kernel for T2 Macs and ordinary PCs, so the decision is made
# on the target and must fail closed everywhere else.
#
# It also guards the 2026-10-06 removal of pcie_ports=compat (a T2 power-cut
# mitigation, replaced by the plain kernel revert of eddba19b8b5f): no boot
# entry may carry it again.
#
# This exercises the SHIPPED code, not a copy: assets/refind/ncz-t2-detect.sh
# is sourced directly with NCZ_DMI_ROOT pointed at fake /sys/class/dmi/id
# trees, and the real T2-cmdline block of
# assets/refind/ncz-refind-refresh-amd64.sh is extracted between its BEGIN/END
# markers and run against those same fake trees.
#
# Contract:
#   * the known T2 models are detected; a pre-T2 Intel Mac, a non-Apple
#     desktop, a QEMU/KVM VM, an Apple machine with an unlisted product and a
#     tree with missing DMI files all fail closed;
#   * the shipped detection block sources the helper, fails closed when the
#     helper is absent, and sets mce=nobootlog on a T2 Mac only (the option
#     assembly and the Default-vs-Console/Rescue split are covered by
#     build/test-t2-mce-nobootlog.sh);
#   * no amd64 boot path carries pcie_ports=compat.
#
# Exit 0 = all checks pass; 1 = one or more failed; 2 = extraction failure.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
HELPER="$REPO/assets/refind/ncz-t2-detect.sh"
SRC="$REPO/assets/refind/ncz-refind-refresh-amd64.sh"
[ -f "$HELPER" ] || { echo "EXTRACT FAILED: $HELPER not found"; exit 2; }
[ -f "$SRC" ] || { echo "EXTRACT FAILED: $SRC not found"; exit 2; }

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS+1)); }
nok() { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else nok "$1: got '$2' want '$3'"; fi; }

TOKEN="pcie_ports=compat"   # removed 2026-10-06; must never come back

# The T2-cmdline block carries BEGIN/END markers, so extraction is byte-exact.
awk -v b='NCZ-T2-CMDLINE-BEGIN' -v e='NCZ-T2-CMDLINE-END' \
    '$0 ~ b {f=1; next} $0 ~ e {f=0} f' "$SRC" > "$W/cmdline.sh"
[ -s "$W/cmdline.sh" ] || { echo "EXTRACT FAILED: T2-cmdline block empty (markers missing?)"; exit 2; }
grep -q 'ncz_is_t2_hardware' "$W/cmdline.sh" || { echo "EXTRACT FAILED: block does not call the detector"; exit 2; }

mkdmi() { # mkdmi <name> <vendor> <product>
    mkdir -p "$W/dmi/$1"
    printf '%s\n' "$2" > "$W/dmi/$1/sys_vendor"
    printf '%s\n' "$3" > "$W/dmi/$1/product_name"
}
detect() { # detect <dmi-root> -> yes|no
    ( NCZ_DMI_ROOT="$1"
      # shellcheck source=/dev/null
      . "$HELPER"
      if ncz_is_t2_hardware; then printf 'yes'; else printf 'no'; fi )
}

echo "=== DMI detection: known T2 models ==="
mkdmi mbp16   "Apple Inc." "MacBookPro16,1"
mkdmi mbp15   "Apple Inc." "MacBookPro15,4"
mkdmi mba8    "Apple Inc." "MacBookAir8,2"
mkdmi mba9    "Apple Inc." "MacBookAir9,1"
mkdmi imac19  "Apple Inc." "iMac19,1"
mkdmi imac20  "Apple Inc." "iMac20,2"
mkdmi imacpro "Apple Inc." "iMacPro1,1"
mkdmi mini    "Apple Inc." "Macmini8,1"
mkdmi macpro  "Apple Inc." "MacPro7,1"
eq "MacBookPro16,1"      "$(detect "$W/dmi/mbp16")"   "yes"
eq "MacBookPro15,4"      "$(detect "$W/dmi/mbp15")"   "yes"
eq "MacBookAir8,2"       "$(detect "$W/dmi/mba8")"    "yes"
eq "MacBookAir9,1"       "$(detect "$W/dmi/mba9")"    "yes"
eq "iMac19,1"            "$(detect "$W/dmi/imac19")"  "yes"
eq "iMac20,2"            "$(detect "$W/dmi/imac20")"  "yes"
eq "iMacPro1,1"          "$(detect "$W/dmi/imacpro")" "yes"
eq "Macmini8,1"          "$(detect "$W/dmi/mini")"    "yes"
eq "MacPro7,1"           "$(detect "$W/dmi/macpro")"  "yes"

echo "=== DMI detection: everything else fails closed ==="
mkdmi mbp11  "Apple Inc." "MacBookPro11,1"                 # pre-T2 Intel Mac
mkdmi asus   "ASUSTeK COMPUTER INC." "PRIME Z390-A"        # generic desktop
mkdmi qemu   "QEMU" "Standard PC (Q35 + ICH9, 2009)"       # VM
mkdmi unlist "Apple Inc." "MacBookPro14,3"                 # Apple, not T2
mkdir -p "$W/dmi/missing"                                  # no DMI files at all
mkdir -p "$W/dmi/emptyprod"                                # vendor but empty product
printf '%s\n' "Apple Inc." > "$W/dmi/emptyprod/sys_vendor"
: > "$W/dmi/emptyprod/product_name"
eq "MacBookPro11,1 (pre-T2)" "$(detect "$W/dmi/mbp11")"     "no"
eq "ASUS desktop"            "$(detect "$W/dmi/asus")"      "no"
eq "QEMU/KVM VM"             "$(detect "$W/dmi/qemu")"      "no"
eq "Apple unlisted model"    "$(detect "$W/dmi/unlist")"    "no"
eq "missing DMI files"       "$(detect "$W/dmi/missing")"   "no"
eq "empty product_name"      "$(detect "$W/dmi/emptyprod")" "no"

echo "=== advisory PCI bridge probe accepts either sysfs form ==="
# Advisory only (never a gate), but proven: Linux sysfs reports "0x106b", so
# the probe strips an optional 0x prefix.
mkpci() { local r="$W/pci/$1/0000:00:00.0"; mkdir -p "$r"; printf '%s\n' "$2" > "$r/vendor"; printf '%s\n' "$3" > "$r/device"; }
pci() { ( NCZ_PCI_DEVICES_ROOT="$1"
          # shellcheck source=/dev/null
          . "$HELPER"
          if ncz_t2_pci_bridge_present; then printf 'yes'; else printf 'no'; fi ); }
mkpci bridge "0x106b" "0x1801"
mkpci nhi    "0x106b" "0x2005"
mkpci bare   "106b"   "1801"
mkpci other  "0x8086" "0x1234"
mkdir -p "$W/pci/empty"
eq "T2 bridge (0x form)"    "$(pci "$W/pci/bridge")" "yes"
eq "T2 NHI (0x form)"       "$(pci "$W/pci/nhi")"    "yes"
eq "T2 bridge (bare form)"  "$(pci "$W/pci/bare")"   "yes"
eq "other vendor -> no"     "$(pci "$W/pci/other")"  "no"
eq "empty tree -> no"       "$(pci "$W/pci/empty")"  "no"

echo "=== shipped detection block: helper sourced, T2-gated mce cmdline ==="
block_is_t2() { # block_is_t2 <dmi-root> <installer-meta> -> yes|no
    ( NCZ_DMI_ROOT="$1"; INSTALLER_META="$2"
      # shellcheck disable=SC1090
      . "$W/cmdline.sh" >/dev/null
      if ncz_is_t2_hardware; then printf 'yes'; else printf 'no'; fi )
}
block_mce() { # block_mce <dmi-root> <installer-meta> -> NCZ_T2_MCE_CMDLINE
    ( NCZ_DMI_ROOT="$1"; INSTALLER_META="$2"
      # shellcheck disable=SC1090
      . "$W/cmdline.sh" >/dev/null
      printf '%s' "${NCZ_T2_MCE_CMDLINE:-}" )
}
eq "T2 Mac is detected through the shipped block" "$(block_is_t2 "$W/dmi/mbp16" "$REPO")" "yes"
eq "generic PC is not"                            "$(block_is_t2 "$W/dmi/asus" "$REPO")"  "no"
eq "absent helper fails closed"                   "$(block_is_t2 "$W/dmi/mbp16" "$W/no-such-meta")" "no"
# The block now supplies the Default-entry boot-MCE suppression on T2 only.
# (Its assembly into STABLE_OPTIONS, and the deliberate omission from the
# Console/Rescue entries, are asserted by build/test-t2-mce-nobootlog.sh.)
eq "T2 Mac gets mce=nobootlog"      "$(block_mce "$W/dmi/mbp16" "$REPO")" "mce=nobootlog"
eq "generic PC gets nothing"        "$(block_mce "$W/dmi/asus" "$REPO")"  ""
eq "absent helper gets nothing"     "$(block_mce "$W/dmi/mbp16" "$W/no-such-meta")" ""

echo "=== pcie_ports=compat stays removed (2026-10-06) ==="
for f in "$SRC" "$REPO/assets/refind/ncz-refind-refresh.sh" "$REPO/build/iso/build-refind-esp.py" \
         "$REPO/preseed/late.sh" "$REPO/preseed/preseed.cfg"; do
    [ -f "$f" ] || continue
    eq "no live $TOKEN in ${f#"$REPO"/}" \
       "$(grep -nE "^[^#]*$TOKEN" "$f" | wc -l | tr -d ' ')" "0"
done

echo
echo "=== amd64 T2 detect test: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ] || exit 1
