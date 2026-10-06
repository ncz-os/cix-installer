#!/bin/bash
# test-components.sh -- fixture test for build/components.py (phase 1).
#
# Operator directive 2026-10-05 (Item C1, phase 1). Runs the drift checker
# against a HERMETIC mini repo (build/fixtures/components-fixtures/mini-repo)
# that contains its own manifests, hooks, mirror script, allowlist, dkms
# assets and a published-artifacts report. The real registry
# (manifests/components.tsv) and the real repo are never touched.
#
# Design:
#   1. pristine mini repo           -> check exits 0 (0 errors)
#   2. one-line drift injections    -> check exits 1 and names the finding:
#        missing-row     drop a manifest-seeded row      -> manifest-registry
#        bad-kind        unknown kind on a row           -> row-format
#        bad-arch        arch vs arch-parity-allowlist   -> arch-allowlist
#        bad-installed   installed_by points at a ghost  -> row-installer
#        bad-required    pool row required=no vs mirror  -> required-optional
#        bad-hook-arch   hook arch vs registry arch      -> hook-arch
#   3. report / diff-published smoke -> exit 0
#
# bash 3.2 compatible (STUDIO /bin/bash): no associative arrays, no
# mapfile, no ${var,,}.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
FIX="$HERE/fixtures/components-fixtures"
MINI="$FIX/mini-repo"
PY="$HERE/components.py"
GEN="$FIX/_generated"

# The published-set source for the mini repo (the real item AC report must
# not leak into the hermetic check).
export NCZ_APT_PUBLISH_REPORT="$MINI/docs/publish-report.md"

PASS=0
FAIL=0

pass() { printf '%s  %s\n' "PASS" "$1"; PASS=$((PASS + 1)); }
fail() {
    printf '%s  %s\n' "FAIL" "$1"
    [ "$2" != "-" ] && printf '    %s\n' "$2"
    FAIL=$((FAIL + 1))
}

if [ ! -d "$MINI" ]; then
    echo "FAIL: fixture mini-repo missing at $MINI" >&2
    exit 1
fi

# run_check <label> <registry> <expected_rc> [grep-pattern]
run_check() {
    local label="$1" registry="$2" expected="$3" want="$4"
    local out rc
    out=$(python3 "$PY" --root "$MINI" --registry "$registry" check 2>&1)
    rc=$?
    if [ "$rc" -ne "$expected" ]; then
        fail "$label (rc=$rc, expected $expected)" "$out"
        return
    fi
    if [ -n "$want" ] && ! printf '%s\n' "$out" | grep -q "$want"; then
        fail "$label (finding '$want' not in output)" "$out"
        return
    fi
    pass "$label (rc=$rc)"
}

# ---------------------------------------------------------------------------
# 1. pristine mini repo: no drift, exit 0.
# ---------------------------------------------------------------------------
run_check "pristine-mini-repo" "$MINI/manifests/components.tsv" 0 ""

# ---------------------------------------------------------------------------
# 2. drift injections: one edit each, expect rc=1 + the finding code.
# ---------------------------------------------------------------------------
rm -rf "$GEN"
mkdir -p "$GEN"
PRISTINE="$MINI/manifests/components.tsv"

# missing-row: drop the gimp row (desktop.pkgs still seeds it).
grep -v "^gimp	" "$PRISTINE" > "$GEN/missing-row.tsv"
if grep -q "^gimp	" "$GEN/missing-row.tsv"; then
    fail "fixture-edit missing-row (gimp not removed)" "-"
else
    run_check "drift-missing-row" "$GEN/missing-row.tsv" 1 "manifest-registry"
fi

# bad-kind: t2smc kind -> bogus-kind.
awk -F'\t' -v OFS='\t' '$1=="t2smc"{$2="bogus-kind"}{print}' "$PRISTINE" \
    > "$GEN/bad-kind.tsv"
run_check "drift-bad-kind" "$GEN/bad-kind.tsv" 1 "row-format"

# bad-arch: ncz-gadget arch -> arm64 (allowlist says amd64-only).
awk -F'\t' -v OFS='\t' '$1=="ncz-gadget"{$4="arm64"}{print}' "$PRISTINE" \
    > "$GEN/bad-arch.tsv"
run_check "drift-bad-arch" "$GEN/bad-arch.tsv" 1 "arch-allowlist"

# bad-installed: t2smc installed_by -> a hook that does not exist.
awk -F'\t' -v OFS='\t' \
    '$1=="t2smc"{$8="post-install/99-nope.sh"}{print}' "$PRISTINE" \
    > "$GEN/bad-installed.tsv"
run_check "drift-bad-installed" "$GEN/bad-installed.tsv" 1 "row-installer"

# bad-required: ncz-core pool row required=no (mirror says required).
awk -F'\t' -v OFS='\t' '$1=="ncz-core"{$6="no"}{print}' "$PRISTINE" \
    > "$GEN/bad-required.tsv"
run_check "drift-bad-required" "$GEN/bad-required.tsv" 1 "required-optional"

# bad-hook-arch: htop arch -> arm64, but 10-base.sh also runs on amd64
# and installs htop there.
awk -F'\t' -v OFS='\t' '$1=="htop"{$4="arm64"}{print}' "$PRISTINE" \
    > "$GEN/bad-hook-arch.tsv"
run_check "drift-bad-hook-arch" "$GEN/bad-hook-arch.tsv" 1 "hook-arch"

# ---------------------------------------------------------------------------
# 3. report + diff-published smoke (pristine registry).
# ---------------------------------------------------------------------------
out=$(python3 "$PY" --root "$MINI" --registry "$PRISTINE" \
    report --arch amd64 --variant desktop 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q "matched rows"; then
    pass "report-amd64-desktop (rc=0)"
else
    fail "report-amd64-desktop (rc=$rc)" "$out"
fi

out=$(python3 "$PY" --root "$MINI" --registry "$PRISTINE" diff-published 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
    pass "diff-published-smoke (rc=0)"
else
    fail "diff-published-smoke (rc=$rc)" "$out"
fi

# ---------------------------------------------------------------------------
# Cleanup generated drift variants (the committed mini-repo stays pristine).
# ---------------------------------------------------------------------------
rm -rf "$GEN"

echo
echo "Summary: $PASS pass, $FAIL fail"
[ "$FAIL" -gt 0 ] && exit 1
exit 0