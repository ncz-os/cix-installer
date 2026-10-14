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
# launch helper, $LOCK + a way to start it. Sets/uses: LOCK_OWNED, GEN, and the
# persisted own-renderer registry file $OWNED_SRC_REG (under $OWNED_WORK).
#
# SIGNALLING OWNERSHIP RULE (both PID and group):
#   * A bare PID is signalled ONLY when its recorded incarnation is intact
#     (alive AND the same /proc start time). A reused PID never qualifies.
#   * A process GROUP (`kill -9 -- -PGID`) is signalled ONLY while the owned
#     group LEADER is intact (the leader owns the group, so the PGID is ours).
#   * When the leader has already exited but an owned RENDERER descendant is
#     still alive in that PGID, the group kill is unsafe/insufficient; the
#     descendant is reaped INDIVIDUALLY, each re-verified by recorded start
#     time (pid:starttime), never by broad name/PID match.
#   * Discovery and signalling EXCLUDE any entry whose leader PID exists but
#     has a DIFFERENT start time (stale incarnation). Such an entry is never
#     registered and never signalled, even if the PID now runs an unrelated
#     process with the EXACT same $SRC exe.
#   * WAITING is also ownership-scoped: we NEVER `wait` on a PID whose
#     incarnation is not intact (a stale-incarnation entry must not block
#     cleanup). We only wait on PIDs we actually signalled as owned.
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

# true if pid $1 is the SAME incarnation as recorded start time $2 (alive AND
# start time unchanged). Reused PID (different start time) => false.
owned_pid_intact() { # $1 = pid, $2 = recorded starttime
    local pid="$1" st="$2" st_now
    [ -n "$pid" ] && [ -n "$st" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    st_now="$(starttime_of "$pid")" || return 1
    [ "$st_now" = "$st" ]
}

# true if the owned entry $1's leader PID is ALIVE but its start time does NOT
# match the recorded one (a stale incarnation: the PID was reused by an
# unrelated process). Such an entry must be EXCLUDED from discovery and
# signalling entirely.
owned_entry_stale() { # $1 = entry
    local e="$1" pid st st_now
    pid="${e%%:*}"; st="${e##*:}"
    [ -n "$pid" ] && [ -n "$st" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    st_now="$(starttime_of "$pid")" || return 1
    [ "$st_now" != "$st" ]
}

# --- own-renderer incarnation registry (persists ACROSS subshells) ------------
# Renderers we have DISCOVERED and intend to reap are recorded as
# "pid:starttime" in a private file under $OWNED_WORK (a real file, not an
# in-memory array: a registry update performed inside a command substitution
# runs in a subshell and would otherwise be lost). One PID per line.
# Private, PERSISTENT registry of discovered own-renderer incarnations. It must
# be a real file (not an in-memory array): a registry update performed inside a
# command substitution (or any subshell) would NOT persist in memory, so the
# owning process would forget the renderer it means to reap. The caller may set
# $OWNED_WORK (harness: $WORK/tmp; unit: its scratch dir); if unset we fall back
# to ${WORK:-}/tmp, and to no-op when neither is available.
#
# FAIL-CLOSED: if neither $OWNED_WORK nor $WORK is set, we REFUSE to run with an
# empty registry path. An empty $OWNED_SRC_REG would silently turn discovery
# into a no-op (record_owned_source returns 0 without persisting), so orphaned
# descendants would be discarded and never reaped. We therefore hard-fail at
# source time unless the caller explicitly opts out via OWNED_ALLOW_NO_REG=1.
OWNED_WORK="${OWNED_WORK:-${WORK:+$WORK/tmp}}"
if [ -z "${OWNED_SRC_REG:-}" ]; then
    if [ -n "${OWNED_WORK:-}" ]; then
        OWNED_SRC_REG="$OWNED_WORK/owned-src.reg"
    elif [ "${OWNED_ALLOW_NO_REG:-0}" = "1" ]; then
        OWNED_SRC_REG=""
    else
        echo "owned-processes.sh: FATAL: OWNED_WORK/WORK unset; refusing to run with an empty OWNED_SRC_REG (set OWNED_WORK or OWNED_ALLOW_NO_REG=1)" >&2
        return 1 2>/dev/null || exit 1
    fi
fi

record_owned_source() { # $1 = pid, $2 = starttime  -> records pid:starttime
    local pid="$1" st="$2"
    [ -n "$pid" ] && [ -n "$st" ] || return 1
    [ -n "${OWNED_SRC_REG:-}" ] || return 1    # fail-closed: no registry, no silent no-op
    mkdir -p "$(dirname "$OWNED_SRC_REG")" 2>/dev/null
    printf '%s:%s\n' "$pid" "$st" >>"$OWNED_SRC_REG" 2>/dev/null
}

# Discover owned renderers in owned group $1 that are NOT yet recorded, then
# record each incarnation (pid:starttime) so it survives a subshell. Prints the
# recorded pid:starttime lines. Ownership = exact PGID + /proc/<pid>/exe == $SRC.
# EXCLUDES any entry whose leader PID exists but has a different start time
# (stale incarnation): such a group is never scanned or signalled.
discover_and_record_owned_sources() { # $1 = pgid, $2 = entry (optional)
    local pid st entry="${2:-}"
    if [ -n "$entry" ] && owned_entry_stale "$entry"; then
        return 0
    fi
    for pid in $(owned_sources_in_pgid "$1"); do
        st="$(starttime_of "$pid")" || continue
        record_owned_source "$pid" "$st"
        printf '%s:%s\n' "$pid" "$st"
    done
}

# Reap every RECORDED own-renderer incarnation that is still intact, verifying
# the recorded start time (pid:starttime) so a reused PID is never killed. Lines
# are consumed from $1 (a file). Prints the pid of each incarnation reaped.
reap_recorded_owned_sources() { # $1 = registry file
    local line pid st
    [ -n "${1:-}" ] && [ -r "$1" ] || return 0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        pid="${line%%:*}"; st="${line#*:}"
        if owned_pid_intact "$pid" "$st"; then
            kill -9 "$pid" 2>/dev/null
            printf '%s\n' "$pid"
        fi
    done <"$1"
}

# Exe of pid $1, or empty.
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
# owned group, so a stray kill can never take an unrelated process. The PID's
# incarnation is verified (alive AND the recorded start time, or the leader's
# recorded start time for the leader) before signalling, so a reused PID cannot
# qualify. If the pid is the owned group LEADER, the group is only signalled
# while the leader is intact.
kill_owned_source() { # $1 = pid
    local pid="$1" e pgid
    [ -n "$pid" ] || return 1
    for e in "${LOCK_OWNED[@]:-}"; do
        [ -n "$e" ] || continue
        pgid="${e#*:}"; pgid="${pgid%%:*}"
        [ "$(pgid_of "$pid")" = "$pgid" ] || continue
        if [ "$pid" = "${e%%:*}" ]; then
            # PID is the owned leader: require the recorded incarnation.
            owned_leader_intact "$e" || return 1
        else
            # Descendant: require an intact incarnation (exe still == real $SRC).
            owned_pid_intact "$pid" "$(starttime_of "$pid")" || return 1
            [ "$(exe_of "$pid")" = "$(readlink -f "$SRC" 2>/dev/null || echo "$SRC")" ] || return 1
        fi
        kill -9 "$pid" 2>/dev/null; return 0
    done
    return 1
}

# Kill every owned lock group/incarnation we recorded, then optionally
# $LABWC_PID. Ownership rules:
#   * leader intact  -> `kill -9 -- -PGID` (the leader owns the group), and the
#     group's owned renderers are discovered+recorded first for the reaper.
#   * leader GONE    -> the group kill is unsafe/insufficient, so any owned
#     renderer descendants still in that PGID are reaped INDIVIDUALLY, each
#     re-verified by its recorded start time (no reused-PID kill, no name scan).
#   * leader PID alive but start time DIFFERENT (stale incarnation) -> the
#     entry is EXCLUDED entirely: no discovery, no group kill, no PID kill,
#     and NO WAIT (waiting on a stale incarnation would block cleanup).
# A bare PID is signalled ONLY when its recorded incarnation is intact. Every
# recorded own renderer incarnation is reaped last, then all owned PIDs we
# actually signalled are waited on so no zombie leaks into the next case.
# Never a process-name match.
stop_all() {
    local e pid pgid reaped
    local -a _waited=()
    # 1) per owned lock: discover+record owned renderer incarnations in the
    #    group (PGID stays valid for descendants even after the leader exits),
    #    then group-kill ONLY while the leader is intact (the leader owns the
    #    group). If the leader is gone, the recorded descendants are reaped
    #    individually in step 2 (no orphaned renderer leak). Stale-incarnation
    #    entries (leader PID alive, different start time) are EXCLUDED.
    for e in "${LOCK_OWNED[@]:-}"; do
        [ -n "$e" ] || continue
        pid="${e%%:*}"; pgid="${e#*:}"; pgid="${pgid%%:*}"
        [ -n "$pgid" ] || continue
        if owned_entry_stale "$e"; then
            continue
        fi
        discover_and_record_owned_sources "$pgid" "$e" >/dev/null 2>&1
        if owned_leader_intact "$e"; then
            kill -9 -- "-$pgid" 2>/dev/null
            _waited+=("$pid")
        fi
    done
    # 2) reap recorded own renderer incarnations (leader gone, orphaned child):
    #    each kills only an intact recorded pid:starttime.
    if [ -n "${OWNED_SRC_REG:-}" ] && [ -r "$OWNED_SRC_REG" ]; then
        reap_recorded_owned_sources "$OWNED_SRC_REG" >/dev/null 2>&1
    fi
    # 3) signal each owned LEADER pid ONLY if its incarnation is intact (a
    #    reused/stale PID is never killed here).
    for e in "${LOCK_OWNED[@]:-}"; do
        [ -n "$e" ] || continue
        pid="${e%%:*}"
        if owned_pid_intact "$pid" "${e##*:}"; then
            kill -9 "$pid" 2>/dev/null
            _waited+=("$pid")
        fi
    done
    # 4) wait ONLY on PIDs we actually signalled as owned. A stale-incarnation
    #    entry (leader PID alive, different start time) is NEVER waited on:
    #    waiting on it would block cleanup for the full lifetime of an
    #    unrelated process that merely reused the PID. We also skip any PID
    #    whose incarnation is no longer intact (already gone/reused).
    for pid in "${_waited[@]:-}"; do
        [ -n "$pid" ] || continue
        wait "$pid" 2>/dev/null
    done
    [ -n "${LABWC_PID:-}" ] && kill -9 "$LABWC_PID" 2>/dev/null
    [ -n "${LABWC_PID:-}" ] && wait "$LABWC_PID" 2>/dev/null
    # shared state consumed by the sourcing harness:
    # shellcheck disable=SC2034
    LOCK_OWNED=(); LOCK_PID=""; LABWC_PID=""
    # clear the persisted own-renderer registry (private work file, not memory)
    [ -n "${OWNED_SRC_REG:-}" ] && : >"$OWNED_SRC_REG" 2>/dev/null
    sleep 0.3
    return 0
}
