#!/bin/bash
# shellcheck disable=SC1090,SC2034  # non-constant source; the extracted blocks read the vars this driver sets
# test-t2-mce-nobootlog.sh -- the installed amd64 rEFInd DEFAULT entry carries
# mce=nobootlog on an Apple T2 Mac only, and the Console/Rescue entries never do.
#
# Why: the Apple firmware on the Coffee Lake-H
# T2 Macs (MacBookPro16,1, i9-9980HK, cpu 906ed) leaves a stale Machine
# Check record in MCA banks 12/13 that Linux logs at boot via pr_emerg
# ("mce: [Hardware Error]: ..."), which quiet loglevel=3 cannot hide. It is a
# left-over from before the kernel booted, not a runtime fault. mce=nobootlog
# makes the kernel skip the boot-time poll/log while still clearing MCi_STATUS;
# runtime MCs stay logged. It is added to the DEFAULT entry ONLY, so a
# technician can still see the raw record on the Console/Rescue entries.
#
# This runs the SHIPPED blocks, not copies:
#   * NCZ-T2-CMDLINE   -> sets NCZ_T2_MCE_CMDLINE per fake DMI tree;
#   * NCZ-DEFAULT-OPTIONS -> assembles STABLE_/STABLE_CONSOLE_/RESCUE_/
#     RESCUEPART_OPTIONS from that variable.
#
# Run: bash build/test-t2-mce-nobootlog.sh    Exit 0 = pass, 1 = fail, 2 = extract failure.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${NCZ_TEST_ROOT:-$(cd "$HERE/.." && pwd)}"
SRC="$ROOT/assets/refind/ncz-refind-refresh-amd64.sh"
ESP_PY="$ROOT/build/iso/build-refind-esp.py"
[ -f "$SRC" ] || { echo "EXTRACT FAILED: $SRC not found"; exit 2; }
W="$(mktemp -d -t t2-mce.XXXXXX)"; trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }
eq()  { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: got '$2' want '$3'"; fi; }
has() { case "$2" in *"$1"*) ok "$3" ;; *) bad "$3" "missing '$1' in: $2" ;; esac; }
hasn(){ case "$2" in *"$1"*) bad "$3" "unexpected '$1' in: $2" ;; *) ok "$3" ;; esac; }

TOKEN="mce=nobootlog"

awk -v b='NCZ-T2-CMDLINE-BEGIN' -v e='NCZ-T2-CMDLINE-END' \
    '$0 ~ b {f=1; next} $0 ~ e {f=0} f' "$SRC" > "$W/t2block.sh"
awk -v b='NCZ-DEFAULT-OPTIONS-BEGIN' -v e='NCZ-DEFAULT-OPTIONS-END' \
    '$0 ~ b {f=1; next} $0 ~ e {f=0} f' "$SRC" > "$W/opts.sh"
[ -s "$W/t2block.sh" ] || { echo "EXTRACT FAILED: T2-CMDLINE block empty"; exit 2; }
[ -s "$W/opts.sh" ]    || { echo "EXTRACT FAILED: DEFAULT-OPTIONS block empty"; exit 2; }
grep -q 'NCZ_T2_MCE_CMDLINE' "$W/t2block.sh" || { echo "EXTRACT FAILED: T2 block sets no MCE cmdline"; exit 2; }
grep -q 'NCZ_T2_MCE_CMDLINE' "$W/opts.sh"    || { echo "EXTRACT FAILED: options block ignores the MCE cmdline"; exit 2; }

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
      . "$W/t2block.sh" >/dev/null 2>&1
      . "$W/opts.sh"    >/dev/null 2>&1
      printf 'NCZ_T2_MCE_CMDLINE=%s\n' "$NCZ_T2_MCE_CMDLINE"
      printf 'STABLE_OPTIONS=%s\n' "$STABLE_OPTIONS"
      printf 'STABLE_CONSOLE_OPTIONS=%s\n' "$STABLE_CONSOLE_OPTIONS"
      printf 'RESCUE_OPTIONS=%s\n' "$RESCUE_OPTIONS"
      printf 'RESCUEPART_OPTIONS=%s\n' "$RESCUEPART_OPTIONS" )
}
field() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

mkdmi mbp16   "Apple Inc." "MacBookPro16,1"     # T2 test unit
mkdmi mbp15   "Apple Inc." "MacBookPro15,4"
mkdmi mba9    "Apple Inc." "MacBookAir9,1"
mkdmi mini    "Apple Inc." "Macmini8,1"
mkdmi asus    "ASUSTeK COMPUTER INC." "PRIME Z390-A"
mkdmi qemu    "QEMU" "Standard PC (Q35 + ICH9, 2009)"
mkdmi mbp11   "Apple Inc." "MacBookPro11,1"

echo "=== T2 Mac: DEFAULT gets mce=nobootlog, console/rescue do not ==="
T2="$(gen "$W/dmi/mbp16" "$ROOT")"
eq "T2 NCZ_T2_MCE_CMDLINE"      "$(field "$T2" NCZ_T2_MCE_CMDLINE)" "$TOKEN"
has "$TOKEN" "$(field "$T2" STABLE_OPTIONS)"         "T2 DEFAULT (STABLE_OPTIONS) carries $TOKEN"
hasn "$TOKEN" "$(field "$T2" STABLE_CONSOLE_OPTIONS)" "T2 Console entry keeps the record visible"
hasn "$TOKEN" "$(field "$T2" RESCUE_OPTIONS)"         "T2 Rescue entry keeps the record visible"
hasn "$TOKEN" "$(field "$T2" RESCUEPART_OPTIONS)"     "T2 Rescue-Partition entry keeps the record visible"

echo "=== every known T2 model gets it ==="
for d in mbp16 mbp15 mba9 mini; do
    has "$TOKEN" "$(field "$(gen "$W/dmi/$d" "$ROOT")" STABLE_OPTIONS)" "$d DEFAULT carries $TOKEN"
done

echo "=== non-T2 (and absent helper) get nothing anywhere ==="
for d in asus qemu mbp11; do
    G="$(gen "$W/dmi/$d" "$ROOT")"
    eq "$d NCZ_T2_MCE_CMDLINE empty" "" "$(field "$G" NCZ_T2_MCE_CMDLINE)"
    hasn "$TOKEN" "$(field "$G" STABLE_OPTIONS)" "$d DEFAULT has no $TOKEN"
done
G="$(gen "$W/dmi/mbp16" "$W/no-such-meta")"
eq "absent helper -> no MCE cmdline (fail closed)" "" "$(field "$G" NCZ_T2_MCE_CMDLINE)"
hasn "$TOKEN" "$(field "$G" STABLE_OPTIONS)" "absent helper DEFAULT has no $TOKEN"

echo "=== source shape: the token only feeds the Default entry ==="
# 1. Every literal mce=nobootlog assignment in the refresh script is the T2 gate.
eq "T2 block is the only literal assignment" \
   "$(grep -cE "^[[:space:]]*NCZ_T2_MCE_CMDLINE=\"$TOKEN\"" "$SRC" | tr -d ' ')" "1"
# 2. The Console/Rescue option strings are built without the MCE variable.
for v in STABLE_CONSOLE_OPTIONS RESCUE_OPTIONS RESCUEPART_OPTIONS; do
    hasn 'NCZ_T2_MCE_CMDLINE' "$(grep "^$v=" "$SRC")" "$v built without the T2 MCE cmdline"
done
hasn 'NCZ_T2_MCE_CMDLINE' "$(grep '^STABLE_OPTIONS=' "$SRC")" "STABLE_OPTIONS assignment has no literal token"
# 3. Only the Default menuentry emits the STABLE_OPTIONS that carry the token
#    (the source writes the rEFInd option line as: options \"$STABLE_OPTIONS\").
eq "Default menuentry is the only user of STABLE_OPTIONS" \
   "$(grep -cF 'options \"$STABLE_OPTIONS\"' "$SRC" | tr -d ' ')" "1"
for v in STABLE_CONSOLE_OPTIONS RESCUE_OPTIONS RESCUEPART_OPTIONS; do
    eq "menuentry emits $v" "$(grep -cF "options \\\"\$$v\\\"" "$SRC" | tr -d ' ')" "1"
done

echo "=== installer media entries are intentionally unchanged ==="
hasn "$TOKEN" "$(cat "$ESP_PY")" "installer/live entries carry no $TOKEN (kept visible for diagnosis)"

echo
echo "T2 MCE nobootlog tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
