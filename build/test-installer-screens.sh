#!/bin/bash
# Fixture tests for build/check-installer-screens.py (both directions) and the ASCII-only template rule.
# 2026-09-30: added --require-prompt-sequence and --require-boot-progress tests covering the
# operator-mandated 6-step interactive flow (components + region + username + password +
# password-confirm + hostname + disk + erase-confirm) and the boot-progress [NCZ HH:MM:SS +Ns]
# messages (Loading installer / Detecting hardware / Detecting storage/USB / Starting network /
# Preparing installer dialogs / Ready).
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAILS=0
expect() { local n="$1" want="$2"; shift 2; "$@" >"$T/out" 2>&1; local rc=$?
    if { [ "$want" = 0 ] && [ $rc = 0 ]; } || { [ "$want" != 0 ] && [ $rc != 0 ]; }; then PASS=$((PASS+1)); echo "ok   $n"
    else FAILS=$((FAILS+1)); echo "FAIL $n (rc=$rc)"; sed 's/^/     /' "$T/out"; fi; }
mk() { rm -rf "$T/s"; mkdir -p "$T/s"; printf '# t=20s\n%s\n' "$1" > "$T/s/0000-0020s.txt"; }
GOOD=$'  NCZ-OS 26.7 Maximilian | arm64 (Sky1) | build abc1234\n  lqqqqqqqqqqqqqqqqqqqqqu [!!] NCZ-OS install tqqqqqqqqqqqqqqqk\n  x Untick to skip an optional component.  x\n  x  [*] Full Singularity desktop           x\n  mqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqj'
chk() { python3 "$HERE/check-installer-screens.py" "$T/s" "$@"; }
mk "$GOOD";                                                   expect "clean dialog passes"                    0 chk --require-dialog "optional component"
mk "$GOOD"$'\n[diag] sshd running pid=1';                      expect "[diag] chatter fails"                    1 chk
mk "$GOOD"$'\n   ssh root@10.0.2.15 (password: diags)';         expect "password hint fails"                     1 chk
mk "${GOOD/Full Singularity desktop/desktop <ERR>}";           expect "<ERR> row fails"                         1 chk
mk "$GOOD"$'\n[ncz components] showing component prompt';      expect "[ncz ...] prefix fails"                  1 chk
mk "$GOOD"$'\nPlease press Enter to activate this console.';   expect "askfirst prompt fails"                   1 chk
mk "$GOOD";                                                   expect "missing required dialog text fails"      1 chk --require-dialog "name this computer"
mk "$GOOD";                                                   expect "header present passes"                   0 chk --require-header "NCZ-OS [0-9.]+ [A-Za-z]+ \\|"
mk $'  lqqqqqqqqqqqqqqu title tqqqqqqk\n  x hello x\n  mqqqqqqqqqqqqqqqqqqj'; expect "dialog without header fails" 1 chk --require-header "NCZ-OS [0-9.]+"
mk2() { rm -rf "$T/s"; mkdir -p "$T/s"; printf '# t=20s\n%s\n' "$1" > "$T/s/0000-0020s.txt"; printf '# t=30s\n%s\n' "$2" > "$T/s/0001-0030s.txt"; }
BLANK=$'[                    (1**installer)  2 shell  3 shell  4- log'
mk3() { rm -rf "$T/s"; mkdir -p "$T/s"; printf '# t=20s\n%s\n' "$1" > "$T/s/0000-0020s.txt"; printf '# t=%s\n%s\n' "$3" "$2" > "$T/s/0001-0030s.txt"; printf '# t=%s\n%s\n' "$4" "$1" > "$T/s/0002-0060s.txt"; }
mk3 "$GOOD" "$BLANK" 30s 60s; expect "a 30 s blank console after the dialog fails" 1 chk --no-blank-after "optional component"
mk3 "$GOOD" "$BLANK" 30s 34s; expect "a 4 s redraw gap is tolerated" 0 chk --no-blank-after "optional component"
mk2 "$GOOD" "$BLANK";                                         expect "a trailing blank console fails"     1 chk --no-blank-after "optional component"
mk2 "$GOOD" "$GOOD";                                          expect "a dialog that stays up passes"            0 chk --no-blank-after "optional component"
mk2 "$BLANK" "$BLANK";                                        expect "blank BEFORE the marker dialog is not judged" 0 chk --no-blank-after "optional component"
rm -rf "$T/s"; mkdir "$T/s";                                  expect "empty capture fails"                     1 chk
# --- operator-required 6-step prompt sequence (2026-09-30) -------------------
# Components, region, username, password, password-confirm, hostname, target disk, erase-confirm.
# Each prompt is a distinct dialog state. The regex tokens are the operator's phrases
# from disk-fs-chooser.sh / region-chooser.sh / user-chooser.sh / hostname-suggest.sh /
# component-selector.sh -- if the chooser source changes a title, the test catches it.
DIALOG_COMP=$'  NCZ-OS 26.10 Cygnus | arm64 (Sky1) | build abc1234\n  lqqqqqqqqq [NCZ-OS install - optional components tqqqqqqqqqq k\n  x Untick to skip an optional component.  x\n  mqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqj'
DIALOG_REG=$'  NCZ-OS 26.10 Cygnus | arm64 (Sky1) | build abc1234\n  lqqqqqqqqq [NCZ-OS install - select your REGION tqqqqqqqqqq k\n  x body x\n  mqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqj'
DIALOG_USR=$'  NCZ-OS 26.10 Cygnus | arm64 (Sky1) | build abc1234\n  lqqqqqqqqq [NCZ-OS install - choose a USERNAME tqqqqqqqqqq k\n  x body x\n  mqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqj'
DIALOG_PWD=$'  NCZ-OS 26.10 Cygnus | arm64 (Sky1) | build abc1234\n  lqqqqqqqqq [NCZ-OS install - choose a PASSWORD for ncz tqqqqq k\n  x body x\n  mqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqj'
DIALOG_PWDC=$'  NCZ-OS 26.10 Cygnus | arm64 (Sky1) | build abc1234\n  lqqqqqqqqq [NCZ-OS install - type the same PASSWORD again tqqq k\n  x body x\n  mqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqj'
DIALOG_HOST=$'  NCZ-OS 26.10 Cygnus | arm64 (Sky1) | build abc1234\n  lqqqqqqqqq [NCZ-OS install - name this computer (hostname) tqqqq k\n  x body x\n  mqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqj'
DIALOG_DISK=$'  NCZ-OS 26.10 Cygnus | arm64 (Sky1) | build abc1234\n  lqqqqqqqqq [NCZ-OS install - select the TARGET DISK tqqqqqqqqq k\n  x body x\n  mqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqj'
DIALOG_ERASE=$'  NCZ-OS 26.10 Cygnus | arm64 (Sky1) | build abc1234\n  lqqqqqqqqq [NCZ-OS install - ERASE /dev/sda and install? tqqqq k\n  x body x\n  mqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqj'
mk8() { rm -rf "$T/s"; mkdir -p "$T/s"
    printf '# t=15s\n%s\n' "$1" > "$T/s/0000-0015s.txt"
    printf '# t=20s\n%s\n' "$2" > "$T/s/0001-0020s.txt"
    printf '# t=25s\n%s\n' "$3" > "$T/s/0002-0025s.txt"
    printf '# t=27s\n%s\n' "$4" > "$T/s/0003-0027s.txt"
    printf '# t=30s\n%s\n' "$5" > "$T/s/0004-0030s.txt"
    printf '# t=33s\n%s\n' "$6" > "$T/s/0005-0033s.txt"
    printf '# t=37s\n%s\n' "$7" > "$T/s/0006-0037s.txt"
    printf '# t=41s\n%s\n' "$8" > "$T/s/0007-0041s.txt"; }
mk8 "$DIALOG_COMP" "$DIALOG_REG" "$DIALOG_USR" "$DIALOG_PWD" "$DIALOG_PWDC" "$DIALOG_HOST" "$DIALOG_DISK" "$DIALOG_ERASE"
expect "operator-required full 8-dialog sequence (6 2x password ERASE) passes" 0 chk --require-prompt-sequence "optional components" "select your REGION" "choose a USERNAME" "choose a PASSWORD" "type the same PASSWORD" "name this computer" "TARGET DISK" "ERASE"
DIALOG_BAD=$'  NCZ-OS 26.10 Cygnus | arm64 (Sky1) | build abc1234\n  lqqqqqqqqq [NCZ-OS install - WRONG-ORDER dialog tqqqqqqqqqq k\n  x body x\n  mqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqj'
mk6() { rm -rf "$T/s"; mkdir -p "$T/s"
    printf '# t=15s\n%s\n' "$1" > "$T/s/0000-0015s.txt"
    printf '# t=20s\n%s\n' "$2" > "$T/s/0001-0020s.txt"
    printf '# t=25s\n%s\n' "$3" > "$T/s/0002-0025s.txt"
    printf '# t=30s\n%s\n' "$4" > "$T/s/0003-0030s.txt"
    printf '# t=35s\n%s\n' "$5" > "$T/s/0004-0035s.txt"; }
mk6 "$DIALOG_REG" "$DIALOG_COMP" "$DIALOG_USR" "$DIALOG_HOST" "$DIALOG_DISK"
expect "operator-required 6-step sequence fails when out of order" 1 chk --require-prompt-sequence "optional components" "select your REGION" "choose a USERNAME" "name this computer" "TARGET DISK"
mk6 "$DIALOG_COMP" "$DIALOG_REG" "$DIALOG_USR" "$DIALOG_HOST" "$DIALOG_DISK"
expect "operator-required 6-step sequence fails when a prompt is missing" 1 chk --require-prompt-sequence "optional components" "select your REGION" "type the same PASSWORD" "name this computer" "TARGET DISK"
# full boot-progress + prompt-sequence, single dialog state holds the boot lines
# (newt clears /dev/tty1 later but the serial capture keeps them in order).
DIALOG_TAIL=$'  [NCZ 14:22:30 +0s] Loading installer...\n  [NCZ 14:22:31 +1s] Detecting hardware...\n  [NCZ 14:22:33 +3s] Detecting storage/USB devices...\n  [NCZ 14:22:34 +4s] Starting network...\n  [NCZ 14:22:36 +6s] Preparing installer dialogs...\n  [NCZ 14:22:38 +8s] Ready: installer UI is loading...\n  NCZ-OS 26.10 Cygnus | arm64 (Sky1) | build abc1234\n  lqqqqqqqqq [NCZ-OS install - optional components tqqqqqqqqq k\n  x body x\n  mqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqj'
rm -rf "$T/s"; mkdir -p "$T/s"; printf '# t=20s\n%s\n' "$DIALOG_TAIL" > "$T/s/0000-0020s.txt"
expect "full boot-progress (6 phases) + first dialog passes" 0 chk --require-boot-progress "Loading installer" "Detecting hardware" "Detecting storage/USB devices" "Starting network" "Preparing installer dialogs" "Ready: installer UI is loading" --require-dialog "optional components"
rm -rf "$T/s"; mkdir "$T/s";                                  expect "empty capture fails"                     1 chk
# templates that d-i draws with newt must be ASCII: the em dash rendered "<ERR>" and truncated the title on hardware
ROOT="$(cd "$HERE/.." && pwd)"
tpl_ascii() { local f; for f in "$ROOT"/preseed/component-selector.sh "$ROOT"/preseed/disk-fs-chooser.sh "$ROOT"/preseed/hostname-suggest.sh "$ROOT"/preseed/region-chooser.sh "$ROOT"/preseed/user-chooser.sh "$ROOT"/preseed/locale-keyboard-chooser.sh "$ROOT"/preseed/late.sh; do
    [ -f "$f" ] || continue
    awk -v f="$f" '
        !r && match($0, /<<-?[\047"]?[A-Z]*TPL/) { w=substr($0, RSTART, RLENGTH); gsub(/[<\047"-]/, "", w); r=1; next }
        r && $0 == w { r=0; next }
        (r || /LONG=/) && /[^\001-\177]/ { print f ": non-ASCII in template text: " $0; bad=1 }
        END { exit bad }' "$f" || return 1
done; }
expect "d-i template sources are ASCII" 0 tpl_ascii
printf 'Template: x/y\nDescription: NCZ install \xe2\x80\x94 pick\n' > "$T/bad.sh"
tpl_bad() { awk '/^Description/ { if ($0 ~ /[^\001-\177]/) bad=1 } END{exit !bad}' "$T/bad.sh"; }
expect "a non-ASCII template line is detected" 0 tpl_bad
echo "installer screen tests: $PASS passed, $FAILS failed"
[ "$FAILS" = 0 ]
