#!/usr/bin/env bash
# test-deb-fixture-guard.sh -- the guard that turns a host problem into one sentence.
#
# On 2026-11-06 HYDRA's TMPDIR hit its quota. Tests that build .deb fixtures and
# suppress dpkg-deb's stderr reported 33 assertion failures about "unreadable
# deb" instead, which reads exactly like a code regression. The guard exists so
# that cannot happen again, and this test proves it fires.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
LIB="$REPO/build/lib/deb-fixture.sh"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS  $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }

[ -s "$LIB" ] && ok "build/lib/deb-fixture.sh exists" || { bad "build/lib/deb-fixture.sh exists"; exit 1; }

T="$(mktemp -d "${TMPDIR:-/var/tmp}/ncz-guard.XXXXXX")" || exit 1
trap 'chmod 700 "$T/ro" 2>/dev/null; rm -rf "$T"' EXIT

# 1. on a healthy TMPDIR the check passes
if ( . "$LIB"; TMPDIR="$T" ncz_deb_fixture_check ); then
    ok "a healthy TMPDIR passes the check"
else
    bad "a healthy TMPDIR passes the check"
fi

# 2. a TMPDIR that cannot be written fails, with a reason that names the likely cause
mkdir -p "$T/ro"; chmod 500 "$T/ro"
out="$( ( . "$LIB"; TMPDIR="$T/ro/sub" ncz_deb_fixture_check ) 2>&1 )"; rc=$?
[ "$rc" != 0 ] && ok "an unwritable TMPDIR fails the check" || bad "an unwritable TMPDIR fails the check"
grep -qiE 'quota|permission' <<< "$out" \
    && ok "the failure names a quota or permission cause" \
    || bad "the failure does not name a likely cause" "$out"

# 3. every suite that builds fixtures calls the guard and exits 3 (not 1) when it trips
for f in test-no-ubuntu test-ssplugin-supply-chain test-module-dkms-collision; do
    s="$REPO/build/$f.sh"
    if grep -q 'ncz_deb_fixture_check' "$s" && grep -q 'exit 3' "$s"; then
        ok "$f calls the guard and exits 3 (environment, not code)"
    else
        bad "$f does not guard its fixtures"
    fi
done

# 4. the dkms fixture no longer hides dpkg-deb's stderr
s="$REPO/build/test-module-dkms-collision.sh"
if grep -q 'fixture build failed' "$s"; then
    ok "the dkms fixture reports dpkg-deb's own error"
else
    bad "the dkms fixture still suppresses dpkg-deb's error"
fi

# 5. the invariant, so coverage cannot rot when a new suite starts building debs:
# every build/test-*.sh that runs dpkg-deb must call the guard first.
missing=""
count=0
for f in "$REPO"/build/test-*.sh; do
    grep -qE 'dpkg-deb [^|]*(--build|\bbuild\b|-b\b)' "$f" 2>/dev/null || continue
    count=$((count + 1))
    grep -q 'ncz_deb_fixture_check' "$f" || missing="$missing $(basename "$f")"
done
if [ "$count" -gt 0 ] && [ -z "$missing" ]; then
    ok "all $count suites that build deb fixtures call the guard"
else
    bad "a suite builds deb fixtures without the guard" "$missing"
fi

echo "test-deb-fixture-guard: $pass passed, $fail failed"
[ "$fail" = 0 ]
