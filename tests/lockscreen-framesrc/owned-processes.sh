#!/bin/bash
# shellcheck disable=SC2034
# Owned-process engine for the lock client's out-of-process frame source.
#
# SOURCED BY BOTH:
#   * tests/lockscreen-framesrc/test-framesrc.sh  (the real headless harness)
#   * tests/lockscreen-framesrc/test-owned-cleanup.sh  (tracked unit, no GPU)
#
# This is the SINGLE source of truth for ownership discovery, fault injection,
# and cleanup. The unit test calls these exact functions; it does NOT
# re-implement (copy) the logic, so a PASS here proves the production helper.
#
# CONTRACT (no broad pkill/pgrep -f anywhere):
#   A lock client is launched with `setsid`, so it and every frame-source
#   descendant live in ONE fresh process group whose PGID == the lock PID
#   (the group leader). Ownership is recorded as pid:pgid:generation together
#   with the leader's /proc start time (Linux starttime, field 22 of
#   /proc/<pid>/stat), so a REUSED PID cannot qualify: after a group leader
#   exits its recorded start time no longer matches, and kill_owned_source
#   verifies the leader is still alive (same start time) before group-killing.
#   The renderer is discovered ONLY by walking /proc for members of an owned
#   group and confirming /proc/<pid>/exe resolves to the real $SRC. An
#   unrelated process that merely shares the testsrc basename is never matched
#   or killed.
#
# Requires the caller to define: $SRC (real frame-source path) and, to use the
# launch helper, $LOCK + a way to start it. Sets/uses: LOCK_OWNED, GEN.
set -u

# Linux start time of pid $1 (jiffies since boot, /proc/<pid>/stat field 22).
# Combined with the PID this uniquely identifies a process incarnation.
starttime_of() {
    local pid="$1" stat rest
    [ -r "/proc/$pid/stat" ] || return 1
    stat="$(cat "/proc/$pid/stat" 2>/dev/null)" || return 1
    # Strip "pid (comm) " — comm may contain spaces/parentheses, so cut after ')'
    rest="${stat##*)}"
    # shellcheck disable=SC2086
    set -- $rest
    # After ')' the fields are state(3) ppid(4) ... starttime(22) => shift 19
    shift 19 2>/dev/null || return 1
    printf '%s' "${1:-}"
}

# Record one owned lock launch: pid:pgid:generation:starttime
owned_add() { LOCK_OWNED+=("$1:$2:$3:${4:-}"); }   # pid:pgid:generation:starttime
_owned_field() { # $1 = field index (1 pid, 2 pgid, 3 gen, 4 starttime)
    local last="${LOCK_OWNED[${#LOCK_OWNED[@]}-1]:-}"; [ -n "$last" ] || return 1
    local rest="$last" i=1
    while [ "$i" -lt "$1" ]; do rest="${rest#*:}"; i=$((i+1)); done
    echo "${rest%%:*}"
}
owned_pid()  { _owned_field 1; }
owned_pgid() { _owned_field 2; }
owned_gen()  { _owned_field 3; }
owned_starttime() { _owned_field 4; }

# true if $1 is a PID of a lock client we launched (any generation)
owned_lock_pid() {
    local pid="$1" e
    for e in "${LOCK_OWNED[@]:-}"; do
        [ -n "$e" ] || continue; [ "${e%%:*}" = "$pid" ] && return 0
    done
    return 1
}

# true if the group leader for owned entry $1 (pid:pgid:gen:starttime) is still
# the SAME incarnation we launched (alive AND starttime unchanged). A reused PID
# fails this because its start time differs.
owned_leader_intact() { # $1 = entry
    local e="$1" pid st want st_now
    pid="${e%%:*}"; st="${e##*:}"
    [ -n "$pid" ] && [ -n "$st" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    st_now="$(starttime_of "$pid")" || return 1
    [ "$st_now" = "$st" ]
}

exe_of() { readlink -f "/proc/$1/exe" 2>/dev/null || true; }
pgid_of() { ps -o pgid= -p "$1" 2>/dev/null | tr -d ' '; }

# Frame sources in owned group $1 whose /proc/<pid>/exe == real $SRC. Nothing
# outside this PGID is considered (a same-basename canary is never matched).
owned_sources_in_pgid() { # $1 = pgid
    local want pid p
    want="$(readlink -f "$SRC" 2>/dev/null || echo "$SRC")"
    for p in /proc/[0-9]*; do
        pid="${p#/proc/}"
        [ "$(pgid_of "$pid")" = "$1" ] || continue
        [ "$(exe_of "$pid")" = "$want" ] && echo "$pid"
    done
    return 0
}

# first owned source PID in the newest owned group (empty if none)
owned_source_pid() {
    local pgid; pgid="$(owned_pgid)" || return 1
    [ -n "$pgid" ] || return 1
    owned_sources_in_pgid "$pgid" | head -1
}
owned_source_alive() { [ -n "$(owned_source_pid)" ]; }

# Fault injection: kill exactly ONE owned source PID. Refuses any PID not in an
# owned group, so a stray kill can never take an unrelated process. If the pid
# is the owned group LEADER, verify the incarnation is intact (leader alive with
# the recorded start time) before signalling the group, so a reused PID cannot
# qualify.
kill_owned_source() { # $1 = pid
    local pid="$1" e pgid
    [ -n "$pid" ] || return 1
    for e in "${LOCK_OWNED[@]:-}"; do
        [ -n "$e" ] || continue
        pgid="${e#*:}"; pgid="${pgid%%:*}"
        [ "$(pgid_of "$pid")" = "$pgid" ] || continue
        [ "$pid" = "${e%%:*}" ] && { owned_leader_intact "$e" || return 1; }
        kill -9 "$pid" 2>/dev/null; return 0
    done
    return 1
}

# Kill every owned lock group and PIDs we recorded, then optionally $LABWC_PID.
# `kill -- -PGID` targets ONLY the owned group; a leader whose incarnation is no
# longer intact is skipped for the group kill (stale PID), and we still wait for
# each owned PID so no zombie leaks into the next case. Never a name scan.
stop_all() {
    local e pid pgid
    for e in "${LOCK_OWNED[@]:-}"; do
        [ -n "$e" ] || continue
        pid="${e%%:*}"; pgid="${e#*:}"; pgid="${pgid%%:*}"
        if [ -n "$pgid" ] && owned_leader_intact "$e"; then
            kill -9 -- "-$pgid" 2>/dev/null
        fi
        [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null
    done
    for e in "${LOCK_OWNED[@]:-}"; do
        [ -n "$e" ] || continue
        pid="${e%%:*}"
        [ -n "$pid" ] && wait "$pid" 2>/dev/null
    done
    [ -n "${LABWC_PID:-}" ] && kill -9 "$LABWC_PID" 2>/dev/null
    [ -n "${LABWC_PID:-}" ] && wait "$LABWC_PID" 2>/dev/null
    # shared state consumed by the sourcing harness:
    # shellcheck disable=SC2034
    LOCK_OWNED=(); LOCK_PID=""; LABWC_PID=""
    sleep 0.3
    return 0
}
