#!/usr/bin/env bash
# test-greeter-console-fallback.sh -- when greetd gives up, tty1 gets a text
# login with a message that says why (post-install/55-greeter.sh).
#
# O6N 2026-10-26: the Mali modules were refused by the kernel, ncz-gpu-env
# refused software rendering (correct), the greeter exited five times, greetd
# hit its start limit, and the screen kept two error lines and no login.
#
# Checks: greetd's drop-in names ncz-greeter-fallback.service in OnFailure=
# and clears a stale message on the next start; the unit runs the script; the
# script writes the message (with the ncz-gpu-env reason when the journal has
# one) to the issue file and the tty, and starts getty@tty1.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../post-install/55-greeter.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/test-greeter-fallback.XXXXXX")"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS: $1"; PASS=$((PASS + 1)); }
no() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
block() {  # block <heredoc tag> -> body of `cat > ... <<'TAG'` in the hook
    awk -v t="$1" '$0 ~ "<<\x27" t "\x27$" {f=1; next} $0 == t {f=0} f' "$HOOK"
}
block FALLBACK > "$T/fallback"; block FBUNIT > "$T/unit"; block GREETDFB > "$T/dropin"
for f in fallback unit dropin; do [ -s "$T/$f" ] && ok "55-greeter.sh writes the $f" || no "55-greeter.sh has no $f block"; done

grep -qx 'OnFailure=ncz-greeter-fallback.service' "$T/dropin" && ok "greetd drop-in: OnFailure=ncz-greeter-fallback.service" || no "greetd drop-in has no OnFailure"
grep -q '/etc/systemd/system/greetd.service.d/12-ncz-console-fallback.conf' "$HOOK" && ok "drop-in path is under greetd.service.d" || no "drop-in not installed under greetd.service.d"
default_issue=$(sed -n 's/^ISSUE=\${NCZ_FALLBACK_ISSUE:-\(.*\)}$/\1/p' "$T/fallback")
grep -qx "ExecStartPre=-/bin/rm -f $default_issue" "$T/dropin" && ok "next greetd start clears the message ($default_issue)" || no "greetd does not clear $default_issue"
grep -qx 'ExecStart=/usr/local/sbin/ncz-greeter-fallback' "$T/unit" && grep -qx 'Type=oneshot' "$T/unit" && ok "unit runs the fallback script" || no "unit does not run the script"

mkdir -p "$T/bin"
cat > "$T/bin/systemctl" <<STUB
#!/bin/sh
echo "\$*" >> "$T/systemctl.log"
STUB
printf '#!/bin/sh\necho "ncz-gpu-env: an older unrelated line"\n[ -n "${JOURNAL_LINE:-}" ] && echo "$JOURNAL_LINE"\necho "ncz-gpu-env: WARNING a later unrelated line"\nexit 0\n' > "$T/bin/journalctl"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/logger"; printf '#!/bin/sh\nexit 0\n' > "$T/bin/chvt"
chmod +x "$T/bin/"*
run() { PATH="$T/bin:$PATH" NCZ_FALLBACK_TTY="$T/tty1" NCZ_FALLBACK_ISSUE="$T/issue" sh "$T/fallback"; }

JOURNAL_LINE="ncz-gpu-env: a hardware GPU is present but no hardware GPU stack is usable; software rendering REFUSED (NCZ_ALLOW_SOFTWARE_FALLBACK=1 overrides). Run: ncz-gpu-status --require-hardware" run
grep -q 'getty@tty1.service' "$T/systemctl.log" 2>/dev/null && grep -q -- '--no-block start getty@tty1.service' "$T/systemctl.log" && ok "starts getty@tty1 (non-blocking)" || no "getty@tty1 not started: $(cat "$T/systemctl.log" 2>/dev/null)"
grep -q 'the graphical login could not start' "$T/issue" && ok "issue file says the greeter could not start" || no "issue file missing the message"
grep -q '^GPU: ncz-gpu-env: a hardware GPU is present' "$T/issue" && ok "issue file carries the ncz-gpu-env reason" || no "issue file has no GPU reason"
grep -q 'ncz-gpu-status --require-hardware' "$T/issue" && ok "issue file points at ncz-gpu-status" || no "issue file has no next step"
cmp -s "$T/issue" "$T/tty1" && ok "the same message is written to tty1" || no "tty1 did not get the message"
grep -qE 'LIBGL_ALWAYS_SOFTWARE|WLR_RENDERER|pixman|llvmpipe|NCZ_ALLOW_SOFTWARE_FALLBACK' "$T/fallback" && no "fallback touches software rendering" || ok "fallback does not enable software rendering"
rm -f "$T/issue" "$T/tty1" "$T/systemctl.log"
JOURNAL_LINE= run
grep -q 'could not start' "$T/issue" && ! grep -q '^GPU:' "$T/issue" \
    && ok "no refusal line -> no GPU cause is claimed" || no "no-refusal case wrong: $(cat "$T/issue" 2>/dev/null)"
grep -q 'start getty@tty1.service' "$T/systemctl.log" && ok "no journal reason -> getty still started" || no "no-reason case did not start getty"

# /etc not writable: tty1 must still get the message (root ignores the mode: skip)
if [ "$(id -u)" = 0 ]; then echo "SKIP: unwritable issue dir case needs a non-root user"; else
rm -f "$T/tty1" "$T/systemctl.log"; mkdir -p "$T/ro"; chmod 0555 "$T/ro"
JOURNAL_LINE="ncz-gpu-env: x software rendering REFUSED y" PATH="$T/bin:$PATH" NCZ_FALLBACK_TTY="$T/tty1" NCZ_FALLBACK_ISSUE="$T/ro/issue" sh "$T/fallback" 2>"$T/ro.err"
chmod 0755 "$T/ro"
grep -q 'could not start' "$T/tty1" && grep -q '^GPU: ncz-gpu-env: x software rendering REFUSED y' "$T/tty1" \
    && ok "unwritable issue dir -> tty1 still gets the message" || no "unwritable issue dir lost the tty message"
[ ! -s "$T/ro.err" ] && ok "unwritable issue dir -> no shell error" || no "unwritable issue dir printed: $(cat "$T/ro.err")"
grep -q 'start getty@tty1.service' "$T/systemctl.log" && ok "unwritable issue dir -> getty still started" || no "getty not started"
fi

echo "test-greeter-console-fallback: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
