#!/bin/bash
# test-claude-code-deferred.sh -- 40-claude-code.sh promises a first-boot
# retry when the chroot `npm install -g @anthropic-ai/claude-code` fails, so
# on failure the hook must stage a oneshot ncz-claude-code-install.service
# (After/Wants=network-online.target, bounded retries with backoff,
# ConditionPathExists=! marker, disables itself on success) and on success it
# must leave no unit behind.
#
# Fake-root hook test with a stubbed npm: covers both paths, plus the staged
# helper's own retry/disable behaviour with stubbed npm/sleep/systemctl.
#
# Run: bash build/test-claude-code-deferred.sh     Exit 0 = pass, 1 = fail.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HOOK="$ROOT/post-install/40-claude-code.sh"
# Scratch dir: $TMPDIR when it takes writes, else the repo's own scratch
# area ($ROOT/.test-tmp, gitignored like test-magnetar-server-accel.sh uses).
# Some verify hosts mount /tmp with a quota that breaks file writes ("Disk
# quota exceeded" even though mkdir succeeds), which fails every fixture here
# even though the hook under test is fine.
W="$(mktemp -d "${TMPDIR:-/tmp}/claude-code.XXXXXX" 2>/dev/null)"
if [ -z "$W" ] || ! : > "$W/.w" 2>/dev/null; then
    rm -rf "$W" 2>/dev/null
    : "${NCZ_TEST_TMPDIR:=$ROOT/.test-tmp}"
    mkdir -p "$NCZ_TEST_TMPDIR" || { echo "cannot create a scratch dir"; exit 2; }
    W="$(mktemp -d "$NCZ_TEST_TMPDIR/claude-code.XXXXXX")" \
        || { echo "cannot create a scratch dir"; exit 2; }
fi
rm -f "$W/.w"
trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS + 1)); return 0; }
bad() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; return 0; }

mkdir -p "$W/bin"
# apt-get: always succeeds (nodejs/npm substrate is not what this test probes).
cat > "$W/bin/apt-get" <<'EOF'
#!/bin/sh
echo "apt-get $*" >> "$LOG"
exit 0
EOF
# npm: exit code driven by $NPM_RC; log every invocation (bounds the retries).
cat > "$W/bin/npm" <<'EOF'
#!/bin/sh
echo "npm $*" >> "$LOG"
exit "${NPM_RC:-0}"
EOF
# claude: only reached on the success path (`claude --version` echo).
cat > "$W/bin/claude" <<'EOF'
#!/bin/sh
echo "1.0.0-test"
exit 0
EOF
# systemctl: log, fail enable so the hook takes its ln -sf fallback (as in a
# chroot without a running systemd), succeed on disable.
cat > "$W/bin/systemctl" <<'EOF'
#!/bin/sh
echo "systemctl $*" >> "$LOG"
case " $* " in
    *" enable "*) exit 1 ;;
    *) exit 0 ;;
esac
EOF
# sleep: log, never wait (keeps the backoff assertions instant).
cat > "$W/bin/sleep" <<'EOF'
#!/bin/sh
echo "sleep $*" >> "$LOG"
exit 0
EOF
chmod +x "$W/bin/"*
export PATH="$W/bin:$PATH" LOG="$W/apt.log"

mkroot() {
    rm -rf "$W/r" "$LOG"; mkdir -p "$W/r"; : > "$LOG"
}
run_hook() {  # NPM_RC set by caller; hook runs against the fixture root
    ( export NCZ_CLAUDE_ROOT="$W/r"; bash "$HOOK" ) > "$W/out" 2>&1
}   # returns the hook's exit status
SVC="$W/r/etc/systemd/system/ncz-claude-code-install.service"
WANTS="$W/r/etc/systemd/system/multi-user.target.wants/ncz-claude-code-install.service"
HELPER="$W/r/usr/local/sbin/ncz-claude-code-install"
PENDING="$W/r/var/lib/ncz/claude-code.pending"
DONE="$W/r/var/lib/ncz/claude-code.done"

echo "=== failure path: offline chroot stages the first-boot retry ==="
mkroot; NPM_RC=1 run_hook; rc=$?
[ "$rc" = 0 ] \
    && ok "hook exits 0 on npm failure (optional hook must not abort the install)" \
    || bad "hook exits $rc on npm failure" "$(cat "$W/out")"
grep -q 'deferred to first boot' "$W/out" \
    && ok "hook still tells the log the install was deferred" \
    || bad "deferral message missing" "$(cat "$W/out")"
[ -f "$SVC" ] \
    && ok "ncz-claude-code-install.service is staged" \
    || bad "service unit missing"
[ -L "$WANTS" ] \
    && ok "service is enabled (multi-user.target.wants symlink)" \
    || bad "enablement symlink missing"
[ -x "$HELPER" ] \
    && ok "retry helper is staged executable" \
    || bad "retry helper missing or not executable"
[ -f "$PENDING" ] \
    && ok "pending marker records the outstanding install" \
    || bad "pending marker missing"
[ ! -e "$DONE" ] \
    && ok "no done marker on the failure path" \
    || bad "done marker wrongly present after a failed install"
grep -q '^After=.*network-online.target' "$SVC" \
    && ok "unit orders After=network-online.target" \
    || bad "unit lacks After=network-online.target" "$(cat "$SVC" 2>/dev/null)"
grep -q '^Wants=network-online.target' "$SVC" \
    && ok "unit Wants=network-online.target" \
    || bad "unit lacks Wants=network-online.target" "$(cat "$SVC" 2>/dev/null)"
grep -q '^Type=oneshot' "$SVC" \
    && ok "unit is Type=oneshot" \
    || bad "unit is not Type=oneshot" "$(cat "$SVC" 2>/dev/null)"
grep -q '^ConditionPathExists=!/var/lib/ncz/claude-code.done' "$SVC" \
    && ok "unit is gated on the missing done marker" \
    || bad "unit lacks ConditionPathExists=! marker" "$(cat "$SVC" 2>/dev/null)"
grep -q '^ExecStart=/usr/local/sbin/ncz-claude-code-install' "$SVC" \
    && ok "unit ExecStart runs the staged helper" \
    || bad "unit ExecStart does not run the helper" "$(cat "$SVC" 2>/dev/null)"
grep -q 'sleep' "$HELPER" \
    && ok "helper backs off between attempts" \
    || bad "helper has no backoff sleep" "$(cat "$HELPER" 2>/dev/null)"
grep -q 'systemctl disable ncz-claude-code-install' "$HELPER" \
    && ok "helper disables itself on success" \
    || bad "helper never disables itself" "$(cat "$HELPER" 2>/dev/null)"
grep -q 'claude-code.done' "$HELPER" \
    && ok "helper records the done marker on success" \
    || bad "helper never writes the done marker" "$(cat "$HELPER" 2>/dev/null)"
bash -n "$HELPER" \
    && ok "staged helper parses (bash -n)" \
    || bad "staged helper has a syntax error"

echo "=== staged helper: bounded retries, then gives up ==="
mkroot; NPM_RC=1 run_hook >/dev/null 2>&1
: > "$LOG"
export NPM_RC=1
( export NCZ_CLAUDE_ROOT="$W/r" NCZ_CLAUDE_MAX_TRIES=3 NCZ_CLAUDE_RETRY_WAIT=1
  bash "$HELPER" ) > "$W/out" 2>&1; rc=$?
unset NPM_RC
[ "$rc" != 0 ] \
    && ok "helper exits nonzero when every attempt fails" \
    || bad "helper exits 0 despite all attempts failing"
[ "$(grep -c '^npm install' "$LOG")" = 3 ] \
    && ok "helper tried exactly 3 times (bounded)" \
    || bad "helper attempt count wrong (want 3)" "$(cat "$LOG")"
[ "$(grep -c '^sleep ' "$LOG")" = 2 ] \
    && ok "helper slept between attempts (backoff, no sleep after the last)" \
    || bad "helper backoff sleeps wrong (want 2)" "$(cat "$LOG")"
[ ! -e "$DONE" ] \
    && ok "no done marker after exhausted retries" \
    || bad "done marker present after exhausted retries"

echo "=== staged helper: success records done and disables itself ==="
mkroot; NPM_RC=1 run_hook >/dev/null 2>&1
: > "$LOG"
( export NCZ_CLAUDE_ROOT="$W/r" NCZ_CLAUDE_MAX_TRIES=3 NCZ_CLAUDE_RETRY_WAIT=1 NPM_RC=0
  bash "$HELPER" ) > "$W/out" 2>&1; rc=$?
[ "$rc" = 0 ] \
    && ok "helper exits 0 on a successful retry" \
    || bad "helper exits $rc on success" "$(cat "$W/out")"
[ -f "$DONE" ] && [ ! -f "$PENDING" ] \
    && ok "done marker written, pending marker cleared" \
    || bad "markers wrong after success"
grep -q 'systemctl disable ncz-claude-code-install' "$LOG" \
    && ok "helper disabled its own unit on success" \
    || bad "helper did not disable its unit" "$(cat "$LOG")"

echo "=== success path: online chroot leaves no unit behind ==="
mkroot; NPM_RC=0 run_hook; rc=$?
[ "$rc" = 0 ] \
    && ok "hook exits 0 on npm success" \
    || bad "hook exits $rc on npm success" "$(cat "$W/out")"
[ ! -e "$SVC" ] && [ ! -e "$WANTS" ] && [ ! -e "$HELPER" ] \
    && [ ! -e "$PENDING" ] && [ ! -e "$DONE" ] \
    && ok "no unit, helper, or marker left after a successful install" \
    || bad "stale first-boot retry left after success" "$(cd "$W/r" && find . | sort)"

echo "claude-code deferred tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
