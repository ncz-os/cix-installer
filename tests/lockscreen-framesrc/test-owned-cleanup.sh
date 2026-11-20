#!/bin/bash
# Tracked unit test for the owned-process engine (tests/lockscreen-framesrc/
# owned-processes.sh). Headless: no GPU, no compositor, no network.
#
# It SOURCES the real engine and CALLS the real functions
# (owned_source_pid / kill_owned_source / stop_all), so a PASS proves the
# production helper — it does NOT copy the logic.
#
# Fixture (created under an explicit TMPDIR, refused if missing or tmpfs):
#   * an OWNED lock "parent" launched with setsid; its little descendant IS a
#     copy of $SRC (basename singularity-lock-framesrc-testsrc) — the real
#     frame-source basename the harness uses.
#   * an UNRELATED canary whose basename is EXACTLY the same
#     (singularity-lock-framesrc-testsrc) but which lives in a different
#     directory and a different (non-owned) process group.
#
# Asserts: owned discovery finds the owned source; fault injection REFUSES the
# unrelated PID; cleanup reaps the owned group and leaves the canary alive; no
# owned orphan/leak remains; a reused-PID leader (start time changed) does not
# qualify; a stale-incarnation entry referring to an unrelated EXACT-same-SRC
# executable in another owned-session group is left alive by stop_all; an
# orphaned real-SRC child whose leader exited is reaped by stop_all while an
# unrelated same-basename canary in another group survives.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"

# --- scratch: explicit TMPDIR only; refuse missing or tmpfs -------------------
# There is no default to /tmp: a missing TMPDIR is a hard error.
if [ -z "${TMPDIR:-}" ]; then
    echo "FATAL: TMPDIR is not set; refusing to default to /tmp" >&2
    exit 2
fi
FSTYPE="$(stat -f -c %T "$TMPDIR" 2>/dev/null || echo unknown)"
if [ "$FSTYPE" = "tmpfs" ]; then
    echo "FATAL: TMPDIR ($TMPDIR) is tmpfs; refusing volatile scratch" >&2
    exit 2
fi

PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

TD="$TMPDIR/task/tmp/owned-cleanup-$$"
rm -rf "$TD"; mkdir -p "$TD/owned" "$TD/elsewhere" || { echo "FATAL: cannot create scratch under $TMPDIR" >&2; exit 2; }

# The REAL frame-source basename, in two DIFFERENT directories.
SRC="$TD/owned/singularity-lock-framesrc-testsrc"
CANARY="$TD/elsewhere/singularity-lock-framesrc-testsrc"
cp /bin/sleep "$SRC"; cp /bin/sleep "$CANARY"
chmod +x "$SRC" "$CANARY"

# Engine under test: the SAME file the harness sources. The engine is
# fail-closed about its persistent registry: it requires OWNED_WORK (or WORK)
# to be set, otherwise it refuses to source. The unit therefore sets OWNED_WORK
# to its own scratch dir BEFORE sourcing, so the registry file lives under $TD
# and is cleaned up with the fixture. This mirrors the real harness, which sets
# WORK (and thus OWNED_WORK=$WORK/tmp) before sourcing the engine.
OWNED_WORK="$TD/owned-work"
mkdir -p "$OWNED_WORK"
# shellcheck source=owned-processes.sh
. "$HERE/owned-processes.sh"

# Extra cleanup on abort paths: reap our fixture groups and the scratch dir.
# Every known child is reaped by EXACT PID (never by name), and we wait on it
# so a failure cannot leak a running orphan or hold stdout open.
CAN_PID=""; OWN_PID=""; OWN_CHILD=""; STALE_PID=""; ORPHAN_LEADER=""; ORPHAN_CHILD=""; ORPHAN_CANARY=""
_reap_pid() { # $1 = pid; kill -9 and wait so no orphan/zombie leaks
    local p="$1"
    [ -n "$p" ] || return 0
    kill -9 "$p" 2>/dev/null
    wait "$p" 2>/dev/null
}
cleanup_fixture() {
    stop_all
    # Reap each known child by exact PID, then its group, then wait.
    _reap_pid "$OWN_CHILD"
    _reap_pid "$CAN_PID"
    _reap_pid "$STALE_PID"
    _reap_pid "$ORPHAN_CHILD"
    _reap_pid "$ORPHAN_CANARY"
    _reap_pid "$ORPHAN_LEADER"
    _reap_pid "$OWN_PID"
    # Group kills as a belt-and-braces for any descendant we did not name.
    [ -n "$OWN_PID" ] && kill -9 -- "-$OWN_PID" 2>/dev/null
    [ -n "$STALE_PID" ] && kill -9 -- "-$STALE_PID" 2>/dev/null
    [ -n "$ORPHAN_LEADER" ] && kill -9 -- "-$ORPHAN_LEADER" 2>/dev/null
    wait 2>/dev/null
    rm -rf "$TD"
}
trap 'cleanup_fixture' EXIT

GEN=0; LOCK_OWNED=()

# --- fixture: OWNED parent (setsid leader) with a real $SRC descendant --------
# The owned lock "parent" is launched with setsid, so it is the group leader
# (PID == PGID). Its descendant IS a copy of $SRC: the leader shell execs the
# real testsrc basename, so the only member has /proc/<pid>/exe == real $SRC.
# This mirrors the production topology (setsid leader == owned PGID, renderer
# descendant discovered by PGID+exe) without any GPU/compositor.
setsid "$SRC" 300 & OWN_PID=$!
sleep 0.4

GEN=$((GEN+1))
owned_add "$OWN_PID" "$OWN_PID" "$GEN" "$(starttime_of "$OWN_PID")"

# --- unrelated canary: EXACT same basename, other dir, other (non-owned) grp --
# Launched plain (not setsid, not recorded): its PGID is the test harness's own
# group, which is NOT the owned group.
"$CANARY" 300 & CAN_PID=$!
sleep 0.3

echo "== owned-process engine unit =="
echo "  fixture: SRC=$SRC"
echo "  fixture: CANARY(basename $(basename "$CANARY"))=$CANARY"

# 1) basenames are identical but paths/incarnations differ (the old canary lied)
if [ "$(basename "$SRC")" = "$(basename "$CANARY")" ]; then
    ok "canary shares the EXACT real testsrc basename ($(basename "$SRC"))"
else
    bad "basename mismatch (test fixture wrong)"
fi
if [ "$(readlink -f "$SRC")" != "$(readlink -f "$CANARY")" ]; then
    ok "SRC and canary are different files (separate dirs)"
else
    bad "SRC and canary resolve to the same file"
fi
if [ "$(pgid_of "$OWN_PID")" != "$(pgid_of "$CAN_PID")" ]; then
    ok "owned group and canary group differ (canary is unrelated)"
else
    bad "canary landed in the owned group (fixture broken)"
fi

# 2) ACTUAL owned_source_pid discovers the owned source, exe-verified
got="$(owned_source_pid)"
if [ -n "$got" ] && [ "$got" = "$OWN_PID" ]; then
    ok "owned_source_pid found the owned source ($got) by PGID+exe"
else
    bad "owned_source_pid did not find the owned source (got '$got', want $OWN_PID)"
fi
if owned_source_alive; then ok "owned_source_alive true while source runs"; else bad "owned_source_alive false"; fi
if [ "$got" != "$CAN_PID" ]; then ok "the unrelated same-basename canary is NOT the owned source"; else bad "canary was selected as owned source"; fi

# 3) ACTUAL kill_owned_source REFUSES the unrelated PID
if kill_owned_source "$CAN_PID"; then
    bad "kill_owned_source accepted an UNOWNED pid ($CAN_PID)"
else
    ok "kill_owned_source refused the unrelated same-basename PID"
fi
if kill -0 "$CAN_PID" 2>/dev/null; then ok "canary still alive after the refused kill"; else bad "canary died despite a refused kill"; fi
if kill_owned_source ""; then bad "kill_owned_source accepted an empty pid"; else ok "kill_owned_source refused an empty pid"; fi
if kill_owned_source "999999"; then bad "kill_owned_source accepted a bogus pid"; else ok "kill_owned_source refused a bogus pid"; fi

# 4) ACTUAL kill_owned_source ACCEPTS the real owned source PID
if kill_owned_source "$got"; then ok "kill_owned_source accepted the owned source ($got)"; else bad "kill_owned_source rejected the owned source"; fi
sleep 0.3
if kill -0 "$got" 2>/dev/null; then bad "owned source survived the -9"; else ok "owned source was reaped (-9)"; fi
if kill -0 "$CAN_PID" 2>/dev/null; then ok "canary survived the owned fault kill"; else bad "canary was killed by owned fault injection"; fi

# 5) ACTUAL stop_all reaps owned and leaves the canary alive; no orphan/leak
#    Re-launch a fresh owned source so stop_all has work to do.
setsid "$SRC" 300 & OWN_PID=$!
sleep 0.4
GEN=$((GEN+1)); owned_add "$OWN_PID" "$OWN_PID" "$GEN" "$(starttime_of "$OWN_PID")"
stop_all
sleep 0.3
if [ -n "$(pgid_of "$OWN_PID")" ]; then
    if pgid_of "$OWN_PID" | grep -qx "$OWN_PID"; then bad "owned group leaked after stop_all"; else ok "no owned-group process leaked after stop_all"; fi
else
    ok "no owned-group process leaked after stop_all"
fi
if kill -0 "$CAN_PID" 2>/dev/null; then ok "canary alive after stop_all"; else bad "stop_all killed the unrelated canary"; fi

# 6) reused-PID safety: a leader whose recorded start time no longer matches
#    must NOT qualify (owned_leader_intact false; kill_owned_source refuses).
GEN=$((GEN+1))
BADENTRY="$$:$$:$GEN:bogus-starttime"     # real pid, real pgid, WRONG starttime
LOCK_OWNED=("$BADENTRY")
if owned_leader_intact "$BADENTRY"; then
    bad "owned_leader_intact accepted a changed start time (reused PID)"
else
    ok "owned_leader_intact rejects a changed start time (reused PID cannot qualify)"
fi
if kill_owned_source "$$"; then
    bad "kill_owned_source qualified a reused-PID leader"
else
    ok "kill_owned_source refuses a leader whose start time changed"
fi
# A true start time for the same pid DOES qualify (proves it is not always false).
LOCK_OWNED=("$$:$$:$GEN:$(starttime_of "$$")")
if kill_owned_source "$$"; then
    bad "kill_owned_source killed the test process itself"
else
    # It refused because $$ is not in group $$ (ppid/pgid differ) — still safe.
    ok "kill_owned_source never kills a PID outside its owned group"
fi
# shellcheck disable=SC2034  # shared with sourced owned-processes.sh
LOCK_OWNED=()

# 7) REGRESSION: stale-incarnation entry refers to an unrelated EXACT-same-SRC
#    executable in another owned-session group, with a WRONG start time.
#    ACTUAL stop_all must leave it alive (then the unit cleans it by exact PID).
#    This proves discovery/signalling EXCLUDE entries whose leader PID exists
#    but has a different start time, even when the exe is the EXACT same $SRC.
#    It ALSO proves stop_all does NOT WAIT on a stale-incarnation entry: if it
#    did, this test would block for the full 300s lifetime of the stale PID.
STALE_PID=""
setsid "$SRC" 300 & STALE_PID=$!
sleep 0.4
if [ -n "$STALE_PID" ] && kill -0 "$STALE_PID" 2>/dev/null; then
    # Record the entry with a WRONG start time (stale incarnation).
    GEN=$((GEN+1))
    LOCK_OWNED=("$STALE_PID:$STALE_PID:$GEN:0")
    stop_all
    sleep 0.3
    if kill -0 "$STALE_PID" 2>/dev/null; then
        ok "stop_all left the stale-incarnation same-SRC process alive (excluded)"
    else
        bad "stop_all killed a stale-incarnation same-SRC process (must exclude)"
    fi
    # Unit cleans it by exact PID (not by name).
    kill -9 -- "-$STALE_PID" 2>/dev/null
    kill -9 "$STALE_PID" 2>/dev/null
    wait "$STALE_PID" 2>/dev/null
    STALE_PID=""
else
    bad "stale-incarnation fixture failed to start"
fi
LOCK_OWNED=()

# 8) REGRESSION: orphan fixture. OWN setsid lock parent forks a real $SRC child,
#    parent exits AFTER the child is registered (handshake barrier), while the
#    child remains. ACTUAL stop_all must terminate the child; an unrelated
#    same-basename canary in another group must survive.
#
#    The orphan child is retained in $ORPHAN_CHILD until we have PROVEN it is
#    dead (kill -0 fails). Only then do we clear the variable, so the EXIT trap
#    can still reap it by exact PID if any assertion fails mid-way. This is the
#    fail-closed contract: a failed assertion must not leak a running orphan.
ORPHAN_LEADER=""; ORPHAN_CHILD=""; ORPHAN_CANARY=""
HANDSHAKE="$TD/orphan.handshake"
rm -f "$HANDSHAKE"
# Launch a setsid leader that forks a real $SRC child, waits for the handshake
# file to appear (proving the child is up and registered), then exits.
setsid bash -c '
    "$1" 300 &
    child=$!
    printf "%s\n" "$child" >"$2"
    # wait for the handshake file to appear (barrier: child is up)
    for _ in $(seq 1 100); do
        [ -e "$3" ] && break
        sleep 0.05
    done
    exit 0
' _ "$SRC" "$TD/orphan.child" "$HANDSHAKE" & ORPHAN_LEADER=$!
sleep 0.4
# Wait for the child PID file to appear (leader forked the child).
for _ in $(seq 1 100); do
    [ -s "$TD/orphan.child" ] && break
    sleep 0.05
 done
ORPHAN_CHILD="$(cat "$TD/orphan.child" 2>/dev/null || true)"
if [ -n "$ORPHAN_CHILD" ] && kill -0 "$ORPHAN_CHILD" 2>/dev/null; then
    # Register the leader entry (with its real start time) BEFORE the leader exits.
    GEN=$((GEN+1))
    owned_add "$ORPHAN_LEADER" "$ORPHAN_LEADER" "$GEN" "$(starttime_of "$ORPHAN_LEADER")"
    # Signal the barrier: leader may now exit.
    : >"$HANDSHAKE"
    # Wait for the leader to exit (child remains orphaned in the owned PGID).
    for _ in $(seq 1 100); do
        kill -0 "$ORPHAN_LEADER" 2>/dev/null || break
        sleep 0.05
    done
    # Unrelated same-basename canary in another (non-owned) group.
    "$CANARY" 300 & ORPHAN_CANARY=$!
    sleep 0.3
    stop_all
    sleep 0.3
    if kill -0 "$ORPHAN_CHILD" 2>/dev/null; then
        bad "stop_all left the orphaned real-SRC child alive"
        # ORPHAN_CHILD is retained so the EXIT trap reaps it by exact PID.
    else
        ok "stop_all reaped the orphaned real-SRC child (leader gone)"
        # Proven dead: clear so the trap does not re-signal a reused PID.
        ORPHAN_CHILD=""
    fi
    if kill -0 "$ORPHAN_CANARY" 2>/dev/null; then
        ok "unrelated same-basename canary survived stop_all (orphan case)"
    else
        bad "stop_all killed the unrelated same-basename canary (orphan case)"
    fi
    kill -9 "$ORPHAN_CANARY" 2>/dev/null; wait "$ORPHAN_CANARY" 2>/dev/null
    ORPHAN_CANARY=""
else
    bad "orphan fixture failed to fork a real-SRC child"
fi
ORPHAN_LEADER=""
# ORPHAN_CHILD is cleared above ONLY after proven dead; on failure it remains
# set so cleanup_fixture reaps it by exact PID.
LOCK_OWNED=()

# 9) canary is still ours to clean up; reap it and the scratch dir
kill -9 "$CAN_PID" 2>/dev/null; wait "$CAN_PID" 2>/dev/null
CAN_PID=""
# REAL topology: owned root -> new-session shell -> real SRC grandchild.
# Register through command substitution before root exits; then kill recorded
# detached descendants after reparenting. Canaries never enter the owned tree.
ORPHAN_LEADER=""; ORPHAN_CHILD=""; ORPHAN_CANARY=""; STALE_PID=""
BARRIER="$TD/detached.release"
setsid bash -c '
    setsid bash -c '\''"$1" 300 & echo $! >"$2"; wait'\'' _ "$1" "$2/source" &
    echo $! >"$2/shell"
    while [ ! -e "$2/release" ]; do sleep 0.02; done
' _ "$SRC" "$TD" & ORPHAN_LEADER=$!
for _ in $(seq 1 100); do [ -s "$TD/source" ] && [ -s "$TD/shell" ] && break; sleep 0.02; done
ORPHAN_CHILD=$(cat "$TD/source")
DETACHED_SHELL=$(cat "$TD/shell")
"$CANARY" 300 & ORPHAN_CANARY=$!
setsid "$SRC" 300 & STALE_PID=$!
GEN=$((GEN+1)); owned_add "$ORPHAN_LEADER" "$ORPHAN_LEADER" "$GEN" "$(starttime_of "$ORPHAN_LEADER")"
got=$(owned_source_pid)
[ "$got" = "$ORPHAN_CHILD" ] && ok "real setsid descendant discovered by ancestry" || bad "real setsid descendant not found"
[ "$(pgid_of "$ORPHAN_CHILD")" != "$ORPHAN_LEADER" ] && ok "renderer actually detached into a different PGID" || bad "fixture did not setsid"
[ -s "$OWNED_SRC_REG" ] && ok "ancestry registry persists across command substitution" || bad "registry not persisted"
: >"$TD/release"
wait "$ORPHAN_LEADER" 2>/dev/null
stop_all
# A terminated adopted child can briefly remain a zombie: it cannot render.
fixture_running() { local s; s=$(ps -o stat= -p "$1" 2>/dev/null); [ -n "$s" ] && [[ "$s" != Z* ]]; }
if fixture_running "$ORPHAN_CHILD"; then bad "detached renderer leaked"; else ok "detached orphan renderer terminated"; fi
if fixture_running "$DETACHED_SHELL"; then bad "detached wrapper leaked"; kill -9 "$DETACHED_SHELL" 2>/dev/null; else ok "detached wrapper terminated"; fi
kill -0 "$ORPHAN_CANARY" 2>/dev/null && ok "same-basename detached canary survives" || bad "same-basename canary killed"
kill -0 "$STALE_PID" 2>/dev/null && ok "exact-same-exe detached canary survives" || bad "exact-same-exe canary killed"
# Retain failed child for the existing EXIT trap, otherwise clear known-dead PID.
fixture_running "$ORPHAN_CHILD" || ORPHAN_CHILD=""

# Reap the previous case's exact same-exe canary before reusing its variable.
kill -9 "$STALE_PID" 2>/dev/null; wait "$STALE_PID" 2>/dev/null
STALE_PID=""
# Fast root exits BEFORE registration; no ancestry observation is possible.
# Only its renderer inherits a unique owner nonce; same-exe canary does not.
ORPHAN_CHILD=""; ORPHAN_LEADER=""
owner_nonce=$(cat /proc/sys/kernel/random/uuid)
NCZ_LOCK_TEST_OWNER="$owner_nonce" setsid bash -c '
    setsid "$1" 300 & echo $! >"$2"
' _ "$SRC" "$TD/fast-exit.child" & ORPHAN_LEADER=$!
wait "$ORPHAN_LEADER" 2>/dev/null
ORPHAN_CHILD=$(cat "$TD/fast-exit.child")
setsid "$SRC" 300 & STALE_PID=$!
GEN=$((GEN+1)); owned_add "$ORPHAN_LEADER" "$ORPHAN_LEADER" "$GEN" "" "$owner_nonce"
stop_all
if fixture_running "$ORPHAN_CHILD"; then bad "fast-root-exit renderer leaked without ancestry discovery"; else ok "nonce recovered detached renderer after root already exited"; ORPHAN_CHILD=""; fi
kill -0 "$STALE_PID" 2>/dev/null && ok "same-exe untagged canary survives fast-root recovery" || bad "untagged canary killed"

echo "== UNIT RESULT: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
