#!/bin/bash
# test-ncz-cli-basics.sh -- shell-level test of the ncz CLI embedded in
# post-install/46-ncz-cli.sh. Does NOT need a real Linux install — exercises
# the parsing, help, version, error paths, exit codes, and the bits of
# `ncz status` that don't require systemd or /dev/aipu.
#
# What this test catches:
#   - the embedded heredoc parses cleanly (catches unbalanced quotes, syntax errors)
#   - `ncz --version` and `ncz version` both work
#   - `ncz help` works and emits the documented subcommands
#   - `ncz status` runs without error even when /dev/dri, /dev/aipu, or
#     BUILD_VARIANT are absent (it should print "absent" / "unknown", not die)
#   - `ncz install foo` (unknown component) exits non-zero with a helpful msg
#   - `ncz` with no args shows help and exits 0
#
# Tested on STUDIO (darwin, 2026-10-13).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/post-install/46-ncz-cli.sh"
T="$(mktemp -d "${TMPDIR:-/var/tmp}/nczutil-test.XXXXXX")"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

# Extract the embedded ncz CLI heredoc body. The heredoc starts at the line
# `install -D -m 0755 /dev/stdin /usr/local/bin/ncz <<'NCZ'` and ends at the
# sole line `NCZ`. We grep for the marker so the test does not need a
# precise line count.
start_line=$(grep -n "^install -D -m 0755 /dev/stdin /usr/local/bin/ncz <<'NCZ'$" "$HOOK" | head -1 | cut -d: -f1)
end_line=$(grep -n '^NCZ$' "$HOOK" | head -1 | cut -d: -f1)
if [ -z "$start_line" ] || [ -z "$end_line" ]; then
    bad "could not locate the embedded ncz heredoc (start=$start_line end=$end_line)"
    echo "--- $pass passed, $fail failed"; exit 1
fi
# Body is start+1 .. end-1 (skip the heredoc start line and the closing tag).
sed -n "$((start_line + 1)),$((end_line - 1))p" "$HOOK" | grep -v '^NCZ$' > "$T/ncz-body"
{ printf '#!/bin/bash\n'; cat "$T/ncz-body"; } > "$T/ncz"
chmod +x "$T/ncz"
# bash -n on the WHOLE thing (post-install hook + ncz body)
if bash -n "$HOOK" 2>"$T/hook-syntax"; then
    ok "post-install/46-ncz-cli.sh parses cleanly"
else
    bad "post-install/46-ncz-cli.sh has a syntax error: $(cat "$T/hook-syntax")"
fi
if bash -n "$T/ncz" 2>"$T/ncz-syntax"; then
    ok "embedded ncz CLI parses cleanly"
else
    bad "embedded ncz CLI has a syntax error: $(cat "$T/ncz-syntax")"
fi

# version / help / default invocation
out=$("$T/ncz" --version 2>&1); rc=$?
[ "$rc" = "0" ] && ok "--version exits 0" || bad "--version exit=$rc"
echo "$out" | grep -q "ncz 0" && ok "--version prints the version banner" || bad "--version did not print version: $out"

out=$("$T/ncz" version 2>&1); rc=$?
[ "$rc" = "0" ] && ok "version exits 0" || bad "version exit=$rc"

out=$("$T/ncz" help 2>&1); rc=$?
[ "$rc" = "0" ] && ok "help exits 0" || bad "help exit=$rc"
echo "$out" | grep -q "ncz — nclawzero operator CLI" && ok "help prints the brand banner" || bad "help banner missing"
for sub in "desktop on" "desktop off" "desktop status" "install mnemos" "install nemoclaw" "agent install" "agent ..." "status" "version" "help"; do
    echo "$out" | grep -q "$sub" && ok "help mentions subcommand '$sub'" || bad "help missing subcommand '$sub'"
done

out=$("$T/ncz" 2>&1); rc=$?
[ "$rc" = "0" ] && ok "bare ncz (no args) exits 0 and shows help" || bad "bare ncz exit=$rc"
echo "$out" | grep -q "ncz — nclawzero operator CLI" && ok "bare ncz shows help banner" || bad "bare ncz did not show help"

# unknown subcommand should exit non-zero and name the bad arg
out=$("$T/ncz" totally-not-a-subcommand 2>&1); rc=$?
[ "$rc" != "0" ] && ok "unknown subcommand exits non-zero ($rc)" || bad "unknown subcommand exit=$rc (expected non-zero)"
echo "$out" | grep -q "totally-not-a-subcommand" && ok "unknown-subcommand error names the bad arg" || bad "unknown-subcommand error did not name the arg: $out"

# install <unknown> should exit non-zero and name the bad component
out=$("$T/ncz" install bogus-component 2>&1); rc=$?
[ "$rc" != "0" ] && ok "ncz install <unknown> exits non-zero ($rc)" || bad "install <unknown> exit=$rc"
echo "$out" | grep -q "bogus-component" && ok "install <unknown> error names the bad component" || bad "install <unknown> did not name component: $out"

# status on a non-systemd host (this very darwin box) must not crash; it
# should print the version banner and "unknown" for systemd-only fields.
out=$("$T/ncz" status 2>&1); rc=$?
[ "$rc" = "0" ] && ok "status exits 0 on non-systemd host" || bad "status exit=$rc (expected 0 — must not crash)"
echo "$out" | grep -q "ncz:" && ok "status prints ncz version row" || bad "status missing version row"
echo "$out" | grep -q "BUILD_VARIANT:" && ok "status prints BUILD_VARIANT" || bad "status missing BUILD_VARIANT"
echo "$out" | grep -qE "NPU:[[:space:]]+(present|absent)" && ok "status prints NPU line" || bad "status missing NPU line"
# Either GPU present or absent must be present
echo "$out" | grep -qE "GPU /dev/dri/renderD128:[[:space:]]+(present|absent)" && ok "status prints GPU line" || bad "status missing GPU line"

# exit-code contract on the unhappy paths we expect the orchestrator to hit
out=$("$T/ncz" agent unknown 2>&1); rc=$?
[ "$rc" != "0" ] && ok "ncz agent <unknown> exits non-zero ($rc)" || bad "ncz agent <unknown> exit=$rc"

echo "--- $pass passed, $fail failed"
[ "$fail" = "0" ]