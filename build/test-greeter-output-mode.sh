#!/bin/bash
# test-greeter-output-mode.sh -- the greeter's labwc autostart (written by
# post-install/55-greeter.sh) must cap every output at 1920x1080 (never 4K), try a
# fallback spelling, and never fail. Runs the REAL heredoc against a fake wlr-randr.
# With assets/display/ncz-display-scale it must keep the cap but pick the panel's
# own aspect ratio (1920x1200 on a 16:10 panel), and fall back to the fixed loop
# whenever the helper is absent or cannot read the outputs.
# GREETER_HOOK may point at another copy of 55-greeter.sh (used to prove the test
# fails against the old autostart).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${GREETER_HOOK:-$ROOT/post-install/55-greeter.sh}"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

# extract the autostart heredoc exactly as installed
awk '/<<.LABAUTO.$/ {on=1; next} /^LABAUTO$/ {on=0} on' "$HOOK" > "$T/autostart"
if [ -s "$T/autostart" ]; then ok "autostart heredoc extracted from $(basename "$HOOK")"; else bad "no LABAUTO heredoc"; exit 1; fi
if bash -n "$T/autostart"; then ok "autostart is valid shell"; else bad "autostart syntax"; fi

mkdir -p "$T/bin"
cat > "$T/bin/wlr-randr" <<'FAKE'
#!/bin/sh
if [ "${1:-}" = --json ]; then
  [ -n "${JSON:-}" ] && [ -f "$JSON" ] || exit 1
  cat "$JSON"; exit 0
fi
if [ $# -eq 0 ]; then
  printf 'DP-2 "ViewSonic"\n  Modes:\n    3840x2160 px, 59.99 Hz (preferred, current)\n    1920x1080 px, 60.00 Hz\nHDMI-A-1 "TV"\n  Modes:\n    1920x1080 px, 60.00 Hz\n'
  exit 0
fi
echo "$*" >> "$CALLS"
case "$BEHAVIOUR" in
  ok) exit 0 ;;
  first-fails) case "$4" in *@60Hz) exit 1 ;; *) exit 0 ;; esac ;;
  all-fail) exit 1 ;;
esac
exit 0
FAKE
chmod +x "$T/bin/wlr-randr"

run() { : > "$T/calls"; CALLS="$T/calls" BEHAVIOUR="$1" NCZ_DISPLAY_SCALE="$T/absent" PATH="$T/bin:/usr/bin:/bin" sh "$T/autostart" >/dev/null 2>&1; echo $?; }

rc=$(run ok)
if [ "$rc" = 0 ]; then ok "exit 0 when modes apply"; else bad "exit $rc when modes apply"; fi
if grep -q -- "--output DP-2 --mode 1920x1080@60Hz" "$T/calls" && grep -q -- "--output HDMI-A-1 --mode 1920x1080@60Hz" "$T/calls"; then
    ok "1920x1080@60Hz requested on every connected output"
else
    bad "missing per-output 1080p request"
fi
if grep -q -E "3840|4096|2160" "$T/calls"; then bad "a 4K mode was requested"; else ok "no 4K mode ever requested"; fi

rc=$(run first-fails)
if [ "$rc" = 0 ] && grep -q -- "--output DP-2 --mode 1920x1080$" "$T/calls"; then
    ok "falls back to the plain 1920x1080 spelling"
else
    bad "no fallback spelling (rc=$rc)"
fi

rc=$(run all-fail)
if [ "$rc" = 0 ]; then ok "exit 0 even if every mode change fails (greeter must not be blocked)"; else bad "exit $rc when all changes fail"; fi

rc=$(PATH="/usr/bin:/bin" sh "$T/autostart" >/dev/null 2>&1; echo $?)
if [ "$rc" = 0 ]; then ok "exit 0 when wlr-randr is absent"; else bad "exit $rc without wlr-randr"; fi

# --- HiDPI helper path (docs/HIDPI-SCALING.md) ---------------------------------
HELPER="$ROOT/assets/display/ncz-display-scale"
cat > "$T/chimera.json" <<'J'
[{"name": "eDP-1", "make": "Apple Computer Inc", "model": "Color LCD", "serial": null,
  "physical_size": {"width": 340, "height": 220}, "enabled": true, "scale": 1.0,
  "modes": [{"width": 3072, "height": 1920, "refresh": 60.0, "preferred": true, "current": true},
            {"width": 1920, "height": 1200, "refresh": 60.0, "preferred": false, "current": false},
            {"width": 1920, "height": 1080, "refresh": 60.0, "preferred": false, "current": false}]}]
J
cat > "$T/fourk.json" <<'J'
[{"name": "DP-2", "make": "ViewSonic", "model": "VX2776", "serial": "X",
  "physical_size": {"width": 597, "height": 336}, "enabled": true, "scale": 1.0,
  "modes": [{"width": 3840, "height": 2160, "refresh": 59.997, "preferred": true, "current": true},
            {"width": 1920, "height": 1080, "refresh": 60.0, "preferred": false, "current": false}]}]
J
runh() { : > "$T/calls"; JSON="$2" CALLS="$T/calls" BEHAVIOUR="$1" NCZ_DISPLAY_SCALE="$HELPER" PATH="$T/bin:/usr/bin:/bin" sh "$T/autostart" >/dev/null 2>&1; echo $?; }

rc=$(runh ok "$T/chimera.json")
if [ "$rc" = 0 ] && grep -qx -- "--output eDP-1 --mode 1920x1200@60.000000Hz --scale 1" "$T/calls"; then
    ok "16:10 panel: helper picks same-aspect 1920x1200, not a letterboxed 1080p"
else
    bad "16:10 panel helper request wrong (rc=$rc): $(tr '\n' ';' < "$T/calls")"
fi
if grep -q -- "1920x1080" "$T/calls"; then bad "legacy 1080p loop also ran after the helper succeeded"; else ok "legacy loop skipped when the helper succeeds"; fi

rc=$(runh ok "$T/fourk.json")
if [ "$rc" = 0 ] && grep -q -- "--output DP-2 --mode 1920x1080@60.000000Hz --scale 1" "$T/calls" && ! grep -q -E "3840|2160" "$T/calls"; then
    ok "4K monitor: helper still never requests a 4K mode"
else
    bad "4K monitor helper request wrong (rc=$rc): $(tr '\n' ';' < "$T/calls")"
fi

rc=$(runh ok "$T/missing.json")
if [ "$rc" = 0 ] && grep -q -- "--output DP-2 --mode 1920x1080@60Hz" "$T/calls"; then
    ok "helper cannot read outputs -> legacy 1080p loop runs"
else
    bad "no legacy fallback when the helper fails (rc=$rc)"
fi

rc=$(: > "$T/calls"; CALLS="$T/calls" BEHAVIOUR=ok NCZ_DISPLAY_SCALE="$T/absent" PATH="$T/bin:/usr/bin:/bin" sh "$T/autostart" >/dev/null 2>&1; echo $?)
if [ "$rc" = 0 ] && grep -q -- "--output DP-2 --mode 1920x1080@60Hz" "$T/calls"; then
    ok "helper not installed -> legacy 1080p loop runs"
else
    bad "no legacy fallback without the helper (rc=$rc)"
fi

echo "greeter-output-mode tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
