#!/bin/bash
# test-reboot-countdown.sh -- ncz_reboot_countdown (preseed/late.sh) is the
# "auto-reboot countdown" docs/INSTALLER-BOOT-UX.md names as the one thing
# not built after the dialogs-vs-silence UX work. It must:
#   1. actually wait, roughly a real second per step, while counting down --
#      not spin through instantly (that would be an unannounced reboot with
#      extra log noise, not a countdown an operator can read)
#   2. show a visible, plain-ASCII status line on every configured console
#   3. let an operator skip the remaining wait by pressing a key (reboot now)
#   4. never run on the unattended path -- ncz_force_reboot's 2nd arg gates it
#
# The real function reads from a real tty (/dev/tty1) and writes status to
# /dev/tty1, /dev/tty3, /dev/console -- all overridable via
# NCZ_REBOOT_INPUT_TTY / NCZ_REBOOT_STATUS_TTYS so this test never touches a
# real console. The input fixture is a FIFO this test keeps open read-write
# itself (fd 3): that satisfies the "a writer exists" condition a tty always
# meets, so the function's own `read -t 1 < fifo` blocks for real wall-clock
# seconds waiting for data exactly like it would on a real tty, instead of
# returning instantly the way reading an empty regular file would (which
# would silently defeat the whole point of a *visible* countdown without
# any test noticing). The status fixture is a plain file: a terminal shows
# only the latest line by nature, and `>` (not `>>`) is the correct,
# intentional choice in the real function for that reason (same pattern as
# ncz_boot_msg elsewhere in this file) -- this test checks reachability and
# wording on the final line, not a scroll-back of every second.
#
# Runs under sh, busybox sh (when installed) and bash, same as the rest of
# this suite. Scratch lives under $TMPDIR (set it to local disk, never tmpfs).
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LATE="$ROOT/preseed/late.sh"

W="$(mktemp -d "${TMPDIR:-/var/tmp}/reboot-countdown-test.XXXXXX")"
trap '[ -n "${KEEP_TEST_DIR:-}" ] || rm -rf "$W"' EXIT

PASS=0; FAILS=0
ok()  { echo "PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL  $1"; FAILS=$((FAILS + 1)); }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

SHELLS="sh"
command -v busybox >/dev/null 2>&1 && busybox sh -c ':' 2>/dev/null && SHELLS="$SHELLS busybox-sh"
SHELLS="$SHELLS bash"

FUNC="$(sed -n '/^ncz_reboot_countdown() {/,/^}/p' "$LATE")"
[ -n "$FUNC" ] || { echo "FAIL  could not extract ncz_reboot_countdown from $LATE"; exit 1; }

for SH in $SHELLS; do
    case "$SH" in
        busybox-sh) RUNNER="busybox sh" ;;
        *) RUNNER="$SH" ;;
    esac

    INFIFO="$W/$SH-in"
    rm -f "$INFIFO"; mkfifo "$INFIFO"

    # --- full countdown, nobody presses a key: must take real wall time ---
    exec 3<>"$INFIFO"   # holds a permanent writer+reader on our side, so the
                         # function's own reads block on DATA (pacing), not
                         # on finding a writer at all (which a tty never does)
    : > "$W/status1"; : > "$W/status3"; : > "$W/console"
    T0=$(date +%s)
    NCZ_REBOOT_INPUT_TTY="$INFIFO" \
    NCZ_REBOOT_STATUS_TTYS="$W/status1 $W/status3 $W/console" \
    timeout 10 $RUNNER -c "$FUNC"$'\n'"ncz_reboot_countdown 2"
    T1=$(date +%s)
    exec 3<&-; exec 3>&-
    DUR=$(( T1 - T0 ))
    check "[$SH] no key pressed: counts down for real wall time (>= 1s for 2 steps)" \
        bash -c "[ ${DUR} -ge 1 ]"
    check "[$SH] no key pressed: does not run away (< 5s for 2 one-second steps)" \
        bash -c "[ ${DUR} -lt 5 ]"
    check "[$SH] final status line is the last second, not a half-finished count" \
        grep -q 'Rebooting in 1s -- press Enter to reboot now' "$W/status1"
    check "[$SH] status reached the tty1 fixture" [ -s "$W/status1" ]
    check "[$SH] status reached the tty3 fixture" [ -s "$W/status3" ]
    check "[$SH] status reached the console fixture" [ -s "$W/console" ]
    check "[$SH] countdown text is ASCII-only (same newt/C-locale constraint as every dialog string)" \
        bash -c '! LC_ALL=C grep -q "[^[:print:][:space:]]" "$1"' _ "$W/status1"

    # --- a key is already waiting in the pipe: skip immediately, no wait ---
    exec 3<>"$INFIFO"
    printf '\n' >&3
    T0=$(date +%s)
    NCZ_REBOOT_INPUT_TTY="$INFIFO" \
    NCZ_REBOOT_STATUS_TTYS="$W/status1 $W/status3 $W/console" \
    timeout 10 $RUNNER -c "$FUNC"$'\n'"ncz_reboot_countdown 30"
    T1=$(date +%s)
    exec 3<&-; exec 3>&-
    DUR=$(( T1 - T0 ))
    check "[$SH] key already waiting: breaks immediately instead of waiting out 30s" \
        bash -c "[ ${DUR} -lt 3 ]"

    rm -f "$INFIFO"
done

# --- ncz_force_reboot only counts down when explicitly told to (2nd arg "1");
#     the unattended call site must stay silent, same as before this feature
#     existed. Greps the call sites rather than running ncz_force_reboot
#     itself (it calls reboot(8) at the end). ---
check "preseed/late.sh: unattended call site passes no countdown flag" \
    bash -c 'grep -q '"'"'ncz_force_reboot "unattended"$'"'"' "$1"' _ "$LATE"
check "preseed/late.sh: interactive call site passes countdown flag 1" \
    bash -c 'grep -q '"'"'ncz_force_reboot "interactive" 1$'"'"' "$1"' _ "$LATE"
check "preseed/late.sh: ncz_force_reboot gates the countdown on \$2 = 1" \
    bash -c 'grep -q '"'"'\[ "\$2" = "1" \] && ncz_reboot_countdown'"'"' "$1"' _ "$LATE"

echo
echo "test-reboot-countdown: $PASS passed, $FAILS failed (shells: $SHELLS)"
[ "$FAILS" -eq 0 ]
