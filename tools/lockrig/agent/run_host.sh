#!/usr/bin/env bash
# tools/lockrig/agent/run_host.sh -- runs ON the target NCZ host AS ROOT.
# Executes the controlled lock/saver/greeter test cases (T1..T20), collects
# evidence, and writes a machine-readable result. It NEVER reboots, never
# touches refind/bootloader, never reconfigures as root beyond the reversible
# gsettings override + the transient uinput devices, and always attempts to
# leave the host unlocked and logged in.
#
# Env in:  LU (login user, default ncz)  D (scratch dir)  TAG (host name)
#          STAGE_FEED (optional abs path to a freeze-capable ncz-screensaver-feed)
# Out:     $D/cases.tsv  $D/result.json  $D/ev/*.png  $D/run.log
set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
LU="${LU:-ncz}"
TAG="${TAG:-host}"
D="${D:-/home/$LU/Projects/lockrig/run-$$}"
E="$D/ev"; mkdir -p "$E"; chmod 777 "$D" "$E" 2>/dev/null
trap 'touch "$D/DONE" 2>/dev/null' EXIT
R="$D/cases.tsv"; : > "$R"; LOG="$D/run.log"; : > "$LOG"
FEED_BIN=/usr/libexec/ncz-screensaver-feed
[ -n "${STAGE_FEED:-}" ] && [ -x "${STAGE_FEED:-}" ] && FEED_BIN="$STAGE_FEED"
SLOG="/home/$LU/.local/state/singularity/singularity-desktop.log"
RUNENV="XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0"
GSENV="XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus GSETTINGS_SCHEMA_DIR=/opt/singularity/share/glib-2.0/schemas"
LIB="$(cd "$(dirname "$0")" && pwd)/lib"

PASS=0; FAIL=0; SKIP=0
say() { echo "[$(date +%T)] $*" | tee -a "$LOG"; }
rec() { # id status detail
  printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >> "$R"
  case "$2" in PASS) PASS=$((PASS+1));; FAIL) FAIL=$((FAIL+1));; SKIP) SKIP=$((SKIP+1));; esac
  say "CASE $1 $2: ${3:-}"
}
run() { runuser -u "$LU" -- env $RUNENV "$@"; }
gs()  { runuser -u "$LU" -- env -u G_MESSAGES_DEBUG $GSENV gsettings "$@" 2>/dev/null | tail -1; }
gsset() { runuser -u "$LU" -- env -u G_MESSAGES_DEBUG $GSENV gsettings "$@" 2>/dev/null; }
shot()  { run grim "$E/$1.png" 2>>"$LOG" && md5sum "$E/$1.png" 2>/dev/null | awk '{print substr($1,1,12)}'; }
crop()  { if command -v magick >/dev/null 2>&1; then magick "$E/$1.png" -crop "$CROP" +repage "$E/$2.png" 2>/dev/null; else convert "$E/$1.png" -crop "$CROP" +repage "$E/$2.png" 2>/dev/null; fi; }
lockpg() { pgrep -f "/opt/singularity/bin/singularity-lockscreen" | head -1; }
lockpg_any() { pgrep -f "singularity-lockscreen" | head -1; }
key()  { python3 "$LIB/kbd2.py" "$@"; }
ptr()  { python3 "$LIB/ptr.py" "$@"; }
feedpids() { pgrep -f "ncz-screensaver-feed|blackhole|glycin|hack" 2>/dev/null | tr '\n' ' '; }
feedcpu() { # max %cpu of feed/hack procs (approx via ps)
  ps -eo pcpu,args 2>/dev/null | grep -aiE 'ncz-screensaver-feed|blackhole|glycin' | grep -av grep | awk '{s+=$1} END{print (s==""?0:s)}'; }
# mean of a power.csv column over rows (a,b] (b=0 => unbounded). col: 3=pkgW 5=gpuW 7=cpuTempMax
pwavg() { awk -F, -v c="$1" -v a="${2:-0}" -v b="${3:-0}" 'NR>a && (b==0||NR<=b) && $c!="" {s+=$c;n++} END{ if(n) printf "%.2f",s/n; else print "n/a" }' "$D/power.csv" 2>/dev/null; }
pwrrows() { wc -l < "$D/power.csv" 2>/dev/null | tr -d ' '; }
# reversible lock-renderer.env seam (the shell sources it per lock; RC6 contract)
ENVFILE=/etc/ncz/lock-renderer.env
renv_backup()  { [ -r "$ENVFILE" ] && cp -a "$ENVFILE" "$D/lock-renderer.env.bak"; }
renv_add()     { [ -n "${1:-}" ] && printf '%s\n' "$1" >> "$ENVFILE"; }
renv_restore() { [ -f "$D/lock-renderer.env.bak" ] && cp -a "$D/lock-renderer.env.bak" "$ENVFILE" 2>/dev/null; }

geom() { # probe full-output size and set CROP (centered card region, ~40%x30%)
  run grim "$E/geom.png" 2>/dev/null
  local wh; wh="$(magick identify -format '%wx%h' "$E/geom.png" 2>/dev/null || identify -format '%wx%h' "$E/geom.png" 2>/dev/null)"
  W="${wh%x*}"; H="${wh#*x}"; [ -n "$W" ] && [ -n "$H" ] && [ "$W" != "$wh" ] || { W=1920; H=1080; }
  local cw ch cx cy
  cw=$((W*40/100)); ch=$((H*30/100)); cx=$(( (W-cw)/2 )); cy=$(( (H-ch)*65/100 ))
  CROP="${cw}x${ch}+${cx}+${cy}"
  # grim -g takes LOGICAL coordinates; W/H are physical, so use a region that is
  # inside the output at any scale <= 2 (central quarter of W/2 x H/2).
  PROG_REGION="$((W/8)),$((H/8)) $((W/4))x$((H/4))"
  say "geometry ${W}x${H} crop=$CROP progress-region=$PROG_REGION"
}

unlock_now() { # up to 4 attempts; returns 0 if unlocked
  local i
  for i in 1 2 3 4; do
    [ -z "$(lockpg)" ] && return 0
    key shift; sleep 1; key type:$PW enter; sleep 3
  done
  [ -z "$(lockpg)" ]
}

wait_lock() { # $1 timeout_s ; sets LOCKED
  local t0; t0=$(date +%s)
  while [ $(( $(date +%s) - t0 )) -lt "$1" ]; do
    sleep 3
    [ -n "$(lockpg)" ] && { LOCKED=$(lockpg); say "lock pid=$LOCKED after $(( $(date +%s)-t0 ))s"; return 0; }
  done
  return 1
}

policy_marker() { env -i "$FEED_BIN" --print-policy 2>/dev/null | head -1; }
# The saver renderer processes (one per output) and their process states.
renderer_pids() { pgrep -f '^/usr/lib/ncz-screensavers/' 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//'; }
renderer_states() { local p; for p in $(renderer_pids); do ps -o stat= -p "$p" 2>/dev/null | cut -c1; done | tr '\n' ' ' | sed 's/ $//'; }
FEEDLOG=/run/user/1000/ncz-screensaver/ncz-saver-feed/feed.log
# Last thermal level the off-screen renderer logged (0/1/2, or "-"): level 2 is
# the thermal pause, the one legitimate reason an unattended saver stands still.
thermal_level() { grep -a -o 'thermal [0-9]* mC -> level [0-9]' "$FEEDLOG" 2>/dev/null | tail -1 | awk '{print $NF}' | grep . || echo -; }
# progress_soak SECONDS STEP TAG -> sets PROG_N (grabs) PROG_T (transitions)
progress_soak() {
  local dur="$1" step="$2" tag="$3" t0 h prev="" i=0
  PROG_N=0; PROG_T=0; : > "$E/$tag.frames"; t0=$(date +%s)
  while [ $(( $(date +%s) - t0 )) -lt "$dur" ]; do
    h=$(run grim -g "$PROG_REGION" -t ppm - 2>/dev/null | md5sum | cut -c1-12)
    echo "$(( $(date +%s) - t0 )) $h" >> "$E/$tag.frames"
    PROG_N=$((PROG_N+1)); [ -n "$prev" ] && [ "$h" != "$prev" ] && PROG_T=$((PROG_T+1)); prev="$h"
    i=$((i+1)); sleep "$step"
  done
}

# ---------------------------------------------------------------- setup
PW="ncz"
command -v magick >/dev/null 2>&1 || command -v convert >/dev/null 2>&1 && HAVE_MAGICK=1 || HAVE_MAGICK=""
say "=== lockrig live run host=$TAG user=$LU D=$D feed=$FEED_BIN ==="
# RC6 images boot to the greeter. If there is no $LU seat0 session (we are at the
# greeter), log in through greetd so the idle-lock path exists to test.
ensure_session() {
  local s i
  s="$(loginctl list-sessions --no-legend 2>/dev/null | awk '$3=="'"$LU"'" && $4=="seat0"{print $1}' | head -1)"
  [ -n "$s" ] && { say "session present: $s"; return 0; }
  say "no $LU seat0 session (at greeter?); logging in via greetd"
  printf '%s\n' "$PW" | python3 "$LIB/greetd_login.py" "$LU" >/dev/null 2>&1
  for i in $(seq 1 40); do
    sleep 2
    s="$(loginctl list-sessions --no-legend 2>/dev/null | awk '$3=="'"$LU"'" && $4=="seat0"{print $1}' | head -1)"
    [ -n "$s" ] && break
  done
  if [ -n "$s" ]; then say "session started: $s"; sleep 4; return 0; fi
  say "WARN: could not establish a $LU seat0 session"; return 1
}
# The launcher sources /etc/ncz/lock-renderer.env once, when the session starts,
# so a seam staged there reaches the lock and the feed only after a new login.
session_cycle() {
  local s i
  s="$(loginctl list-sessions --no-legend 2>/dev/null | awk '$3=="'"$LU"'" && $4=="seat0"{print $1}' | head -1)"
  [ -n "$s" ] && loginctl terminate-session "$s" 2>/dev/null
  for i in $(seq 1 30); do sleep 2; pgrep -f singularity-greeter >/dev/null && break; done
  sleep 4
  ensure_session && sleep 8
}
ensure_session || say "WARN: proceeding without a session (T1 will likely FAIL)"
unlock_now || say "WARN: still locked at start"
IDLE_BEFORE="$(gs get dev.sinty.lockscreen idle-delay)"
HACK_BEFORE="$(gs get dev.ncz.screensaver hack-idle-delay)"
say "recorded idle-delay=$IDLE_BEFORE hack-idle-delay=$HACK_BEFORE"
geom
python3 "$LIB/sampler.py" "$D/power.csv" 5 200 "$TAG" >/dev/null 2>&1 &
SAM=$!
gsset set dev.sinty.lockscreen idle-delay 60
gsset set dev.ncz.screensaver hack-idle-delay 60
: > "$SLOG" 2>/dev/null || true

# ---------------------------------------------------------------- T1 idle -> lock
FL0=$(stat -c %s "$FEEDLOG" 2>/dev/null || echo 0)
LOCKED=""; S0=$(shot m0-desktop)
if wait_lock 120; then rec T1 PASS "idle->lock at 60s override (pid $LOCKED)"; else rec T1 FAIL "no lock within 120s"; fi

if [ -z "$LOCKED" ]; then
  for c in T2 T3 T4 T5 T18 T6 T6b T7 T8 T9 T10 T11 T19 T20 T12 T13 T14 T15; do rec $c SKIP "no lock acquired (T1 failed)"; done
else
  # ------------------------------------------------------------ T2 no prompt before input
  sleep 2
  A=$(shot t2a); crop t2a t2a-card; sleep 4
  B=$(shot t2b); crop t2b t2b-card
  if grep -aq "prompt raised over saver" "$SLOG"; then
    rec T2 FAIL "prompt raised with NO input (log: prompt raised over saver)"
  else
    rec T2 PASS "no prompt before input (log clean; crops t2a/t2b)"
  fi

  # ------------------------------------------------------------ T3 saver animates (intro)
  : > "$E/t3.frames"; local_i=0; prev=""
  PW_A=$(pwrrows); [ -n "$PW_A" ] || PW_A=0
  TT0=$(date +%s%N)
  while :; do
    h=$(shot t3-$local_i); echo "$h" >> "$E/t3.frames"
    local_i=$((local_i+1))
    [ $(( ($(date +%s%N)-TT0)/1000000 )) -ge 10000 ] && break
  done
  TT1=$(date +%s%N); EL=$(( (TT1-TT0)/1000000 ))
  nd=$(sort -u "$E/t3.frames" | wc -l | tr -d ' ')
  trans=0; prev=""
  while read -r h; do [ -n "$prev" ] && [ "$h" != "$prev" ] && trans=$((trans+1)); prev="$h"; done < "$E/t3.frames"
  FPSEST=$(awk -v t="$trans" -v e="$EL" 'BEGIN{ if(e>0) printf "%.1f", t/(e/1000.0); else print "0" }')
  if [ "$nd" -ge 3 ]; then rec T3 PASS "saver animates: $nd distinct/$local_i grabs over ${EL}ms (fps_est>=${FPSEST}, capture-limited)"
  else rec T3 FAIL "saver static: $nd distinct/$local_i grabs over ${EL}ms"; fi
  MARK="$(policy_marker)"; [ "$MARK" = none ] && MARK=""
  if [ -n "$MARK" ]; then
    FPSPOL=$(echo "$MARK" | grep -oE 'lock_fps=[0-9]+' | head -1 | tr -dc 0-9)
    if [ -n "$FPSPOL" ]; then
      awk -v f="$FPSEST" -v p="$FPSPOL" 'BEGIN{exit !(f<=p+4)}' && rec T3b PASS "policy fps=$FPSPOL; captured fps_est $FPSEST consistent" \
        || rec T3b FAIL "policy fps=$FPSPOL but captured fps_est $FPSEST"
    else rec T3b SKIP "policy marker present but no lock_fps"; fi
  else rec T3b SKIP "no --print-policy marker (pre-0.8.12 feed): cannot verify fps policy"; fi

  # ------------------------------------------------------------ T4 no freeze without input
  # Policy (freeze mode "prompt"): an unattended saver keeps animating; there is
  # no time-based freeze. Past the old 15 s intro (we are ~20 s after the lock)
  # the frames must still change and the lock must not have received a HOLD.
  PW_B=$(pwrrows); [ -n "$PW_B" ] || PW_B=0
  sleep 8
  f1=$(shot t4a); sleep 2; f2=$(shot t4b); sleep 2; f3=$(shot t4c)
  PW_C=$(pwrrows); [ -n "$PW_C" ] || PW_C=0
  FCPU=$(feedcpu)
  PKG_I=$(pwavg 3 "$PW_A" "$PW_B"); GPU_I=$(pwavg 5 "$PW_A" "$PW_B"); TMP_I=$(pwavg 7 "$PW_A" "$PW_B")
  PKG_F=$(pwavg 3 "$PW_B" "$PW_C"); GPU_F=$(pwavg 5 "$PW_B" "$PW_C"); TMP_F=$(pwavg 7 "$PW_B" "$PW_C")
  PWRTXT="power 0-10s pkg=${PKG_I}W gpu=${GPU_I}W temp=${TMP_I}C -> 20-30s pkg=${PKG_F}W gpu=${GPU_F}W temp=${TMP_F}C"
  TL=$(thermal_level)
  if grep -aq "frame source HOLD" "$SLOG"; then
    rec T4 FAIL "the saver froze with no input (lock got a HOLD: timer freeze still active); feed CPU ${FCPU}%; $PWRTXT"
  elif [ "$f1" != "$f2" ] || [ "$f2" != "$f3" ]; then
    rec T4 PASS "no input, ~25 s after the lock: frames still change ($f1/$f2/$f3), no HOLD; feed CPU ${FCPU}%; $PWRTXT"
  elif [ "$TL" = 2 ]; then
    rec T4 SKIP "frames constant but the renderer is in its thermal pause (level 2): protection, not a freeze; $PWRTXT"
  else
    rec T4 FAIL "frames constant with no input and no thermal pause ($f1); feed CPU ${FCPU}%; $PWRTXT"
  fi

  # ------------------------------------------------------------ T5 no HOLD in the feed without input
  if tail -c +$(( ${FL0:-0} + 1 )) "$FEEDLOG" 2>/dev/null | grep -aq "HOLD after"; then
    rec T5 FAIL "feed logged a HOLD in this lock with no input (timer freeze)"
  else
    rec T5 PASS "feed sent no HOLD without input (policy: $(policy_marker | grep -o 'freeze=[a-z]*'))"
  fi

  # ------------------------------------------------------------ T18 long frame-progress (no input)
  # The idle saver must keep animating for minutes, not seconds: sample a central
  # region every 10 s for LOCKRIG_PROGRESS_S (default 330 s) with no input and
  # require motion in >= 90% of the intervals (thermal-pause intervals excused).
  PS_S="${LOCKRIG_PROGRESS_S:-330}"
  if [ "$PS_S" -gt 0 ] 2>/dev/null; then
    progress_soak "$PS_S" 10 t18
    NEED=$(( (PROG_N - 1) * 9 / 10 ))
    TL=$(thermal_level)
    if [ -z "$(lockpg)" ]; then
      rec T18 FAIL "lock vanished during the ${PS_S}s no-input soak"
    elif grep -aq "frame source HOLD" "$SLOG"; then
      rec T18 FAIL "saver froze during the ${PS_S}s no-input soak (HOLD); transitions $PROG_T/$((PROG_N-1))"
    elif [ "$PROG_T" -ge "$NEED" ]; then
      rec T18 PASS "saver kept animating ${PS_S}s with no input: $PROG_T/$((PROG_N-1)) intervals changed (need $NEED)"
    elif [ "$TL" = 2 ]; then
      rec T18 SKIP "only $PROG_T/$((PROG_N-1)) intervals changed; renderer ended in its thermal pause (protection)"
    else
      rec T18 FAIL "saver stalled: only $PROG_T/$((PROG_N-1)) intervals changed in ${PS_S}s with no input (need $NEED)"
    fi
  else
    rec T18 SKIP "LOCKRIG_PROGRESS_S=0"
  fi

  # ------------------------------------------------------------ T6 pointer raises prompt
  : > "$SLOG"
  ptr 80 40; sleep 2; PR=$(shot t6); crop t6 t6-card
  if { grep -aq "prompt raised over saver" "$SLOG" || [ "$PR" != "$f3" ]; } && [ -n "$(lockpg)" ]; then
    rec T6 PASS "pointer motion raised prompt over saver (surface ${f3}->${PR})"
  elif [ -z "$(lockpg)" ]; then
    rec T6 FAIL "unlocked on pointer motion"
  else
    rec T6 FAIL "pointer did not raise prompt/surface"
  fi

  # ------------------------------------------------------------ T6b the prompt suspends the saver
  # The renderer must stop (process state T: no GL work, no frame path) and the
  # last real frame must stay on screen behind the prompt.
  q1=$(shot t6b-a); sleep 2; q2=$(shot t6b-b); sleep 2; q3=$(shot t6b-c)
  RST=$(renderer_states)
  if [ "$q1" = "$q2" ] && [ "$q2" = "$q3" ] && grep -aq "frame source paused" "$SLOG" && echo "$RST" | grep -q 'T' && ! echo "$RST" | grep -qE '(^| )[RS]'; then
    rec T6b PASS "the prompt suspended the saver: renderer state $RST, frame held ($q1)"
  elif [ "$q1" = "$q2" ] && [ "$q2" = "$q3" ] && grep -aq "frozen on demand" "$SLOG"; then
    rec T6b FAIL "frame held but the saver was ended, not suspended (lock or feed without PAUSE support)"
  elif [ "$q1" = "$q2" ] && [ "$q2" = "$q3" ]; then
    rec T6b FAIL "frame held but the renderer is not suspended (states: ${RST:-none})"
  else
    rec T6b FAIL "frames still change behind the prompt ($q1/$q2/$q3)"
  fi

  # ------------------------------------------------------------ T7 key raises / stays locked
  PA=$(shot t7); key shift; sleep 2; PB=$(shot t7b)
  [ -n "$(lockpg)" ] && rec T7 PASS "still locked after key; surface ${PA}->${PB}" || rec T7 FAIL "unlocked on key"

  # ------------------------------------------------------------ T8 input freezes immediately
  # fresh lock cycle: unlock, re-lock, inject at t+5s, expect freeze
  unlock_now; sleep 2; : > "$SLOG"
  if wait_lock 120; then
    sleep 5; key shift; sleep 1
    g1=$(shot t8a); sleep 2; g2=$(shot t8b); sleep 2; g3=$(shot t8c)
    if [ "$g1" = "$g2" ] && [ "$g2" = "$g3" ]; then rec T8 PASS "input 5 s into the saver froze it immediately (hash $g1 constant)"
    else rec T8 FAIL "input did NOT freeze the saver (frames differ)"; fi
  else rec T8 SKIP "could not re-lock for T8"; fi
  [ -n "$(lockpg)" ] || { unlock_now; }

  # ------------------------------------------------------------ T9 wrong pw rejected / stays locked
  key type:lockrigbad enter; sleep 4
  [ -n "$(lockpg)" ] && rec T9 PASS "wrong password rejected, still locked" || rec T9 FAIL "wrong password unlocked!"
  key rep:32:backspace; sleep 1

  # ------------------------------------------------------------ T10 right pw unlocks
  key shift; sleep 1; key type:$PW enter; sleep 6
  if [ -z "$(lockpg)" ]; then U=$(shot t10-unlocked); rec T10 PASS "right password unlocked; desktop shot $U"; else rec T10 FAIL "right password did not unlock"; fi
  unlock_now

  # ------------------------------------------------------------ T11 FAIL-CLOSED on feed kill
  : > "$SLOG"
  if wait_lock 120; then
    sleep 3
    FP=$(pgrep -f "ncz-screensaver-feed" | head -1)
    if [ -n "$FP" ]; then
      kill -9 "$FP" 2>/dev/null; sleep 3
      if [ -n "$(lockpg)" ]; then
        K1=$(shot t11a); crop t11a t11a-card
        # prompt must still be reachable and correct pw unlocks
        key shift; sleep 1; key type:$PW enter; sleep 6
        if [ -z "$(lockpg)" ]; then rec T11 PASS "feed killed during intro: stayed locked, prompt reachable, correct pw unlocked (K=$K1)"
        else rec T11 FAIL "feed killed: stayed locked but could not unlock"; fi
      else rec T11 FAIL "lock released when feed was killed (desktop exposed!)"; fi
    else rec T11 SKIP "no feed process found to kill (mode may be prompt-only)"; fi
  else rec T11 SKIP "could not re-lock for T11"; fi
  unlock_now

  # ------------------------------------------------------------ T19 prompt times out -> saver continues
  # No input after the prompt came up: within 60 s the prompt is dismissed and
  # the SAME suspended renderer continues (live frames replace the held one);
  # the session stays locked.
  unlock_now; sleep 2; : > "$SLOG"
  if wait_lock 120; then
    sleep 5; P19=$(renderer_pids); ptr 80 40; T19S=$(date +%s); sleep 2
    r1=$(shot t19a); sleep 2; r2=$(shot t19b)
    for i in $(seq 1 75); do grep -aq "prompt lowered" "$SLOG" && break; sleep 1; done
    T19E=$(( $(date +%s) - T19S ))
    sleep 3
    r3=$(shot t19c); sleep 1; r4=$(shot t19d); sleep 1; r5=$(shot t19e)
    P19B=$(renderer_pids)
    if [ -z "$(lockpg)" ]; then
      rec T19 FAIL "unlocked while waiting for the prompt to time out (desktop exposed)"
    elif [ "$r1" != "$r2" ]; then
      rec T19 FAIL "saver not held behind the prompt ($r1/$r2)"
    elif ! grep -aq "prompt lowered" "$SLOG"; then
      rec T19 FAIL "the prompt did not time out within 75 s"
    elif [ "$T19E" -gt 62 ]; then
      rec T19 FAIL "the prompt timed out after ${T19E}s (want <= 60 s)"
    elif [ "$r3" = "$r4" ] && [ "$r4" = "$r5" ]; then
      rec T19 FAIL "prompt dismissed after ${T19E}s but the saver stayed still ($r3)"
    elif [ -n "$P19" ] && [ "$P19" != "$P19B" ]; then
      rec T19 FAIL "prompt dismissed after ${T19E}s, saver animating, but it was restarted ($P19 -> $P19B), not continued"
    else
      rec T19 PASS "prompt dismissed after ${T19E}s with no input, the same saver ($P19B) continues ($r3/$r4/$r5), still locked"
    fi
  else rec T19 SKIP "could not re-lock for T19"; fi

  # ------------------------------------------------------------ T20 input restarts the prompt timeout
  # Input at 50 s keeps the prompt up: it must still be up at 65 s after it came
  # up, and go away at most 60 s after the last input (someone mid-password is
  # not cut off, and the prompt never sits idle for more than 60 s).
  unlock_now; sleep 2; : > "$SLOG"
  if wait_lock 120; then
    sleep 5; ptr 80 40; T20S=$(date +%s)
    sleep 50; key shift; T20K=$(date +%s)
    sleep 15
    if grep -aq "prompt lowered" "$SLOG"; then
      rec T20 FAIL "the prompt went away $(( $(date +%s) - T20S ))s after it came up despite input at 50 s"
    else
      for i in $(seq 1 60); do grep -aq "prompt lowered" "$SLOG" && break; sleep 1; done
      T20E=$(( $(date +%s) - T20K ))
      if [ -z "$(lockpg)" ]; then rec T20 FAIL "unlocked while waiting (desktop exposed)"
      elif ! grep -aq "prompt lowered" "$SLOG"; then rec T20 FAIL "the prompt did not go away within 75 s of the last input"
      elif [ "$T20E" -gt 62 ]; then rec T20 FAIL "the prompt went away ${T20E}s after the last input (want <= 60 s)"
      else rec T20 PASS "input at 50 s kept the prompt up past 65 s; it went away ${T20E}s after the last input, still locked"; fi
    fi
  else rec T20 SKIP "could not re-lock for T20"; fi
  unlock_now

  # ------------------------------------------------------------ T13 thermal governor
  # The feed re-evaluates hwmon once/s and pauses above ~85C. Test seam:
  # NCZ_FEED_THERMAL_ROOT points the feed at a fake hwmon tree (no real heating).
  if [ -n "$MARK" ] && [ -n "$HAVE_MAGICK" ]; then
    if renv_backup; then
      mkdir -p "$D/hot"
      for i in 0 1 2 3; do
        mkdir -p "$D/hot/hwmon$i"
        case $i in 0) nm=amdgpu;; 1) nm=coretemp;; *) nm=k10temp;; esac
        echo "$nm" > "$D/hot/hwmon$i/name"
        echo 95000 > "$D/hot/hwmon$i/temp1_input"
      done
      chmod -R a+rX "$D/hot"
      renv_add "NCZ_FEED_THERMAL_ROOT=$D/hot"
      session_cycle; unlock_now; sleep 2; : > "$SLOG"
      if wait_lock 120; then
        sleep 4
        h1=$(shot t13a); sleep 2; h2=$(shot t13b); sleep 2; h3=$(shot t13c)
        if [ "$h1" = "$h2" ] && [ "$h2" = "$h3" ]; then
          rec T13 PASS "thermal governor: at simulated 95C the feed paused (frames constant $h1); seam NCZ_FEED_THERMAL_ROOT=$D/hot"
        else
          rec T13 FAIL "thermal governor: feed did NOT pause at simulated 95C (frames differ: $h1/$h2/$h3)"
        fi
      else rec T13 SKIP "could not re-lock for T13"; fi
      unlock_now; renv_restore; session_cycle; unlock_now
    else rec T13 SKIP "no $ENVFILE to stage the NCZ_FEED_THERMAL_ROOT seam"; fi
  else
    rec T13 SKIP "no --print-policy marker (pre-0.8.12 feed): no thermal seam to exercise"
  fi

  # ------------------------------------------------------------ T14 blank-after-N while locked
  # Only a feed that advertises blank_after in --print-policy implements it.
  if [ -n "$MARK" ] && ! echo "$MARK" | grep -q 'blank_after'; then
    rec T14 SKIP "installed feed does not implement NCZ_SAVER_BLANK_AFTER_S (no blank_after in its policy marker)"
  elif [ -n "$MARK" ] && [ -n "$HAVE_MAGICK" ]; then
    if renv_backup; then
      renv_add "NCZ_SAVER_BLANK_AFTER_S=8"
      session_cycle; unlock_now; sleep 2; : > "$SLOG"
      if wait_lock 120; then
        sleep 14
        b=$(shot t14-blank)
        bmean=$(magick "$E/t14-blank.png" -colorspace Gray -format '%[fx:mean]' info: 2>/dev/null || echo 1)
        if [ -n "$(lockpg)" ] && awk -v m="$bmean" 'BEGIN{exit !(m<0.02)}'; then
          ptr 80 40; sleep 3; pb=$(shot t14-wake)
          if [ -n "$(lockpg)" ] && [ "$pb" != "$b" ]; then
            rec T14 PASS "blank-after-8s: output blanked (mean=$bmean) while locked; input woke the prompt over the held frame, no desktop exposure"
          else rec T14 FAIL "blanked while locked but input did not wake the prompt (or desktop exposed)"; fi
        else rec T14 FAIL "output not blanked after 8s of lock (mean=$bmean)"; fi
      else rec T14 SKIP "could not re-lock for T14"; fi
      unlock_now; renv_restore; session_cycle; unlock_now
    else rec T14 SKIP "no $ENVFILE to stage NCZ_SAVER_BLANK_AFTER_S"; fi
  else
    rec T14 SKIP "NCZ_SAVER_BLANK_AFTER_S (blank-after-N) absent in this payload (pre-0.8.12)"
  fi

  # ------------------------------------------------------------ T15 policy defaults present
  if [ -n "$MARK" ]; then
    echo "$MARK" | grep -q 'lock_fps=30' && echo "$MARK" | grep -q 'render_div=1' && echo "$MARK" | grep -q 'freeze=prompt' \
      && rec T15 PASS "installed feed carries policy defaults: $MARK" \
      || rec T15 FAIL "policy marker incomplete: $MARK"
  else
    rec T15 FAIL "no policy defaults in installed feed (pre-0.8.12); expected lock_fps=30 render_div=1 freeze=prompt"
  fi

  # ------------------------------------------------------------ T12 greeter (DISRUPTIVE, last)
  if [ "${SKIP_GREETER:-0}" = 1 ]; then
    rec T12 SKIP "greeter cycle disabled for this run"
  else
    SESS=$(loginctl list-sessions --no-legend 2>/dev/null | awk '$3=="'"$LU"'" && $4=="seat0"{print $1}' | head -1)
    if [ -n "$SESS" ]; then
      loginctl terminate-session "$SESS" 2>/dev/null
      GREET=""
      for i in $(seq 1 30); do sleep 2; pgrep -f singularity-greeter >/dev/null && { GREET=1; break; }; done
      sleep 4
      runuser -u _greetd -- env XDG_RUNTIME_DIR=/run/user/986 WAYLAND_DISPLAY=wayland-0 grim "$E/t12-greeter.png" 2>/dev/null
      if [ -n "$GREET" ]; then
        # wrong password: no session
        printf 'wrongpw\n' | python3 "$LIB/greetd_login.py" "$LU" 2>>"$LOG"
        WRC=$?
        sleep 3
        WS=$(loginctl list-sessions --no-legend 2>/dev/null | awk '$3=="'"$LU"'" && $4=="seat0"{print $1}' | head -1)
        # right password via greetd IPC
        printf '%s\n' "$PW" | python3 "$LIB/greetd_login.py" "$LU" >/dev/null 2>>"$LOG"
        RS=""
        for i in $(seq 1 20); do sleep 2; RS=$(loginctl list-sessions --no-legend 2>/dev/null | awk '$3=="'"$LU"'" && $4=="seat0"{print $1}' | head -1); [ -n "$RS" ] && break; done
        if [ "$WRC" != 0 ] && [ -z "$WS" ] && [ -n "$RS" ]; then
          rec T12 PASS "greeter: wrong pw no session; right pw session=$RS started"
        else rec T12 FAIL "greeter cycle: wrong(rc=$WRC) no-sess=$([ -z "$WS" ] && echo yes || echo no) right-sess=${RS:-none}"; fi
      else
        rec T12 FAIL "greeter did not appear after session terminate"
      fi
    else rec T12 SKIP "no $LU seat0 session to terminate"; fi
  fi
fi

# ---------------------------------------------------------------- T16/T16b/T17 logind lock + sleep
# T16  loginctl lock-session locks through the shell lock path; right password unlocks.
# T16b a second lock-session while locked is a no-op (one lock client, same pid).
# T17  the shell holds a logind "sleep" delay inhibitor (lock before suspend).
# T17s opt-in real suspend (LOCKRIG_SUSPEND=1, needs an RTC wake alarm): the
#      session is locked when the host comes back.
unlock_now
SID="$(loginctl list-sessions --no-legend 2>/dev/null | awk '$3=="'"$LU"'" && $4=="seat0"{print $1}' | head -1)"
if ! grep -aq "LogindLock: following" /opt/singularity/bin/singularity-desktop 2>/dev/null; then
  for c in T16 T16b T17; do rec $c SKIP "payload has no logind lock listener (shell patch 0022 absent)"; done
elif [ -z "$SID" ]; then
  for c in T16 T16b T17; do rec $c SKIP "no $LU seat0 session"; done
else
  # A lock-session sent before the shell follows the session is lost (T12 just
  # logged in again), so wait for the listener first.
  for i in $(seq 1 30); do grep -aq "LogindLock: following /org/freedesktop/login1/session/$SID" "$SLOG" 2>/dev/null && break; sleep 1; done
  n0=$(wc -l < "$SLOG" 2>/dev/null || echo 0)
  loginctl lock-session "$SID"; got=""
  for i in $(seq 1 10); do sleep 1; [ -n "$(lockpg)" ] && { got=$i; break; }; done
  if [ -n "$got" ]; then
    P16=$(lockpg); sleep 3; S16=$(shot t16-locked)
    loginctl lock-session "$SID"; sleep 4
    n16=$(pgrep -fc "/opt/singularity/bin/singularity-lockscreen")
    if [ "$n16" = 1 ] && [ "$(lockpg)" = "$P16" ]; then rec T16b PASS "second lock-session while locked: one lock client (pid $P16)"
    else rec T16b FAIL "second lock-session: $n16 lock clients (first pid $P16, now $(lockpg))"; fi
    key shift; sleep 1; key type:$PW enter; sleep 6
    if [ -z "$(lockpg)" ]; then rec T16 PASS "loginctl lock-session locked in ${got}s (shot $S16); right password unlocked"
    else rec T16 FAIL "lock-session locked but the right password did not unlock"; fi
  else
    rec T16 FAIL "loginctl lock-session did not lock within 10s"; rec T16b SKIP "no lock from T16"
  fi
  tail -n +$((n0+1)) "$SLOG" 2>/dev/null | grep -a "LogindLock" > "$E/t16-shell.log"
  unlock_now
  if systemd-inhibit --list --no-pager 2>/dev/null | grep -a "Lock the screen before the system sleeps" | grep -aqw delay; then
    rec T17 PASS "shell holds a sleep delay inhibitor"
  else rec T17 FAIL "no Singularity sleep delay inhibitor in systemd-inhibit --list"; fi
  systemd-inhibit --list --no-pager > "$E/t17-inhibitors.txt" 2>&1
  if [ "${LOCKRIG_SUSPEND:-0}" = 1 ] && [ -w /sys/class/rtc/rtc0/wakealarm ] && command -v rtcwake >/dev/null 2>&1; then
    los="$(gs get dev.sinty.lockscreen lock-on-suspend)"
    n0=$(wc -l < "$SLOG" 2>/dev/null || echo 0)
    rtcwake -m no -s 40 >>"$LOG" 2>&1 && systemctl suspend >>"$LOG" 2>&1
    sleep 75
    tail -n +$((n0+1)) "$SLOG" 2>/dev/null | grep -a "LogindLock" > "$E/t17s-shell.log"
    if [ "$los" != true ]; then rec T17s SKIP "lock-on-suspend is $los"
    elif [ -n "$(lockpg)" ] && grep -aq "going to sleep" "$E/t17s-shell.log"; then rec T17s PASS "locked across suspend (lock-on-suspend=$los)"
    else rec T17s FAIL "not locked after suspend/resume (lock-on-suspend=$los)"; fi
    unlock_now
  fi
fi

# ---------------------------------------------------------------- restore
say "=== RESTORE ==="
renv_restore
unlock_now || say "WARN: left locked; restoring gsettings anyway"
gsset reset dev.sinty.lockscreen idle-delay 2>/dev/null
gsset reset dev.ncz.screensaver hack-idle-delay 2>/dev/null
IDLE_AFTER="$(gs get dev.sinty.lockscreen idle-delay)"
HACK_AFTER="$(gs get dev.ncz.screensaver hack-idle-delay)"
say "restored idle-delay=$IDLE_AFTER hack-idle-delay=$HACK_AFTER (were $IDLE_BEFORE/$HACK_BEFORE)"
LOCKSTATE=$([ -n "$(lockpg)" ] && echo locked || echo unlocked)
[ -z "$(lockpg)" ] && rec TRESTORE PASS "host left unlocked & logged in; gsettings reset ($IDLE_AFTER/$HACK_AFTER)" \
  || rec TRESTORE FAIL "host left LOCKED after run"

cat > "$D/result.json" <<JSON
{"host":"$TAG","mode":"live","ended_iso":"$(date -u +%Y-%m-%dT%H:%M:%SZ)",
 "feed_bin":"$FEED_BIN","policy_marker":"${MARK:-none}",
 "summary":{"pass":$PASS,"fail":$FAIL,"skip":$SKIP},"lock_state":"$LOCKSTATE"}
JSON
touch "$D/DONE"
say "RESULT pass=$PASS fail=$FAIL skip=$SKIP"

# best-effort: stop our own samplers / helpers (never touch unrelated processes)
kill "$SAM" 2>/dev/null
exit 0
