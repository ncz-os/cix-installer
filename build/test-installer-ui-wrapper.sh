#!/bin/bash
# test-installer-ui-wrapper.sh -- exercise the REAL build/kvm-installer-ui-check.sh against the REAL
# build/check-installer-screens.py, with a narrowly stubbed capture harness (build/boot-screens.py) that
# writes real fb-states/ and serial-screens/ fixtures. No VM, no deps, no network.
#
# The stub replaces ONLY the capture step (boot-screens.py). Every checker invocation goes to the real
# python3 + the real production checker. A private python shim skips only the pyte import preflight and
# generates the capture fixtures for boot-screens.
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

# Stub boot-screens.py: writes fb-states/, fb-frames.txt, serial-screens/, answers.log.
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
ap.add_argument("--enter-every", type=int, default=0)
ap.add_argument("--enter-after", type=int, default=0)
ap.add_argument("--answer", action="append", default=[])
a = ap.parse_args()
work = a.work
os.makedirs(work, exist_ok=True)
mode = os.environ.get("NCZ_TEST_FIXTURE", "amd_zero")

def w(path, text):
    with open(path, "w") as fh: fh.write(text)

if a.arch == "amd64":
    fb = os.path.join(work, "fb-states"); os.makedirs(fb, exist_ok=True)
    # >=20 states, >=8 distinct frames; zero-title by default (framebuffer-only).
    for i in range(24):
        t = i * 3
        body = "framebuffer frame %d\n" % (i % 10)
        if mode == "amd_nonzero":
            # synthetic: one state happens to contain a real newt title bar (still not a real text channel)
            if i == 10:
                body = ("lqqqqqqqqqqqqqqqqqqqqqu [!!] NCZ-OS install tqqqqqqqqqqqqqqqk\n"
                        "x optional components                                                    x\n"
                        "mqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqj\n")
        if mode == "amd_late_blank":
            # Real persistent blank state: t=30 blank, next state at t=63 (33s > max-blank-secs 8),
            # with a framebuffer marker before it so the continuity check has a start point.
            # Intermediate states are skipped so the blank duration is measured against the NEXT
            # state file, not against a consecutive blank run.
            if t == 30:
                body = ""
            elif 33 <= t <= 60:
                continue
        w(os.path.join(fb, "%04d-%ds.txt" % (i, t)), "# t=%ds\n%s" % (t, body))
    with open(os.path.join(work, "fb-frames.txt"), "w") as fh:
        for i in range(24):
            fh.write("%04d %d\n" % (i, i % 10))
    with open(os.path.join(work, "answers.log"), "w") as fh:
        fh.write("t=25s rule 0 optional components=\\r\n")
else:
    ss = os.path.join(work, "serial-screens"); os.makedirs(ss, exist_ok=True)
    # ARM: full contract fixtures. Header, prompt sequence, login line, >=20 states, >=5 dialogs.
    hdr = "NCZ-OS 1.2 Codename"
    def frame(title, body):
        # Real newt title bar: l qqq u TITLE t qqq k, then body rows, then bottom border.
        return ("lqqqqqqqqqqqqqqqqqqqqqu %s tqqqqqqqqqqqqqqqk\n"
                "x %s x\n"
                "mqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqj\n"
                "%s\n" % (title, title, body))
    steps = [
        ("select your REGION", "region"),
        ("choose a USERNAME", "username"),
        ("choose a PASSWORD", "password"),
        ("type the same PASSWORD", "confirm"),
        ("optional components", "components"),
    ]
    for i in range(24):
        t = i * 3
        if i < len(steps):
            title, _ = steps[i]
            body = frame(title, hdr + "\n" + title)
        else:
            body = frame("Installing the base system", hdr + "\nprogress")
        if mode == "arm_missing_header" and i == 0:
            body = frame("select your REGION", "no brand here")
        if mode == "arm_wrong_order" and i == 0:
            body = frame("choose a USERNAME", hdr + "\nchoose a USERNAME")
        if mode == "arm_wrong_order" and i == 1:
            body = frame("select your REGION", hdr + "\nselect your REGION")
        w(os.path.join(ss, "%04d-%ds.txt" % (i, t)), "# t=%ds\n%s" % (t, body))
    # login line in at least one state
    w(os.path.join(ss, "0099-297s.txt"),
      "# t=297s\ndiagnostics login: root / set by ncz_diag_pw\n")
    with open(os.path.join(work, "answers.log"), "w") as fh:
        fh.write("t=25s rule 0 optional components=\\r\n")
PY
chmod +x "$STUB"

# --- harness: run the real wrapper with the stub capture and shimmed python ----------------------
run_case() {
    local name="$1" arch="$2" fixture="$3" require="$4" expect_rc="$5" expect_out="$6"
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
    out="$(NCZ_TEST_FIXTURE="$fixture" NCZ_UI_CHECK_REQUIRE_DIALOGS="$require" \
           NCZ_PYTE_PYTHON="$SHIM/pyte.py" PYTHONPATH="$SHIM" \
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

# AMD zero-title default -> PASS-LIMITED
run_case amd_zero_default amd64 amd_zero 0 0 "PASS-LIMITED" || fail=1
# AMD zero-title strict -> reject
run_case amd_zero_strict amd64 amd_zero 1 1 "NCZ_UI_CHECK_REQUIRE_DIALOGS=1" || fail=1
# AMD real parsed nonzero-title default -> PASS-LIMITED (still limited: no text channel)
run_case amd_nonzero_default amd64 amd_nonzero 0 0 "PASS-LIMITED" || fail=1
# AMD nonzero strict -> reject
run_case amd_nonzero_strict amd64 amd_nonzero 1 1 "NCZ_UI_CHECK_REQUIRE_DIALOGS=1" || fail=1
# AMD 30s late blank still reject (continuity check unchanged)
run_case amd_late_blank amd64 amd_late_blank 0 1 "blank console after" || fail=1

# ARM positive valid full contract -> PASS
run_case arm_valid arm64 arm_valid 0 0 "UI CHECK PASS" || fail=1
# ARM missing header -> reject
run_case arm_missing_header arm64 arm_missing_header 0 1 "header" || fail=1
# ARM wrong prompt order -> reject
run_case arm_wrong_order arm64 arm_wrong_order 0 1 "never matched" || fail=1

if [ $fail -ne 0 ]; then
    echo "test-installer-ui-wrapper: FAIL" >&2
    exit 1
fi
echo "test-installer-ui-wrapper: OK"
exit 0
