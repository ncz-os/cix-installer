#!/bin/bash
# Shared by the real harness and its real-process unit tests.
# Renderers deliberately setsid(): ownership follows PPID ancestry while the
# root incarnation is intact, then persisted PID/starttime after reparenting.
# An exec preserves that process incarnation; saved exe is diagnostic identity.
# Fault injection additionally requires the CURRENT exe to be the real $SRC.
set -u
starttime_of() {
    local s r
    s=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
    r=${s##*)}; set -- $r; shift 19 || return 1
    printf '%s' "${1:-}"
}
exe_of() { readlink -f "/proc/$1/exe" 2>/dev/null || true; }
pgid_of() { ps -o pgid= -p "$1" 2>/dev/null | tr -d ' '; }
owned_pid_intact() {
    [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 1
    [ "$(starttime_of "$1")" = "$2" ]
}
owned_leader_intact() {
    local e=$1 pid pgid
    pid=${e%%:*}; pgid=${e#*:}; pgid=${pgid%%:*}
    owned_pid_intact "$pid" "${e##*:}" || return 1
    [ "$(pgid_of "$pid")" = "$pgid" ]
}
owned_entry_stale() {
    local e=$1 now
    now=$(starttime_of "${e%%:*}") || return 1
    [ "$now" != "${e##*:}" ]
}
_owned_field() {
    local e=${LOCK_OWNED[${#LOCK_OWNED[@]}-1]:-} i=1
    [ -n "$e" ] || return 1
    while [ "$i" -lt "$1" ]; do e=${e#*:}; i=$((i+1)); done
    printf '%s\n' "${e%%:*}"
}
owned_pid() { _owned_field 1; }
owned_pgid() { _owned_field 2; }
owned_gen() { _owned_field 3; }
owned_starttime() { _owned_field 4; }
owned_lock_pid() {
    local e
    for e in "${LOCK_OWNED[@]:-}"; do
        [ "${e%%:*}" = "$1" ] && owned_leader_intact "$e" && return 0
    done
    return 1
}
OWNED_WORK=${OWNED_WORK:-${WORK:+$WORK/tmp}}
[ -n "$OWNED_WORK" ] || { echo 'FATAL: owned process registry needs WORK/OWNED_WORK' >&2; exit 2; }
mkdir -p "$OWNED_WORK" || exit 2
OWNED_SRC_REG=${OWNED_SRC_REG:-$OWNED_WORK/owned-src.reg}
: >>"$OWNED_SRC_REG" || exit 2
OWNED_TAGS=()
OWNED_UID=$(id -u)
record_owned_source() {
    local pid=$1 st=$2 exe
    exe=$(exe_of "$pid")
    [ -n "$exe" ] && owned_pid_intact "$pid" "$st" || return 1
    printf '%s\t%s\t%s\n' "$pid" "$st" "$exe" >>"$OWNED_SRC_REG"
}
# Test whether a candidate's CURRENT PPID chain reaches the intact owned root.
_owned_descendant() {
    local pid=$1 root=$2 e=$3 s r n=0
    while [ "$pid" -gt 1 ] 2>/dev/null && [ "$n" -lt 512 ]; do
        [ "$pid" = "$root" ] && owned_leader_intact "$e" && return 0
        s=$(cat "/proc/$pid/stat" 2>/dev/null) || return 1
        r=${s##*)}; set -- $r
        pid=${2:-0}; n=$((n+1))
    done
    return 1
}
discover_and_record_owned_sources() {
    local root=$1 e=${2:-} f pid st
    [ -n "$e" ] && owned_leader_intact "$e" || return 0
    for f in /proc/[0-9]*/stat; do
        pid=${f#/proc/}; pid=${pid%/stat}
        st=$(starttime_of "$pid") || continue
        _owned_descendant "$pid" "$root" "$e" || continue
        record_owned_source "$pid" "$st" || true
    done
}
# Per-launch nonce is injected ONLY into an owned root, never the harness.
# fork/setsid/exec inherit it, so a fast-root-exit renderer remains identifiable
# without a sampling race. Also require same UID and a known harness exe.
_recover_owned_tags() {
    local f pid tag uid exe st allowed
    for f in /proc/[0-9]*/environ; do
        pid=${f#/proc/}; pid=${pid%/environ}
        uid=$(awk '/^Uid:/{print $2;exit}' "/proc/$pid/status" 2>/dev/null)
        [ "$uid" = "$OWNED_UID" ] || continue
        for tag in "${OWNED_TAGS[@]:-}"; do
            [ -n "$tag" ] || continue
            grep -zFxq -- "NCZ_LOCK_TEST_OWNER=$tag" "$f" 2>/dev/null || continue
            exe=$(exe_of "$pid"); allowed=0
            for known in "$SRC" "${LOCK:-}" /bin/sh /bin/bash /bin/sleep; do
                [ -n "$known" ] || continue
                [ "$exe" = "$(readlink -f "$known")" ] && allowed=1 && break
            done
            [ "$allowed" = 1 ] || continue
            st=$(starttime_of "$pid") || continue
            record_owned_source "$pid" "$st" || true
        done
    done
}
owned_add() {
    local e="$1:$2:$3:${4:-}"
    LOCK_OWNED+=("$e")
    [ -n "${5:-}" ] && OWNED_TAGS+=("$5")
    _recover_owned_tags
    # Snapshot children already present (also covers the orphan fixture).
    discover_and_record_owned_sources "$1" "$e"
}
_refresh_owned() {
    local e
    _recover_owned_tags
    for e in "${LOCK_OWNED[@]:-}"; do
        [ -n "$e" ] || continue
        discover_and_record_owned_sources "${e%%:*}" "$e"
    done
}
# Legacy API name retained for callers; root identity, NOT shared PGID, owns it.
owned_sources_in_pgid() {
    local root=$1 e pid st exe want
    for e in "${LOCK_OWNED[@]:-}"; do
        [ "${e%%:*}" = "$root" ] || continue
        discover_and_record_owned_sources "$root" "$e"
    done
    want=$(readlink -f "$SRC")
    while IFS=$'\t' read -r pid st exe; do
        owned_pid_intact "$pid" "$st" || continue
        [ "$(exe_of "$pid")" = "$want" ] && printf '%s\n' "$pid"
    done <"$OWNED_SRC_REG"
    return 0
}
owned_source_pid() {
    local root
    root=$(owned_pid) || return 1
    owned_sources_in_pgid "$root" | sort -nu | head -1
}
owned_source_alive() { [ -n "$(owned_source_pid)" ]; }
kill_owned_source() {
    local target=${1:-} pid st exe want
    [ -n "$target" ] || return 1
    _refresh_owned
    want=$(readlink -f "$SRC")
    while IFS=$'\t' read -r pid st exe; do
        [ "$pid" = "$target" ] || continue
        owned_pid_intact "$pid" "$st" || continue
        [ "$(exe_of "$pid")" = "$want" ] || continue
        kill -9 "$pid" 2>/dev/null && return 0
    done <"$OWNED_SRC_REG"
    return 1
}
reap_recorded_owned_sources() {
    local pid st exe
    while IFS=$'\t' read -r pid st exe; do
        owned_pid_intact "$pid" "$st" || continue
        kill -9 "$pid" 2>/dev/null || true
    done <"$1"
}
stop_all() {
    local e pid
    local -a waited=()
    # Record the tree BEFORE terminating any root. New sessions stay ours.
    _refresh_owned
    for e in "${LOCK_OWNED[@]:-}"; do
        [ -n "$e" ] && owned_leader_intact "$e" || continue
        pid=${e%%:*}
        kill -9 "$pid" 2>/dev/null && waited+=("$pid")
    done
    # Root may already have exited; inherited nonce recovers its detached
    # children even when no ancestry snapshot ever observed them.
    _recover_owned_tags
    reap_recorded_owned_sources "$OWNED_SRC_REG"
    sleep 0.05
    _recover_owned_tags
    reap_recorded_owned_sources "$OWNED_SRC_REG"
    for pid in "${waited[@]:-}"; do [ -n "$pid" ] && wait "$pid" 2>/dev/null; done
    [ -n "${LABWC_PID:-}" ] && kill -9 "$LABWC_PID" 2>/dev/null
    [ -n "${LABWC_PID:-}" ] && wait "$LABWC_PID" 2>/dev/null
    LOCK_OWNED=(); OWNED_TAGS=(); LOCK_PID=""; LABWC_PID=""
    : >"$OWNED_SRC_REG"
    sleep 0.3
    return 0
}
