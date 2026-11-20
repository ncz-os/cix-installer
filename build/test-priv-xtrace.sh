#!/bin/bash
# test-priv-xtrace.sh -- the sudo password must never reach an xtrace log.
#
# 2026-11-13 side finding (cycle 232): priv.sh's secret-bearing lines were
# traced when a caller ran with `set -x` / `bash -x` (the "extraction failure"
# debugging path), leaking the sudo-pass file content into build logs:
#   + NCZ_SUDO_PASS=<the password>
#   + printf '%s\n' '<the password>'
# priv.sh now runs that region with xtrace forced off and restores the caller's
# setting on every exit path.  This test pins the behaviour.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PRIV="$ROOT/build/lib/priv.sh"
T="$(mktemp -d "${TMPDIR:-/var/tmp}/privxtrace.XXXXXX")"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

SECRET="hunter2-xtrace-LEAKME-9d1c"

# A stub sudo: `sudo -n true` fails (forcing the sudo-stdin model without real
# root); `sudo -S ...` records its first stdin line to $SUDO_LOG and runs the
# rest for real, so exit codes still propagate.
mkdir -p "$T/bin"
cat > "$T/bin/sudo" <<'STUB'
#!/bin/bash
if [ "$1" = "-n" ]; then exit 1; fi
if [ "$1" = "-S" ]; then
    IFS= read -r pw || true
    printf '%s\n' "$pw" >> "$SUDO_LOG"
    shift 3   # -S -p '' --
    "$@"
    exit $?
fi
exit 1
STUB
chmod +x "$T/bin/sudo"
export SUDO_LOG="$T/sudo.log"

# fixture pass files
printf '{"sudo_password":"%s"}\n' "$SECRET" > "$T/pass-ok.json"
printf 'NOT-JSON{%s\n' "$SECRET" > "$T/pass-bad.json"
printf '{"other":"%s"}\n'    "$SECRET" > "$T/pass-missing-key.json"

# run a snippet under `bash -x`, print only its stderr
xt() {
    env PATH="$T/bin:$PATH" SUDO_LOG="$SUDO_LOG" \
        NCZ_SUDO=1 NCZ_SUDO_PASS_FILE="$1" NCZ_SUDO_PASS_KEY=sudo_password \
        bash -x -c ". '$PRIV'; $2" 2>&1 >/dev/null
}

# 1. success path under xtrace: no secret in the trace
out="$(xt "$T/pass-ok.json" '_ncz_read_sudo_pass && ncz_sudo /bin/true')"
case "$out" in
    *"$SECRET"*) bad "xtrace leaks the password on the success path" "$out" ;;
    *) ok "success path under xtrace: password absent from the trace" ;;
esac

# 2. functional: the stub sudo really got the password on stdin (model works)
got="$(tail -n1 "$SUDO_LOG" 2>/dev/null)"
[ "$got" = "$SECRET" ] && ok "sudo -S still receives the correct password on stdin" \
    || bad "sudo -S got '$got', wanted the real password"

# 3. failure paths under xtrace: rc=1 and no secret in the trace
out="$(xt "$T/pass-bad.json" '_ncz_read_sudo_pass; echo rc=$?')"
case "$out" in
    *"$SECRET"*) bad "xtrace leaks the password on the bad-JSON path" "$out" ;;
    *'rc=1'*)    ok "bad-JSON path: rc=1 and password absent from the trace" ;;
    *)           bad "bad-JSON path did not report rc=1" "$out" ;;
esac
out="$(xt "$T/pass-missing-key.json" '_ncz_read_sudo_pass; echo rc=$?')"
case "$out" in
    *"$SECRET"*) bad "xtrace leaks the password on the missing-key path" "$out" ;;
    *'rc=1'*)    ok "missing-key path: rc=1 and password absent from the trace" ;;
    *)           bad "missing-key path did not report rc=1" "$out" ;;
esac

# 4. xtrace state is restored after the calls
out="$(xt "$T/pass-ok.json" '_ncz_read_sudo_pass; ncz_sudo /bin/true; case "$-" in *x*) echo XTRACE-ON ;; *) echo XTRACE-OFF ;; esac')"
case "$out" in
    *XTRACE-ON*)  ok "caller xtrace setting is restored after the secret region" ;;
    *XTRACE-OFF*) bad "xtrace was left disabled for the caller" "$out" ;;
    *)            bad "xtrace state probe did not run" "$out" ;;
esac

# 5. behaviour without xtrace is unchanged
NCZ_SUDO_PASS_FILE="$T/pass-ok.json" NCZ_SUDO_PASS_KEY=sudo_password
export NCZ_SUDO_PASS_FILE NCZ_SUDO_PASS_KEY
# shellcheck source=lib/priv.sh
. "$PRIV"
_ncz_read_sudo_pass && [ "$NCZ_SUDO_PASS" = "$SECRET" ] \
    && ok "without xtrace the password is still extracted correctly" \
    || bad "plain extraction broken (got '${NCZ_SUDO_PASS:-}')"
unset NCZ_SUDO_PASS
_ncz_read_sudo_pass; rc=$?
[ "$rc" = 0 ] || bad "second extraction unexpectedly failed rc=$rc"

echo "== ${pass} passed, ${fail} failed =="
[ "$fail" = 0 ]
