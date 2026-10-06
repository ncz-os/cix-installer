#!/bin/bash
# test-components-generate.sh -- hermetic fail-before / pass-after for the
# phase 3 generators (manifests/*.pkgs, NCZ_LOCAL_DEBS, the parity allowlist).
#
# The real repo is never the subject. A throwaway copy is. The copy is the
# byte-identity baseline: a regen against an unchanged copy must report every
# file unchanged. A hand-edit must make --check exit 1. Restoring the
# registry side of that edit must make --check exit 0 again.
#
# bash 3.2 compatible (no namerefs, no ${var,,}).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
GEN="$HERE/gen-components-registry.py"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/components-generate.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1"; [ "$2" != "-" ] && printf '    %s\n' "$2"; FAIL=$((FAIL + 1)); }

mkdir -p "$WORK/manifests" "$WORK/build"
cp "$ROOT/manifests/components.tsv" "$WORK/manifests/"
cp "$ROOT/manifests/"*.pkgs "$WORK/manifests/"
cp "$ROOT/build/build-desktop-mirror.sh" "$WORK/build/"
cp "$ROOT/build/arch-parity-allowlist.tsv" "$WORK/build/"
cp "$GEN" "$WORK/build/"

# --- pass-after: an unchanged copy regenerates byte-identical -------------
out=$(python3 "$WORK/build/gen-components-registry.py" --root "$WORK" \
    --render-seeds --render-local-debs --render-allowlist --check 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'unchanged'; then
    pass "pass-after unchanged copy is byte-identical (rc=0)"
else
    fail "pass-after unchanged copy (rc=$rc)" "$out"
fi

# --- fail-before: a hand-added seed the registry does not cite ------------
printf '\nnot-a-real-package\n' >> "$WORK/manifests/desktop.pkgs"
out=$(python3 "$WORK/build/gen-components-registry.py" --root "$WORK" \
    --render-seeds --check 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'desktop.pkgs name set differs'; then
    pass "fail-before hand-added seed (rc=$rc)"
else
    fail "fail-before hand-added seed (rc=$rc)" "$out"
fi
# restore
cp "$ROOT/manifests/desktop.pkgs" "$WORK/manifests/"

# --- fail-before: a hand-flipped NCZ_LOCAL_DEBS required flag -------------
# The literal the screensaver test greps must be what the registry says.
# Flip it in the script only; the registry still says required.
python3 - <<PY
from pathlib import Path
p = Path("$WORK/build/build-desktop-mirror.sh")
t = p.read_text()
old = "ncz-screensavers|"
# Flip only the required flag on the screensavers data line.
lines = []
for raw in t.splitlines(True):
    if raw.startswith("ncz-screensavers|") and raw.rstrip().endswith("|required"):
        raw = raw.replace("|required", "|optional", 1)
    lines.append(raw)
p.write_text("".join(lines))
PY
out=$(python3 "$WORK/build/gen-components-registry.py" --root "$WORK" \
    --render-local-debs --check 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'rows differ'; then
    pass "fail-before flipped NCZ_LOCAL_DEBS flag (rc=$rc)"
else
    fail "fail-before flipped NCZ_LOCAL_DEBS flag (rc=$rc)" "$out"
fi
cp "$ROOT/build/build-desktop-mirror.sh" "$WORK/build/"

# --- fail-before: a parity gap with no allowlist row ----------------------
cp "$WORK/build/arch-parity-allowlist.tsv" "$WORK/build/arch-parity-allowlist.tsv.keep"
grep -v $'^desktop\tvalac\t' "$WORK/build/arch-parity-allowlist.tsv.keep" \
    > "$WORK/build/arch-parity-allowlist.tsv"
out=$(python3 "$WORK/build/gen-components-registry.py" --root "$WORK" \
    --render-allowlist --check 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'valac is arm64-only'; then
    pass "fail-before missing allowlist row (rc=$rc)"
else
    fail "fail-before missing allowlist row (rc=$rc)" "$out"
fi
cp "$WORK/build/arch-parity-allowlist.tsv.keep" "$WORK/build/arch-parity-allowlist.tsv"

# --- fail-before: an allowlist side the manifests contradict --------------
printf 'desktop\tgimp\tamd64-only\tfixture contradiction\n' \
    >> "$WORK/build/arch-parity-allowlist.tsv"
out=$(python3 "$WORK/build/gen-components-registry.py" --root "$WORK" \
    --render-allowlist --check 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'disagrees'; then
    pass "fail-before contradictory allowlist side (rc=$rc)"
else
    fail "fail-before contradictory allowlist side (rc=$rc)" "$out"
fi

# --- pass-after: the restored copy is byte-identical again ----------------
cp "$ROOT/build/arch-parity-allowlist.tsv" "$WORK/build/"
out=$(python3 "$WORK/build/gen-components-registry.py" --root "$WORK" \
    --render-seeds --render-local-debs --render-allowlist --check 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
    pass "pass-after restored copy (rc=0)"
else
    fail "pass-after restored copy (rc=$rc)" "$out"
fi

printf '\ntest-components-generate: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
