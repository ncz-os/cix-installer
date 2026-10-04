#!/bin/bash
# test-greeter-output-mode.sh -- the greeter's labwc autostart (written by
# post-install/55-greeter.sh) must cap every output at 1920x1080 (never 4K), try a
# fallback spelling, and never fail. Runs the REAL heredoc against a fake wlr-randr.
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

run() { : > "$T/calls"; CALLS="$T/calls" BEHAVIOUR="$1" PATH="$T/bin:/usr/bin:/bin" sh "$T/autostart" >/dev/null 2>&1; echo $?; }

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

echo "greeter-output-mode tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
