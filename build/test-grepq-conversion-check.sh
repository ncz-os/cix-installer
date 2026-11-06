#!/usr/bin/env bash
# Guard the guard: the grep -q conversion checker must accept real conversions
# and must catch the corruptions that a blind transform produces.
#
# The checker exists because a `grep -q` -> `grep ... >/dev/null` sweep can
# change what a test looks for while still parsing and still passing the lint.
# If this test ever passes while the checker is broken, the lint's green result
# means nothing, so the failure cases here are as important as the passing ones.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CHECKER="$HERE/check-grepq-conversion.py"
pass=0
fail=0

ok()   { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
nok()  { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

if ! command -v python3 >/dev/null 2>&1; then
    echo "grepq-conversion: SKIP (no python3)"
    exit 0
fi

[ -f "$CHECKER" ] || { nok "checker is present at build/check-grepq-conversion.py"; exit 1; }
ok "checker is present at build/check-grepq-conversion.py"

out=$(python3 "$CHECKER" --self-test 2>&1)
rc=$?
if [ "$rc" = 0 ]; then
    ok "self-test accepts 3 conversions and catches 4 corruptions"
else
    nok "self-test failed (rc=$rc): $(printf '%s' "$out" | tail -1)"
fi

# A redirect that lands inside a quoted pattern must be refused.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/inside.diff" <<'DIFF'
diff --git a/y.sh b/y.sh
@@ -1,1 +1,1 @@
-grep -q "a b" "$f"
+grep "a >/dev/null b" "$f"
DIFF
python3 "$CHECKER" "$tmp/inside.diff" >/dev/null 2>&1 \
    && nok "a redirect inserted inside a quoted pattern is refused" \
    || ok "a redirect inserted inside a quoted pattern is refused"

# A pattern whose internal whitespace changed must be refused.
cat > "$tmp/space.diff" <<'DIFF'
diff --git a/z.sh b/z.sh
@@ -1,1 +1,1 @@
-grep -q 'keep me' "$f"
+grep 'keep  me' "$f" >/dev/null
DIFF
python3 "$CHECKER" "$tmp/space.diff" >/dev/null 2>&1 \
    && nok "a pattern whose whitespace changed is refused" \
    || ok "a pattern whose whitespace changed is refused"

# The genuine article must be accepted, including a multi-letter flag cluster.
cat > "$tmp/good.diff" <<'DIFF'
diff --git a/w.sh b/w.sh
@@ -1,2 +1,2 @@
-grep -qF -- "$pkg"; then
+grep -F -- "$pkg" >/dev/null; then
-grep -qai "braille device" "$log"
+grep -ai "braille device" "$log" >/dev/null
DIFF
python3 "$CHECKER" "$tmp/good.diff" >/dev/null 2>&1 \
    && ok "real conversions are accepted (flag clusters -qF, -qai)" \
    || nok "real conversions were refused"

echo "check-grepq-conversion: $pass passed, $fail failed"
[ "$fail" = 0 ]
