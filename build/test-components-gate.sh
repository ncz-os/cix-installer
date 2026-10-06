#!/bin/bash
# test-components-gate.sh -- hermetic fail-before / pass-after for the
# phase 2 registry gate (components.py check --gate).
#
# The real repo is never the subject. A copy of the mini-repo fixture is.
#   fail-before: a required staged-deb row marked optional must exit 1
#   pass-after:  the pristine fixture, and a fixture whose only error is a
#                documented waiver (seed-published chromium-ncz-sky1), exit 0
#
# bash 3.2 compatible.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
FIX="$HERE/fixtures/components-fixtures/mini-repo"
PY="$HERE/components.py"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/components-gate.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1"; [ "$2" != "-" ] && printf '    %s\n' "$2"; FAIL=$((FAIL + 1)); }

cp -R "$FIX/." "$WORK/"
export NCZ_APT_PUBLISH_REPORT="$WORK/docs/publish-report.md"

# --- fail-before: required pool row flipped to optional ------------------
awk -F'\t' -v OFS='\t' '$1=="ncz-core"{$6="no"}{print}' \
    "$WORK/manifests/components.tsv" > "$WORK/bad.tsv"
out=$(python3 "$PY" --root "$WORK" --registry "$WORK/bad.tsv" check --gate 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'required-optional'; then
    pass "fail-before required-optional (rc=$rc)"
else
    fail "fail-before required-optional (rc=$rc)" "$out"
fi

# --- pass-after: pristine fixture ----------------------------------------
out=$(python3 "$PY" --root "$WORK" --registry "$WORK/manifests/components.tsv" check --gate 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
    pass "pass-after pristine (rc=0)"
else
    fail "pass-after pristine (rc=$rc)" "$out"
fi

# --- waiver: a documented seed-published name must not fail the gate -----
# Add the seed to a manifest and a matching registry row, with no published
# table entry. check (ungated) must still report the error.
printf '\nchromium-ncz-sky1\n' >> "$WORK/manifests/desktop.pkgs"
printf '%s\n' \
    $'chromium-ncz-sky1\tncz-apt\tbuildkite-packages\tarm64\tdesktop\tyes\t\tmanifest\tbuild/verify-packages.sh\tmanifests/desktop.pkgs\twaiver fixture' \
    >> "$WORK/manifests/components.tsv"
out=$(python3 "$PY" --root "$WORK" check 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q "seed-published.*chromium-ncz-sky1"; then
    pass "ungated still reports the waived seed-published error"
else
    fail "ungated did not report the waived error (rc=$rc)" "$out"
fi
out=$(python3 "$PY" --root "$WORK" check --gate 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'documented waiver'; then
    pass "gate waives chromium-ncz-sky1 seed-published (rc=0)"
else
    fail "gate did not waive chromium-ncz-sky1 (rc=$rc)" "$out"
fi

# --- a non-waived seed-published name still fails the gate ---------------
printf '\nncz-not-a-real-package\n' >> "$WORK/manifests/desktop.pkgs"
printf '%s\n' \
    $'ncz-not-a-real-package\tncz-apt\tbuildkite-packages\tarm64\tdesktop\tyes\t\tmanifest\tbuild/verify-packages.sh\tmanifests/desktop.pkgs\tnot waived' \
    >> "$WORK/manifests/components.tsv"
out=$(python3 "$PY" --root "$WORK" check --gate 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'ncz-not-a-real-package'; then
    pass "gate still fails an unwaived seed-published name (rc=$rc)"
else
    fail "gate swallowed an unwaived seed (rc=$rc)" "$out"
fi

echo
echo "Summary: $PASS pass, $FAIL fail"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
