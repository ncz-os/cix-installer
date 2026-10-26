#!/bin/bash
# test-boot-splash-unit.sh -- post-install/60-boot-splash.sh: the splash unit's
# start timeout outlives the wrapper's own cap, a splash that gives up at its
# cap (timeout rc 124/137) or cannot own DRM (rc 1) is a clean exit, and a
# real crash still fails the unit (2026-10-26: TimeoutStartSec equalled the
# wrapper cap, so systemd killed a gracefully-releasing splash and the unit
# failed on a slow first boot).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HOOK="${NCZ_HOOK_UNDER_TEST:-$ROOT/post-install/60-boot-splash.sh}"
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
grep -q '^Type=oneshot$' <<<"$unit" && ok "the unit is a oneshot (its start lasts as long as the wrapper)" || bad "unit type changed"
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
