#!/bin/bash
# test-check-installer-screens.sh -- the --expect-dialogs contract of
# build/check-installer-screens.py (NG-NC-35).
#
# The defect this covers: the checker printed "dialogs in capture order (0): NOT VERIFIED"
# for EVERY capture without extracted dialog titles, so a variant that legitimately has
# no dialogs (the Magnetar Server medium: no component dialog) could never pass, and a
# desktop capture that LOST its dialogs got the very same message -- the two opposite
# outcomes were indistinguishable (lieutenant status c803: the server UI check always
# ends NOT VERIFIED and needs a human note).
#
# --expect-dialogs {desktop,server,none} declares the EXPECTED title sequence for the
# capture's variant:
#   server / none with 0 extracted titles  -> OK   (the empty sequence IS the expectation)
#   desktop with 0 extracted titles         -> FAIL (a desktop run must show its dialogs)
# A framebuffer-only capture (fb-states/) has no console text at all, so it is judged
# with --expect-dialogs none: it carries no dialog text by construction.
#
# The fixture capture dirs live in build/testdata/installer-screens/expect-dialogs/:
#   desktop-console/     real recorded d-i dialog states (r201 d90ed961 arm64 KVM gate)
#   server-console/      a Magnetar Server medium's steps (no component dialog)
#   console-no-dialogs/  a CONSOLE capture whose dialogs were lost (boot text only)
#   framebuffer-only/    the framebuffer sampling states (no console text by construction)
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAILS=0
expect() { local n="$1" want="$2"; shift 2; "$@" >"$T/out" 2>&1; local rc=$?
    if { [ "$want" = 0 ] && [ $rc = 0 ]; } || { [ "$want" != 0 ] && [ $rc != 0 ]; }; then PASS=$((PASS+1)); echo "ok   $n"
    else FAILS=$((FAILS+1)); echo "FAIL $n (rc=$rc, wanted rc=$want)"; sed 's/^/     /' "$T/out"; fi; }
FX="$HERE/testdata/installer-screens/expect-dialogs"
chk() { python3 "$HERE/check-installer-screens.py" "$1" "${@:2}"; }
DESK="$FX/desktop-console"
SRV="$FX/server-console"
LOST="$FX/console-no-dialogs"
FB="$FX/framebuffer-only"

# --- the fixtures themselves must be what the contract says they are -----------------
expect "the desktop fixture really carries dialog titles" 0 chk "$DESK"
expect "the server fixture really carries dialog titles" 0 chk "$SRV"
expect "the lost-dialogs console fixture really has none" 0 chk "$LOST"
expect "the framebuffer-only fixture really has none" 0 chk "$FB"

# --- server / none: the EMPTY sequence is the expectation, so 0 titles is OK ----------
expect "server with 0 dialog titles passes (the empty sequence IS the expectation)" 0 chk "$LOST" --expect-dialogs server
expect "none with 0 dialog titles passes" 0 chk "$LOST" --expect-dialogs none
expect "server with 0 dialog titles passes on a framebuffer-only capture" 0 chk "$FB" --expect-dialogs server
expect "none with 0 dialog titles passes on a framebuffer-only capture" 0 chk "$FB" --expect-dialogs none
# ... and it must not claim "NOT VERIFIED" any more: the sequence was VERIFIED (as empty).
chk "$LOST" --expect-dialogs server >"$T/ev" 2>&1
if grep -q 'NOT VERIFIED' "$T/ev"; then FAILS=$((FAILS+1)); echo "FAIL a server capture with 0 titles still says NOT VERIFIED"; sed 's/^/     /' "$T/ev"
else PASS=$((PASS+1)); echo "ok   a server capture with 0 titles no longer says NOT VERIFIED"; fi
chk "$LOST" --expect-dialogs none >"$T/ev" 2>&1
if grep -q 'NOT VERIFIED' "$T/ev"; then FAILS=$((FAILS+1)); echo "FAIL a none capture with 0 titles still says NOT VERIFIED"; sed 's/^/     /' "$T/ev"
else PASS=$((PASS+1)); echo "ok   a none capture with 0 titles no longer says NOT VERIFIED"; fi
# the verdict must SAY the empty sequence was checked, so the gate log is readable
chk "$LOST" --expect-dialogs server >"$T/ev" 2>&1
if grep -q 'dialogs in capture order (0): OK' "$T/ev"; then PASS=$((PASS+1)); echo "ok   the verdict names the empty sequence as verified"
else FAILS=$((FAILS+1)); echo "FAIL the verdict does not name the empty sequence as verified"; sed 's/^/     /' "$T/ev"; fi

# --- desktop: 0 titles on a CONSOLE capture is the defect this task is about ---------
expect "desktop with 0 dialog titles on a console capture FAILS (the dialogs were lost)" 1 chk "$LOST" --expect-dialogs desktop
expect "desktop with 0 dialog titles on a framebuffer-only capture FAILS" 1 chk "$FB" --expect-dialogs desktop
chk "$LOST" --expect-dialogs desktop >"$T/ev" 2>&1
if grep -q 'expected dialog titles' "$T/ev"; then PASS=$((PASS+1)); echo "ok   the desktop failure names the expected dialog titles"
else FAILS=$((FAILS+1)); echo "FAIL the desktop failure does not name the expected dialog titles"; sed 's/^/     /' "$T/ev"; fi

# --- a capture that DID show its dialogs passes for every variant --------------------
expect "desktop with dialogs passes under --expect-dialogs desktop" 0 chk "$DESK" --expect-dialogs desktop
expect "server with dialogs passes under --expect-dialogs server" 0 chk "$SRV" --expect-dialogs server
# a desktop capture with dialogs is still fine under server/none: the expectation is
# about the EMPTY case, not a title whitelist (the title content is judged elsewhere).
expect "desktop with dialogs passes under --expect-dialogs server" 0 chk "$DESK" --expect-dialogs server
expect "desktop with dialogs passes under --expect-dialogs none" 0 chk "$DESK" --expect-dialogs none

# --- a BROKEN title extraction is a defect for EVERY variant, not an expected empty ---
# A capture that drew a dialog FRAME but whose title could not be parsed is a broken
# extraction, not a capture with no dialogs: it must fail under every expectation, and
# the empty-sequence verdict must NOT be claimed for it.
BROKEN="$T/broken"; mkdir -p "$BROKEN"
printf '# t=20s\n  lqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqk\n  x no title bar here           x\n  mqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqj\n' > "$BROKEN/0000-0020s.txt"
expect "a broken title extraction fails under --expect-dialogs desktop" 1 chk "$BROKEN" --expect-dialogs desktop
expect "a broken title extraction fails under --expect-dialogs server" 1 chk "$BROKEN" --expect-dialogs server
expect "a broken title extraction fails under --expect-dialogs none" 1 chk "$BROKEN" --expect-dialogs none
chk "$BROKEN" --expect-dialogs server >"$T/ev" 2>&1
if grep -q 'dialogs in capture order (0): OK' "$T/ev"; then FAILS=$((FAILS+1)); echo "FAIL a broken extraction is claimed as the expected empty sequence"; sed 's/^/     /' "$T/ev"
else PASS=$((PASS+1)); echo "ok   a broken extraction is not claimed as the expected empty sequence"; fi

# --- the argument is validated, not silently ignored ---------------------------------
expect "an unknown --expect-dialogs value is rejected" 1 chk "$DESK" --expect-dialogs bogus
chk "$DESK" --expect-dialogs bogus >"$T/ev" 2>&1
if grep -q 'expect-dialogs' "$T/ev"; then PASS=$((PASS+1)); echo "ok   the rejection names the argument"
else FAILS=$((FAILS+1)); echo "FAIL the rejection does not name the argument"; sed 's/^/     /' "$T/ev"; fi

# --- without the argument the checker behaves exactly as before ----------------------
# (the default is the historical "no expectation": a capture without dialogs is still
# reported, not failed, so every existing caller is unaffected).
expect "without --expect-dialogs a 0-title console capture still passes" 0 chk "$LOST"
chk "$LOST" >"$T/ev" 2>&1
if grep -q 'dialogs in capture order (0): NOT VERIFIED' "$T/ev"; then PASS=$((PASS+1)); echo "ok   without the argument the historical NOT VERIFIED line is unchanged"
else FAILS=$((FAILS+1)); echo "FAIL without the argument the historical NOT VERIFIED line changed"; sed 's/^/     /' "$T/ev"; fi

# --- the gate wires the variant into the checker -------------------------------------
KV="$HERE/kvm-installer-ui-check.sh"
n=$(awk '/^judge_text\(\) \{/,/^\}/' "$KV" | grep -c -- "--expect-dialogs desktop")
[ "$n" = 1 ] \
    && { PASS=$((PASS+1)); echo "ok   kvm-installer-ui-check.sh passes --expect-dialogs desktop in judge_text"; } \
    || { FAILS=$((FAILS+1)); echo "FAIL kvm-installer-ui-check.sh judge_text does not pass --expect-dialogs desktop (found $n)"; }
n=$(awk '/^judge_text_server\(\) \{/,/^\}/' "$KV" | grep -c -- "--expect-dialogs server")
[ "$n" = 1 ] \
    && { PASS=$((PASS+1)); echo "ok   kvm-installer-ui-check.sh passes --expect-dialogs server in judge_text_server"; } \
    || { FAILS=$((FAILS+1)); echo "FAIL kvm-installer-ui-check.sh judge_text_server does not pass --expect-dialogs server (found $n)"; }
# the framebuffer-only capture (fb-states/) has no console text by construction: it must
# be judged with the empty expectation, never with the desktop one.
n=$(grep -c -- '--expect-dialogs none' "$KV")
[ "$n" -ge 1 ] \
    && { PASS=$((PASS+1)); echo "ok   kvm-installer-ui-check.sh judges the framebuffer-only capture with --expect-dialogs none"; } \
    || { FAILS=$((FAILS+1)); echo "FAIL kvm-installer-ui-check.sh does not judge the framebuffer-only capture with --expect-dialogs none (found $n)"; }
# the blank-after check judges the SAME console capture as the text judge, so it must
# carry the same expectation (otherwise the server run still ends NOT VERIFIED there).
n=$(grep -c -- '--expect-dialogs "$VARIANT"' "$KV")
[ "$n" -ge 1 ] \
    && { PASS=$((PASS+1)); echo "ok   kvm-installer-ui-check.sh judges the blank-after console capture with the variant's expectation"; } \
    || { FAILS=$((FAILS+1)); echo "FAIL kvm-installer-ui-check.sh does not judge the blank-after console capture with the variant's expectation (found $n)"; }

echo "check-installer-screens tests: $PASS passed, $FAILS failed"
[ "$FAILS" = 0 ]
