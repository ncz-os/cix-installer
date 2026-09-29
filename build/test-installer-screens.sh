#!/bin/bash
# Fixture tests for build/check-installer-screens.py (both directions) and the ASCII-only template rule.
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
rm -rf "$T/s"; mkdir "$T/s";                                  expect "empty capture fails"                     1 chk
# templates that d-i draws with newt must be ASCII: the em dash rendered "<ERR>" and truncated the title on hardware
ROOT="$(cd "$HERE/.." && pwd)"
tpl_ascii() { local f; for f in "$ROOT"/preseed/component-selector.sh "$ROOT"/preseed/disk-fs-chooser.sh "$ROOT"/preseed/hostname-suggest.sh "$ROOT"/preseed/locale-keyboard-chooser.sh "$ROOT"/preseed/late.sh; do
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
