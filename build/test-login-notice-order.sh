#!/bin/bash
# test-login-notice-order.sh -- on a first login the desktop tour comes first.
#
# Three notices start at login with the tour: the quote of the day
# (post-install/57-qotd.sh), the firewall notice (post-install/34-firewall.sh)
# and the update notifier (assets/update-manager/ncz-update-notifier). Each
# calls `ncz-first-login-tour wait-done` before it notifies, so on a first
# login (no tour-seen marker) it holds back until the tour has closed, at most
# a bounded time; on every later login wait-done returns at once.
#
# This test drives wait-done through every state with the NCZ_TOUR_* seams
# (no Wayland, no session, no real tour) and checks that all three notices
# call it before they sleep and notify.
#
# Usage: bash build/test-login-notice-order.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${NCZ_FIRSTLOGIN_TOUR:-$ROOT/assets/branding/first-login-tour/ncz-first-login-tour}"
QOTD_HOOK="$ROOT/post-install/57-qotd.sh"
FW_HOOK="$ROOT/post-install/34-firewall.sh"
NOTIFIER="$ROOT/assets/update-manager/ncz-update-notifier"
GATE='/usr/local/bin/ncz-first-login-tour wait-done'

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1" >&2; }

for f in "$SCRIPT" "$QOTD_HOOK" "$FW_HOOK" "$NOTIFIER"; do
    [ -f "$f" ] || { bad "missing: $f"; echo "1..0"; exit 1; }
done

W="$(mktemp -d "${TMPDIR:-/tmp}/ncz-notice-order.XXXXXX")"
trap 'rm -rf "$W"' EXIT

N=0
mk_sandbox() { N=$((N + 1)); S="$W/s-$N"; mkdir -p "$S/home" "$S/state" "$S/config" "$S/run"; }
# wait_case <name> <min_s> <max_s> [VAR=VAL ...] -- run wait-done in the
# sandbox, require exit 0 and an elapsed time within [min_s, max_s].
wait_case() {
    local name="$1" lo="$2" hi="$3" t0 el rc
    shift 3
    t0=$(date +%s)
    env -i PATH="$PATH" HOME="$S/home" \
        NCZ_TOUR_STATE_HOME="$S/state" NCZ_TOUR_CONFIG_HOME="$S/config" \
        NCZ_TOUR_OPT_OUT="$S/no-such-optout" NCZ_TOUR_UID=1000 \
        NCZ_TOUR_WAYLAND=1 NCZ_TOUR_DRM_STATUS=connected NCZ_TOUR_LIVE=0 \
        NCZ_TOUR_FIRST_RUN=0 NCZ_TOUR_LOCKED=0 NCZ_TOUR_RUNNING=0 \
        NCZ_TOUR_RUNTIME_DIR="$S/run" NCZ_TOUR_WAIT_STEP=0.2 \
        "$@" sh "$SCRIPT" wait-done "${WAIT_MAX:-3}" >/dev/null 2>&1
    rc=$?
    el=$(( $(date +%s) - t0 ))
    if [ "$rc" -ne 0 ]; then bad "$name: exit $rc (wait-done must always exit 0)"; return; fi
    if [ "$el" -ge "$lo" ] && [ "$el" -le "$hi" ]; then ok "$name (${el}s)"; else bad "$name: took ${el}s, want ${lo}-${hi}s"; fi
}
seen() { mkdir -p "$S/state/ncz"; : >"$S/state/ncz/tour-seen"; }
state() { printf '%s\n' "$1" >"$S/run/first-login-tour.state"; }
age() { touch -d "-$1 seconds" "$S/run/first-login-tour.state"; }

# --- later logins and no-tour sessions: no wait --------------------------------------------------
mk_sandbox; seen
wait_case "later login (tour seen, no state): returns at once" 0 1
mk_sandbox; seen; state closed
wait_case "state closed: returns at once" 0 1
mk_sandbox; : >"$S/optout"
wait_case "admin opt-out, no state: returns at once" 0 1 NCZ_TOUR_OPT_OUT="$S/optout"
mk_sandbox
wait_case "headless session, no state: returns at once" 0 1 NCZ_TOUR_DRM_STATUS=disconnected
mk_sandbox
wait_case "root session: returns at once" 0 1 NCZ_TOUR_UID=0

# --- first login: hold until the tour is out of the way -------------------------------------------
mk_sandbox
wait_case "first login, launcher not started yet: waits to the bound" 3 5
mk_sandbox; state pending
wait_case "launcher settling (pending): waits to the bound" 3 5
mk_sandbox; seen; state open
wait_case "tour window open: waits to the bound" 3 5 NCZ_TOUR_RUNNING=1
mk_sandbox; seen; state open; age 30
wait_case "tour closed (open state, no window): returns at once" 0 1
mk_sandbox; seen; state open
WAIT_MAX=20 wait_case "just launched, no window yet: 5 s grace, then returns" 4 7
mk_sandbox; state pending; age 120
wait_case "stale pending state from an earlier launcher: returns at once" 0 1

# pending -> closed while waiting: returns promptly after the change.
mk_sandbox; state pending
( sleep 1; printf 'closed\n' >"$S/run/first-login-tour.state" ) &
WAIT_MAX=20 wait_case "pending then closed: returns after the change" 1 3

# open -> window gone while waiting (NCZ_TOUR_RUNNING follows a file here).
mk_sandbox; seen; state open; age 30
mkdir -p "$W/run-stub"
cat >"$W/run-stub/pgrep" <<STUB
#!/bin/sh
[ -e "$S/window" ]
STUB
chmod +x "$W/run-stub/pgrep"
: >"$S/window"
( sleep 2; rm -f "$S/window" ) &
t0=$(date +%s)
env -i PATH="$W/run-stub:$PATH" HOME="$S/home" NCZ_TOUR_STATE_HOME="$S/state" NCZ_TOUR_CONFIG_HOME="$S/config" \
    NCZ_TOUR_RUNTIME_DIR="$S/run" NCZ_TOUR_WAIT_STEP=0.2 sh "$SCRIPT" wait-done 20 >/dev/null 2>&1
el=$(( $(date +%s) - t0 ))
if [ "$el" -ge 1 ] && [ "$el" -le 4 ]; then ok "tour window closes while waiting: returns (${el}s, pgrep path)"; else bad "window close not noticed: ${el}s"; fi

# A non-numeric bound falls back to the default instead of failing.
mk_sandbox; seen
t0=$(date +%s)
env -i PATH="$PATH" HOME="$S/home" NCZ_TOUR_STATE_HOME="$S/state" NCZ_TOUR_RUNTIME_DIR="$S/run" \
    sh "$SCRIPT" wait-done abc >/dev/null 2>&1; rc=$?
if [ "$rc" = 0 ] && [ $(( $(date +%s) - t0 )) -le 1 ]; then ok "non-numeric bound: exit 0, no wait on a later login"; else bad "non-numeric bound: rc=$rc"; fi

# --- the three notices call the gate before they sleep and notify -----------------------------------
# body <file> <heredoc tag> -- the script a hook writes from a quoted heredoc.
body() { awk -v tag="$2" '$0 ~ "<<\x27" tag "\x27" {on=1; next} on && $0 == tag {exit} on {print}' "$1"; }
gate_before() {   # gate_before <name> <script text>
    local name="$1" text="$2" g s n
    g=$(printf '%s\n' "$text" | grep -n -F "$GATE" | head -1 | cut -d: -f1)
    s=$(printf '%s\n' "$text" | grep -n -E '^sleep ' | head -1 | cut -d: -f1)
    n=$(printf '%s\n' "$text" | grep -n -E '^notify-send' | head -1 | cut -d: -f1)
    if [ -n "$g" ] && [ -n "$s" ] && [ -n "$n" ] && [ "$g" -lt "$s" ] && [ "$g" -lt "$n" ]; then
        ok "$name: waits for the tour before it sleeps and notifies"
    else
        bad "$name: gate line ${g:-missing}, sleep ${s:-?}, notify-send ${n:-?}"
    fi
    if printf '%s\n' "$text" | grep -q -F "[ -x /usr/local/bin/ncz-first-login-tour ] && $GATE"; then
        ok "$name: gate is optional (no launcher installed -> no wait)"
    else
        bad "$name: gate is not guarded by [ -x ]"
    fi
}
gate_before "quote of the day (ncz-qotd-notify)" "$(body "$QOTD_HOOK" NOTIFY)"
gate_before "firewall notice (ncz-firewall-notify)" "$(body "$FW_HOOK" NOTIFY)"
# The firewall notice still exits first when nftables is active (no gate wait).
fw="$(body "$FW_HOOK" NOTIFY)"
a=$(printf '%s\n' "$fw" | grep -n 'is-active --quiet nftables' | cut -d: -f1)
g=$(printf '%s\n' "$fw" | grep -n -F "$GATE" | cut -d: -f1)
if [ -n "$a" ] && [ -n "$g" ] && [ "$a" -lt "$g" ]; then ok "firewall notice: an active firewall exits before the gate"; else bad "firewall notice: gate before the nftables check"; fi

# Gated scripts run: with a stub gate on PATH they still notify.
for pair in "qotd:$QOTD_HOOK" "firewall:$FW_HOOK"; do
    nm=${pair%%:*}; hook=${pair#*:}
    mkdir -p "$W/run-$nm/bin"
    body "$hook" NOTIFY | sed -e "s#/usr/local/bin/ncz-first-login-tour#$W/run-$nm/bin/gate#g" \
        -e "s#/usr/local/bin/ncz-qotd#$W/run-$nm/bin/qotd#g" -e 's/^sleep [0-9]*/sleep 0/' >"$W/run-$nm/notify"
    printf '#!/bin/sh\necho "$*" >>"%s/run-%s/gate.log"\n' "$W" "$nm" >"$W/run-$nm/bin/gate"
    printf '#!/bin/sh\necho a quote\n' >"$W/run-$nm/bin/qotd"
    printf '#!/bin/sh\necho sent >>"%s/run-%s/sent.log"\n' "$W" "$nm" >"$W/run-$nm/bin/notify-send"
    printf '#!/bin/sh\nexit 3\n' >"$W/run-$nm/bin/systemctl"
    chmod +x "$W/run-$nm/bin/"*
    PATH="$W/run-$nm/bin:$PATH" sh "$W/run-$nm/notify" >/dev/null 2>&1
    if [ "$(cat "$W/run-$nm/gate.log" 2>/dev/null)" = wait-done ] && [ -s "$W/run-$nm/sent.log" ]; then
        ok "$nm notice: runs the gate (wait-done) and then notifies"
    else
        bad "$nm notice: gate '$(cat "$W/run-$nm/gate.log" 2>/dev/null)', sent '$(cat "$W/run-$nm/sent.log" 2>/dev/null)'"
    fi
done

# The update notifier: the gate runs first, bounded, and its time counts
# towards the usual 90 s login delay (later logins: unchanged 90 s).
if command -v python3 >/dev/null 2>&1; then
    out="$(python3 - "$NOTIFIER" "$W" <<'PY'
import importlib.machinery, importlib.util, os, sys, time
path, work = sys.argv[1], sys.argv[2]
loader = importlib.machinery.SourceFileLoader("ncz_update_notifier", path)
spec = importlib.util.spec_from_loader("ncz_update_notifier", loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
gate = os.path.join(work, "py-gate")
with open(gate, "w") as f:
    f.write('#!/bin/sh\necho "$*" >"%s/py-gate.log"\nsleep 1\n' % work)
os.chmod(gate, 0o755)
mod.TOUR_GATE = gate
t0 = time.monotonic()
mod.wait_for_first_login_tour()
el = time.monotonic() - t0
args = open(os.path.join(work, "py-gate.log")).read().strip()
mod.TOUR_GATE = os.path.join(work, "no-such-gate")
t1 = time.monotonic(); mod.wait_for_first_login_tour(); el2 = time.monotonic() - t1
print(args, "%.1f" % el, "%.1f" % el2, mod.LOGIN_DELAY)
PY
)"
    set -- $out
    if [ "${1:-} ${2:-}" = "wait-done 90" ] && [ "${4:-}" = "0.0" ] && [ "${5:-}" = 90 ]; then
        ok "update notifier: calls wait-done 90 (bounded), skips without the launcher, login delay 90 s"
    else
        bad "update notifier: gate call/delay wrong ($out)"
    fi
    if grep -q 'LOGIN_DELAY - (time.monotonic() - started)' "$NOTIFIER"; then
        ok "update notifier: time spent waiting counts towards the 90 s login delay"
    else
        bad "update notifier: login delay is not reduced by the tour wait"
    fi
else
    ok "update notifier: python3 case skipped (no python3)"
fi

echo "$((PASS + FAIL)) checks, $PASS ok, $FAIL failed"
[ "$FAIL" -eq 0 ]
