#!/usr/bin/env bash
# test-image-ci-units.sh -- the installed-loop units must stay valid and inert.
#
# The image CI loop is three files: a oneshot service, a timer, and a host env
# example. They are INSTALLED BY THE OPERATOR, so a broken unit is a silent
# failure at 3 a.m. rather than in CI. This test keeps them honest offline:
# systemd's own parser when it is available, and structural assertions for the
# properties that matter (it must actually build, and it must never publish).
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
D="$REPO/build/systemd"
SVC="$D/image-ci-poll.service"
TMR="$D/image-ci-poll.timer"
ENVF="$D/image-ci.env.example"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS  $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }

for f in "$SVC" "$TMR" "$ENVF"; do
    [ -s "$f" ] && ok "$(basename "$f") exists and is non-empty" || bad "$(basename "$f") exists and is non-empty"
done

# 1. systemd's own parser, when present
if command -v systemd-analyze >/dev/null 2>&1; then
    out="$(systemd-analyze verify "$SVC" "$TMR" 2>&1)"; rc=$?
    if [ "$rc" = 0 ] && ! printf '%s' "$out" | grep -q 'image-ci'; then
        ok "systemd-analyze verify accepts both units with no finding about them"
    else
        bad "systemd-analyze verify accepts both units" "$(printf '%s\n' "$out" | grep image-ci | head -3)"
    fi
else
    echo "  SKIP  systemd-analyze is not installed here"
fi

# 2. the service must actually build (--execute) and must never publish
grep -q 'image-ci-run.sh --execute' "$SVC" \
    && ok "the service runs the runner with --execute (it builds, not just plans)" \
    || bad "the service does not run image-ci-run.sh --execute"
grep -q '^Type=oneshot' "$SVC" && ok "the service is oneshot" || bad "the service is not Type=oneshot"
# Directives only: a comment saying "the runner refuses to publish" is not a hook.
# One grep, no pipe: piping into `grep -q` under pipefail can report "no match"
# when the first grep dies of SIGPIPE, which would be a false negative here.
if grep -qiE '^(ExecStart|ExecStartPre|ExecStop|Environment)=.*(publish|reprepro|r2/)' "$SVC"; then
    bad "the service executes a publish hook"
else
    ok "no ExecStart/Environment directive publishes"
fi
grep -q 'EnvironmentFile=-/etc/ncz/image-ci.env' "$SVC" \
    && ok "host-specific paths come from an environment file, not the unit" \
    || bad "the unit hardcodes or omits the environment file"

# 3. the timer must be periodic and survive a missed run
for want in 'OnUnitActiveSec=30min' 'Persistent=true' 'RandomizedDelaySec=' 'WantedBy=timers.target'; do
    grep -q -- "$want" "$TMR" && ok "timer: $want" || bad "timer is missing: $want"
done

# 4. the env example must name every input the runner needs
for want in NCZ_IMAGE_CI_REPO NCZ_PAYLOAD_SRC_ROOT NCZ_SSPLUGIN_SRC_ROOT; do
    grep -q "^$want=" "$ENVF" && ok "env example defines $want" || bad "env example lacks $want"
done

# 5. the units must not be installed by this repo (operator's action)
if grep -rq 'systemctl enable' "$D" 2>/dev/null; then
    bad "the repo installs the timer itself (that is the operator's call)"
else
    ok "nothing here installs the timer by itself"
fi

echo "test-image-ci-units: $pass passed, $fail failed"
[ "$fail" = 0 ]
