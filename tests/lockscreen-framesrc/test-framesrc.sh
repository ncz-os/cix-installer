#!/bin/bash
# Headless labwc test for the lock client's out-of-process frame source.
#
# Runs INSIDE a debian:forky container with: labwc, wtype, wlrctl, wayland-utils,
# grim, python3 + python3-pil, and the three binaries built by build.sh, all
# under /work. It drives a real labwc (WLR_BACKENDS=headless) and a real lock
# client, and asserts on the lock's own stderr log and on real screen captures.
# Restarts labwc per case so a lock left held never wedges the next case.
#
# Cases 7-9 pin the idle-lock-over-saver contract: with the cursor over the
# output BEFORE the lock starts, mapping the lock surface under a stationary
# cursor must NOT raise the unlock prompt (a compositor pointer ENTER is not
# user input); the prompt must be raised only by a real key/button/motion.
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
LOCK_PID=""
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
stop_all() {
    [ -n "$LOCK_PID" ] && kill -9 "$LOCK_PID" 2>/dev/null
    pkill -9 -f lock-framesrc-testsrc 2>/dev/null
    [ -n "$LABWC_PID" ] && kill -9 "$LABWC_PID" 2>/dev/null
    LOCK_PID=""; LABWC_PID=""
    sleep 0.3
}
trap 'stop_all' EXIT

start_lock() { # $1 = env value for SINGULARITY_LOCK_RENDERER (may be empty), $2 log, $3 delay ms
    local cmd="$1" log="$2" delay="${3:-2500}"
    : >"$log"; : >"${log}.lfs"
    SINGULARITY_LOCK_RENDERER="$cmd" \
    SINGULARITY_LOCK_RENDERER_SOCKET="$SOCK" \
    SINGULARITY_LOCK_RENDERER_LOG="${log}.lfs" \
    SINGULARITY_LOCK_RENDERER_DELAY_MS="$delay" \
    "$LOCK" >>"$log" 2>&1 &
    LOCK_PID=$!
}
wait_for() { # $1 file, $2 string, $3 seconds
    for _ in $(seq 1 $(( ${3:-5} * 10 ))); do
        have "$1" "$2" && return 0
        sleep 0.1
    done
    return 1
}
frame_count() { grep -c "testsrc: frame seq=" "$1" 2>/dev/null || true; }
alive() { kill -0 "$1" 2>/dev/null; }

# Drive a virtual pointer through labwc's zwlr_virtual_pointer_manager_v1.
# Placing the cursor BEFORE the lock maps the surface under a stationary
# cursor, which is what a real host looks like; a later move is real input.
ptr_move() { wlrctl pointer move "$1" "$2" >/dev/null 2>&1; }
ptr_click() { wlrctl pointer click left >/dev/null 2>&1; }

# Sample the corners of a screen capture and report whether the background is
# anything but one flat colour. A live frame source paints a moving pattern; the
# fail-closed prompt over no frames is a single flat fill.
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
if command -v wlrctl >/dev/null 2>&1; then
    wayland-info 2>/dev/null | grep -q "zwlr_virtual_pointer_manager_v1" \
        && ok "labwc advertises zwlr_virtual_pointer_manager_v1 (pointer cases)" \
        || echo "  SKIP: no virtual-pointer protocol; pointer cases will be skipped"
else
    echo "  SKIP: wlrctl not installed; pointer cases will be skipped"
fi
stop_all

echo "== case 1: frames render; input raises the prompt over the live saver =="
start_labwc || exit 1
start_lock "$SRC --frames 400" "$WORK/tmp/c1.log" 4000
if wait_for "$WORK/tmp/c1.log" "frame source accepted" 6; then ok "lock accepted the frame source"; else bad "lock did not accept the frame source"; fi
if wait_for "$WORK/tmp/c1.log" "testsrc: frame seq=" 4; then ok "frame source rendered frames"; else bad "no frames rendered"; fi
sleep 1
f0=$(frame_count "$WORK/tmp/c1.log")
if [ "${f0:-0}" -ge 3 ]; then ok "multiple frames streamed ($f0)"; else bad "too few frames ($f0)"; fi
if alive "$LOCK_PID"; then ok "lock client alive while presenting"; else bad "lock client died"; fi
# input: a key press must RAISE THE PROMPT while the saver keeps running. wtype
# creates a transient virtual keyboard, so the first key can race the seat
# gaining the keyboard capability; retry a few times.
for _ in 1 2 3 4 5; do
    wtype -d 300 -k a >/dev/null 2>&1
    have "$WORK/tmp/c1.log" "prompt raised over saver" && break
    sleep 0.3
done
if have "$WORK/tmp/c1.log" "prompt raised over saver"; then ok "input raised the prompt"; else bad "input did not raise the prompt"; fi
if have "$WORK/tmp/c1.log" "frame source stopped"; then bad "input stopped the saver (prompt does not overlay)"; else ok "input did NOT stop the saver"; fi
# The source must keep delivering frames behind the prompt.
fa=$(frame_count "$WORK/tmp/c1.log"); sleep 1; fb=$(frame_count "$WORK/tmp/c1.log")
if [ "${fb:-0}" -gt "${fa:-0}" ]; then ok "frames kept streaming behind the prompt ($fa -> $fb)"; else bad "frames stopped behind the prompt ($fa -> $fb)"; fi
# Sample the real composited output: the backdrop under the prompt must be the
# live saver, not the flat dark fill.
if grim "$WORK/tmp/c1-prompt.png" >/dev/null 2>&1; then
    if rng=$(backdrop_is_live "$WORK/tmp/c1-prompt.png"); then ok "prompt backdrop is not the flat fill ($rng)"; else bad "prompt backdrop is the flat fill ($rng)"; fi
else
    bad "grim could not capture the locked screen"
fi
if alive "$LOCK_PID"; then ok "lock client alive after input"; else bad "lock died on input"; fi
# After the prompt has been idle, the raw saver returns.
if wait_for "$WORK/tmp/c1.log" "prompt lowered; saver frames resumed" 8; then ok "prompt lowered and the saver resumed"; else bad "prompt did not lower"; fi
stop_all

echo "== case 2: feed kill -9 => lock held and the prompt still works =="
start_labwc || exit 1
start_lock "$SRC --frames 400" "$WORK/tmp/c2.log" 3000
wait_for "$WORK/tmp/c2.log" "frame source accepted" 6 || true
testsrc_pid=$(pgrep -f "lock-framesrc-testsrc" | head -1)
if [ -n "$testsrc_pid" ]; then kill -9 "$testsrc_pid"; ok "killed the frame source (-9)"; else bad "frame source pid not found"; fi
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
"$LOCKOFF" >>"$WORK/tmp/c6.log" 2>&1 &
LOCK_PID=$!
if wait_for "$WORK/tmp/c6.log" "lock: configure" 6; then ok "default build locks as upstream"; else bad "default build did not lock"; fi
if have "$WORK/tmp/c6.log" "framesrc" ; then bad "default build somehow used the frame source"; else ok "default build used no frame source"; fi
stop_all

# Cases 7-9 need the virtual-pointer protocol + wlrctl. Detect once.
PTR_OK=0
if command -v wlrctl >/dev/null 2>&1; then
    start_labwc || exit 1
    wayland-info 2>/dev/null | grep -q "zwlr_virtual_pointer_manager_v1" && PTR_OK=1
    stop_all
fi

# Stage a lock with the cursor placed over the output BEFORE the lock starts,
# and wait until the surface is accepted and frames are flowing. Echoes nothing;
# leaves the lock running with the prompt NOT raised.
stage_stationary_lock() { # $1 = log, $2 = delay ms
    local log="$1" delay="${2:-4000}"
    start_labwc || return 1
    ptr_move 400 300; sleep 0.5     # cursor over the output before the lock
    start_lock "$SRC --frames 400" "$log" "$delay"
    wait_for "$log" "frame source accepted" 6 || true
    wait_for "$log" "testsrc: frame seq=" 4 || true
    sleep 2                          # a window with no user input at all
}

if [ "$PTR_OK" = 1 ]; then
    echo "== case 7: stationary cursor at lock => NO prompt; a real MOVE raises it =="
    if stage_stationary_lock "$WORK/tmp/c7.log"; then
        if have "$WORK/tmp/c7.log" "prompt raised over saver"; then
            bad "pointer ENTER/initial motion raised the prompt at lock time (no input)"
        else
            ok "stationary cursor at lock: no prompt before input"
        fi
        # a REAL pointer move must raise the prompt (pt_motion path)
        ptr_move 720 520
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            have "$WORK/tmp/c7.log" "prompt raised over saver" && break; sleep 0.3
        done
        if have "$WORK/tmp/c7.log" "prompt raised over saver"; then ok "a real pointer move raised the prompt"; else bad "a real pointer move did NOT raise the prompt"; fi
        if alive "$LOCK_PID"; then ok "lock client still alive after the move"; else bad "lock died on a pointer move"; fi
    else
        bad "case 7: could not stage the stationary-cursor lock"
    fi
    stop_all

    echo "== case 8: stationary cursor at lock => NO prompt; a BUTTON raises it =="
    if stage_stationary_lock "$WORK/tmp/c8.log"; then
        if have "$WORK/tmp/c8.log" "prompt raised over saver"; then
            bad "prompt raised with no input before the button"
        else
            ok "stationary cursor at lock: no prompt before the button"
        fi
        ptr_click
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            have "$WORK/tmp/c8.log" "prompt raised over saver" && break; sleep 0.3
        done
        if have "$WORK/tmp/c8.log" "prompt raised over saver"; then ok "a pointer button raised the prompt"; else bad "a pointer button did NOT raise the prompt"; fi
    else
        bad "case 8: could not stage the stationary-cursor lock"
    fi
    stop_all

    echo "== case 9: stationary cursor at lock => NO prompt; a KEY raises it =="
    if stage_stationary_lock "$WORK/tmp/c9.log"; then
        if have "$WORK/tmp/c9.log" "prompt raised over saver"; then
            bad "prompt raised with no input before the key"
        else
            ok "stationary cursor at lock: no prompt before the key"
        fi
        for _ in 1 2 3 4 5; do
            wtype -d 300 -k a >/dev/null 2>&1
            have "$WORK/tmp/c9.log" "prompt raised over saver" && break; sleep 0.3
        done
        if have "$WORK/tmp/c9.log" "prompt raised over saver"; then ok "a key press raised the prompt"; else bad "a key press did NOT raise the prompt"; fi
    else
        bad "case 9: could not stage the stationary-cursor lock"
    fi
    stop_all
else
    echo "== cases 7-9: SKIPPED (no wlrctl / virtual-pointer protocol) =="
fi

echo ""
echo "== RESULT: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
