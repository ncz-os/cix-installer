#!/bin/bash
# progress-msg.sh -- one-line milestone feedback for long post-install hooks.
#
# Operator 2026-10-10: "We also need more installation feedback such as in the
# GPU driver installs." The GPU/DKMS steps already have lib/gpu-progress.sh.
# This gives the OTHER long, user-visible steps (firmware BOM, kernel, desktop,
# wallpapers, boot splash, bootloader, first-boot prep) the same kind of honest
# one-line status: what is being done and a rough time class.
#
# SOURCE this file, then call ncz_msg "<text>". It writes an INFO record into
# run-all.sh's progress protocol (progress.state + progress.tsv) and mirrors the
# line to the d-i log VT (tty3), so late.sh's heartbeat renders it and
# build/kvm-install-gate-gpt.sh can assert it textually from the install log.
# The record layout is identical to apt-progress-shim:
#   started|updated|event|phase|index|total|hook|percent|rc|detail
#
# Callers ALWAYS use event INFO (never WARN/FAIL): a post-install hook must not
# fabricate a gate-visible failure row — run-all.sh owns FAIL/WARN for a step.
# A skip or a real failure is stated in the text, with the hook's log path.
#
# Everything here is best-effort and never returns non-zero: a missing d-i
# context (e.g. a unit test sourcing this) is a silent no-op.

ncz_msg() {  # ncz_msg <detail-text>
    local detail="$1" now tmp record
    [ -n "${NCZ_PROGRESS_FILE:-}" ] || return 0
    now=$(date +%s)
    detail=$(printf '%s' "$detail" | tr '|\t\r\n' '     ' | cut -c1-180)
    record="${NCZ_PROGRESS_STARTED:-$now}|$now|INFO|${NCZ_PROGRESS_PHASE:-optional}|${NCZ_PROGRESS_INDEX:-0}|${NCZ_PROGRESS_TOTAL:-0}|${NCZ_PROGRESS_HOOK:-hook}|||${detail}"
    tmp="${NCZ_PROGRESS_FILE}.msg.$$"
    printf '%s\n' "$record" > "$tmp" 2>/dev/null && mv -f "$tmp" "$NCZ_PROGRESS_FILE" 2>/dev/null
    [ -n "${NCZ_PROGRESS_LOG:-}" ] && printf '%s\n' "$record" >> "$NCZ_PROGRESS_LOG" 2>/dev/null
    printf '[%s] [%s] %s\n' "$(date -u +%H:%M:%S)" "${NCZ_PROGRESS_HOOK:-hook}" "$detail" \
        > "${NCZ_TTY:-/dev/tty3}" 2>/dev/null || true
    return 0
}

# ncz_msg_step <n> <m> <text> -- prefix "step n of m" for multi-phase hooks.
ncz_msg_step() { ncz_msg "step $1 of $2: $3"; }
