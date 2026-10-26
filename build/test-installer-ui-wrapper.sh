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
# the UART console is appended only by --serial-console (amd_fb_uart: a framebuffer boot that wrongly carries it)
uart = (a.serial_console and mode != "amd_no_console") or (not a.serial_console and mode == "amd_fb_uart")
# The shipped Rescue entry carries console=ttyS0 by design (2026-10-26: the framebuffer-boot UART check first
# read the whole file and refused every real image); it must not count against the Install entry.
rescue = 'menuentry "NCZ-OS Installer -- Rescue mode" {\n  options "rescue/enable=true console=ttyS0,115200n8 console=tty0"\n}\n'
w(os.path.join(work, "refind.conf"),
  ('menuentry "NCZ-OS Installer -- Install" {\n  options "quiet console=tty0 console=ttyS0,115200"\n}\n'
   if uart else
   'menuentry "NCZ-OS Installer -- Install" {\n  options "quiet console=tty0"\n}\n') + rescue)

# the framebuffer is sampled on BOTH architectures now (continuity + distinct frames)
fb = os.path.join(work, "fb-states"); os.makedirs(fb, exist_ok=True)
# 2026-10-26 amd64: with the UART as /dev/console the monitor of the SERIAL boot stays static (no fb-states,
# 2 distinct frames); only the separate framebuffer boot shows d-i.
static = mode == "amd_serial_fb_static" and a.serial_console
for i in range(0 if static else 24):
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
        fh.write("%04d %d\n" % (i, (i % 2) if static else (i % 10)))

ss = os.path.join(work, "serial-screens"); os.makedirs(ss, exist_ok=True)
server = os.environ.get("NCZ_UI_CHECK_VARIANT", "desktop") == "server"
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
if server:
    # Magnetar Server medium (preseed/ncz-ui.sh ncz_ui_title): "Magnetar Server - Step n of 7: <action>" titles, the
    # full edition on the id line, no component dialog, and a review that states the download before the erase.
    # srv_cygnus: the pre-fix brand; srv_components_shown: the 2026-10-26 cyclops selector; srv_desktop_review: the
    # review promises a desktop; srv_no_download: the review omits the network requirement.
    full = "NCZ-OS 26.10 Cygnus" if mode == "srv_cygnus" else "NCZ-OS 26.10 Magnetar Server"
    hdr = "%s | %s | build abc1234" % (full, "amd64 (T2/x86_64)" if a.arch == "amd64" else "arm64 (Sky1)")
    short = "NCZ-OS 26.10 Cygnus" if mode == "srv_cygnus" else "Magnetar Server"
    acts = ["Choose your country", "Choose a user name", "Choose a password", "Type the password again"]
    rows = [("%s - Step %d of 7: %s" % (short, i + 1, t), "") for i, t in enumerate(acts)]
    rows.append(("%s - What we found" % short, ""))
    if mode == "srv_components_shown":
        rows.append(("%s - optional components" % short, "[*] Full Singularity desktop"))
    rows += [("%s - Step 5 of 7: Choose the disk to ERASE" % short, ""),
             ("%s - Step 6 of 7: Choose the file system" % short, "")]
    review = ("  Target disk:       /dev/vda\n  Root filesystem:   btrfs\n  Rescue partition:  yes\n")
    if mode == "srv_desktop_review":
        review += "  Components:        Full Singularity desktop\n"
    if mode != "srv_no_download":
        review += "This install downloads about 3 GB after the disk is erased.\n"
    rows.append(("%s - Step 7 of 7: Erase disk and install?" % short, review))
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
# 2026-10-26 arm64: the erase confirmation answered No (Down does not move off the last button), the chooser
# aborted, and preseed/command_failed crashed cdebconf on a ${...} in partman/early_command.
if mode == "arm_erase_declined":
    w(os.path.join(ss, "0098-296s.txt"), "# t=296s\nOct 26 02:03:41 log-output: [ncz chooser] ABORT: "
      "the operator did not confirm erasing /dev/vda - wiping NOTHING, stopping install.\n")
serial = "boot\n"
if mode == "arm_debconf_assert":
    serial += "debconf: ./src/question.c:276: lookup_directive: Assertion `'!' == directive[0]' failed.\n"
w(os.path.join(work, "serial0.log"), serial)
with open(os.path.join(work, "answers.log"), "w") as fh:
    fh.write("t=25s rule 0 %s=\\r\n" % ("Choose your country" if server else "optional components"))
PY
chmod +x "$STUB"

# --- harness: run the real wrapper with the stub capture and shimmed python ----------------------
run_case() {
    local name="$1" arch="$2" fixture="$3" expect_rc="$4" expect_out="$5" variant="${6:-desktop}"
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
    out="$(NCZ_TEST_FIXTURE="$fixture" NCZ_PYTE_PYTHON="$SHIM/pyte.py" PYTHONPATH="$SHIM" NCZ_UI_CHECK_VARIANT="$variant" \
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

# the monitor is judged on its own boot: the serial boot's static framebuffer must not fail a good install ...
run_case amd_serial_fb_static amd64 amd_serial_fb_static 0 "UI CHECK PASS (amd64)" || fail=1
F2="$WORK/amd_valid/work/fb/flags-argv.txt"
grep -qx 'serial-console=0' "$F2" 2>/dev/null && grep -qx 'ask-disk=0' "$F2" 2>/dev/null \
    && echo "ok amd_fb_boot_without_uart" \
    || { echo "FAIL amd_fb_boot_without_uart: no second boot without --serial-console for the framebuffer checks"; cat "$F2" 2>/dev/null; fail=1; }
# ... and a framebuffer boot that carries the UART console is refused (the monitor would not show d-i)
run_case amd_fb_uart amd64 amd_fb_uart 1 "framebuffer boot's Install entry carries a UART console" || fail=1

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
# the erase confirmation must select Yes: Enter alone answers No and the install never reaches the disk.
# cdebconf's newt boolean is [Go Back] [text] [Yes] [No] with focus on No and newt does not wrap focus, so
# only Left (or Up) reaches Yes; Down did nothing and answered No (2026-10-26, Preview4 arm64).
if grep -qxF 'ERASE /dev/vda and install=\x1b[D\r' "$WORK/arm_valid/work/answers-argv.txt" 2>/dev/null; then
    echo "ok arm_erase_answer (Left, Enter)"
else
    echo "FAIL arm_erase_answer: the erase rule must send Left then Enter (\\x1b[D\\r) to select Yes"
    cat -v "$WORK/arm_valid/work/answers-argv.txt"; fail=1
fi
# an erase answered No and a dead debconf frontend are named, not left to their symptoms
run_case arm_erase_declined arm64 arm_erase_declined 1 "erase confirmation was answered No" || fail=1
run_case arm_debconf_assert arm64 arm_debconf_assert 1 "debconf frontend aborted" || fail=1

# --- Magnetar Server medium (NCZ_UI_CHECK_VARIANT=server, the KVM gate's server set) ------------
# 2026-10-26, first real server install (cyclops): every dialog said "Cygnus" and the desktop component selector
# was shown. The server UI check must pass a correct capture and name both defects.
for _a in amd64 arm64; do
    run_case "srv_valid_$_a" "$_a" srv_valid 0 "UI CHECK PASS ($_a, Magnetar Server)" server || fail=1
    run_case "srv_cygnus_$_a" "$_a" srv_cygnus 1 "names the desktop codename 'Cygnus'" server || fail=1
    run_case "srv_components_shown_$_a" "$_a" srv_components_shown 1 "component selector appeared" server || fail=1
    run_case "srv_desktop_review_$_a" "$_a" srv_desktop_review 1 "lists desktop components" server || fail=1
    run_case "srv_no_download_$_a" "$_a" srv_no_download 1 "downloads about 3 GB" server || fail=1
done
# the server capture never sends an answer for the component dialog it must not show; rule 0 is the country
for _a in amd64 arm64; do
    if [ "$(head -1 "$WORK/srv_valid_$_a/work/answers-argv.txt" 2>/dev/null)" = 'Choose your country=\r' ] \
       && ! grep -q 'optional components' "$WORK/srv_valid_$_a/work/answers-argv.txt"; then
        echo "ok srv_rule0_region_$_a"
    else
        echo "FAIL srv_rule0_region_$_a: a server capture must not answer a component dialog"; cat "$WORK/srv_valid_$_a/work/answers-argv.txt" 2>/dev/null; fail=1
    fi
done
run_case bad_variant arm64 text_valid 1 "NCZ_UI_CHECK_VARIANT must be desktop or server" bogus || fail=1

if [ $fail -ne 0 ]; then
    echo "test-installer-ui-wrapper: FAIL" >&2
    exit 1
fi
echo "test-installer-ui-wrapper: OK"
exit 0
