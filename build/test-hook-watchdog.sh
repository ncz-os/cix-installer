#!/bin/bash
# test-hook-watchdog.sh -- a hung command or hook cannot hang the install
# (GU502LV install hang, 2026-10-06).
#
# A process in uninterruptible sleep survives SIGKILL, so `timeout cmd`
# waits for it forever and `cmd | tee` never sees EOF. Contract, checked
# against the SHIPPED code:
#
#   1. lib/bounded-run.sh returns on its deadline even when the command
#      ignores SIGTERM and a child holds its output open; kills the whole
#      process group; propagates real exit codes; tells its own timeout apart
#      from a command that exits 124; stream mode also returns;
#   2. run-all.sh: a hanging optional hook is killed by the watchdog, logged
#      "timed out ..., continuing", counted as failed, and the next hook runs.
#
# Linux only (reads /proc); run on a build host. NCZ_TEST_ROOT=<tree> tests
# another checkout. Exit 0 = pass, 1 = fail.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${NCZ_TEST_ROOT:-$(cd "$HERE/.." && pwd)}"
W="$(mktemp -d)" && [ -d "$W" ] || { echo "cannot create a scratch dir"; exit 2; }
trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS + 1)); }
nok() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }
# count this user's processes whose argv is exactly "<a> <b>" (argv[0] may
# carry a path: /bin/sleep matches sleep). The durations used here (301-305,
# 3603) are unique to this test, so the exact match cannot see other work.
mine() {
    ps -u "$(id -u)" -o args= \
        | awk -v a="$1" -v b="$2" '{ n = split($1, p, "/") } p[n] == a && $2 == b && NF == 2' \
        | wc -l | tr -d ' '
}
# wait up to 5 s for the kernel to reap killed processes before counting
settle() {
    local tries=25
    while [ "$tries" -gt 0 ]; do
        [ "$(mine "$1" "$2")" = 0 ] && return 0
        sleep 0.2
        tries=$((tries - 1))
    done
}
extract_between() { awk -v b="$2" -v e="$3" '$0 ~ b {f=1; next} $0 ~ e {f=0} f' "$1"; }

echo "=== 1. lib/bounded-run.sh ==="
if [ -r "$ROOT/post-install/lib/bounded-run.sh" ]; then
. "$ROOT/post-install/lib/bounded-run.sh"
t0=$(date +%s)
# ignores SIGTERM, and a child keeps the output open: `timeout cmd | tail` would hang here
ncz_bounded_run 2 "t" "$W/b1.out" bash -c 'trap "" TERM; sleep 301 & echo started; sleep 301' 2> "$W/b1.err"
rc=$?; dt=$(( $(date +%s) - t0 ))
[ "$rc" = 124 ] && [ "$NCZ_BOUNDED_TIMED_OUT" = 1 ] && ok "hung command -> rc 124, NCZ_BOUNDED_TIMED_OUT=1" || nok "hung command rc=$rc flag=$NCZ_BOUNDED_TIMED_OUT"
[ "$dt" -le 6 ] && ok "returned within the deadline (${dt}s for a 2s limit)" || nok "took ${dt}s for a 2s limit"
grep -q 'timed out after 2s' "$W/b1.err" && ok "logs 'timed out ... continuing'" || nok "no timeout log line"
grep -q started "$W/b1.out" && ok "output captured to the file" || nok "output not captured"
settle sleep 301
left=$(mine sleep 301)
[ "$left" = 0 ] && ok "the whole process group was killed (no 'sleep 301' left)" || nok "$left 'sleep 301' processes survived"
ncz_bounded_run 5 "t" "$W/b2.out" bash -c 'echo hi; exit 7'
rc=$?
[ "$rc" = 7 ] && [ "$NCZ_BOUNDED_TIMED_OUT" = 0 ] && ok "real exit status propagated (7), flag 0" || nok "rc=$rc flag=$NCZ_BOUNDED_TIMED_OUT"
ncz_bounded_run 5 "t" "$W/b3.out" bash -c 'exit 124'
rc=$?
[ "$rc" = 124 ] && [ "$NCZ_BOUNDED_TIMED_OUT" = 0 ] && ok "a command's own rc 124 is not reported as a timeout" || nok "own-124 flag=$NCZ_BOUNDED_TIMED_OUT"
t0=$(date +%s)
out=$(NCZ_BOUNDED_STREAM=1 ncz_bounded_run 2 "t" "$W/b4.out" bash -c 'echo streamed; sleep 302 & sleep 302' 2>/dev/null)
dt=$(( $(date +%s) - t0 ))
printf '%s\n' "$out" | grep >/dev/null streamed && ok "stream mode copies output to stdout" || nok "stream mode lost output"
[ "$dt" -le 6 ] && ok "stream mode returns on the deadline too (${dt}s)" || nok "stream mode took ${dt}s"
# no-setsid path: the started PID shares the caller's process group, so a
# group kill would hit the caller; only the PID and its descendants may die
sleep 305 &
sib=$!
t0=$(date +%s)
NCZ_BOUNDED_SETSID=0 ncz_bounded_run 2 "t" "$W/b5.out" bash -c 'sleep 303 & sleep 303' 2>/dev/null
rc=$?; dt=$(( $(date +%s) - t0 ))
[ "$rc" = 124 ] && [ "$dt" -le 6 ] && ok "no-setsid path also times out (${dt}s, rc 124)" || nok "no-setsid path rc=$rc after ${dt}s"
settle sleep 303
[ "$(mine sleep 303)" = 0 ] && ok "no-setsid path killed the command and its child" || nok "no-setsid path left $(mine sleep 303) 'sleep 303'"
kill -0 "$sib" 2>/dev/null && ok "a sibling in the caller's process group survived (no group kill)" || nok "the caller's process group was signalled"
kill "$sib" 2>/dev/null; wait "$sib" 2>/dev/null
else
    nok "post-install/lib/bounded-run.sh missing"
fi

echo "=== 2. run-all.sh watchdog on a hanging optional hook ==="
RA="$W/ra"; mkdir -p "$RA/hooks/lib" "$RA/log" "$RA/shim"
cp "$ROOT/post-install/run-all.sh" "$RA/hooks/"
cp "$ROOT/post-install/lib/bounded-run.sh" "$RA/hooks/lib/"
printf '#!/bin/bash\necho kernel ok\n' > "$RA/hooks/10-amd64-kernel.sh"
printf '#!/bin/bash\necho gpu hook starts\nsleep 3603 &\nsleep 3603\n' > "$RA/hooks/54-gpu-accel.sh"
printf '#!/bin/bash\necho greeter ran > "%s/greeter.ran"\n' "$RA" > "$RA/hooks/55-greeter.sh"
chmod +x "$RA/hooks/"*.sh
t0=$(date +%s)
env NCZ_HOOK_DIR="$RA/hooks" NCZ_LOGDIR="$RA/log" NCZ_TTY=/dev/null NCZ_APT_SHIM_DIR="$RA/shim" \
    NCZ_DISABLE_APT_SHIM=1 NCZ_TARGET_ARCH=amd64 NCZ_OPT_HOOK_TIMEOUT=3 \
    timeout -k 5 90 bash "$RA/hooks/run-all.sh" > "$RA/out" 2>&1
rc=$?; dt=$(( $(date +%s) - t0 ))
[ "$rc" != 124 ] && [ "$dt" -lt 60 ] && ok "run-all.sh finished in ${dt}s (rc $rc) despite a hook that never exits" || nok "run-all.sh rc=$rc after ${dt}s"
[ -e "$RA/greeter.ran" ] && ok "the next optional hook (55-greeter) still ran" || nok "55-greeter never ran"
grep -q '54-gpu-accel.sh timed out after 3s, continuing' "$RA/out" && ok "console log says '54-gpu-accel.sh timed out after 3s, continuing'" || nok "no timeout line in run-all output"
grep -q 'timed out after 3s, continuing' "$RA/log/54-gpu-accel.log" && ok "the hook's own log records the timeout" || nok "hook log lacks the timeout"
grep -q 'gpu hook starts' "$RA/out" && ok "hook output still streamed to the console" || nok "hook output not streamed"
grep -q 'some optional hooks failed: *54-gpu-accel.sh' "$RA/out" && ok "timed-out hook is counted as failed" || nok "timed-out hook not in FAILED_HOOKS"
settle sleep 3603; settle sleep 302
left=$(( $(mine sleep 3603) + $(mine sleep 302) ))
[ "$left" = 0 ] && ok "no hook processes left behind" || nok "$left hook processes left behind"


echo
echo "test-hook-watchdog: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
