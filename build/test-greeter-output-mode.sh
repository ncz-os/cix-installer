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

run() { : > "$T/calls"; CALLS="$T/calls" BEHAVIOUR="$1" NCZ_DISPLAY_SCALE_HELPER="$T/absent" PATH="$T/bin:/usr/bin:/bin" sh "$T/autostart" >/dev/null 2>&1; echo $?; }

rc=$(run ok)
if [ "$rc" = 0 ]; then ok "exit 0 when modes apply"; else bad "exit $rc when modes apply"; fi
if grep -q -- "--output DP-2 --mode 1920x1080@60Hz --on" "$T/calls" && grep -q -- "--output HDMI-A-1 --mode 1920x1080@60Hz --on" "$T/calls"; then
    ok "1920x1080@60Hz + --on requested on every connected output"
else
    bad "missing per-output 1080p/--on request"
fi
if grep -q -E "3840|4096|2160" "$T/calls"; then bad "a 4K mode was requested"; else ok "no 4K mode ever requested"; fi

rc=$(run first-fails)
if [ "$rc" = 0 ] && grep -q -- "--output DP-2 --mode 1920x1080 --on" "$T/calls"; then
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
cat > "$T/mbp16.json" <<'J'
[{"name": "eDP-1", "make": "Apple Computer Inc", "model": "Color LCD", "serial": null,
  "physical_size": {"width": 340, "height": 220}, "enabled": true, "scale": 1.0,
  "modes": [{"width": 3072, "height": 1920, "refresh": 60.0, "preferred": true, "current": false},
            {"width": 1920, "height": 1200, "refresh": 60.0, "preferred": false, "current": false},
            {"width": 1920, "height": 1080, "refresh": 60.0, "preferred": false, "current": false}]}]
J
cat > "$T/fourk.json" <<'J'
[{"name": "DP-2", "make": "ViewSonic", "model": "VX2776", "serial": "X",
  "physical_size": {"width": 597, "height": 336}, "enabled": true, "scale": 1.0,
  "modes": [{"width": 3840, "height": 2160, "refresh": 59.997, "preferred": true, "current": true},
            {"width": 1920, "height": 1080, "refresh": 60.0, "preferred": false, "current": false}]}]
J
runh() { : > "$T/calls"; JSON="$2" CALLS="$T/calls" BEHAVIOUR="$1" NCZ_DISPLAY_SCALE_HELPER="$HELPER" PATH="$T/bin:/usr/bin:/bin" sh "$T/autostart" >/dev/null 2>&1; echo $?; }

rc=$(runh ok "$T/mbp16.json")
# cap is 3072x1920 (was 1920x1200), so the MacBookPro16,1
# panel's preferred 3072x1920 now fits and the scale is the policy density
# (227 ppi -> 2.0x). The 16:10 fix is still in force -- the panel's preferred
# mode IS now used directly, instead of being letterboxed by a smaller mode.
if [ "$rc" = 0 ] && grep -qx -- "--output eDP-1 --mode 3072x1920@60.000000Hz --scale 2 --on" "$T/calls"; then
    ok "16:10 panel: helper uses panel's preferred mode (cap 3072x1920), not letterboxed"
else
    bad "16:10 panel helper request wrong (rc=$rc): $(tr '\n' ';' < "$T/calls")"
fi
if grep -q -- "1920x1080" "$T/calls"; then bad "legacy 1080p loop also ran after the helper succeeded"; else ok "legacy loop skipped when the helper succeeds"; fi

# An output the compositor already lit at a capped mode must be left untouched:
# a redundant mode set is the disable->enable cycle that wedges the trilin AUX
# engine (fix/greeter-dp-handoff-20261011).
cat > "$T/already_capped.json" <<'J'
[{"name": "DP-2", "make": "ViewSonic", "model": "VX2776", "serial": "X",
  "physical_size": {"width": 597, "height": 336}, "enabled": true, "scale": 1.0,
  "modes": [{"width": 3840, "height": 2160, "refresh": 59.997, "preferred": true, "current": false},
            {"width": 1920, "height": 1080, "refresh": 60.0, "preferred": false, "current": true}]}]
J
rc=$(runh ok "$T/already_capped.json")
if [ "$rc" = 0 ] && [ ! -s "$T/calls" ]; then
    ok "already-lit capped output: no mode change (no disable->enable trigger)"
else
    bad "already-lit capped output was re-moded (rc=$rc): $(tr '\n' ';' < "$T/calls")"
fi

# A disabled output (greeter labwc runs autoEnableOutputs=no) must be enabled in
# one commit at the capped mode, not left dark.
cat > "$T/disabled.json" <<'J'
[{"name": "DP-2", "make": "ViewSonic", "model": "VX2776", "serial": "X",
  "physical_size": {"width": 597, "height": 336}, "enabled": false, "scale": 1.0,
  "modes": [{"width": 3840, "height": 2160, "refresh": 59.997, "preferred": true, "current": false},
            {"width": 1920, "height": 1080, "refresh": 60.0, "preferred": false, "current": false}]}]
J
rc=$(runh ok "$T/disabled.json")
if [ "$rc" = 0 ] && grep -qx -- "--output DP-2 --mode 1920x1080@60.000000Hz --scale 1 --on" "$T/calls"; then
    ok "disabled output is enabled once at the capped mode (--on)"
else
    bad "disabled output not enabled at capped mode (rc=$rc): $(tr '\n' ';' < "$T/calls")"
fi

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

rc=$(: > "$T/calls"; CALLS="$T/calls" BEHAVIOUR=ok NCZ_DISPLAY_SCALE_HELPER="$T/absent" PATH="$T/bin:/usr/bin:/bin" sh "$T/autostart" >/dev/null 2>&1; echo $?)
if [ "$rc" = 0 ] && grep -q -- "--output DP-2 --mode 1920x1080@60Hz" "$T/calls"; then
    ok "helper not installed -> legacy 1080p loop runs"
else
    bad "no legacy fallback without the helper (rc=$rc)"
fi

# A single-mode 3840x2160 panel (GU502LV eDP AU Optronics 0x31EB) has no capped
# mode. Under autoEnableOutputs=no it is left off by the compositor, so the
# helper must enable it at its own native mode with --on (never "leave it
# alone", never a 4K --mode). Regression 2026-10-11.
cat > "$T/single_mode_4k.json" <<'J'
[{"name": "eDP-1", "make": "AU Optronics", "model": "0x31EB", "serial": null,
  "physical_size": {"width": 344, "height": 194}, "enabled": false, "scale": 1.0,
  "modes": [{"width": 3840, "height": 2160, "refresh": 59.997, "preferred": true, "current": true}]}]
J
rc=$(runh ok "$T/single_mode_4k.json")
if [ "$rc" = 0 ] && grep -qx -- "--output eDP-1 --scale 2 --on" "$T/calls" && ! grep -q -E "3840|4096|2160" "$T/calls"; then
    ok "single-mode 4K panel: helper enables at native + density scale (--scale 2 --on)"
else
    bad "single-mode 4K panel helper wrong (rc=$rc): $(tr '\n' ';' < "$T/calls")"
fi

# Same panel already lit (amd64 keeps the labwc default): --on with no --mode
# is still issued, so a panel can never be left dark; no 4K mode is requested.
cat > "$T/single_mode_4k_lit.json" <<'J'
[{"name": "eDP-1", "make": "AU Optronics", "model": "0x31EB", "serial": null,
  "physical_size": {"width": 344, "height": 194}, "enabled": true, "scale": 1.0,
  "modes": [{"width": 3840, "height": 2160, "refresh": 59.997, "preferred": true, "current": true}]}]
J
rc=$(runh ok "$T/single_mode_4k_lit.json")
if [ "$rc" = 0 ] && grep -qx -- "--output eDP-1 --scale 2 --on" "$T/calls" && ! grep -q -E "3840|4096|2160" "$T/calls"; then
    ok "single-mode 4K panel already lit: re-asserted with --on + scale 2, no 4K mode"
else
    bad "already-lit single-mode 4K panel wrong (rc=$rc): $(tr '\n' ';' < "$T/calls")"
fi

# --- rc.xml <autoEnableOutputs> policy is arch-gated ---------------------------
# The Sky1 DP AUX wedge is a trilin/arm64 problem; on amd64 the key makes labwc
# try to disable the console-inherited CRTC, which fails on i915 and leaves the
# greeter black (GU502LV RC2 325c9510). assets/display/ncz-greeter-rcxml owns it.
RCXML="$ROOT/assets/display/ncz-greeter-rcxml"
if [ -f "$RCXML" ]; then ok "ncz-greeter-rcxml asset present"; else bad "ncz-greeter-rcxml asset missing"; fi
if sh -n "$RCXML"; then ok "ncz-greeter-rcxml is valid shell"; else bad "ncz-greeter-rcxml syntax"; fi

amd=$(sh "$RCXML" --arch amd64 --dry-run 2>/dev/null)
if printf '%s\n' "$amd" | grep -q '<labwc_config>' && \
   ! printf '%s\n' "$amd" | grep -q '<autoEnableOutputs>'; then
    ok "amd64 rc.xml keeps the labwc default (no autoEnableOutputs element)"
else
    bad "amd64 rc.xml still disables output auto-enable: $amd"
fi

for a in arm64 aarch64; do
    sky=$(sh "$RCXML" --arch "$a" --dry-run 2>/dev/null)
    if printf '%s\n' "$sky" | grep -q '<autoEnableOutputs>no</autoEnableOutputs>'; then
        ok "$a rc.xml keeps the Sky1 autoEnableOutputs=no workaround"
    else
        bad "$a rc.xml lost the Sky1 workaround: $sky"
    fi
done

TMPRC="$T/rc-amd64.xml"
if sh "$RCXML" --arch amd64 --out "$TMPRC" >/dev/null 2>&1 && [ -s "$TMPRC" ] && \
   ! grep -q '<autoEnableOutputs>' "$TMPRC"; then
    ok "ncz-greeter-rcxml writes the amd64 rc.xml to --out"
else
    bad "ncz-greeter-rcxml --out did not write the expected amd64 file"
fi

if grep -q 'ncz-greeter-rcxml' "$HOOK"; then
    ok "55-greeter.sh delegates the rc.xml policy to ncz-greeter-rcxml"
else
    bad "55-greeter.sh does not call ncz-greeter-rcxml"
fi
# No ACTIVE line may write the element; a comment naming it is fine.
if grep -vE '^[[:space:]]*#' "$HOOK" | grep -q '<autoEnableOutputs>'; then
    bad "55-greeter.sh still hard-codes the autoEnableOutputs element (would ship on amd64)"
else
    ok "55-greeter.sh does not hard-code the autoEnableOutputs element"
fi

# --- ncz-has-drm-output lit-gate is arm64-only --------------------------------
# Requiring a CONNECTED *and enabled* output exists for the Sky1 trilin race.
# On amd64 the compositor lights the output itself, so that requirement only
# risks a needless (bounded) greetd delay -- the amd64 half of the same
# 2026-10-11 regression. Run the REAL generated gate against a faked DRM tree
# and stubbed uname/sleep/logger.
DRMRAW="$T/drmtest.raw"
awk '/<<.DRMTEST.$/ {on=1; next} /^DRMTEST$/ {on=0} on' "$HOOK" > "$DRMRAW"
if [ -s "$DRMRAW" ] && sh -n "$DRMRAW"; then
    ok "ncz-has-drm-output heredoc extracted and is valid shell"
else
    bad "no valid DRMTEST heredoc"
fi
sed "s#/sys/class/drm#$T/sys/class/drm#g" "$DRMRAW" > "$T/drmtest"

mkdir -p "$T/drmbin"
cat > "$T/drmbin/uname" <<'U'
#!/bin/sh
echo "${FAKE_UNAME_M:-x86_64}"
U
cat > "$T/drmbin/sleep" <<'S'
#!/bin/sh
echo x >> "$SLEEP_LOG"
S
cat > "$T/drmbin/logger" <<'L'
#!/bin/sh
echo "$*" >> "$LOGGER_LOG"
L
chmod +x "$T/drmbin/uname" "$T/drmbin/sleep" "$T/drmbin/logger"

# run_gate ARCH STATUS ENABLED -> "rc sleeps logs" (ENABLED=none omits the file)
run_gate() {
    _arch=$1; _status=$2; _en=$3
    rm -rf "$T/sys"; mkdir -p "$T/sys/class/drm/card1-eDP-1"
    printf '%s\n' "$_status" > "$T/sys/class/drm/card1-eDP-1/status"
    [ "$_en" = none ] || printf '%s\n' "$_en" > "$T/sys/class/drm/card1-eDP-1/enabled"
    : > "$T/sleeps"; : > "$T/logs"
    FAKE_UNAME_M="$_arch" SLEEP_LOG="$T/sleeps" LOGGER_LOG="$T/logs" \
        PATH="$T/drmbin:/usr/bin:/bin" sh "$T/drmtest" >/dev/null 2>&1
    printf '%s %s %s\n' "$?" "$(grep -c . "$T/sleeps")" "$(grep -c . "$T/logs")"
}
# shellcheck disable=SC2046
set -- $(run_gate x86_64 connected disabled)
if [ "$1" = 0 ] && [ "$2" = 0 ]; then
    ok "amd64 gate: a connected output passes at once (no LIT wait)"
else
    bad "amd64 gate still waits for a lit CRTC (rc/sleeps/logs=$1/$2/$3)"
fi
# shellcheck disable=SC2046
set -- $(run_gate aarch64 connected enabled)
if [ "$1" = 0 ] && [ "$2" = 0 ]; then
    ok "arm64 gate: a lit output passes at once"
else
    bad "arm64 lit path wrong (rc/sleeps/logs=$1/$2/$3)"
fi
# shellcheck disable=SC2046
set -- $(run_gate aarch64 connected disabled)
if [ "$1" = 0 ] && [ "$2" -ge 32 ] && [ "$3" -ge 1 ]; then
    ok "arm64 gate: connected-but-unlit fails open after the bounded grace"
else
    bad "arm64 fail-open grace wrong (rc/sleeps/logs=$1/$2/$3)"
fi
# shellcheck disable=SC2046
set -- $(run_gate x86_64 disconnected none)
if [ "$1" = 1 ]; then
    ok "gate: no connected output exits 1 (greetd skipped on a headless boot)"
else
    bad "headless gate did not exit 1 (rc/sleeps/logs=$1/$2/$3)"
fi

echo "greeter-output-mode tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
