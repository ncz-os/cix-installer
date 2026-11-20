#!/bin/bash
# shellcheck disable=SC1090,SC2034  # non-constant source; the extracted blocks read the vars this driver sets
# test-amd64-pcie-native.sh -- the installed amd64 rEFInd DEFAULT and CONSOLE
# entries carry pcie_ports=native on the ASUS ROG Zephyrus M15 only, and no
# rescue entry ever does.
#
# Why: on the ASUS ROG Zephyrus M15 GU502LV (DMI sys_vendor "ASUSTeK COMPUTER
# INC.", product_name "ROG Zephyrus M15 GU502LV_GU502LV") the ACPI _OSC reply
# says "platform does not support [AER]", so Linux never enables AER there.
# Booting with pcie_ports=native forces OS control of the native PCIe
# features: AER then enables on all 15 AER-capable devices, no error flood,
# and the machine boots normally. The image is shared by every PC and T2 Mac,
# so the option must be decided on the TARGET machine at boot-menu generation
# time -- never baked in at image build time.
#
# This runs the SHIPPED code, not copies:
#   * assets/refind/ncz-t2-detect.sh -> ncz_dmi_quirk_matches (NCZ_DMI_ROOT);
#   * NCZ-PCIE-NATIVE-CMDLINE  -> sets NCZ_PCIE_NATIVE_CMDLINE per fake DMI;
#   * NCZ-DEFAULT-OPTIONS      -> assembles STABLE_/STABLE_CONSOLE_/RESCUE_/
#     RESCUEPART_OPTIONS from that variable;
#   * NCZ-ADDONLY-HELPERS      -> the --add path's token carry, driven against
#     the shipped helper so a later kernel install cannot lose the token.
#
# Run: bash build/test-amd64-pcie-native.sh
# Exit 0 = pass, 1 = fail, 2 = extract failure.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${NCZ_TEST_ROOT:-$(cd "$HERE/.." && pwd)}"
SRC="$ROOT/assets/refind/ncz-refind-refresh-amd64.sh"
HELPER="$ROOT/assets/refind/ncz-t2-detect.sh"
ESP_PY="$ROOT/build/iso/build-refind-esp.py"
W="$(mktemp -d "${TMPDIR:-/var/tmp}/pcie-native.XXXXXX")"; trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }
eq()  { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: got '$2' want '$3'"; fi; }
has() { case " $2 " in *" $1 "*) ok "$3" ;; *) bad "$3" "missing '$1' in: $2" ;; esac; }
hasn(){ case " $2 " in *" $1 "*) bad "$3" "unexpected '$1' in: $2" ;; *) ok "$3" ;; esac; }

TOKEN="pcie_ports=native"

[ -f "$SRC" ]    || { echo "EXTRACT FAILED: $SRC not found"; exit 2; }
[ -r "$HELPER" ] || { echo "EXTRACT FAILED: $HELPER not found"; exit 2; }

awk -v b='NCZ-HELPER-LOAD-BEGIN' -v e='NCZ-HELPER-LOAD-END' \
    '$0 ~ b {f=1; next} $0 ~ e {f=0} f' "$SRC" > "$W/load.sh"
awk -v b='NCZ-PCIE-NATIVE-CMDLINE-BEGIN' -v e='NCZ-PCIE-NATIVE-CMDLINE-END' \
    '$0 ~ b {f=1; next} $0 ~ e {f=0} f' "$SRC" > "$W/quirk.sh"
awk -v b='NCZ-DEFAULT-OPTIONS-BEGIN' -v e='NCZ-DEFAULT-OPTIONS-END' \
    '$0 ~ b {f=1; next} $0 ~ e {f=0} f' "$SRC" > "$W/opts.sh"
awk -v b='NCZ-ADDONLY-HELPERS-BEGIN' -v e='NCZ-ADDONLY-HELPERS-END' \
    '$0 ~ b {f=1; next} $0 ~ e {f=0} f' "$SRC" > "$W/addonhy.sh"
# A missing DEFAULT-OPTIONS block is the only true extraction failure: that
# block predates this feature, so its absence means the markers moved.
[ -s "$W/opts.sh" ] || { echo "EXTRACT FAILED: DEFAULT-OPTIONS block empty"; exit 2; }
# The quirk block, the helper load and the --add helpers are what this change
# adds; when they are absent (a pre-fix script) that is a test FAILURE, not an
# unusable run: the blocks are then empty, so every case needing them fails.
[ -s "$W/quirk.sh" ] && grep -q 'NCZ_PCIE_NATIVE_CMDLINE' "$W/quirk.sh" \
    || bad "the shipped script sets NCZ_PCIE_NATIVE_CMDLINE from DMI" \
           "no NCZ-PCIE-NATIVE-CMDLINE block (pre-fix?)"
grep -q 'NCZ_PCIE_NATIVE_CMDLINE' "$W/opts.sh" \
    || bad "the options block consults the quirk cmdline" \
           "NCZ-DEFAULT-OPTIONS does not read NCZ_PCIE_NATIVE_CMDLINE"
# The load block and the helpers are NOT extraction failures when absent: a
# pre-fix script has neither, and that must be reported as test FAILURES (the
# quarantined blocks are then empty, so every case that needs them fails)
# rather than as an unusable test run. Only the source file itself is fatal.
if ! grep -q 'ncz_add_only_cmdline_tokens' "$W/addonhy.sh" 2>/dev/null; then
    bad "the --add path carries the target-machine cmdline tokens" \
        "no ncz_add_only_cmdline_tokens in the shipped script (pre-fix?)"
fi

mkdmi() { # mkdmi <name> <vendor> <product>
    mkdir -p "$W/dmi/$1"
    printf '%s\n' "$2" > "$W/dmi/$1/sys_vendor"
    printf '%s\n' "$3" > "$W/dmi/$1/product_name"
}

# gen <dmi-root> <installer-meta> -> the candidate cmdline variable values, one
# "NAME=value" per line, produced by running the SHIPPED blocks in order.
gen() {
    ( set +u
      NCZ_DMI_ROOT="$1"; INSTALLER_META="$2"
      # Defaults the DEFAULT-OPTIONS block reads (mirrors the script's own vars).
      STABLE_AVAILABLE=1
      ROOT_OPTS="root=PARTUUID=1234-ABCD rootwait rootfstype=ext4 rw"
      STABLE_CMDLINE_BASE="console=tty0 systemd.condition_first_boot=false audit_backlog_limit=8192"
      SPLASH="quiet loglevel=3 vt.global_cursor_default=0 systemd.show_status=false rd.systemd.show_status=false"
      NCZ_SERIAL_CONSOLE_ARG=""
      RESCUEPART_PARTUUID="1234-ABCD"
      . "$W/load.sh"  >/dev/null 2>&1
      . "$W/quirk.sh" >/dev/null 2>&1
      . "$W/opts.sh"  >/dev/null 2>&1
      printf 'NCZ_PCIE_NATIVE_CMDLINE=%s\n' "$NCZ_PCIE_NATIVE_CMDLINE"
      printf 'STABLE_OPTIONS=%s\n' "$STABLE_OPTIONS"
      printf 'STABLE_CONSOLE_OPTIONS=%s\n' "$STABLE_CONSOLE_OPTIONS"
      printf 'RESCUE_OPTIONS=%s\n' "$RESCUE_OPTIONS"
      printf 'RESCUEPART_OPTIONS=%s\n' "$RESCUEPART_OPTIONS" )
}
field() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

# The --add path: source the shipped helper and carry the tokens onto a reused
# options string. <ref>-tokens <live-options> <t2-cmdline> <pcie-cmdline>
add_tokens() { # <live-options> <t2-cmdline> <pcie-cmdline>
    ( NCZ_T2_MCE_CMDLINE="${2:-}"; NCZ_PCIE_NATIVE_CMDLINE="${3:-}"
      # shellcheck disable=SC1090
      . "$W/addonhy.sh"
      _t="$(ncz_add_only_cmdline_tokens)"
      ncz_options_with_cmdline_tokens "$1" "$_t" )
}

mkdmi zephyrus "ASUSTeK COMPUTER INC." "ROG Zephyrus M15 GU502LV_GU502LV"
mkdmi zephyrus2 "ASUSTeK COMPUTER INC." "ROG Zephyrus M15 GU502LV"
mkdmi asusother "ASUSTeK COMPUTER INC." "ROG Zephyrus M16 GU604VI_GU604VI"
mkdmi zenbook "ASUSTeK COMPUTER INC." "ZenBook UX425EA_UX425EA"
mkdmi mbp16 "Apple Inc." "MacBookPro16,1"
mkdmi qemu "QEMU" "Standard PC (Q35 + ICH9, 2009)"
mkdmi empty "" ""
mkdir -p "$W/dmi/missing"

echo "=== matching DMI: Default and Console carry $TOKEN, rescue entries never do ==="
Z="$(gen "$W/dmi/zephyrus" "$ROOT")"
eq "Zephyrus NCZ_PCIE_NATIVE_CMDLINE" "$(field "$Z" NCZ_PCIE_NATIVE_CMDLINE)" "$TOKEN"
has "$TOKEN" "$(field "$Z" STABLE_OPTIONS)"         "Zephyrus DEFAULT (STABLE_OPTIONS) carries $TOKEN"
has "$TOKEN" "$(field "$Z" STABLE_CONSOLE_OPTIONS)" "Zephyrus Console entry carries $TOKEN"
hasn "$TOKEN" "$(field "$Z" RESCUE_OPTIONS)"        "Zephyrus Rescue / No Accelerators stays minimal"
hasn "$TOKEN" "$(field "$Z" RESCUEPART_OPTIONS)"    "Zephyrus Rescue Partition stays minimal"
# The product_name suffix is firmware-appended; a shorter name still matches.
has "$TOKEN" "$(field "$(gen "$W/dmi/zephyrus2" "$ROOT")" STABLE_OPTIONS)" \
   "Zephyrus without the _GU502LV suffix still matches (prefix rule)"

echo "=== non-matching hardware: no token anywhere ==="
for d in asusother zenbook mbp16 qemu; do
    G="$(gen "$W/dmi/$d" "$ROOT")"
    eq "$d NCZ_PCIE_NATIVE_CMDLINE empty" "" "$(field "$G" NCZ_PCIE_NATIVE_CMDLINE)"
    hasn "$TOKEN" "$(field "$G" STABLE_OPTIONS)"         "$d DEFAULT has no $TOKEN"
    hasn "$TOKEN" "$(field "$G" STABLE_CONSOLE_OPTIONS)" "$d Console has no $TOKEN"
done
echo "=== missing / empty DMI fails closed ==="
for d in missing empty; do
    G="$(gen "$W/dmi/$d" "$ROOT")"
    eq "$d NCZ_PCIE_NATIVE_CMDLINE empty" "" "$(field "$G" NCZ_PCIE_NATIVE_CMDLINE)"
    hasn "$TOKEN" "$(field "$G" STABLE_OPTIONS)" "$d DEFAULT has no $TOKEN"
done
G="$(gen "$W/dmi/zephyrus" "$W/no-such-meta")"
eq "absent helper -> no quirk cmdline (fail closed)" "" "$(field "$G" NCZ_PCIE_NATIVE_CMDLINE)"
hasn "$TOKEN" "$(field "$G" STABLE_OPTIONS)" "absent helper DEFAULT has no $TOKEN"

echo "=== --add: the appended entry carries the token exactly once ==="
LIVE="root=PARTUUID=1234-ABCD rootwait rw quiet loglevel=3"
out="$(add_tokens "$LIVE" "" "$TOKEN")"
eq "no token yet -> appended once" "$out" "$LIVE $TOKEN"
eq "token already present -> not duplicated" "$(add_tokens "$LIVE $TOKEN" "" "$TOKEN")" "$LIVE $TOKEN"
eq "non-matching hardware -> --add stays verbatim" "$(add_tokens "$LIVE" "" "")" "$LIVE"
eq "T2 + quirk tokens both carried" \
   "$(add_tokens "$LIVE" "mce=nobootlog" "$TOKEN")" "$LIVE mce=nobootlog $TOKEN"
# A look-alike word is not the token (whole-word rule, like the mce= one).
eq "a longer word containing the token does not count as present" \
   "$LIVE pcie_ports=native_on $TOKEN" \
   "$(add_tokens "$LIVE pcie_ports=native_on" "" "$TOKEN")"
# The rescue token set is deliberately not carried: --add appends ONE entry and
# never builds a rescue entry, so the carry must not know about blacklists.
case "$(add_tokens "$LIVE" "mce=nobootlog" "$TOKEN")" in
    *module_blacklist*) bad "--add carry never injects rescue-only tokens" ;;
    *) ok "--add carry never injects rescue-only tokens" ;;
esac

echo "=== source shape: the token only feeds Default, Console and --add ==="
eq "quirk block is the only literal assignment" \
   "$(grep -cE "^[[:space:]]*NCZ_PCIE_NATIVE_CMDLINE=\"$TOKEN\"" "$SRC" | tr -d ' ')" "1"
for v in RESCUE_OPTIONS RESCUEPART_OPTIONS; do
    hasn 'NCZ_PCIE_NATIVE_CMDLINE' "$(grep "^$v=" "$SRC")" "$v built without the quirk cmdline"
done
for v in STABLE_OPTIONS STABLE_CONSOLE_OPTIONS; do
    eq "$v assembly appends the quirk cmdline once" \
       "$(grep -cF "\"\$$v \$NCZ_PCIE_NATIVE_CMDLINE\"" "$SRC" | tr -d ' ')" "1"
done
# The T2 MCE behaviour is untouched: still Default-entry only.
hasn 'NCZ_T2_MCE_CMDLINE' "$(grep '^STABLE_CONSOLE_OPTIONS=' "$SRC")" \
     "Console entry still gets no mce=nobootlog (T2 behaviour unchanged)"
eq "Default menuentry is the only user of STABLE_OPTIONS" \
   "$(grep -cF 'options \"$STABLE_OPTIONS\"' "$SRC" | tr -d ' ')" "1"
# The token is not baked into the image build (target-machine decision only).
hasn "$TOKEN" "$(cat "$ESP_PY")" "installer/live entries carry no $TOKEN"

echo "=== helper: the DMI quirk table and its fail-closed rule ==="
quirq() { ( NCZ_DMI_ROOT="$1"; . "$HELPER" >/dev/null 2>&1; ncz_dmi_quirk_matches pcie_native ) ; }
quirq "$W/dmi/zephyrus" && ok "helper matches the Zephyrus M15 GU502LV" \
    || bad "helper matches the Zephyrus M15 GU502LV"
for d in zenbook qemu empty; do
    quirq "$W/dmi/$d" && bad "helper rejects $d" || ok "helper rejects $d"
done
quirq "$W/dmi/missing" && bad "helper rejects a missing DMI tree" \
    || ok "helper rejects a missing DMI tree"
eq "the quirk table is table-driven (one row per laptop)" \
   "$( NCZ_DMI_ROOT="$W/dmi/zenbook"; . "$HELPER" >/dev/null 2>&1; ncz_dmi_quirk_table | wc -l | tr -d ' ')" "1"
eq "the seeded row is the Zephyrus M15 GU502LV" \
   "$( NCZ_DMI_ROOT="$W/dmi/zenbook"; . "$HELPER" >/dev/null 2>&1; ncz_dmi_quirk_table )" \
   "pcie_native|ASUSTeK COMPUTER INC.|ROG Zephyrus M15 GU502LV"

echo
echo "AMD64 pcie_ports=native tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
