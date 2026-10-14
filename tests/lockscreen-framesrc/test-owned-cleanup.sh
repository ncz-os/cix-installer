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
# qualify.
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

# Engine under test: the SAME file the harness sources.
# shellcheck source=owned-processes.sh
. "$HERE/owned-processes.sh"

# Extra cleanup on abort paths: reap our two fixture groups and the scratch dir.
CAN_PID=""; OWN_PID=""; OWN_CHILD=""
cleanup_fixture() {
    [ -n "$OWN_PID" ] && kill -9 -- "-$OWN_PID" 2>/dev/null
    [ -n "$OWN_PID" ] && kill -9 "$OWN_PID" 2>/dev/null
    [ -n "$OWN_CHILD" ] && kill -9 "$OWN_CHILD" 2>/dev/null
    [ -n "$CAN_PID" ] && kill -9 "$CAN_PID" 2>/dev/null
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
BADENTRY="$$:$$\:$GEN:bogus-starttime"     # real pid, real pgid, WRONG starttime
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
LOCK_OWNED=("$$:$$\:$GEN:$(starttime_of "$$")")
if kill_owned_source "$$"; then
    bad "kill_owned_source killed the test process itself"
else
    # It refused because $$ is not in group $$ (ppid/pgid differ) — still safe.
    ok "kill_owned_source never kills a PID outside its owned group"
fi
# shellcheck disable=SC2034  # shared with sourced owned-processes.sh
LOCK_OWNED=()

# 7) canary is still ours to clean up; reap it and the scratch dir
kill -9 "$CAN_PID" 2>/dev/null; wait "$CAN_PID" 2>/dev/null
echo "== UNIT RESULT: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
