#!/bin/bash
# shellcheck disable=SC2015,SC2016,SC1091  # ok/bad return 0; literal $ in patch/regex matches; generated temp sources
# Regression test for the Singularity desktop supervisor forensics fix
# (assets/singularity/patches/singularity-session/0002-supervisor-per-run-logs-signals-core.patch).
#
# The supervisor used to append every shell run to one desktop.log, and the next
# launcher invocation moved it aside to desktop.log.1 -- destroying the crashed
# run's stdout/stderr. It logged a bare 128+N exit code, and the child inherited
# soft core limit 0, so systemd-coredump had nothing to capture. This test
# checks the patch adds per-run timestamped files with 8-file retention, decodes
# a >128 exit code to a signal name, raises the soft core limit inside the child
# subshell, and leaves the crash-count/safe-mode logic untouched.
#
# Runs standalone. The functional half uses the pinned singularity-session commit
# (cloned via build/singularity-pins.sh) and is skipped (not failed) when that
# clone is impossible (offline, pin not cached); point SINGULARITY_SESSION_SRC at
# a checkout to override.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PATCH="$ROOT/assets/singularity/patches/singularity-session/0002-supervisor-per-run-logs-signals-core.patch"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAILS=0
ok() { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAILS=$((FAILS+1)); echo "FAIL $1"; }

# ---- structural: the patch is present and carries every required change
if [ -f "$PATCH" ]; then ok "patch present"; else bad "patch present ($PATCH missing)"; fi
grep -q '^+_run_log_path()' "$PATCH"                       && ok "per-run path helper added"   || bad "per-run path helper missing"
grep -q '^+_prune_run_logs()' "$PATCH"                     && ok "retention helper added"      || bad "retention helper missing"
grep -q '^+_exit_status_text()' "$PATCH"                   && ok "signal-name helper added"    || bad "signal-name helper missing"
grep -q '^+[[:space:]]*ulimit -c unlimited' "$PATCH"       && ok "child core limit raised"     || bad "child core limit not raised"
grep -q '^+[[:space:]]*exec "\$_DESKTOP"' "$PATCH"         && ok "child exec in subshell"      || bad "child not exec'd in subshell"
grep -q '^-[[:space:]]*"\$_DESKTOP" >> "\$_LOG" 2>&1' "$PATCH" && ok "old single-log append removed" || bad "old single-log append not removed"

# The only removed lines must be the old append and the old exit echo: the
# crash-count/safe-mode body (lines 71-83 upstream) is not in the diff at all.
removed="$(grep '^-' "$PATCH" | grep -vE '^---($| )|^-- $' || true)"
removed_n="$(printf '%s\n' "$removed" | grep -c . || true)"
if [ "$removed_n" = 2 ] && ! printf '%s\n' "$removed" | grep -q 'safe-mode-request'; then
    ok "crash-count/safe-mode lines untouched"
else
    bad "crash-count/safe-mode lines changed ($removed_n removed lines)"
fi

# ---- extracted helpers: decode >128 exit codes to signal names, prune to 8
sed -n '/^+_exit_status_text() {/,/^+}/p' "$PATCH" | sed 's/^+//' > "$T/status.sh"
status_ok=1
. "$T/status.sh"
[ "$(_exit_status_text 1)" = "1" ] || status_ok=0
[ "$(_exit_status_text 139)" = "139 (signal 11: SEGV)" ] || status_ok=0
[ "$(_exit_status_text 143)" = "143 (signal 15: TERM)" ] || status_ok=0
[ "$status_ok" = 1 ] && ok "exit_status_text names SEGV/TERM, leaves normal codes" || bad "exit_status_text decoding"

sed -n '/^+_prune_run_logs() {/,/^+}/p' "$PATCH" | sed 's/^+//' > "$T/prune.sh"
mkdir -p "$T/runs"
for i in $(seq 1 10); do touch "$T/runs/desktop-old-$i.log"; sleep 0.01; done
_RUN_DIR="$T/runs"; _RUN_KEEP=8
. "$T/prune.sh"
_prune_run_logs
kept="$(find "$T/runs" -name 'desktop-*.log' | wc -l)"
[ "$kept" = 8 ] && ok "retention keeps exactly 8 run logs" || bad "retention kept $kept (want 8)"

# ---- functional: apply the patch to an upstream checkout and run the supervisor
# Default: the singularity-session commit pinned in assets/singularity/upstream-pins.tsv,
# cloned through build/singularity-pins.sh (bare-mirror cache first, then the
# network). This used to default to a stray home-directory checkout from
# 2026-10-04, so a pin bump made the patch "not apply" to a tree that is not the
# one the payload is built from.
SRC="${SINGULARITY_SESSION_SRC:-}"
if [ -z "$SRC" ] && bash "$ROOT/build/singularity-pins.sh" clone subprojects/singularity-session "$T/pinned-session" >/dev/null 2>&1; then
    SRC="$T/pinned-session"
fi
if [ -f "$SRC/src/singularity-desktop-session.in" ] && [ -f "$PATCH" ]; then
    cp -r "$SRC" "$T/sess"; rm -rf "$T/sess/.git"
    git -C "$T/sess" init -q
    git -C "$T/sess" add -A
    git -C "$T/sess" -c user.email=t@t -c user.name=t commit -qm base
    if git -C "$T/sess" apply "$PATCH"; then ok "patch applies to upstream checkout"; else bad "patch does not apply to upstream checkout"; fi

    cat > "$T/fake-desktop" <<'FAKE'
#!/bin/sh
_n=0; [ -f "$FAKE_COUNT" ] && _n=$(cat "$FAKE_COUNT")
_n=$((_n + 1)); printf '%s\n' "$_n" > "$FAKE_COUNT"
printf 'FAKE-RUN-%s core_limit=%s\n' "$_n" "$(ulimit -c)"
exit 139
FAKE
    chmod +x "$T/fake-desktop"
    mkdir -p "$T/state" "$T/rt"; chmod 700 "$T/rt"
    # the supervisor kills its PPID on safe mode; run it under a throwaway parent
    env XDG_STATE_HOME="$T/state" XDG_RUNTIME_DIR="$T/rt" \
        FAKE_COUNT="$T/count" SINGULARITY_DESKTOP_BINARY="$T/fake-desktop" \
        SINGULARITY_SESSION_SUPERVISOR_ONLY=1 SINGULARITY_SESSION_BUILD_ID=forensics-test \
        bash -c 'trap "" TERM; bash "$1" & c=$!; wait "$c"' _ \
        "$T/sess/src/singularity-desktop-session.in" >/dev/null 2>&1
    RUNS="$T/state/singularity/runs"
    runcount="$(find "$RUNS" -name 'desktop-*.log' 2>/dev/null | wc -l)"
    [ "$runcount" = 3 ] && ok "3 crashes -> 3 per-run files" || bad "expected 3 run files, got $runcount"
    if ls "$RUNS"/desktop-*.log >/dev/null 2>&1; then
        grep -q 'FAKE-RUN-' "$RUNS"/desktop-*.log && ok "per-run files hold the child output" || bad "per-run files are empty"
        # every run has its own distinct line: nothing was overwritten
        [ "$(grep -h 'FAKE-RUN-' "$RUNS"/desktop-*.log | sort -u | wc -l)" = 3 ] \
            && ok "no previous run's output was truncated" || bad "run outputs collided"
        grep -q 'signal 11: SEGV' "$RUNS"/desktop-*.log && ok "run trailer names the signal" || bad "run trailer lacks signal name"
        grep -q 'signal 11: SEGV' "$T/state/singularity/desktop.log" && ok "status log names the signal" || bad "status log lacks signal name"
        hard="$(ulimit -Hc)"
        if [ "$hard" = unlimited ] || [ "$hard" -gt 0 ] 2>/dev/null; then
            grep -q 'core_limit=unlimited' "$RUNS"/desktop-*.log && ok "child sees unlimited core limit" || bad "child core limit not raised"
        else
            echo "SKIP child core limit: hard limit is $hard"
        fi
    else
        bad "no per-run files written under $RUNS"
    fi
    [ -f "$T/state/singularity/safe-mode-request" ] && ok "safe mode still requested after 3 crashes" || bad "safe-mode-request missing"
    [ "$(cat "$T/count" 2>/dev/null)" = 3 ] && ok "crash budget still exactly 3" || bad "crash budget changed"
else
    echo "SKIP functional: upstream singularity-session not found at $SRC"
fi

echo "supervisor forensics test: $PASS passed, $FAILS failed"
[ "$FAILS" = 0 ]
