#!/bin/bash
# test-installer-ui-wrapper.sh -- exercise the REAL build/kvm-installer-ui-check.sh against the REAL
# build/check-installer-screens.py, with a narrowly stubbed capture harness (build/boot-screens.py) that
# writes real fb-states/ and serial-screens/ fixtures. No VM, no deps, no network.
#
# The stub replaces ONLY the capture step (boot-screens.py). Every checker invocation goes to the real
# python3 + the real production checker. A private python shim skips only the pyte import preflight and
# generates the capture fixtures for boot-screens.
#
# Both architectures are judged through the SAME serial text contract (2026-10-17: amd64 boots the ui-check copy
# with d-i on console=ttyS0,115200 and is judged exactly like arm64). The amd64 cases therefore fail on the text
# (missing disk title in the prompt sequence, swapped Choices/Choices-C, lost component defaults) and keep the
# framebuffer continuity/diversity checks.
#
# UI_WRAPPER_UNDER_TEST=<path> runs the same tests against a baseline copy of the wrapper (e.g. 01cc) to
# prove the strict-nonzero and false-claim negatives actually fail on the old logic. We do not fabricate
# old logic here; the caller supplies the baseline path.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
WRAPPER="${UI_WRAPPER_UNDER_TEST:-$HERE/kvm-installer-ui-check.sh}"
[ -x "$WRAPPER" ] || { echo "test-installer-ui-wrapper: wrapper not executable: $WRAPPER" >&2; exit 2; }

TMPROOT="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "$TMPROOT/ncz-ui-test.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

# --- private python shim: skip pyte preflight, generate capture fixtures -------------------------
SHIM="$WORK/pyshim"
mkdir -p "$SHIM"
cat > "$SHIM/pyte.py" <<'PY'
# Minimal pyte stand-in: the wrapper only does `import pyte` as a preflight.
PY

# Stub boot-screens.py: writes fb-states/, fb-frames.txt, refind.conf, rules.readback, serial-screens/, answers.log.
STUB="$WORK/boot-screens.py"
cat > "$STUB" <<'PY'
#!/usr/bin/env python3
import os, sys, argparse
ap = argparse.ArgumentParser()
ap.add_argument("image"); ap.add_argument("work")
ap.add_argument("--arch", default="amd64")
ap.add_argument("--interactive", action="store_true")
ap.add_argument("--secs", type=int, default=200)
ap.add_argument("--every", type=int, default=30)
ap.add_argument("--serial-console", action="store_true")
ap.add_argument("--ask-disk", action="store_true")
ap.add_argument("--enter-every", type=int, default=0)
ap.add_argument("--enter-after", type=int, default=0)
ap.add_argument("--answer", action="append", default=[])
a = ap.parse_args()
work = a.work
os.makedirs(work, exist_ok=True)
# record the flags + answer rules the wrapper passed, for the assertions below
with open(os.path.join(work, "answers-argv.txt"), "w") as fh:
    fh.write("".join(x + "\n" for x in a.answer))
with open(os.path.join(work, "flags-argv.txt"), "w") as fh:
    fh.write("arch=%s\ninteractive=%d\nserial-console=%d\nask-disk=%d\n" % (
        a.arch, 1 if a.interactive else 0, 1 if a.serial_console else 0, 1 if a.ask_disk else 0))
mode = os.environ.get("NCZ_TEST_FIXTURE", "text_valid")

def w(path, text):
    with open(path, "w") as fh: fh.write(text)

# the test copy's boot artifacts the wrapper reads back on amd64
hook_ok = mode != "amd_no_hook"
w(os.path.join(work, "rules.readback"),
  "# ncz_ui_check=1   (test copy)\n" if hook_ok else "# unrelated preseed hook\n")
w(os.path.join(work, "refind.conf"),
  'menuentry "NCZ-OS Installer -- Install" {\n  options "quiet console=tty0 console=ttyS0,115200"\n}\n'
  if mode != "amd_no_console" else
  'menuentry "NCZ-OS Installer -- Install" {\n  options "quiet console=tty0"\n}\n')

# the framebuffer is sampled on BOTH architectures now (continuity + distinct frames)
fb = os.path.join(work, "fb-states"); os.makedirs(fb, exist_ok=True)
for i in range(24):
    t = i * 3
    body = "framebuffer frame %d\n" % (i % 10) if mode != "amd_late_blank" or t not in range(30, 63) else ""
    if mode == "amd_late_blank":
        if t == 30:
            body = ""
        elif 33 <= t <= 60:
            continue
    w(os.path.join(fb, "%04d-%ds.txt" % (i, t)), "# t=%ds\n%s" % (t, body))
with open(os.path.join(work, "fb-frames.txt"), "w") as fh:
    for i in range(24):
        fh.write("%04d %d\n" % (i, i % 10))

ss = os.path.join(work, "serial-screens"); os.makedirs(ss, exist_ok=True)
hdr = "NCZ-OS 26.10 Cygnus | %s | build abc1234" % ("amd64 (T2/x86_64)" if a.arch == "amd64" else "arm64 (Sky1)")
def frame(title, body):
    # Real newt title bar: l qqq u TITLE t qqq k, then body rows, then bottom border.
    return ("lqqqqqqqqqqqqqqqqqqqqqu %s tqqqqqqqqqqqqqqqk\n"
            "x NCZ-OS install - %s x\n"
            "mqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqj\n"
            "%s\n" % (title, title, body))
steps = [
    ("select your REGION", "region"),
    ("choose a USERNAME", "username"),
    ("choose a PASSWORD", "password"),
    ("type the same PASSWORD", "confirm"),
    ("HARDWARE SUMMARY", "hwsummary"),
    ("optional components", "components"),
    ("select the TARGET DISK", "disk"),
    ("root (/) filesystem", "fs"),
]
if mode in ("text_missing_disk", "amd_missing_disk"):
    steps = [st for st in steps if st[0] != "select the TARGET DISK"]
if mode == "arm_no_hwsummary":
    steps = [st for st in steps if st[0] != "HARDWARE SUMMARY"]
erase = [
    ("ERASE /dev/vda and install", "  Target disk:       /dev/vda\n"
     "  Root filesystem:   btrfs\n"
     "  Rescue partition:  %s\n"
     "  Components:        %s" % (
         "no" if mode in ("text_lost_rescue", "amd_lost_rescue") else "yes",
         "no optional components" if mode in ("text_swapped_choices", "amd_swapped_choices")
         else "Full Singularity desktop + management container + rescue partition")),
]
if mode in ("text_swapped_choices", "amd_swapped_choices"):
    # 2026-10-17 CHIMERA: Choices/Choices-C swapped -> the chooser answers its own labels and d-i refuses the value
    erase.append(("not in the candidate set", "ncz/components: 'Full Singularity desktop' is not in the candidate set"))
rows = steps + erase
for i in range(24):
    t = i * 3
    if i < len(rows):
        title, _ = rows[i]
        body = frame(title, hdr + "\n" + rows[i][1])
    else:
        body = frame("Installing the base system", hdr + "\nprogress")
    if mode == "arm_missing_header" and i == 0:
        body = frame("select your REGION", "no brand here")
    if mode in ("arm_wrong_order", "text_wrong_order", "amd_wrong_order") and i == 0:
        body = frame("choose a USERNAME", hdr + "\nchoose a USERNAME")
    if mode in ("arm_wrong_order", "text_wrong_order", "amd_wrong_order") and i == 1:
        body = frame("select your REGION", hdr + "\nselect your REGION")
    w(os.path.join(ss, "%04d-%ds.txt" % (i, t)), "# t=%ds\n%s" % (t, body))
w(os.path.join(ss, "0099-297s.txt"), "# t=297s\ndiagnostics login: root / set by ncz_diag_pw\n")
with open(os.path.join(work, "answers.log"), "w") as fh:
    fh.write("t=25s rule 0 optional components=\\r\n")
PY
chmod +x "$STUB"

# --- harness: run the real wrapper with the stub capture and shimmed python ----------------------
run_case() {
    local name="$1" arch="$2" fixture="$3" expect_rc="$4" expect_out="$5"
    local w="$WORK/$name"
    mkdir -p "$w"
    # Point the wrapper's boot-screens.py at our stub by shadowing HERE via a copy of the wrapper dir.
    local wdir="$w/wrap"; mkdir -p "$wdir"
    cp "$WRAPPER" "$wdir/kvm-installer-ui-check.sh"
    chmod +x "$wdir/kvm-installer-ui-check.sh"
    cp "$STUB" "$wdir/boot-screens.py"
    cp "$HERE/check-installer-screens.py" "$wdir/check-installer-screens.py"
    mkdir -p "$wdir/lib"
    [ -f "$HERE/lib/priv.sh" ] && cp "$HERE/lib/priv.sh" "$wdir/lib/priv.sh"
    local out rc
    out="$(NCZ_TEST_FIXTURE="$fixture" NCZ_PYTE_PYTHON="$SHIM/pyte.py" PYTHONPATH="$SHIM" \
           bash "$wdir/kvm-installer-ui-check.sh" /dev/null "$arch" "$w/work" 2>&1)"
    rc=$?
    if [ "$expect_rc" = "0" ] && [ $rc -ne 0 ]; then
        echo "FAIL $name: expected rc=0, got $rc"; echo "$out"; return 1
    fi
    if [ "$expect_rc" != "0" ] && [ $rc -eq 0 ]; then
        echo "FAIL $name: expected rc!=0, got 0"; echo "$out"; return 1
    fi
    if [ -n "$expect_out" ] && ! grep -q "$expect_out" <<<"$out"; then
        echo "FAIL $name: expected output to contain '$expect_out'"; echo "$out"; return 1
    fi
    echo "ok $name"
}

fail=0

# --- amd64: the UART text channel is now the judge, exactly like arm64 -------------------------
# valid capture -> full PASS on amd64 (no more PASS-LIMITED)
run_case amd_valid amd64 text_valid 0 "UI CHECK PASS (amd64)" || fail=1
# the boot copy, flags and rules the wrapper must pass for the channel to exist
F="$WORK/amd_valid/work/flags-argv.txt"
grep -qx 'arch=amd64' "$F" 2>/dev/null && grep -qx 'serial-console=1' "$F" 2>/dev/null \
    && grep -qx 'ask-disk=1' "$F" 2>/dev/null && echo "ok amd_boots_test_copy_on_serial" \
    || { echo "FAIL amd_boots_test_copy_on_serial: boot-screens.py was not called with --serial-console --ask-disk on amd64"; cat "$F" 2>/dev/null; fail=1; }
# the 2026-10-17 class the framebuffer could never see: a dialog silently dropped from the operator's sequence
run_case amd_missing_disk amd64 amd_missing_disk 1 "never matched" || fail=1
# ... and the disk chooser rejecting its own answer (Choices/Choices-C swapped)
run_case amd_swapped_choices amd64 amd_swapped_choices 1 "Choices/Choices-C swapped" || fail=1
# the component defaults are lost at the erase review
run_case amd_lost_rescue amd64 amd_lost_rescue 1 "default rescue partition was lost" || fail=1
# wrong prompt order is caught on amd64 too
run_case amd_wrong_order amd64 amd_wrong_order 1 "never matched" || fail=1
# the framebuffer checks still run and still fail a late blank
run_case amd_late_blank amd64 amd_late_blank 1 "blank console after" || fail=1
# honest failure when the test channel did not reach the booted copy (never judge a UART we did not boot)
run_case amd_no_hook amd64 amd_no_hook 1 "no ncz_ui_check=1 preseed hook" || fail=1
run_case amd_no_console amd64 amd_no_console 1 "no console=ttyS0,115200" || fail=1

# --- arm64: unchanged contract ---------------------------------------------------------------
run_case arm_valid arm64 text_valid 0 "UI CHECK PASS (arm64)" || fail=1
run_case arm_missing_header arm64 arm_missing_header 1 "header" || fail=1
run_case arm_wrong_order arm64 arm_wrong_order 1 "never matched" || fail=1
# the HARDWARE SUMMARY note (preseed/hw-summary.sh) sits between the password confirm and the
# component dialog on an interactive install; a capture without it fails the sequence ...
run_case arm_no_hwsummary arm64 arm_no_hwsummary 1 "never matched" || fail=1
# ... and the wrapper answers it (Continue), otherwise the real capture stalls on it (Rebuild B 5a320504,
# arm64: 7 states, the component dialog never reached).
if grep -qx 'HARDWARE SUMMARY=\\r' "$WORK/arm_valid/work/answers-argv.txt" 2>/dev/null; then
    echo "ok arm_answers_hwsummary"
else
    echo "FAIL arm_answers_hwsummary: no 'HARDWARE SUMMARY=\r' answer rule passed to boot-screens.py"
    cat "$WORK/arm_valid/work/answers-argv.txt" 2>/dev/null; fail=1
fi
# rule 0 must stay the component dialog (T_ANS in the wrapper keys on it)
if [ "$(head -1 "$WORK/arm_valid/work/answers-argv.txt" 2>/dev/null)" = 'optional components=\r' ]; then
    echo "ok arm_rule0_components"
else
    echo "FAIL arm_rule0_components: rule 0 is not the component dialog"; fail=1
fi
# the erase confirmation must select Yes: Enter alone answers No and the install never reaches the disk
# (the wrapper's default is Down,Enter; an operator can override it for a different capture)
if grep -q 'ERASE /dev/vda and install=$' "$WORK/arm_valid/work/answers-argv.txt" 2>/dev/null; then
    echo "FAIL arm_erase_answer: the erase rule sends no keys (Enter would answer No)"
    cat -v "$WORK/arm_valid/work/answers-argv.txt"; fail=1
else
    echo "ok arm_erase_answer"
fi

if [ $fail -ne 0 ]; then
    echo "test-installer-ui-wrapper: FAIL" >&2
    exit 1
fi
echo "test-installer-ui-wrapper: OK"
exit 0
