#!/bin/bash
# bounded-run.sh -- run a command with a hard deadline that a hung command
# cannot defeat. SOURCE this file.
#
# Why not plain `timeout N cmd`: a process stuck in uninterruptible sleep (D
# state, e.g. a PCI config read of a GPU whose runtime-PM transition never
# finished; see lib/pci-sysfs.sh) does not die on SIGKILL, so `timeout` sends
# its signal and then waits for the child forever. And `cmd | tail` hangs the
# same way: the stuck process keeps the pipe's write end open, so the reader
# never sees EOF.
#
# ncz_bounded_run therefore:
#   - starts the command in its own session (setsid) with stdin from
#     /dev/null and stdout+stderr to a regular FILE, never a pipe;
#   - polls /proc/<pid>/stat until it exits or the deadline passes;
#   - on the deadline sends TERM then KILL to the whole process group by its
#     exact PGID, logs "timed out ... continuing", and returns 124 WITHOUT
#     waiting, so the caller always gets control back. The group signal is
#     only used after /proc confirms the started PID leads its own group
#     (pgrp == pid), so it can never reach the caller's group; otherwise
#     (no setsid, or setsid had to fork) the PID and the descendants listed
#     before the first signal are signalled one by one. A D-state leftover
#     is reported with its state and left to the kernel.
#
# Usage: ncz_bounded_run <seconds> <label> <outfile> <command> [args...]
#   Returns the command's exit status, or 124 on timeout; NCZ_BOUNDED_TIMED_OUT
#   is set to 1 on a timeout and 0 otherwise, so a command that itself exits
#   124 is not mistaken for one this function killed.
#   NCZ_BOUNDED_STREAM=1 also copies the output to stdout as it is written
#   (tail --pid), for the post-install orchestrator's console log.
#   NCZ_BOUNDED_POLL (seconds, default 0.2) is the poll interval.
#   NCZ_BOUNDED_SETSID=0 forces the no-setsid path (tests).

ncz__proc_state() { # print the one-letter state of PID, nothing if it is gone
    local s
    s=$(cat "/proc/$1/stat" 2>/dev/null) || return 0
    s=${s##*) }
    printf '%s' "${s%% *}"
}

ncz__proc_pgrp() { # print the process group of PID (stat field 5)
    local s
    s=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
    s=${s##*) }
    # shellcheck disable=SC2086  # split "state ppid pgrp ..." on purpose
    set -- $s
    printf '%s' "$3"
}

ncz__descendants() { # print every descendant PID of PID, children first
    local c
    for c in $(ps -o pid= --ppid "$1" 2>/dev/null); do
        ncz__descendants "$c"
        printf '%s\n' "$c"
    done
}

# ncz__signal_tree <signal> <pid> <group:1|0> <descendant pids...>
ncz__signal_tree() {
    local sig="$1" pid="$2" group="$3" p
    shift 3
    if [ "$group" = 1 ] && kill -"$sig" -- "-$pid" 2>/dev/null; then
        return 0
    fi
    for p in "$@"; do kill -"$sig" "$p" 2>/dev/null; done
    kill -"$sig" "$pid" 2>/dev/null
}

ncz_bounded_run() {
    local secs="$1" label="$2" out="$3"
    shift 3
    local poll="${NCZ_BOUNDED_POLL:-0.2}" pid tail_pid="" st start now rc
    # shellcheck disable=SC2034  # read by callers (run-all.sh)
    NCZ_BOUNDED_TIMED_OUT=0
    : > "$out" 2>/dev/null || { echo "[$label] cannot write $out; running unbounded" >&2; "$@" </dev/null; return; }
    if [ "${NCZ_BOUNDED_SETSID:-1}" = 1 ] && command -v setsid >/dev/null 2>&1; then
        # -w: should setsid ever have to fork (caller is a process-group
        # leader), it still reports the command's exit status.
        setsid -w "$@" </dev/null >"$out" 2>&1 &
    else
        "$@" </dev/null >"$out" 2>&1 &
    fi
    pid=$!
    if [ "${NCZ_BOUNDED_STREAM:-0}" = 1 ]; then
        tail -n +1 -f --pid="$pid" "$out" 2>/dev/null &
        tail_pid=$!
    fi
    start=$(date +%s)
    while :; do
        st=$(ncz__proc_state "$pid")
        case "$st" in ''|Z|X) break ;; esac
        now=$(date +%s)
        if [ $((now - start)) -ge "$secs" ]; then
            echo "[$label] timed out after ${secs}s (pid $pid state $st): $*; continuing without it" >&2
            local group=0 kids
            [ "$(ncz__proc_pgrp "$pid")" = "$pid" ] && group=1
            kids=$(ncz__descendants "$pid")
            # shellcheck disable=SC2086  # one PID per word
            ncz__signal_tree TERM "$pid" "$group" $kids
            sleep 1
            # shellcheck disable=SC2086
            ncz__signal_tree KILL "$pid" "$group" $kids
            st=$(ncz__proc_state "$pid")
            case "$st" in
                D) echo "[$label] pid $pid is in uninterruptible sleep (D) and cannot be killed; left behind" >&2 ;;
            esac
            if [ -n "$tail_pid" ]; then
                kill "$tail_pid" 2>/dev/null
                wait "$tail_pid" 2>/dev/null
            fi
            disown "$pid" 2>/dev/null
            # shellcheck disable=SC2034  # read by callers (run-all.sh)
            NCZ_BOUNDED_TIMED_OUT=1
            return 124
        fi
        sleep "$poll"
    done
    wait "$pid"
    rc=$?
    if [ -n "$tail_pid" ]; then
        wait "$tail_pid" 2>/dev/null
    fi
    return "$rc"
}
