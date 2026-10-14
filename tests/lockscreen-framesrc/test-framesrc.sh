#!/bin/bash
# Headless labwc test for the lock client's out-of-process frame source.
#
# Runs INSIDE a debian:forky container with: labwc, wtype, wayland-utils, grim,
# python3 + python3-pil, and the three binaries built by build.sh, all under
# /work. It drives a real labwc (WLR_BACKENDS=headless) and a real lock client,
# and asserts on the lock's own stderr log and on real screen captures. Restarts
# labwc per case so a lock left held never wedges the next case.
#
# OWNED-PROCESS CONTRACT (no broad pkill/pgrep -f anywhere):
#   Every lock client is launched with `setsid`, so it and every frame-source
#   descendant it spawns live in ONE fresh process group whose PGID == the lock
#   PID (the group leader), recorded as the owned PGID. The renderer is
#   discovered ONLY by walking /proc for members of that owned group and
#   confirming /proc/<pid>/exe resolves to the real $SRC. Fault injection and
#   cleanup signal only owned PIDs/PGIDs and wait for them; an unrelated process
#   that merely shares the testsrc basename is never matched or killed.
set -u

WORK="${WORK:-/work}"
RT="$WORK/tmp/xdg"
SOCK="$RT/lfs.sock"
LOCK="${LOCK:-$WORK/singularity-lockscreen-on}"
LOCKOFF="${LOCKOFF:-$WORK/singularity-lockscreen-off}"
SRC="${SRC:-$WORK/singularity-lock-framesrc-testsrc}"

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
have() { grep -qF -- "$2" "$1" 2>/dev/null; }

mkdir -p "$RT"; chmod 700 "$RT"
export XDG_RUNTIME_DIR="$RT"
export WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_HEADLESS_OUTPUTS=1
export WLR_RENDERER=pixman WLR_NO_HARDWARE_CURSORS=1
unset WAYLAND_DISPLAY

LABWC_PID=""
LOCK_OWNED=()   # one entry per live lock launch: "PID:PGID:GENERATION"
GEN=0

# --- owned-process engine -----------------------------------------------------
owned_add() { LOCK_OWNED+=("$1:$2:$3"); }                 # pid:pgid:generation
owned_pid() {
    local last="${LOCK_OWNED[${#LOCK_OWNED[@]}-1]:-}"; [ -n "$last" ] || return 1
    echo "${last%%:*}"
}
owned_pgid() {
    local last="${LOCK_OWNED[${#LOCK_OWNED[@]}-1]:-}"; [ -n "$last" ] || return 1
    local rest="${last#*:}"; echo "${rest%%:*}"
}
owned_gen() {
    local last="${LOCK_OWNED[${#LOCK_OWNED[@]}-1]:-}"; [ -n "$last" ] || return 1
    echo "${last##*:}"
}
# true if $1 is a PID of a lock client we launched (any generation)
owned_lock_pid() {
    local pid="$1" e
    for e in "${LOCK_OWNED[@]:-}"; do
        [ -n "$e" ] || continue; [ "${e%%:*}" = "$pid" ] && return 0
    done
    return 1
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
    owned_sources_in_pgid "$pgid" | head -1
}
owned_source_alive() { [ -n "$(owned_source_pid)" ]; }

# Fault injection: kill exactly ONE owned source PID. Refuses any PID not in an
# owned group, so a stray kill can never take an unrelated process.
kill_owned_source() { # $1 = pid
    local pid="$1" e pgid
    [ -n "$pid" ] || return 1
    for e in "${LOCK_OWNED[@]:-}"; do
        [ -n "$e" ] || continue
        pgid="${e#*:}"; pgid="${pgid%%:*}"
        [ "$(pgid_of "$pid")" = "$pgid" ] && { kill -9 "$pid" 2>/dev/null; return 0; }
    done
    return 1
}

LABWC_PID=""
start_labwc() {
    rm -f "$RT"/wayland-* "$SOCK"
    labwc >"$WORK/tmp/labwc.log" 2>&1 &
    LABWC_PID=$!
    for _ in $(seq 1 50); do
        [ -S "$RT/wayland-0" ] && export WAYLAND_DISPLAY=wayland-0 && return 0
        [ -S "$RT/wayland-1" ] && export WAYLAND_DISPLAY=wayland-1 && return 0
        sleep 0.1
    done
    echo "labwc did not create a wayland socket"; return 1
}

# Kill every owned lock group and PIDs we recorded, then the labwc we started.
# `kill -- -PGID` targets ONLY the owned group; we then wait for each owned PID
# so no zombie leaks into the next case. Never a name scan.
stop_all() {
    local e pid pgid
    for e in "${LOCK_OWNED[@]:-}"; do
        [ -n "$e" ] || continue
        pid="${e%%:*}"; pgid="${e#*:}"; pgid="${pgid%%:*}"
        [ -n "$pgid" ] && kill -9 -- "-$pgid" 2>/dev/null
        [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null
    done
    for e in "${LOCK_OWNED[@]:-}"; do
        [ -n "$e" ] || continue
        pid="${e%%:*}"
        [ -n "$pid" ] && wait "$pid" 2>/dev/null
    done
    [ -n "$LABWC_PID" ] && kill -9 "$LABWC_PID" 2>/dev/null
    [ -n "$LABWC_PID" ] && wait "$LABWC_PID" 2>/dev/null
    LOCK_OWNED=(); LOCK_PID=""; LABWC_PID=""
    sleep 0.3
    return 0
}
trap 'stop_all' EXIT

# Launch an owned lock via setsid. $1=env renderer value, $2=log, $3=delay ms.
# Records PID/PGID/generation; LOCK_PID mirrors the owned PID.
start_lock() {
    local cmd="$1" log="$2" delay="${3:-2500}"
    : >"$log"; : >"$log.lfs"
    GEN=$((GEN+1))
    SINGULARITY_LOCK_RENDERER="$cmd" \
    SINGULARITY_LOCK_RENDERER_SOCKET="$SOCK" \
    SINGULARITY_LOCK_RENDERER_LOG="${log}.lfs" \
    SINGULARITY_LOCK_RENDERER_DELAY_MS="$delay" \
    setsid "$LOCK" >>"$log" 2>&1 &
    LOCK_PID=$!
    owned_add "$LOCK_PID" "$LOCK_PID" "$GEN"   # setsid: leader PID == PGID
}
wait_for() { local f="$1" s="$2" secs="${3:-5}"
    for _ in $(seq 1 $(( secs * 10 ))); do have "$f" "$s" && return 0; sleep 0.1; done
    return 1
}
frame_count() { grep -c "testsrc: frame seq=" "$1" 2>/dev/null || true; }
alive() { kill -0 "$1" 2>/dev/null; }

# Sample corners of a capture; exit 0 if the backdrop is anything but one flat
# colour. A live/held saver paints a pattern; the fail-closed flat fill does not.
backdrop_is_live() { # $1 = png
    python3 - "$1" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
w, h = im.size
regions = [(0, 0, w // 6, h // 6), (w - w // 6, 0, w, h // 6),
           (0, h - h // 6, w // 6, h), (w - w // 6, h - h // 6, w, h)]
mn, mx = 255, 0
for (x0, y0, x1, y1) in regions:
    for x in range(x0, x1, max(1, (x1 - x0) // 12)):
        for y in range(y0, y1, max(1, (y1 - y0) // 12)):
            for c in im.getpixel((x, y)):
                mn = min(mn, c); mx = max(mx, c)
print("corner_range=%d" % (mx - mn))
sys.exit(0 if (mx - mn) > 20 else 1)
PY
}

echo "== probe: labwc globals =="
if ! start_labwc; then echo "FATAL: no headless labwc"; exit 1; fi
wayland-info 2>/dev/null | grep -o "ext_session_lock_manager_v1" | head -1 \
    && ok "labwc advertises ext_session_lock_manager_v1" \
    || bad "labwc does NOT advertise ext_session_lock_manager_v1"
stop_all

echo "== case 1: frames render; input raises the prompt and freezes the saver =="
start_labwc || exit 1
start_lock "$SRC --frames 400" "$WORK/tmp/c1.log" 4000
if wait_for "$WORK/tmp/c1.log" "frame source accepted" 6; then ok "lock accepted the frame source"; else bad "lock did not accept the frame source"; fi
if wait_for "$WORK/tmp/c1.log" "testsrc: frame seq=" 4; then ok "frame source rendered frames"; else bad "no frames rendered"; fi
sleep 1
f0=$(frame_count "$WORK/tmp/c1.log")
if [ "${f0:-0}" -ge 3 ]; then ok "multiple frames streamed ($f0)"; else bad "too few frames ($f0)"; fi
if alive "$LOCK_PID"; then ok "lock client alive while presenting"; else bad "lock client died"; fi
# A key press must RAISE THE PROMPT and FREEZE the saver at this frame (policy:
# the saver never resumes while locked). wtype races the seat gaining the
# keyboard capability, so retry a few times.
for _ in 1 2 3 4 5; do
    wtype -d 300 -k a >/dev/null 2>&1
    have "$WORK/tmp/c1.log" "prompt raised over saver" && break
    sleep 0.3
done
if have "$WORK/tmp/c1.log" "prompt raised over saver"; then ok "input raised the prompt"; else bad "input did not raise the prompt"; fi
if wait_for "$WORK/tmp/c1.log" "frozen on demand" 4; then ok "input froze the saver at the current frame"; else bad "input did not freeze the saver"; fi
if have "$WORK/tmp/c1.log" "frame source failed"; then bad "the freeze was treated as a fault"; else ok "the freeze was not treated as a fault"; fi
# The saver must STOP rendering behind the prompt (freeze, not keep streaming).
fa=$(frame_count "$WORK/tmp/c1.log"); sleep 1; fb=$(frame_count "$WORK/tmp/c1.log")
if [ "${fb:-0}" -le "${fa:-0}" ]; then ok "saver stopped rendering after the freeze ($fa -> $fb)"; else bad "frames kept streaming behind the prompt ($fa -> $fb)"; fi
if grim "$WORK/tmp/c1-prompt.png" >/dev/null 2>&1; then
    if rng=$(backdrop_is_live "$WORK/tmp/c1-prompt.png"); then ok "prompt backdrop is the held frame ($rng)"; else bad "prompt backdrop is the flat fill ($rng)"; fi
else
    bad "grim could not capture the locked screen"
fi
if alive "$LOCK_PID"; then ok "lock client alive after input"; else bad "lock died on input"; fi
# Once the prompt has been idle for the delay it lowers and the saver resumes: a
# fresh source is started, frames stream, the lock stays held throughout.
if wait_for "$WORK/tmp/c1.log" "frame source resumed (prompt lowered)" 8; then ok "prompt idle: the frozen saver was resumed"; else bad "the frozen saver was not resumed after the prompt lowered"; fi
if wait_for "$WORK/tmp/c1.log" "prompt lowered; saver frames resumed" 4; then ok "prompt lowered over the resumed saver"; else bad "prompt did not lower"; fi
fr0=$(frame_count "$WORK/tmp/c1.log")
for _ in $(seq 1 40); do fr1=$(frame_count "$WORK/tmp/c1.log"); [ "${fr1:-0}" -gt $(( ${fr0:-0} + 3 )) ] && break; sleep 0.1; done
if [ "${fr1:-0}" -gt $(( ${fr0:-0} + 3 )) ]; then ok "frames stream again after the resume ($fr0 -> $fr1)"; else bad "no new frames after the resume ($fr0 -> ${fr1:-0})"; fi
if have "$WORK/tmp/c1.log" "cleared frames (fail-closed)"; then bad "the resume cleared the frame (fail-closed path)"; else ok "the resume did not clear the held frame"; fi
if alive "$LOCK_PID"; then ok "lock client alive after the resume"; else bad "lock died on the resume"; fi
# Input again freezes the resumed saver.
for _ in 1 2 3 4 5; do
    wtype -d 300 -k a >/dev/null 2>&1
    [ "$(grep -c "frozen on demand" "$WORK/tmp/c1.log")" -ge 2 ] && break
    sleep 0.3
done
if [ "$(grep -c "frozen on demand" "$WORK/tmp/c1.log")" -ge 2 ]; then ok "input froze the resumed saver again"; else bad "input did not freeze the resumed saver"; fi
stop_all

echo "== case 2: feed kill -9 => lock held and the prompt still works =="
start_labwc || exit 1
start_lock "$SRC --frames 400" "$WORK/tmp/c2.log" 3000
wait_for "$WORK/tmp/c2.log" "frame source accepted" 6 || true
testsrc_pid="$(owned_source_pid)"   # ONLY the owned group, exe-verified
if [ -n "$testsrc_pid" ] && kill_owned_source "$testsrc_pid"; then ok "killed the owned frame source (-9)"; else bad "owned frame source pid not found"; fi
if wait_for "$WORK/tmp/c2.log" "frame source failed" 4 || wait_for "$WORK/tmp/c2.log" "exited status" 2; then ok "lock noticed the dead frame source"; else bad "lock did not notice the dead source"; fi
sleep 0.5
if alive "$LOCK_PID"; then ok "lock client still alive after saver -9 (fail-closed)"; else bad "lock client died with the saver"; fi
for _ in 1 2 3 4 5; do
    wtype -d 300 -k a >/dev/null 2>&1
    have "$WORK/tmp/c2.log" "prompt raised over saver" && break
    sleep 0.3
done
if have "$WORK/tmp/c2.log" "prompt raised over saver"; then ok "prompt works after the feed crash"; else bad "prompt did not work after the feed crash"; fi
if alive "$LOCK_PID"; then ok "lock still held after input post-crash"; else bad "lock died on input post-crash"; fi
stop_all

echo "== case 3: hung saver -> frame watchdog =="
start_labwc || exit 1
start_lock "$SRC --hang=2" "$WORK/tmp/c3.log"
wait_for "$WORK/tmp/c3.log" "testsrc: hanging" 6 || true
if wait_for "$WORK/tmp/c3.log" "frame watchdog" 6; then ok "frame watchdog fired on a hung saver"; else bad "frame watchdog did not fire"; fi
if alive "$LOCK_PID"; then ok "lock client alive after a hung saver"; else bad "lock died on a hung saver"; fi
stop_all

echo "== case 4: bad fd / short buffer rejected =="
start_labwc || exit 1
start_lock "$SRC --bad-fd --frames 3" "$WORK/tmp/c4.log"
if wait_for "$WORK/tmp/c4.log" "shm too small" 6; then ok "short buffer rejected"; else bad "short buffer not rejected"; fi
if alive "$LOCK_PID"; then ok "lock client alive after a bad fd"; else bad "lock died on a bad fd"; fi
stop_all

echo "== case 5: saver GPU error (exits after HELLO) =="
start_labwc || exit 1
start_lock "$SRC --gpu-error" "$WORK/tmp/c5.log"
if wait_for "$WORK/tmp/c5.log" "frame source failed" 6 || wait_for "$WORK/tmp/c5.log" "exited status" 3; then ok "GPU error handled"; else bad "GPU error not handled"; fi
if alive "$LOCK_PID"; then ok "lock client alive after a GPU error"; else bad "lock died on a GPU error"; fi
stop_all

echo "== case 6: default build is inert (no frame source) =="
start_labwc || exit 1
: >"$WORK/tmp/c6.log"
GEN=$((GEN+1))
setsid "$LOCKOFF" >>"$WORK/tmp/c6.log" 2>&1 &
LOCK_PID=$!
owned_add "$LOCK_PID" "$LOCK_PID" "$GEN"
if wait_for "$WORK/tmp/c6.log" "lock: configure" 6; then ok "default build locks as upstream"; else bad "default build did not lock"; fi
if have "$WORK/tmp/c6.log" "framesrc" ; then bad "default build somehow used the frame source"; else ok "default build used no frame source"; fi
stop_all

echo "== case 7: source HOLD => freeze; the lock keeps the last frame, then idles =="
start_labwc || exit 1
start_lock "$SRC --hold=4" "$WORK/tmp/c7.log" 3000
wait_for "$WORK/tmp/c7.log" "frame source accepted" 6 || true
wait_for "$WORK/tmp/c7.log" "testsrc: HOLD" 6 || true
if wait_for "$WORK/tmp/c7.log" "frame source HOLD: keeping the last frame" 6; then ok "lock entered HOLD"; else bad "lock never entered HOLD"; fi
sleep 1
if owned_source_alive; then bad "source still rendering after HOLD"; else ok "source exited after HOLD (render work ended)"; fi
if have "$WORK/tmp/c7.log" "frame source failed"; then bad "HOLD was treated as a fault"; else ok "HOLD was not treated as a fault"; fi
if have "$WORK/tmp/c7.log" "frame source stopped"; then bad "the lock cleared the held frame"; else ok "the held frame was not cleared"; fi
if have "$WORK/tmp/c7.log" "cleared frames (fail-closed)"; then bad "HOLD took the fail-closed clear path"; else ok "HOLD did not clear (freeze path)"; fi
if alive "$LOCK_PID"; then ok "lock client alive after HOLD"; else bad "lock died on HOLD"; fi
if grim "$WORK/tmp/c7-frozen.png" >/dev/null 2>&1; then
    if rng=$(backdrop_is_live "$WORK/tmp/c7-frozen.png"); then ok "frozen backdrop is the held saver frame ($rng)"; else bad "frozen backdrop is the flat fill ($rng)"; fi
else
    bad "grim could not capture the frozen screen"
fi
for _ in 1 2 3 4 5; do
    wtype -d 300 -k a >/dev/null 2>&1
    have "$WORK/tmp/c7.log" "prompt raised over saver" && break
    sleep 0.3
done
if have "$WORK/tmp/c7.log" "prompt raised over saver"; then ok "input raised the prompt over the held frame"; else bad "input did not raise the prompt over the held frame"; fi
if grim "$WORK/tmp/c7-prompt.png" >/dev/null 2>&1; then
    if rng=$(backdrop_is_live "$WORK/tmp/c7-prompt.png"); then ok "prompt overlays the held frame ($rng)"; else bad "prompt backdrop is the flat fill ($rng)"; fi
else
    bad "grim could not capture the frozen prompt"
fi
if alive "$LOCK_PID"; then ok "lock still held after input over a frozen frame"; else bad "lock died on input over a frozen frame"; fi
stop_all

echo "== case 8: crash WITHOUT HOLD => frame cleared (fail-closed flat) =="
start_labwc || exit 1
start_lock "$SRC --frames 400" "$WORK/tmp/c8.log" 3000
wait_for "$WORK/tmp/c8.log" "frame source accepted" 6 || true
wait_for "$WORK/tmp/c8.log" "testsrc: frame seq=" 4 || true
testsrc_pid="$(owned_source_pid)"
if [ -n "$testsrc_pid" ] && kill_owned_source "$testsrc_pid"; then ok "killed the owned frame source (-9)"; else bad "owned frame source pid not found"; fi
if wait_for "$WORK/tmp/c8.log" "frame source failed" 4 || wait_for "$WORK/tmp/c8.log" "exited status" 2; then ok "lock noticed the dead frame source"; else bad "lock did not notice the dead source"; fi
sleep 0.5
if have "$WORK/tmp/c8.log" "frame source HOLD"; then bad "a crash produced a HOLD"; else ok "a crash did not produce a HOLD"; fi
if have "$WORK/tmp/c8.log" "cleared frames (fail-closed)"; then ok "a crash cleared the frame (fail-closed)"; else bad "a crash did not clear the frame"; fi
if alive "$LOCK_PID"; then ok "lock client alive after the crash (fail-closed)"; else bad "lock died on the crash"; fi
stop_all

echo "== case 9: input BEFORE the freeze timer => prompt over a held frame =="
start_labwc || exit 1
start_lock "$SRC --frames 400" "$WORK/tmp/c9.log" 3000
wait_for "$WORK/tmp/c9.log" "frame source accepted" 6 || true
wait_for "$WORK/tmp/c9.log" "testsrc: frame seq=" 4 || true
src_before="$(owned_source_pid)"
if [ -n "$src_before" ]; then ok "saver was streaming before input"; else bad "saver never produced a frame"; fi
for _ in 1 2 3 4 5; do
    wtype -d 300 -k a >/dev/null 2>&1
    have "$WORK/tmp/c9.log" "prompt raised over saver" && break
    sleep 0.3
done
if have "$WORK/tmp/c9.log" "prompt raised over saver"; then ok "input raised the prompt"; else bad "input did not raise the prompt"; fi
if wait_for "$WORK/tmp/c9.log" "frozen on demand" 4; then ok "source frozen on demand (input before the timer)"; else bad "source not frozen on demand"; fi
sleep 1
if owned_source_alive; then bad "saver still rendering after the freeze"; else ok "saver stopped after the freeze"; fi
if have "$WORK/tmp/c9.log" "frame source failed"; then bad "the freeze was treated as a fault"; else ok "the freeze was not treated as a fault"; fi
if have "$WORK/tmp/c9.log" "cleared frames (fail-closed)"; then bad "the freeze cleared the frame"; else ok "the held frame was not cleared"; fi
if alive "$LOCK_PID"; then ok "lock alive after the freeze"; else bad "lock died on the freeze"; fi
if grim "$WORK/tmp/c9.png" >/dev/null 2>&1; then
    if rng=$(backdrop_is_live "$WORK/tmp/c9.png"); then ok "prompt backdrop is the held frame ($rng)"; else bad "prompt backdrop is the flat fill ($rng)"; fi
else
    bad "grim could not capture the frozen prompt"
fi
stop_all

echo "== case 10: two lock clients at once (second yields; first keeps its source) =="
start_labwc || exit 1
start_lock "$SRC --frames 200" "$WORK/tmp/c10a.log"
first_pid="$(owned_pid)"; first_pgid="$(owned_pgid)"
if wait_for "$WORK/tmp/c10a.log" "frame source accepted" 6; then ok "first lock accepted the frame source"; else bad "first lock did not accept the frame source"; fi
# A second lock client starts against the SAME renderer socket while the first
# owns it. It must yield instead of unlinking the live socket, and must not
# disturb the first instance. Launched via setsid -> its OWN group, recorded.
: >"$WORK/tmp/c10b.log"
GEN=$((GEN+1))
SINGULARITY_LOCK_RENDERER="$SRC --frames 200" \
SINGULARITY_LOCK_RENDERER_SOCKET="$SOCK" \
    setsid "$LOCK" >>"$WORK/tmp/c10b.log" 2>&1 &
LOCK2_PID=$!
owned_add "$LOCK2_PID" "$LOCK2_PID" "$GEN"
if wait_for "$WORK/tmp/c10b.log" "another lock instance owns the renderer socket; yielding" 6; then
    ok "second lock yielded instead of clobbering the socket"
else
    bad "second lock did not yield (see c10b.log)"
fi
sleep 1
if [ -S "$SOCK" ]; then ok "renderer socket survived the second client"; else bad "renderer socket was removed by the second client"; fi
if grep -q "testsrc: frame seq=" "$WORK/tmp/c10a.log"; then ok "first lock is still streaming after the race"; else bad "first lock stopped streaming"; fi
if kill -0 "$first_pid" 2>/dev/null; then ok "first lock still alive"; else bad "first lock died"; fi
# Cleanup covers BOTH exact owned groups (first + second), each by own PGID.
kill -9 -- "-$first_pgid" 2>/dev/null
kill -9 -- "-$LOCK2_PID" 2>/dev/null
wait "$first_pid" 2>/dev/null
wait "$LOCK2_PID" 2>/dev/null
stop_all

echo "== case 11: a source that dies after every handshake backs off exponentially =="
start_labwc || exit 1
start_lock "$SRC --gpu-error" "$WORK/tmp/c11.log"
sleep 6
n=$(grep -c "spawned frame source" "$WORK/tmp/c11.log" 2>/dev/null || true)
if have "$WORK/tmp/c11.log" "backoff 1000ms"; then ok "backoff grows across handshakes"; else bad "backoff did not grow (see c11.log)"; fi
if [ "${n:-0}" -le 7 ]; then ok "source respawned $n times in 6 s"; else bad "source respawned $n times in 6 s"; fi
if alive "$LOCK_PID"; then ok "lock alive while backing off"; else bad "lock died while backing off"; fi
stop_all

echo "== case 12: no output => the source is not started =="
WLR_HEADLESS_OUTPUTS=0 start_labwc || exit 1
start_lock "$SRC --frames 200" "$WORK/tmp/c12.log"
if wait_for "$WORK/tmp/c12.log" "[framesrc] enabled" 6; then
    sleep 3
    if have "$WORK/tmp/c12.log" "spawned frame source"; then bad "source spawned with no output (see c12.log)"; else ok "no source spawned without an output"; fi
    if alive "$LOCK_PID"; then ok "lock alive with no output"; else bad "lock died with no output"; fi
else
    echo "  SKIP: the lock was not engaged without an output on this compositor"
fi
stop_all

echo "== case 13: pause-capable saver: input suspends it, prompt timeout resumes it =="
start_labwc || exit 1
start_lock "$SRC --frames 600 --pause-ok" "$WORK/tmp/c13.log" 4000
wait_for "$WORK/tmp/c13.log" "frame source accepted" 6 || true
wait_for "$WORK/tmp/c13.log" "testsrc: frame seq=3" 6 || true
src13="$(owned_source_pid)"
for _ in 1 2 3 4 5; do
    wtype -d 300 -k a >/dev/null 2>&1
    have "$WORK/tmp/c13.log" "prompt raised over saver" && break
    sleep 0.3
done
if wait_for "$WORK/tmp/c13.log" "frame source paused (prompt up; renderer suspended)" 4; then ok "input paused the saver (no freeze/kill)"; else bad "input did not pause the saver"; fi
if wait_for "$WORK/tmp/c13.log" "testsrc: PAUSE" 3; then ok "the source received PAUSE"; else bad "the source never saw PAUSE"; fi
fa=$(frame_count "$WORK/tmp/c13.log"); sleep 2; fb=$(frame_count "$WORK/tmp/c13.log")
if [ "$fb" -le $(( fa + 1 )) ]; then ok "no frames while paused ($fa -> $fb)"; else bad "frames kept coming while paused ($fa -> $fb)"; fi
if have "$WORK/tmp/c13.log" "frame source frozen on demand"; then bad "a pause-capable saver was frozen/ended"; else ok "the saver was not ended"; fi
if wait_for "$WORK/tmp/c13.log" "frame source resumed (renderer continues)" 8; then ok "prompt timeout resumed the same saver"; else bad "the saver was not resumed"; fi
if wait_for "$WORK/tmp/c13.log" "(suspended saver continues)" 3; then ok "prompt lowered over the continuing saver"; else bad "prompt did not lower"; fi
for _ in $(seq 1 40); do fc=$(frame_count "$WORK/tmp/c13.log"); [ "$fc" -gt $(( fb + 3 )) ] && break; sleep 0.1; done
if [ "$fc" -gt $(( fb + 3 )) ]; then ok "frames stream again after RESUME ($fb -> $fc)"; else bad "no frames after RESUME ($fb -> $fc)"; fi
src13b="$(owned_source_pid)"
if [ -n "$src13" ] && [ "$src13" = "$src13b" ] && [ "$(grep -c "spawned frame source" "$WORK/tmp/c13.log")" = 1 ]; then ok "same source process continued (no respawn)"; else bad "the source was respawned ($src13 -> $src13b)"; fi
if alive "$LOCK_PID"; then ok "lock still held after the resume"; else bad "lock died"; fi
stop_all

echo "== case 14: the prompt timeout is at most 60 s =="
start_labwc || exit 1
start_lock "$SRC --frames 100 --pause-ok" "$WORK/tmp/c14.log" 120000
if wait_for "$WORK/tmp/c14.log" "lock: prompt timeout 60000 ms" 6; then ok "a requested 120 s timeout is clamped to 60 s"; else bad "prompt timeout not clamped ($(grep -a 'prompt timeout' "$WORK/tmp/c14.log"))"; fi
stop_all
start_labwc || exit 1
start_lock "$SRC --frames 100 --pause-ok" "$WORK/tmp/c14b.log" 3000
if wait_for "$WORK/tmp/c14b.log" "lock: prompt timeout 3000 ms" 6; then ok "a shorter timeout is kept"; else bad "a shorter timeout was not kept"; fi
stop_all

echo ""
echo "== RESULT: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
