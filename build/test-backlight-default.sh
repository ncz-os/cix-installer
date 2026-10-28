#!/bin/sh
# test-backlight-default.sh -- post-install/43-hw-quirks.sh: the first-boot
# laptop backlight default (ncz-backlight-default). On a laptop the FIRST boot
# raises brightness to >= 40 % of max, once; a user-set value from a later
# boot is never clobbered (the marker in /var/lib makes it first-run only).
# Non-laptop platforms (desktop chassis / VM) are skipped.
#
# The real script runs in a sandbox: fake /sys/class/backlight, fake
# /sys/class/dmi/id/chassis_type, fake logger.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../post-install/43-hw-quirks.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/test-backlight.XXXXXX")"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS: $1"; PASS=$((PASS + 1)); }
no() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
block() {
    awk -v t="$1" '$0 ~ "<<\x27" t "\x27$" {f=1; next} $0 == t {f=0} f' "$HOOK"
}
block BLDEF > "$T/bldef"
block BLUNIT > "$T/unit"
[ -s "$T/bldef" ] && ok "43-hw-quirks.sh writes the backlight script" || no "43-hw-quirks.sh has no BLDEF block"
[ -s "$T/unit" ] && ok "43-hw-quirks.sh writes the backlight unit" || no "43-hw-quirks.sh has no BLUNIT block"

# --- the unit: oneshot, before greetd, wanted by graphical.target -----------
grep -qx 'Type=oneshot' "$T/unit" && ok "unit: Type=oneshot" || no "unit is not a oneshot"
grep -qx 'WantedBy=graphical.target' "$T/unit" && ok "unit: WantedBy=graphical.target" || no "unit not wanted by graphical.target"
grep -qx 'Before=greetd.service' "$T/unit" && ok "unit: Before=greetd.service (first frame at readable brightness)" || no "unit does not order before greetd"
grep -qx 'ExecStart=/usr/local/sbin/ncz-backlight-default' "$T/unit" && ok "unit runs the backlight script" || no "unit does not run the script"

# --- sandbox ----------------------------------------------------------------
SYS="$T/sys"; SB="$T/bin"; MARK="/var/lib/ncz/backlight-default-applied"
mkdir -p "$SYS/class/backlight" "$SYS/class/dmi/id" "$SYS/devices/virtual/dmi/id" "$SB"
# The marker lands in $T/varlib-ncz (the sed-rewritten /var/lib/ncz). Create
# it up front: has_marker() must be able to see a marker even if the script's
# own install -d is unavailable, and each sub-test's rm -rf only removes the
# marker file's parent's contents, never the dir itself.
mkdir -p "$T/varlib-ncz"
# panel backlight: max 4882 (the DELL .70 panel), low initial 342 (7 %)
mkdir -p "$SYS/class/backlight/intel_backlight"
echo 4882 > "$SYS/class/backlight/intel_backlight/max_brightness"
echo 342  > "$SYS/class/backlight/intel_backlight/brightness"
chmod 644 "$SYS/class/backlight/intel_backlight/brightness" "$SYS/class/backlight/intel_backlight/max_brightness"
# a small dummy (USB/ACPI) that must NOT be picked (max < 16)
mkdir -p "$SYS/class/backlight/usb-dummy"
echo 4 > "$SYS/class/backlight/usb-dummy/max_brightness"
echo 2 > "$SYS/class/backlight/usb-dummy/brightness"
cat > "$SB/logger" <<'LOGGERSTUB'
#!/bin/sh
[ -n "${FLOG:-}" ] && echo "$*" >> "${FLOG}"
exit 0
LOGGERSTUB
chmod +x "$SB/"*

set_laptop() { echo "$1" > "$SYS/class/dmi/id/chassis_type"; }   # 9=laptop, 3=desktop
run_bl() {  # run_bl -> exit code; journal in $T/journal
    PATH="$SB:/bin:/usr/bin" \
    FLOG="$T/journal" \
    /bin/sh <(sed -e "s#/sys/class/backlight#$SYS/class/backlight#g" \
                 -e "s#/sys/class/dmi#$SYS/class/dmi#g" \
                 -e "s#/sys/class/power_supply#$SYS/class/power_supply#g" \
                 -e "s#/sys/devices/virtual/dmi#$SYS/devices/virtual/dmi#g" \
                 -e "s#/var/lib/ncz#$T/varlib-ncz#g" \
                 "$T/bldef")
}
reset_panel() {  # reset the panel to a known low brightness
    echo 342 > "$SYS/class/backlight/intel_backlight/brightness"
}
has_marker() { [ -e "$T/varlib-ncz/backlight-default-applied" ]; }

# (1) laptop + first boot (no marker) + low brightness -> raised to >= 40 %
set_laptop 9; rm -f "$T/varlib-ncz/backlight-default-applied"; reset_panel
run_bl; rc=$?
[ "$rc" = 0 ] && ok "(1) laptop first boot: script exits 0" || no "(1) rc=$rc"
new=$(cat "$SYS/class/backlight/intel_backlight/brightness")
max=$(cat "$SYS/class/backlight/intel_backlight/max_brightness")
[ "$new" -ge $((max * 40 / 100)) ] && ok "(1) brightness raised to $new >= 40% of $max" || no "(1) brightness $new < 40% of $max"
has_marker && ok "(1) marker created (first-run done)" || no "(1) no marker after first run"
grep -q 'first boot' "$T/journal" && ok "(1) diagnostic logged" || no "(1) no diagnostic"

# (2) laptop + marker present + user set a low value -> NOT clobbered
set_laptop 9; echo 100 > "$SYS/class/backlight/intel_backlight/brightness"
run_bl; rc=$?
[ "$rc" = 0 ] && ok "(2) marker present: script exits 0" || no "(2) rc=$rc"
[ "$(cat "$SYS/class/backlight/intel_backlight/brightness")" = 100 ] \
    && ok "(2) user value 100 preserved (not clobbered)" \
    || no "(2) user value clobbered to $(cat "$SYS/class/backlight/intel_backlight/brightness")"

# (3) desktop chassis (3) -> skipped, no marker
set_laptop 3; rm -f "$T/varlib-ncz/backlight-default-applied"; reset_panel
run_bl; rc=$?
[ "$rc" = 0 ] && ok "(3) desktop: script exits 0" || no "(3) rc=$rc"
[ "$(cat "$SYS/class/backlight/intel_backlight/brightness")" = 342 ] \
    && ok "(3) desktop: brightness untouched (342)" \
    || no "(3) desktop: brightness changed"
! has_marker && ok "(3) desktop: no marker created (will re-check)" || no "(3) desktop: marker wrongly created"

# (4) no DMI chassis_type (VM) -> skipped
rm -f "$SYS/class/dmi/id/chassis_type"; rm -f "$T/varlib-ncz/backlight-default-applied"; reset_panel
run_bl; rc=$?
[ "$rc" = 0 ] && ok "(4) no DMI: script exits 0" || no "(4) rc=$rc"
[ "$(cat "$SYS/class/backlight/intel_backlight/brightness")" = 342 ] \
    && ok "(4) no DMI: brightness untouched" \
    || no "(4) no DMI: brightness changed"
! has_marker && ok "(4) no DMI: no marker" || no "(4) no DMI: marker wrongly created"

# (8) chassis 8 (Portable) IS a laptop - the DELL Inspiron 5521 case that
# booted at 7 % because 8 was missing from the accepted list.
set_laptop 8; rm -f "$T/varlib-ncz/backlight-default-applied"; reset_panel
run_bl; rc=$?
[ "$rc" = 0 ] && ok "(8) chassis 8: runs" || no "(8) rc=$rc"
got=$(cat "$SYS/class/backlight/intel_backlight/brightness")
[ "$got" = "1952" ] && ok "(8) chassis 8 (Portable) raised to 40 % ($got)" \
    || no "(8) chassis 8: brightness $got, want 1952"
has_marker && ok "(8) chassis 8: marker written" || no "(8) chassis 8: no marker"

# (9) a desktop chassis code with a battery and a panel is still portable
set_laptop 3; mkdir -p "$SYS/class/power_supply/BAT0"
rm -f "$T/varlib-ncz/backlight-default-applied"; reset_panel
run_bl; rc=$?
got=$(cat "$SYS/class/backlight/intel_backlight/brightness")
[ "$got" = "1952" ] && ok "(9) desktop chassis + battery: raised anyway ($got)" \
    || no "(9) chassis 3 with battery: $got, want 1952"
rm -rf "$SYS/class/power_supply/BAT0"

# (5) the dummy (max<16) is not the device chosen; only the panel is written
set_laptop 9; rm -f "$T/varlib-ncz/backlight-default-applied"; reset_panel
run_bl
[ "$(cat "$SYS/class/backlight/usb-dummy/brightness")" = 2 ] \
    && ok "(5) the USB/ACPI dummy (max<16) is not touched" \
    || no "(5) the dummy was written"

echo "test-backlight-default: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
