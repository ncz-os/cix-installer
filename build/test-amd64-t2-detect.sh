#!/bin/bash
# test-amd64-t2-detect.sh -- prove the amd64 edge pcie_ports=compat decision
# is gated on Apple T2 hardware at entry-generation time (operator directive
# 2026-10-05). The amd64 image ships ONE unified x86 kernel for T2 Macs and
# ordinary PCs, so the token must only reach the edge entry on a real T2 Mac:
# on a generic machine it would needlessly switch off AER/PME/native hotplug.
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
#     tree with missing DMI files all fail closed (no parameter);
#   * the shipped cmdline block sets pcie_ports=compat only when T2 is
#     detected, and fails closed when the helper itself is absent.
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

TOKEN="pcie_ports=compat"

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

echo "=== shipped cmdline block gates the token on detection ==="
cmdline_for() { # cmdline_for <dmi-root> -> token or ""
    ( NCZ_DMI_ROOT="$1"; INSTALLER_META="$REPO"
      # shellcheck disable=SC1090
      . "$W/cmdline.sh" >/dev/null
      printf '%s' "$NCZ_T2_EDGE_EXTRA_CMDLINE" )
}
eq "T2 Mac sets the token"       "$(cmdline_for "$W/dmi/mbp16")"   "$TOKEN"
eq "generic PC leaves it empty"  "$(cmdline_for "$W/dmi/asus")"    ""
eq "pre-T2 Mac leaves it empty"  "$(cmdline_for "$W/dmi/mbp11")"   ""
eq "QEMU leaves it empty"        "$(cmdline_for "$W/dmi/qemu")"    ""
eq "missing DMI leaves it empty" "$(cmdline_for "$W/dmi/missing")" ""
# Fail closed if the helper is not present in the staged tree at all.
eq "absent helper fails closed" \
   "$( NCZ_DMI_ROOT="$W/dmi/mbp16" INSTALLER_META="$W/no-such-meta"
      # shellcheck disable=SC1090
      . "$W/cmdline.sh" >/dev/null
      printf '%s' "$NCZ_T2_EDGE_EXTRA_CMDLINE" )" ""

echo
echo "=== amd64 T2 detect test: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
