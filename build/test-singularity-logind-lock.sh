#!/bin/bash
# test-singularity-logind-lock.sh -- the shell patch that makes
# `loginctl lock-session` and a logind-initiated suspend lock the session
# (assets/singularity/patches/singularity-shell/0022-core-follow-logind-lock-*).
#
# Static part (always): the patch is in the queue, wires the listener into the
# shell build and startup, subscribes to Session.Lock/Unlock and
# Manager.PrepareForSleep with logind as the sender, takes a "sleep" *delay*
# inhibitor, reads the lock-on-suspend key, and locks through the shell's
# existing PowerActions.lock_screen() path. It must not touch the lock client
# (src/lockscreen/), so the frame-source backoff (0020) and the
# screensaver-then-lock order are unchanged.
#
# Dynamic part (when valac, gio-unix-2.0 and dbus-daemon exist): the new
# sources are extracted from the patch and its unit test runs against a fake
# logind on a GTestDBus bus.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
Q="$ROOT/assets/singularity/patches/singularity-shell"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

P="$(ls "$Q"/0022-core-follow-logind-lock-*.patch 2>/dev/null | head -1)"
if [ -z "$P" ]; then bad "shell patch 0022 (logind lock) is in the queue"; echo "test-singularity-logind-lock: $pass passed, $fail failed"; exit 1; fi
ok "shell patch $(basename "$P") is in the queue"

has() { grep -qF -- "$1" "$P"; }
has "+    'src/core/logind_lock.vala'," && has "+    'src/core/logind_lock_shell.vala'," && ok "listener sources are in the shell build" || bad "listener sources not in meson.build"
has "+        Singularity.LogindLock.start();" && ok "shell starts the listener at startup" || bad "listener not started in main.vala"
has "+test('logind-lock', logind_lock_test" && ok "unit test registered with meson" || bad "unit test not registered"
has 'bus.signal_subscribe(BUS_NAME, SESSION_IFACE, null, session_path' && ok "Session signals on the shell's own session, sender logind" || bad "Session subscription missing or not sender-filtered"
has '"PrepareForSleep", MANAGER_PATH' && ok "Manager.PrepareForSleep subscription" || bad "PrepareForSleep subscription missing"
has '"sleep", "Singularity", "Lock the screen before the system sleeps", "delay"' && ok "sleep inhibitor is a delay lock (never block)" || bad "inhibitor is not a sleep delay"
has 'get_boolean("lock-on-suspend")' && ok "honours dev.sinty.lockscreen lock-on-suspend" || bad "lock-on-suspend not read"
has '+            PowerActions.get_default().lock_screen();' && ok "locks through PowerActions.lock_screen() (idle-lock path)" || bad "does not use the shell lock path"
has 'if (locker.is_locked()) {' && ok "lock request while locked is a no-op" || bad "no idempotency check"
has 'repeat_guard_us' && ok "repeat guard against a lock-session loop" || bad "no repeat guard"
has 'sleep_wait_max_ms = 3000' && ok "sleep wait bounded below logind's 5 s delay" || bad "sleep wait not bounded"
if grep -E '^(\+\+\+|---) [ab]/src/lockscreen/' "$P" >/dev/null; then bad "patch touches the lock client (0020 backoff / saver order)"; else ok "lock client untouched (0020 backoff and saver order unchanged)"; fi
grep -qiE '^(Assisted-by|AI-Scope|Co-Authored-By):' "$P" && bad "carried patch has attribution trailers" || ok "carried patch has no attribution trailers"

# extract new files (whole-file additions) from the patch into DIR. The unit
# test needs only the two new sources; a missing one fails the test below.
extract() {
    awk -v dir="$1" '
        /^diff --git / { out = ""; next }
        /^\+\+\+ b\// { path = substr($0, 7); next }
        /^@@ -0,0 / { out = dir "/" path; n = split(path, a, "/"); d = dir; for (i = 1; i < n; i++) { d = d "/" a[i]; system("mkdir -p \"" d "\"") } printf "" > out; next }
        /^@@ / { out = ""; next }
        out != "" && /^\+/ { print substr($0, 2) >> out; next }
        out != "" && /^\\/ { next }
    ' "$P"
}

if command -v valac >/dev/null 2>&1 && pkg-config --exists gio-unix-2.0 2>/dev/null && command -v dbus-daemon >/dev/null 2>&1; then
    T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
    extract "$T/src"
    if [ -f "$T/src/src/core/logind_lock.vala" ] && [ -f "$T/src/tests/logind_lock_test.vala" ]; then
        ok "new sources extracted from the patch"
        if (cd "$T" && valac -q -d "$T/build" --pkg gio-2.0 --pkg gio-unix-2.0 --pkg posix -X -w \
                -o logind-lock-test src/src/core/logind_lock.vala src/tests/logind_lock_test.vala >"$T/valac.log" 2>&1); then
            ok "unit test compiles"
            out="$(cd "$T" && timeout 120 "$T/build/logind-lock-test" 2>&1)"; rc=$?
            res="$(printf '%s\n' "$out" | grep '^== RESULT' | tail -1)"
            if [ "$rc" = 0 ] && printf '%s' "$res" | grep -q ' 0 failed'; then ok "unit test against a fake logind: ${res#== RESULT: }"
            else bad "unit test rc=$rc: $res"; printf '%s\n' "$out" | grep -E 'FAIL' | head; fi
        else
            bad "unit test does not compile"; grep -i error "$T/valac.log" | head
        fi
    else
        bad "could not extract the new sources from the patch"
    fi
else
    echo "skip unit test: needs valac, gio-unix-2.0 and dbus-daemon"
fi

echo "test-singularity-logind-lock: $pass passed, $fail failed"
[ "$fail" = 0 ]
