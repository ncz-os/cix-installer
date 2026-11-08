#!/usr/bin/env bash
# Tests for image-ci-run.sh: the loop that turns a trigger into a build.
#
# The properties that matter are the ones that could hurt: nothing publishes, a
# host is never given two builds, a skipped action says why, and a launch that
# fails does not consume the trigger. A dry run must start nothing at all.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
RUN="$HERE/image-ci-run.sh"
pass=0
fail=0
ok()  { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
nok() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

[ -f "$RUN" ] || { echo "missing $RUN"; exit 1; }
command -v python3 >/dev/null || { echo "SKIP: no python3"; exit 0; }

T="$(mktemp -d)"
cleanup() {
    if [ -f "$T/markers/ncz-image-ci-forky-pin" ]; then
        p="$(cat "$T/markers/ncz-image-ci-forky-pin" 2>/dev/null)"
        [ -n "$p" ] && kill "$p" 2>/dev/null
    fi
    rm -rf "$T"
}
trap cleanup EXIT

export NCZ_IMAGE_CI_STATE="$T/state.json"
export NCZ_IMAGE_CI_MARKER_DIR="$T/markers"
export NCZ_IMAGE_CI_RUNS="$T/runs"
mkdir -p "$T/markers" "$T/runs"
# A state that remembers an older pin than manifests/base.pin carries, so exactly
# the forky trigger reports WOULD TRIGGER without depending on the network.
printf '{"forky.stamp":"20200101T000000Z"}' > "$NCZ_IMAGE_CI_STATE"

# 1. dry run plans the image build and starts nothing
out="$(cd "$HERE/.." && bash "$RUN" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "dry run exits 0" || nok "dry run exited $rc"
printf '%s' "$out" | grep  'forky-pin.*WOULD RUN' >/dev/null \
    && ok "dry run names the forky trigger and the command" \
    || nok "dry run did not plan the forky trigger: $(printf '%s' "$out" | head -3)"
# An image trigger runs the matrix for this host's arch: desktop AND server
# (Magnetar), each built twice and compared (image-ci-matrix.sh).
printf '%s' "$out" | grep 'forky-pin.*WOULD RUN' | grep 'build/image-ci-matrix.sh --foreground --arch' >/dev/null \
    && ok "the planned command is the image matrix for this host's arch" \
    || nok "the planned command is not the image matrix: $(printf '%s' "$out" | grep forky-pin | head -1)"
mx="$(cd "$HERE/.." && bash build/image-ci-matrix.sh --arch "$(dpkg --print-architecture 2>/dev/null || echo amd64)" 2>&1)"
[ "$(grep -c '^cell \(desktop\|server\)/' <<<"$mx")" = 2 ] \
    && ok "that matrix covers both variants" || nok "the matrix does not cover desktop and server: $(grep '^cell' <<<"$mx")"
! grep '^  build' <<<"$mx" | grep -v -- '--no-publish' | grep -q . && grep -q '^  build a:' <<<"$mx" \
    && ok "every build the matrix plans carries --no-publish" \
    || nok "a build the matrix plans does not carry --no-publish"
[ -z "$(ls -A "$T/markers" 2>/dev/null)" ] && ok "dry run wrote no marker" || nok "dry run wrote a marker"
[ ! -e "$T/runs/launched.jsonl" ] && ok "dry run recorded no launch" || nok "dry run recorded a launch"

# 2. a command that would publish is refused before anything runs
out="$(cd "$HERE/.." && NCZ_IMAGE_CI_CMD_FORKY_PIN='bash build/ncz-reprepro-publish.sh' bash "$RUN" 2>&1)"; rc=$?
[ "$rc" = 2 ] && ok "a publishing command is refused with exit 2" || nok "publishing command exited $rc, wanted 2"
printf '%s' "$out" | grep 'refusing to start' >/dev/null && ok "the refusal says why" || nok "the refusal does not say why"

# 3. a host already building is skipped, with the reason
out="$(cd "$HERE/.." && NCZ_IMAGE_CI_CMD_FORKY_PIN='true' bash "$RUN" 2>&1)"
printf '%s' "$out" | grep 'WOULD RUN' >/dev/null && ok "control: without a marker the action is planned" || nok "control failed"
# a genuinely live pid: the marker must be judged by whether that process runs
sleep 30 & LIVE=$!
printf '%s\n' "$LIVE" > "$T/markers/ncz-image-ci-forky-pin"
out="$(cd "$HERE/.." && NCZ_IMAGE_CI_CMD_FORKY_PIN='true' bash "$RUN" 2>&1)"
kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null
printf '%s' "$out" | grep  'SKIP: a build already holds' >/dev/null \
    && ok "an existing live marker skips the action and names it" \
    || nok "an existing live marker did not skip the action"
rm -f "$T/markers/ncz-image-ci-forky-pin"

# 3b. a marker whose pid is gone must not block the trigger forever
printf '999999\n' > "$T/markers/ncz-image-ci-forky-pin"
out="$(cd "$HERE/.." && NCZ_IMAGE_CI_CMD_FORKY_PIN='true' bash "$RUN" 2>&1)"
printf '%s' "$out" | grep  'clearing a stale marker' >/dev/null \
    && ok "a stale marker is cleared and named" \
    || nok "a stale marker blocked the trigger: $(printf '%s' "$out" | grep forky | head -1)"
[ ! -e "$T/markers/ncz-image-ci-forky-pin" ] && ok "the stale marker is gone" || nok "the stale marker survived"
# 3c. the reservation is atomic AND never empty (an empty marker reads as stale)
grep -q 'set -C; printf' "$RUN" && ok "the marker is reserved with O_EXCL semantics and a pid" \
    || nok "the marker is reserved by a check-then-create race, or reserved empty"
# 3e. the child writes its own pid, so a runner crash cannot leave a stale marker
grep -q 'BASHPID" > "$marker"' "$RUN" \
    && ok "the child records its own pid before exec (no crash window)" \
    || nok "the marker pid is written by the parent, leaving a crash window"

# 3d. the recorded pid must be the subshell that WAITS for the build, not a wrapper.
# Assert the property, not the exact line: the child block is the range from the
# marker write to the ") &" that backgrounds it, and that block must (i) run the
# build through setsid in a NESTED context so the pid survives, and (ii) release
# the marker afterwards.
# The range must end at THIS block's terminator, not at the next ") &" in the
# file: a loose pattern let the source assertion pass even with the cleanup
# deleted, because it picked up a later block's rm.
child_block="$(awk '/BASHPID" > "\$marker"/,/exit \$rc \) &$/' "$RUN")"
[ -n "$child_block" ] && ok "the runner's launch block is extractable" \
    || nok "could not find the launch block in image-ci-run.sh"
grep -q 'setsid bash -c "$cmd"' <<< "$child_block" \
    && ok "the recorded pid belongs to a process that outlives the wrapper" \
    || nok "the marker may record a wrapper pid that dies while the build runs"
grep -q 'rm -f "$marker"' <<< "$child_block" \
    && ok "and the same block releases the marker when the build ends" \
    || nok "the launch block never gives the marker back"

# 4. execute launches, records, keeps a marker, and advances the state
# Run it the way a timer or cron does: stdout to a file, NOT a command
# substitution. A background job started inside $( ) dies with the substitution,
# which is a property of the caller, not of the runner -- and testing through
# $( ) would report a failure the timer would never see.
( cd "$HERE/.." && NCZ_IMAGE_CI_CMD_FORKY_PIN='sleep 30' bash "$RUN" --execute > "$T/exec.log" 2>&1 ); rc=$?
out="$(cat "$T/exec.log")"
[ "$rc" = 0 ] && ok "execute exits 0 when the launch succeeds" || nok "execute exited $rc"
[ -s "$T/markers/ncz-image-ci-forky-pin" ] && ok "execute wrote a marker holding the pid" || nok "execute wrote no marker"
pid="$(cat "$T/markers/ncz-image-ci-forky-pin" 2>/dev/null)"
[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && ok "the launched process is alive" || nok "the launched pid is not alive"
grep -q '"trigger":"forky-pin"' "$T/runs/launched.jsonl" 2>/dev/null \
    && ok "the launch is recorded in launched.jsonl" || nok "no launch record"
python3 - "$NCZ_IMAGE_CI_STATE" <<'PY' && ok "the state advanced to the pin that was built" || nok "the state did not advance"
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if d.get("forky.stamp") != "20200101T000000Z" else 1)
PY
# 4b. a second execute must not double-build the same host. The state advanced in
# 4, so put it back to the stale value first: the marker, not the state, is what
# has to stop the second launch.
printf '{"forky.stamp":"20200101T000000Z"}' > "$NCZ_IMAGE_CI_STATE"
out="$(cd "$HERE/.." && NCZ_IMAGE_CI_CMD_FORKY_PIN='true' bash "$RUN" --execute 2>&1)"
printf '%s' "$out" | grep  'SKIP: a build already holds' >/dev/null \
    && ok "the same trigger cannot be launched twice on one host" \
    || nok "the runner launched (or planned) the same trigger twice: $(printf '%s' "$out" | grep forky-pin | head -1)"
lines="$(wc -l < "$T/runs/launched.jsonl" 2>/dev/null || echo 0)"
[ "$lines" = 1 ] && ok "still exactly one launch record after the blocked attempt" \
    || nok "launch records: $lines, wanted 1"

# A finished build must give its marker back.  It used to be left behind, so every
# completed build looked like a running one to host_status.sh and the next pass had
# to clear it (measured on HYDRA, cycle 483).
printf '{"forky.stamp":"20200101T000000Z"}' > "$NCZ_IMAGE_CI_STATE"
rm -f "$T/markers/ncz-image-ci-forky-pin"
out="$(cd "$HERE/.." && NCZ_IMAGE_CI_CMD_FORKY_PIN='sleep 2; true' bash "$RUN" --execute 2>&1)"
grep -q 'started pid=' <<< "$out" && ok "a short build starts" || nok "the short build did not start: $out"
sleep 5
[ ! -e "$T/markers/ncz-image-ci-forky-pin" ] \
    && ok "a finished build releases its own marker" \
    || nok "a finished build left its marker behind (pid $(cat "$T/markers/ncz-image-ci-forky-pin" 2>/dev/null))"

# ...but only its OWN.  If a successor re-took the marker while a long build ran,
# removing it would let a second build start on the same host.
printf '{"forky.stamp":"20200101T000000Z"}' > "$NCZ_IMAGE_CI_STATE"
out="$(cd "$HERE/.." && NCZ_IMAGE_CI_CMD_FORKY_PIN='sleep 3; true' bash "$RUN" --execute 2>&1)"
grep -q 'started pid=' <<< "$out" && ok "the second short build starts" || nok "the second short build did not start: $out"
sleep 1; printf '999999\n' > "$T/markers/ncz-image-ci-forky-pin"
sleep 5
[ "$(cat "$T/markers/ncz-image-ci-forky-pin" 2>/dev/null)" = "999999" ] \
    && ok "a marker re-taken by another pid is NOT removed" \
    || nok "the build removed a marker that was no longer its own"
rm -f "$T/markers/ncz-image-ci-forky-pin"

echo "test-image-ci-run: $pass passed, $fail failed"
[ "$fail" = 0 ]
