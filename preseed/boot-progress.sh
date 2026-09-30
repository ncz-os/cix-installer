#!/bin/sh
# boot-progress.sh -- NCZ installer boot progress messages.
#
# Baked into the initrd at /ncz/boot-progress.sh by build/iso/patch-initrd-t2-kernel.py
# (see BAKED_HELPERS) so preseed/early_command can call it BEFORE the d-i
# component-loader finishes and BEFORE the newt UI takes over. The point of
# this script is to give the operator a visible timeline on the primary console
# while the installer is still loading; without it the operator sees a blank
# framebuffer for ~13 s after the early_command banner at ~14 s (until the
# first newt screen at ~27 s, measured 2026-09-29 on arm64 KVM). That gap is
# the operator-reported "silent boot".
#
# USAGE:  . /ncz/boot-progress.sh     # sources the helper (defines ncz_boot_msg)
#         ncz_boot_msg <phase> <description>
#
# The messages are written to /dev/tty1, /dev/tty3 and /dev/console. The newt
# UI later takes over /dev/tty1, but the messages run BEFORE the component
# loader (so BEFORE newt), so they ARE visible until newt starts. /dev/tty3
# remains a diagnostic console the operator can switch to with Alt-F3 and see
# the full timeline. /dev/console is the kernel's preferred console; the
# installer's serial capture sees it too.
#
# SHELL:  POSIX sh (the installer's busybox ash).
#
# WHY A SEPARATE HELPER (instead of inline in preseed.cfg): the joined
# d-i early_command string has a hard budget (check-early-command-size.sh,
# 13 000 bytes is the proven cliff). Boot progress is six short calls --
# putting them in a helper keeps early_command well under the budget.
set +e

# ncz_boot_msg <phase> <description>
#   <phase>      -- one short token for grep (loading, hardware, storage, ...)
#   <description>-- the human-readable line the operator sees
# Outputs "[NCZ HH:MM:SS +Ns] <description>" with HH:MM:SS in UTC and N the
# seconds since this helper was first sourced (NCZ_BOOT_T0; the early_command
# caller sources us FIRST so all phases share a single t0). A failure to open
# any one TTY is non-fatal (the loop continues); the install never aborts on
# a console write.
ncz_boot_msg() {
    _phase="$1"
    _desc="$2"
    _now=$(date +%s 2>/dev/null || echo 0)
    _dur=$(( _now - ${NCZ_BOOT_T0:-0} ))
    _stamp=$(date -u +%H:%M:%S 2>/dev/null || echo "??:??:??")
    for _V in /dev/tty1 /dev/tty3 /dev/console; do
        printf '[NCZ %s +%ss] %s\n' "$_stamp" "$_dur" "$_desc" > "$_V" 2>/dev/null || true
    done
}
