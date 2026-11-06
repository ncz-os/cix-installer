#!/bin/bash
# test-console-font-autosize.sh -- 95-console-font-autosize.sh sizes the VT font
# only on a text-mode console and never fails the boot when there is none.
# With deferred fbcon takeover the VTs stay on the dummy console until output;
# the script then exits 0 and a udev rule re-runs the unit on takeover.
#
# The kernel refuses a font change while the VT is in KD_GRAPHICS mode, which
# the KMS boot splash and the greeter compositor set on tty1. setfont then
# printed "Console is not in text mode", the unit exited 1 and the system booted
# "degraded" on a 3840x2160 Sky1 display. The runtime script must exit 0 with a
# log line for a graphics console or a missing display, still set the font on a
# text console, and still fail for a real setfont error. The unit must run
# before the splash and greetd as an early-boot unit.
#
# Run: bash build/test-console-font-autosize.sh    Exit 0 = pass, 1 = fail.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${NCZ_TEST_ROOT:-$(cd "$HERE/.." && pwd)}"
G="$ROOT/post-install/95-console-font-autosize.sh"
SPLASH="$ROOT/post-install/60-boot-splash.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/font-autosize.XXXXXX")"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

[ -f "$G" ] || { echo "FATAL: $G not found" >&2; exit 2; }

S="$T/ncz-console-font-autosize"
U="$T/unit"
awk '/cat > \/usr\/local\/bin\/ncz-console-font-autosize <<.SCRIPT.$/ {f=1; next} f && /^SCRIPT$/ {exit} f {print}' "$G" > "$S"
awk '/cat > \/etc\/systemd\/system\/ncz-console-font-autosize.service <<.UNIT.$/ {f=1; next} f && /^UNIT$/ {exit} f {print}' "$G" > "$U"
[ -s "$S" ] || { echo "FATAL: runtime script not extracted" >&2; exit 2; }
[ -s "$U" ] || { echo "FATAL: unit not extracted" >&2; exit 2; }
sh -n "$S" && ok "runtime script parses (sh -n)" || bad "runtime script syntax error"

# --- fixture ------------------------------------------------------------------
# $1 = virtual_size ("" = no fb0), $2 = EDID width in cm (0 = no size, "" = no EDID)
# $3 = kbdinfo mode output ("" = kbdinfo fails), $4 = setfont mode: ok|graphics|notfound|dummy
# $5 = bound VT console driver: fb (default) | dummy (deferred fbcon takeover) | none (no vtconsole class)
setup() {
    rm -rf "$T/case"; mkdir -p "$T/case/bin" "$T/case/drm" "$T/case/fonts" "$T/case/vtcon"
    case "${5:-fb}" in
        fb)    mkdir -p "$T/case/vtcon/vtcon0" "$T/case/vtcon/vtcon1"
               echo "(S) dummy device" > "$T/case/vtcon/vtcon0/name"; echo 0 > "$T/case/vtcon/vtcon0/bind"
               echo "(S) frame buffer device" > "$T/case/vtcon/vtcon1/name"; echo 1 > "$T/case/vtcon/vtcon1/bind" ;;
        dummy) mkdir -p "$T/case/vtcon/vtcon0"
               echo "(S) dummy device" > "$T/case/vtcon/vtcon0/name"; echo 1 > "$T/case/vtcon/vtcon0/bind" ;;
        none)  ;;
    esac
    [ -n "$1" ] && printf '%s\n' "$1" > "$T/case/virtual_size"
    if [ -n "$2" ]; then
        mkdir -p "$T/case/drm/card0-DP-1"
        echo connected > "$T/case/drm/card0-DP-1/status"
        { head -c 21 /dev/zero; printf '%b' "\\$(printf %03o "$2")"; head -c 106 /dev/zero; } \
            > "$T/case/drm/card0-DP-1/edid"
    fi
    for f in Lat15-TerminusBold32x16 Lat15-Terminus20x10 Lat15-Terminus16; do
        : > "$T/case/fonts/$f.psf.gz"
    done
    cat > "$T/case/bin/kbdinfo" <<STUB
#!/bin/sh
echo "\$*" >> "$T/case/kbdinfo.calls"
[ -n "$3" ] || { echo "kbdinfo: Couldn't open \$2" >&2; exit 1; }
echo "$3"
STUB
    cat > "$T/case/bin/setfont" <<STUB
#!/bin/sh
echo "\$*" >> "$T/case/setfont.calls"
case "$4" in
    ok) exit 0 ;;
    graphics) echo "setfont: ERROR kdfontop.c:38 is_kd_text_mode: Console is not in text mode" >&2; exit 1 ;;
    notfound) echo "setfont: ERROR psffontop.c:XX: Unable to find file" >&2; exit 66 ;;
    dummy) echo "setfont: ERROR kdfontop.c:242 put_font_kdfontop: Unable to load such font with such kernel version" >&2; exit 1 ;;
esac
STUB
    chmod +x "$T/case/bin/kbdinfo" "$T/case/bin/setfont"
}
run() {
    PATH="$T/case/bin:$PATH" \
    NCZ_FB_VIRTUAL_SIZE="$T/case/virtual_size" NCZ_DRM_SYSFS="$T/case/drm" \
    NCZ_CONSOLEFONTS_DIR="$T/case/fonts" NCZ_VTCONSOLE_SYSFS="$T/case/vtcon" \
        sh "$S" > "$T/case/out" 2>&1
    RC=$?
    OUT=$(cat "$T/case/out")
    CALLS=$(cat "$T/case/setfont.calls" 2>/dev/null || true)
}

# 1. Console in graphics mode (splash / compositor): skip cleanly.
setup 3840,2160 60 graphics ok; run
[ "$RC" = 0 ] && ok "graphics-mode console exits 0" || bad "graphics-mode console rc=$RC: $OUT"
[ -z "$CALLS" ] && ok "graphics-mode console: setfont not run" || bad "graphics-mode console ran setfont: $CALLS"
grep -q 'graphics mode' <<<"$OUT" && ok "graphics-mode console logs why the font was left" \
    || bad "graphics-mode console: no log line ($OUT)"

# 2. kbdinfo says text, then setfont reports the real kernel refusal (race).
setup 3840,2160 60 text graphics; run
[ "$RC" = 0 ] && ok "setfont 'Console is not in text mode' exits 0" || bad "setfont text-mode refusal rc=$RC: $OUT"
grep -q 'graphics mode; console font left unchanged' <<<"$OUT" \
    && ok "setfont text-mode refusal is logged" || bad "setfont text-mode refusal not logged ($OUT)"

# 3. kbdinfo unavailable: setfont's own refusal is still classified.
setup 3840,2160 "" "" graphics; run
[ "$RC" = 0 ] && ok "no kbdinfo answer + text-mode refusal exits 0" || bad "no kbdinfo + refusal rc=$RC: $OUT"

# 4. Text-mode success, EDID path: 3840 px over 60 cm = 162 DPI -> 20x10.
setup 3840,2160 60 text ok; run
[ "$RC" = 0 ] && ok "text-mode console exits 0" || bad "text-mode console rc=$RC: $OUT"
[ "$CALLS" = "-C /dev/tty0 Lat15-Terminus20x10" ] && ok "text-mode console: setfont -C /dev/tty0 Lat15-Terminus20x10" \
    || bad "text-mode console setfont args: '$CALLS'"
grep -q 'font set to Lat15-Terminus20x10' <<<"$OUT" && ok "text-mode success is logged" || bad "no success log ($OUT)"

# 5. Text-mode success, Retina-class panel: 3072 px over 34 cm = 229 DPI -> 32x16.
setup 3072,1920 34 text ok; run
[ "$CALLS" = "-C /dev/tty0 Lat15-TerminusBold32x16" ] && ok "229 DPI panel gets Lat15-TerminusBold32x16" \
    || bad "229 DPI panel setfont args: '$CALLS'"

# 6. No EDID physical size: resolution fallback, 2160 rows -> 32x16.
setup 3840,2160 0 text ok; run
[ "$CALLS" = "-C /dev/tty0 Lat15-TerminusBold32x16" ] && ok "no EDID size: 2160p fallback gets Lat15-TerminusBold32x16" \
    || bad "no EDID size fallback setfont args: '$CALLS'"

# 7. NCZ_CONSOLE_TTY selects the console for both the mode check and setfont.
setup 3840,2160 0 text ok
PATH="$T/case/bin:$PATH" NCZ_CONSOLE_TTY=/dev/tty3 NCZ_FB_VIRTUAL_SIZE="$T/case/virtual_size" \
    NCZ_DRM_SYSFS="$T/case/drm" NCZ_CONSOLEFONTS_DIR="$T/case/fonts" NCZ_VTCONSOLE_SYSFS="$T/case/vtcon" sh "$S" >/dev/null 2>&1
grep -q -- '-C /dev/tty3 getmode' "$T/case/kbdinfo.calls" 2>/dev/null && grep -q -- '-C /dev/tty3 ' "$T/case/setfont.calls" 2>/dev/null \
    && ok "NCZ_CONSOLE_TTY targets that console" || bad "NCZ_CONSOLE_TTY not honoured"

# 8. Missing display: no fb0 -> exit 0 with a log line, setfont not run.
setup "" "" text ok; run
[ "$RC" = 0 ] && ok "missing display exits 0" || bad "missing display rc=$RC: $OUT"
[ -z "$CALLS" ] && ok "missing display: setfont not run" || bad "missing display ran setfont: $CALLS"
grep -q 'no framebuffer console' <<<"$OUT" && ok "missing display is logged" || bad "missing display not logged ($OUT)"

# 9. Low-DPI large display: kernel default kept, exit 0, logged.
setup 1920,1080 100 text ok; run
[ "$RC" = 0 ] && [ -z "$CALLS" ] && grep -q 'kernel default font kept' <<<"$OUT" \
    && ok "low-DPI display keeps the kernel font (logged)" || bad "low-DPI path rc=$RC calls='$CALLS' out=$OUT"

# 10. A real setfont failure still fails the unit.
setup 3840,2160 60 text notfound; run
[ "$RC" = 1 ] && ok "other setfont error still exits 1" || bad "other setfont error rc=$RC"
grep -q 'Unable to find file' <<<"$OUT" && grep -q 'setfont Lat15-Terminus20x10 failed' <<<"$OUT" \
    && ok "other setfont error is reported with setfont's message" || bad "setfont error not reported ($OUT)"

# 11. Missing font file still fails the unit.
setup 3840,2160 60 text ok; rm -f "$T/case/fonts/Lat15-Terminus20x10.psf.gz"; run
[ "$RC" = 1 ] && [ -z "$CALLS" ] && ok "missing console-setup font exits 1" || bad "missing font rc=$RC calls='$CALLS'"

# 12. Deferred fbcon takeover (amd64 kernel, CONFIG_FRAMEBUFFER_CONSOLE_DEFERRED_TAKEOVER=y):
#     only the dummy console is bound, so KDFONTOP cannot work. KVM gate 2026-10-26: setfont
#     "Unable to load such font with such kernel version", unit failed. Exit 0, no setfont.
setup 1280,800 30 text dummy dummy; run
[ "$RC" = 0 ] && ok "dummy console only (deferred takeover) exits 0" || bad "dummy console rc=$RC: $OUT"
[ -z "$CALLS" ] && ok "dummy console: setfont not run" || bad "dummy console ran setfont: $CALLS"
grep -q 'takeover deferred' <<<"$OUT" && ok "dummy console logs the deferred takeover" || bad "dummy console not logged ($OUT)"

# 13. fbcon registered but not yet bound (bind=0), dummy still bound: same as 12.
setup 1280,800 30 text dummy dummy
mkdir -p "$T/case/vtcon/vtcon1"; echo "(S) frame buffer device" > "$T/case/vtcon/vtcon1/name"; echo 0 > "$T/case/vtcon/vtcon1/bind"
run
[ "$RC" = 0 ] && [ -z "$CALLS" ] && ok "registered-but-unbound fbcon is treated as not taken over" \
    || bad "unbound fbcon rc=$RC calls='$CALLS' out=$OUT"

# 14. vgacon bound (text console without fbcon): font is set.
setup 3840,2160 60 text ok none
mkdir -p "$T/case/vtcon/vtcon0"; echo "(S) VGA+" > "$T/case/vtcon/vtcon0/name"; echo 1 > "$T/case/vtcon/vtcon0/bind"
run
[ "$RC" = 0 ] && [ "$CALLS" = "-C /dev/tty0 Lat15-Terminus20x10" ] && ok "vgacon-bound console gets its font" \
    || bad "vgacon rc=$RC calls='$CALLS' out=$OUT"

# 15. No vtconsole class at all: do not guess, run the normal path.
setup 3840,2160 60 text ok none; run
[ "$RC" = 0 ] && [ "$CALLS" = "-C /dev/tty0 Lat15-Terminus20x10" ] && ok "no vtconsole class: normal path" \
    || bad "no vtconsole class rc=$RC calls='$CALLS' out=$OUT"

# 16. fbcon bound but setfont still says "such kernel version": a real failure, stays loud.
setup 3840,2160 60 text dummy; run
[ "$RC" = 1 ] && ok "KDFONTOP refusal with fbcon bound still exits 1" || bad "bound fbcon refusal rc=$RC: $OUT"

# --- udev re-run on takeover --------------------------------------------------
R="$T/rules"
awk '/cat > \/etc\/udev\/rules.d\/90-ncz-console-font-autosize.rules <<.RULES.$/ {f=1; next} f && /^RULES$/ {exit} f {print}' "$G" > "$R"
if [ -s "$R" ]; then
    ok "udev rule extracted"
    grep -E '^ACTION=="add", SUBSYSTEM=="vtconsole", KERNEL=="vtcon\*", ATTR\{name\}!="\*dummy device", RUN\+="/usr/bin/systemctl --no-block restart ncz-console-font-autosize.service"$' "$R" >/dev/null \
        && ok "udev rule restarts the unit when a non-dummy vtconsole is added" || bad "vtconsole udev rule missing or changed: $(cat "$R")"
    grep -E '^ACTION=="add", SUBSYSTEM=="graphics", KERNEL=="fb0", RUN\+="/usr/bin/systemctl --no-block restart ncz-console-font-autosize.service"$' "$R" >/dev/null \
        && ok "udev rule restarts the unit when fb0 is added" || bad "fb0 udev rule missing or changed"
    grep -v '^#' "$R" | grep -q -- 'restart' && ! grep -v '^#' "$R" | grep -q -- 'systemctl restart' \
        && ok "udev restarts are --no-block" || bad "a udev rule restarts without --no-block (would stall udev)"
    if command -v udevadm >/dev/null 2>&1; then
        cp "$R" "$T/90-ncz-console-font-autosize.rules"
        udevadm verify --no-style "$T/90-ncz-console-font-autosize.rules" >/dev/null 2>&1 \
            && ok "udevadm verify accepts the rule" || bad "udevadm verify rejects the rule: $(udevadm verify --no-style "$T/90-ncz-console-font-autosize.rules" 2>&1 | head -3)"
    fi
else
    bad "hook installs no udev rule for the deferred fbcon takeover"
fi

# --- unit ordering -----------------------------------------------------------
key() { sed -n "s/^$1=//p" "$U" | tr ' ' '\n'; }
key DefaultDependencies | grep >/dev/null -x no && ok "unit is an early-boot unit (DefaultDependencies=no)" \
    || bad "unit keeps default dependencies (runs after basic.target, races the splash)"
for b in singularity-boot-splash.service greetd.service getty@tty1.service shutdown.target; do
    key Before | grep >/dev/null -x "$b" && ok "unit Before=$b" || bad "unit not ordered Before=$b"
done
for a in systemd-vconsole-setup.service systemd-udev-trigger.service local-fs.target; do
    key After | grep >/dev/null -x "$a" && ok "unit After=$a" || bad "unit not ordered After=$a"
done
key Conflicts | grep >/dev/null -x shutdown.target && ok "unit Conflicts=shutdown.target" || bad "unit lacks Conflicts=shutdown.target"
if grep -qE '^(Requires|RequiredBy|BindsTo|Requisite)=' "$U"; then
    bad "unit has a hard dependency that could block greetd"
else
    ok "no hard dependency: a failure cannot block greetd"
fi
grep -qE '^TimeoutStartSec=[0-9]+s?$' "$U" && ok "unit start time is bounded" || bad "unit has no start timeout"
key WantedBy | grep >/dev/null -x sysinit.target && ok "unit WantedBy=sysinit.target" || bad "unit install target changed"
if [ -f "$SPLASH" ] && grep -qE '^(After|Before)=.*ncz-console-font-autosize' "$SPLASH"; then
    bad "boot splash unit orders itself against the font unit (cycle risk)"
else
    ok "boot splash unit has no reverse ordering against the font unit"
fi

echo "console-font-autosize tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
