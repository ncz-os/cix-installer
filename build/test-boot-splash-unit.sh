#!/bin/bash
# test-boot-splash-unit.sh -- post-install/60-boot-splash.sh: the splash unit's
# start timeout outlives the wrapper's own cap, the wrapper's DRM-ownership
# cap is bounded to total <= 8 s (2026-10-27 DELL .70: an unbounded handoff
# wait held DRM 16 s past the greeter's drmSetMaster), a splash that gives up
# at its cap (timeout rc 124/137) or cannot own DRM (rc 1) is a clean exit,
# and a real crash still fails the unit (2026-10-26: TimeoutStartSec
# equalled the wrapper cap, so systemd killed a gracefully-releasing splash
# and the unit failed on a slow first boot). Also asserts the ordering
# contract: greetd is ordered After= the splash unit (55-greeter.sh drop-in),
# the splash no longer claims the greeter-ready marker as a dependency, and
# the splash must not block on that marker beyond its cap.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HOOK="${NCZ_HOOK_UNDER_TEST:-$ROOT/post-install/60-boot-splash.sh}"
GREET_HOOK="$ROOT/post-install/55-greeter.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/boot-splash-unit.XXXXXX")" || exit 2
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }
unit=$(sed -n "/^cat > \/etc\/systemd\/system\/singularity-boot-splash.service <<'UNIT'$/,/^UNIT$/p" "$HOOK")
wrap=$(sed -n "/^cat > \/usr\/local\/bin\/ncz-boot-splash <<'WRAPPER'$/,/^WRAPPER$/p" "$HOOK" | sed '1d;$d')
[ -n "$unit" ] && [ -n "$wrap" ] || { bad "unit or wrapper heredoc not found in the hook"; echo "--- $pass passed, $fail failed"; exit 1; }
secs() { case "$1" in *min) echo $(( ${1%min} * 60 )) ;; *s) echo "${1%s}" ;; *) echo "$1" ;; esac; }
ts=$(secs "$(sed -n 's/^TimeoutStartSec=//p' <<<"$unit")")
cap=$(sed -n 's/.*timeout --kill-after=\([0-9]*\)s \([0-9]*\)s .*/\2/p' <<<"$wrap")
ka=$(sed -n 's/.*timeout --kill-after=\([0-9]*\)s \([0-9]*\)s .*/\1/p' <<<"$wrap")
if [ -n "$ts" ] && [ -n "$cap" ] && [ -n "$ka" ] && [ "$ts" -gt $((cap + ka)) ]; then
    ok "TimeoutStartSec=${ts}s outlives the wrapper cap ${cap}s + kill-after ${ka}s"
else
    bad "TimeoutStartSec=${ts:-?}s does not exceed the wrapper cap ${cap:-?}s + kill-after ${ka:-?}s"
fi
# The splash's DRM ownership must be bounded: total worst case
# (timeout cap + kill-after) <= 8 s. This is what makes the greetd After=
# ordering terminate instead of stalling the graphical boot, and what kept
# the DELL panel from waiting on a 16 s handoff.
if [ -n "$cap" ] && [ -n "$ka" ] && [ $((cap + ka)) -le 8 ]; then
    ok "wrapper DRM ownership is bounded: timeout ${cap}s + kill-after ${ka}s = $((cap + ka))s <= 8s"
else
    bad "wrapper DRM ownership ${cap:-?}s + kill-after ${ka:-?}s exceeds the 8s bound"
fi
# The cap must break the wait on the greeter-ready marker, not block on it:
# the marker is a fast handoff hint, the timeout is the hard bound.
grep -q -- '--greeter-ready /run/singularity/greeter-ready' <<<"$wrap" \
    && ok "the wrapper still accepts the greeter-ready marker as a fast handoff" || bad "greeter-ready flag missing from the wrapper"
grep -q 'timeout --kill-after' <<<"$wrap" \
    && ok "the marker wait is bounded by the timeout (it cannot block past the cap)" || bad "no timeout around the marker wait"
grep -q '^Type=oneshot$' <<<"$unit" && ok "the unit is a oneshot (its start lasts as long as the wrapper)" || bad "unit type changed"

# --- ordering contract: greetd After= splash, no cycle back ------------------
# greetd must start only after the splash released DRM (DELL .70 lost the
# drmSetMaster race and never retried). The drop-in lives in 55-greeter.sh;
# it must not be a unit rewrite of the splash.
handoff_dropin=$(awk '/<<.GREETDSPLASH.$/{f=1;next} f&&/^GREETDSPLASH$/{f=0} f' "$GREET_HOOK")
if [ -n "$handoff_dropin" ]; then
    ok "55-greeter.sh installs the splash handoff drop-in (GREETDSPLASH)"
    grep -q '^After=singularity-boot-splash.service$' <<<"$handoff_dropin" \
        && ok "greetd is ordered After= singularity-boot-splash.service (exact line)" \
        || bad "handoff drop-in has no After=singularity-boot-splash.service"
    grep -qE '^\[Service\]' <<<"$handoff_dropin" && bad "handoff drop-in touches the splash unit (must be a greetd drop-in only)" \
        || ok "handoff drop-in is greetd-scoped (no splash unit rewrite)"
    grep -q 'greetd.service.d' "$GREET_HOOK" && ok "handoff drop-in is under greetd.service.d" || bad "handoff drop-in not under greetd.service.d"
else
    bad "55-greeter.sh has no GREETDSPLASH drop-in block"
fi
# The splash unit must not order itself after greetd (the direction that would
# cycle), and the old parallel-start comment is gone.
grep -qE '^After=.*greetd' <<<"$unit" && bad "splash unit orders itself after greetd (cycle risk)" \
    || ok "splash unit does not order itself after greetd (no ordering cycle)"
# The old (wrong) comment "greetd starts ... in parallel with this unit" must
# be gone. The ordering-contract comment legitimately says "do not ... in
# parallel", so check for the specific stale phrasing, not the word "parallel".
grep -q 'greetd starts.*in parallel\|starts after USB readiness in parallel' <<<"$unit" \
    && bad "unit still documents greetd starting in parallel" \
    || ok "unit no longer documents a parallel greetd start"
# The splash cannot wait for the greeter past its cap: with a bounded timeout
# around the marker wait (asserted above) plus the 8s bound, the After= wait
# terminates. Document the bound in the unit itself.
grep -q '8 s' <<<"$unit" && ok "splash unit documents the bounded cap" || bad "splash unit does not document the cap bound"
# Run the real wrapper against a stub splash: sandboxed sysfs/dev, short cap.
mkdir -p "$T/sys/card0-HDMI-A-1" "$T/dev" "$T/run"
echo connected > "$T/sys/card0-HDMI-A-1/status"; : > "$T/dev/card0"
printf '%s\n' "$wrap" | sed -e "s#/sys/class/drm#$T/sys#g" -e "s#/dev/dri#$T/dev#g" \
    -e "s#/run/singularity#$T/run#g" -e "s#^BSP=.*#BSP=$T/bsp#" \
    -e 's#timeout --kill-after=[0-9]*s [0-9]*s#timeout --kill-after=1s 1s#' > "$T/wrapper.sh"
run() {  # run <stub body> -> wrapper exit code
    printf '#!/bin/sh\n%s\n' "$1" > "$T/bsp"; chmod +x "$T/bsp"
    sh "$T/wrapper.sh" > "$T/out" 2>&1; echo $?
}
[ "$(run 'exit 0')" = 0 ] && ok "a splash that hands off to the greeter exits 0" || bad "clean handoff did not exit 0"
[ "$(run 'sleep 30')" = 0 ] && grep -q 'handoff/headless (rc=124)' "$T/out" \
    && ok "a splash that runs into the cap (timeout rc 124) is a clean exit" || bad "cap path is not a clean exit: $(cat "$T/out")"
[ "$(run 'trap "" TERM; sleep 30')" = 0 ] && grep -q 'rc=137' "$T/out" \
    && ok "a splash that ignores TERM and is killed (rc 137) is a clean exit" || bad "kill-after path: $(cat "$T/out")"
[ "$(run 'exit 1')" = 0 ] && ok "a splash that cannot own DRM (rc 1) is a clean exit" || bad "rc 1 not clean"
[ "$(run 'exit 2')" = 2 ] && ok "a splash crash (rc 2) still fails the unit" || bad "rc 2 swallowed"
[ "$(run 'kill -SEGV $$')" = 139 ] && ok "a splash killed by SIGSEGV (rc 139) still fails the unit" || bad "SIGSEGV swallowed"
echo "--- $pass passed, $fail failed"
[ "$fail" = 0 ]
