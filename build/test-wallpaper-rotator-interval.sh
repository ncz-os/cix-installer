#!/bin/bash
# test-wallpaper-rotator-interval.sh -- regression test for the 2026-10-11 fix:
# the wallpaper daemon must NOT rotate merely because it (re)started.
#
# Why this exists: ncz-wallpaper-daemon ran `ncz-wallpaper-rotate` as its very
# first action, so every login, every session restart and every crash-loop spin
# (live O6N, shell crash loop) changed the wallpaper. Rotation is now gated on a
# persisted $XDG_STATE_HOME/ncz-wallpaper/last-rotate timestamp:
#
#   * restart inside the interval           -> no rotation
#   * restart after the interval elapsed    -> one rotation
#   * no state file (brand-new user)        -> one rotation, and it is recorded
#   * corrupt / future / leading-zero state -> one rotation (never blocked)
#   * rotate-enabled=0                      -> no rotation
#   * the start-up aspect re-fit still runs in every case.
#
# It extracts the real DAEMON heredoc from post-install/45-wallpaper-rotator.sh
# and runs it against a fake clock (a `date` shim) and a counting fake
# ncz-wallpaper-rotate, each case in its own HOME/XDG dirs. A negative
# self-check runs the pre-fix start action and shows it rotates inside the
# interval, so this test would have caught the live regression.
#
# Run: bash build/test-wallpaper-rotator-interval.sh
# Exit 0 = all cases passed; 1 = at least one failed; 2 = a source file is
# missing.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$REPO/post-install/45-wallpaper-rotator.sh"
[ -r "$HOOK" ] || { echo "FATAL: cannot read $HOOK" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      /'; }

# Extract a quoted heredoc body (marker in $2) from a shell source file.
extract_heredoc() {
    awk -v m="$2" '
        $0 ~ "<<.?" m "." { f=1; next }
        f && $0 == m { f=0 }
        f { print }
    ' "$1"
}

T="$(mktemp -d)" || exit 2
trap 'rm -rf "$T"' EXIT

BIN="$T/bin"; mkdir -p "$BIN"
# Fake clock: `date +%s` returns the epoch the test pinned in NCZ_FAKE_NOW.
cat > "$BIN/date" <<'EOF'
#!/bin/sh
printf '%s\n' "${NCZ_FAKE_NOW:-0}"
EOF
# Fake sleep: the clock is frozen, so no amount of loop iteration can make the
# daemon rotate again -- the loop only ever sees the same timestamp. Spinning
# it fast just yields a core, so each "sleep" is a short real pause instead of
# the daemon's 2s warm-up + 15s tick. This keeps the test quick without
# touching the decision logic under test.
cat > "$BIN/sleep" <<'EOF'
#!/bin/sh
exec /bin/sleep 0.2
EOF
# Fake rotate binary: counts real rotations; counts --refit separately.
cat > "$BIN/ncz-wallpaper-rotate" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "--refit" ]; then
    printf 'refit\n' >> "${NCZ_TEST_COUNTER}.refit"
    exit 0
fi
printf 'rotate\n' >> "$NCZ_TEST_COUNTER"
EOF
chmod 0755 "$BIN/date" "$BIN/sleep" "$BIN/ncz-wallpaper-rotate"

DAEMON="$T/ncz-wallpaper-daemon"
extract_heredoc "$HOOK" DAEMON > "$DAEMON"
[ -s "$DAEMON" ] || { echo "FATAL: DAEMON heredoc not found in $HOOK" >&2; exit 2; }

NOW="$(date +%s)"   # the real clock, pinned into the fake one
RUN_TIMEOUT=2       # generous vs the frozen-clock 0.2s warm-up

count() {  # lines in a counter file
    if [ -f "$1" ]; then grep -c . "$1"; else echo 0; fi
}

# run_daemon <home> <cfg> <state> <run> <counter>
run_daemon() {
    env HOME="$1" XDG_CONFIG_HOME="$2" XDG_STATE_HOME="$3" XDG_RUNTIME_DIR="$4" \
        PATH="$BIN:$PATH" NCZ_FAKE_NOW="$NOW" \
        NCZ_WALLPAPER_ROTATE="$BIN/ncz-wallpaper-rotate" \
        NCZ_TEST_COUNTER="$5" \
        timeout "$RUN_TIMEOUT" sh "$DAEMON" >/dev/null 2>&1
}

# run_case NAME <state: MISSING|VALUE> <interval> <enabled> <expected_rotations>
# Also asserts the start-up re-fit ran (it must survive the fix).
run_case() {
    local name="$1" state="$2" interval="$3" enabled="$4" want="$5"
    local base="$T/case" home="$T/case/home" cfg="$T/case/config" \
          st="$T/case/state" run="$T/case/run" counter="$T/case/rotate.calls"
    rm -rf "$base"
    mkdir -p "$home" "$cfg/singularity/wallpaper-rotation" "$st" "$run"
    printf '%s\n' "$interval" > "$cfg/singularity/wallpaper-rotation/rotate-interval"
    printf '%s\n' "$enabled"  > "$cfg/singularity/wallpaper-rotation/rotate-enabled"
    if [ "$state" != MISSING ]; then
        mkdir -p "$st/ncz-wallpaper"
        printf '%s\n' "$state" > "$st/ncz-wallpaper/last-rotate"
    fi
    run_daemon "$home" "$cfg" "$st" "$run" "$counter"
    local got refits
    got=$(count "$counter")
    refits=$(count "$counter.refit")
    if [ "$got" = "$want" ]; then
        ok "$name (rotations=$got)"
    else
        bad "$name" "want $want rotation(s), got $got"
    fi
    if [ "$refits" -ge 1 ]; then
        ok "$name: aspect re-fit still ran on start (refits=$refits)"
    else
        bad "$name: aspect re-fit did not run on start"
    fi
}

# ---- the matrix ------------------------------------------------------------
run_case "restart inside the interval -> no rotation"          "$((NOW - 100))" 600 1 0
run_case "restart after the interval -> one rotation"          "$((NOW - 700))" 600 1 1
run_case "restart exactly at the interval -> one rotation"     "$((NOW - 600))" 600 1 1
run_case "one second before the interval -> no rotation"       "$((NOW - 599))" 600 1 0
run_case "no state file (brand-new user) -> one rotation"      MISSING          600 1 1
run_case "corrupt state -> one rotation"                       "not-a-timestamp" 600 1 1
run_case "future timestamp (clock step back) -> one rotation"  "$((NOW + 100000))" 600 1 1
run_case "leading-zero numeric state -> one rotation"          "007"            600 1 1
run_case "rotation disabled + elapsed -> no rotation"          "$((NOW - 700))" 600 0 0
run_case "rotation disabled + no state -> no rotation"         MISSING          600 0 0
run_case "interval floor: <30s is clamped up (elapsed 31 -> 1)" "$((NOW - 31))"  1  1 1
run_case "interval floor: <30s is clamped up (elapsed 10 -> 0)" "$((NOW - 10))"  1  1 0

# ---- the schedule is persisted across restarts -----------------------------
base="$T/persist"; home="$base/home"; cfg="$base/config"
st="$base/state"; run="$base/run"; counter="$base/rotate.calls"
rm -rf "$base"
mkdir -p "$home" "$cfg/singularity/wallpaper-rotation" "$st" "$run"
printf '600\n' > "$cfg/singularity/wallpaper-rotation/rotate-interval"
printf '1\n'   > "$cfg/singularity/wallpaper-rotation/rotate-enabled"
mkdir -p "$st/ncz-wallpaper"; printf '%s\n' "$((NOW - 700))" > "$st/ncz-wallpaper/last-rotate"
run_daemon "$home" "$cfg" "$st" "$run" "$counter"
first=$(count "$counter")
if [ "$first" = 1 ]; then ok "persist: first start after the interval rotates once"; else bad "persist: first start" "want 1, got $first"; fi
if [ "$(cat "$st/ncz-wallpaper/last-rotate" 2>/dev/null)" = "$NOW" ]; then
    ok "persist: rotation time recorded atomically as the current epoch"
else
    bad "persist: last-rotate not updated" "got '$(cat "$st/ncz-wallpaper/last-rotate" 2>/dev/null)' want '$NOW'"
fi
# Immediate restart: the record now shows a rotation "just now", so no rotation.
run_daemon "$home" "$cfg" "$st" "$run" "$counter"
second=$(count "$counter")
if [ "$second" = 1 ]; then
    ok "persist: immediate restart rotates 0 more times (total stays 1)"
else
    bad "persist: immediate restart rotated again" "total=$second want 1"
fi

# ---- negative self-check: the pre-fix daemon rotates inside the interval ----
# The pre-fix start action in isolation. It must rotate even though the state
# says a rotation happened 100s ago, which is what broke every login.
OLD="$T/old-daemon"
cat > "$OLD" <<'OLD'
#!/bin/sh
ROTATE=${NCZ_WALLPAPER_ROTATE:-/usr/local/bin/ncz-wallpaper-rotate}
sleep 1
"$ROTATE"
OLD
base="$T/oldcase"; home="$base/home"; cfg="$base/config"
st="$base/state"; run="$base/run"; oldcounter="$base/rotate.calls"
rm -rf "$base"
mkdir -p "$home" "$cfg/singularity/wallpaper-rotation" "$st/ncz-wallpaper" "$run"
printf '600\n' > "$cfg/singularity/wallpaper-rotation/rotate-interval"
printf '1\n'   > "$cfg/singularity/wallpaper-rotation/rotate-enabled"
printf '%s\n' "$((NOW - 100))" > "$st/ncz-wallpaper/last-rotate"
env HOME="$home" XDG_CONFIG_HOME="$cfg" XDG_STATE_HOME="$st" XDG_RUNTIME_DIR="$run" \
    PATH="$BIN:$PATH" NCZ_FAKE_NOW="$NOW" \
    NCZ_WALLPAPER_ROTATE="$BIN/ncz-wallpaper-rotate" \
    NCZ_TEST_COUNTER="$oldcounter" \
    timeout "$RUN_TIMEOUT" sh "$OLD" >/dev/null 2>&1
oldgot=$(count "$oldcounter")
if [ "$oldgot" -ge 1 ]; then
    ok "self-check: pre-fix daemon DOES rotate inside the interval (bug reproduced)"
else
    bad "self-check: pre-fix daemon did not rotate (test cannot catch the bug)"
fi

echo
echo "wallpaper-rotator interval tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
