#!/usr/bin/env bash
# Guard the guard: the grep -q conversion checker must accept real conversions
# and must catch the corruptions that a blind transform produces.
#
# The checker exists because a `grep -q` -> `grep ... >/dev/null` sweep can
# change what a test looks for -- or rewrite a comment -- while still parsing
# and still passing the lint. If this test ever passes while the checker is
# broken, the lint's green result means nothing, so the failure cases here are
# as important as the passing ones.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CHECKER="$HERE/check-grepq-conversion.py"
pass=0
fail=0

ok()  { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
nok() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

if ! command -v python3 >/dev/null 2>&1; then
    echo "grepq-conversion: SKIP (no python3)"
    exit 0
fi

[ -f "$CHECKER" ] || { nok "checker is present at build/check-grepq-conversion.py"; exit 1; }
ok "checker is present at build/check-grepq-conversion.py"

out=$(python3 "$CHECKER" --self-test 2>&1)
rc=$?
if [ "$rc" = 0 ]; then
    ok "self-test accepts 5 conversions and catches 6 corruptions"
else
    nok "self-test failed (rc=$rc): $(printf '%s' "$out" | tail -1)"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Each case below is one -/+ pair. expect_bad=1 means the checker must refuse it.
probe() {  # probe <name> <expect_bad> <minus line> <plus line>
    local name="$1" want_bad="$2" minus="$3" plus="$4"
    {
        printf 'diff --git a/p.sh b/p.sh\n@@ -1,1 +1,1 @@\n'
        printf -- '-%s\n' "$minus"
        printf -- '+%s\n' "$plus"
    } > "$tmp/case.diff"
    if python3 "$CHECKER" "$tmp/case.diff" >/dev/null 2>&1; then
        [ "$want_bad" = 1 ] && nok "$name (accepted, should be refused)" || ok "$name"
    else
        [ "$want_bad" = 1 ] && ok "$name" || nok "$name (refused, should be accepted)"
    fi
}

probe "a redirect inserted inside a quoted pattern is refused" 1 \
    'grep -q "a b" "$f"' 'grep "a >/dev/null b" "$f"'
probe "a pattern whose whitespace changed is refused" 1 \
    "grep -q 'keep me' \"\$f\"" "grep 'keep  me' \"\$f\" >/dev/null"
probe "a q removed with no redirect added is refused" 1 \
    "grep -q 'lost' \"\$f\"" "grep 'lost' \"\$f\""
probe "a redirect added with no q removed is refused" 1 \
    "grep 'gained' \"\$f\"" "grep 'gained' \"\$f\" >/dev/null"
probe "comment text rewritten by the sweep is refused" 1 \
    "grep 'x' \"\$f\" >/dev/null  # was grep -q 'y'" "grep 'x' \"\$f\" >/dev/null"
probe "real conversions are accepted (-qF, -qai clusters)" 0 \
    "grep -qF -- \"\$pkg\"; then" "grep -F -- \"\$pkg\" >/dev/null; then"
probe "real conversion beside 2>&1 is accepted" 0 \
    "vm 2>&1 | grep -q 'booted'" "vm 2>&1 | grep 'booted' >/dev/null"
probe "real conversion with an escaped quote in the pattern is accepted" 0 \
    'grep -q "a \"b\" c" "$f"' 'grep "a \"b\" c" "$f" >/dev/null'

echo "check-grepq-conversion: $pass passed, $fail failed"
[ "$fail" = 0 ]
