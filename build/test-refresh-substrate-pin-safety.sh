#!/bin/bash
# test-refresh-substrate-pin-safety.sh -- regressions for the two ways
# build/refresh-substrate.sh could be talked out of its fails-closed guarantee.
#
# Both defects sit on the pinned-snapshot digest step, which is the only place
# the script touches a value derived from a TRACKED file (manifests/base.pin)
# and hands it to a shell.  A re-pin is the operator's review surface, so a
# committed base.pin is normally trusted -- but a trusted file must never be
# able to turn into a command, and a production run must never be able to skip
# the gpgv check because of an inherited variable.
#
# Cases:
#   1. a malformed snapshot stamp in manifests/base.pin must be REFUSED before
#      it reaches the digest command (no side effect is observed);
#   2. NCZ_SUITE_DIGESTS_CMD alone must NOT replace the signed fetch -- it is
#      honoured only with the explicit NCZ_ALLOW_SUITE_DIGESTS_CMD=1 opt-in;
#   3. with the opt-in and a well-formed pin, the override runs the stub.
#
# The fixture is a throwaway COPY of this checkout so the real script runs
# against a real manifests/base.pin and release.conf; the network, the ISO
# fetch and the measurement are not reached because every case stops at the
# digest step (or before it).
#
# Usage: bash build/test-refresh-substrate-pin-safety.sh   Exit 0 = all pass.
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
REFRESH="$ROOT/build/refresh-substrate.sh"

pass=0 fail=0
ok() { echo "  PASS  $*"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $*"; [ $# -gt 1 ] && printf '%s\n' "$2" | sed 's/^/        /'; fail=$((fail + 1)); }

[ -f "$REFRESH" ] || { echo "FAIL: $REFRESH is missing" >&2; exit 1; }

T="$(mktemp -d "${TMPDIR:-$HOME}/.refresh-pin-safety.XXXXXX")" \
    || { echo "FAIL: cannot create a scratch dir" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT

# A fixture repo: the few files the digest step reads/writes.
# The script resolves ROOT from its own location, so each fixture is a real
# mini-checkout: the script is copied in and driven from there.
mk_repo() {  # dir [snapshot-stamp]
    local d="$1" snap="${2-20300101T000000Z}"
    mkdir -p "$d/build/lib" "$d/manifests/keys"
    cp "$REFRESH" "$d/build/refresh-substrate.sh"
    cp "$ROOT/build/lib/ncz-site.sh" "$d/build/lib/"
    printf 'NCZ_BASE_MIRROR_SNAPSHOT="%s"\n' "$snap" > "$d/release.conf"
    printf '# arch\tdate\tsha256\tsnapshot\n' > "$d/manifests/base.pin"
    printf 'amd64\t2030-01-01\t%s\t%s\n' "$(printf 'a%.0s' {1..64})" "$snap" >> "$d/manifests/base.pin"
    printf 'arm64\t2030-01-01\t%s\t%s\n' "$(printf 'b%.0s' {1..64})" "$snap" >> "$d/manifests/base.pin"
}

# --sync-only re-derives from the committed pin and stops at the digest step.
run_sync() {  # repo [env...] -- runs the real script from the fixture
    local d="$1"; shift
    ( cd "$d" && env NCZ_SUBSTRATE_CACHE_DIR="$T/cache" "$@" \
        bash "$d/build/refresh-substrate.sh" --sync-only ) 2>&1
}

echo "== a malformed snapshot stamp in base.pin is refused before it is run =="
F="$T/stamp"; mk_repo "$F"
# Use a malformed stamp.
MARK="$T/stamp.marker"
MALFORMED_STAMP="20300101T000000Z\$(touch $MARK)"
# BOTH rows carry the SAME payload: that keeps the pre-existing "rows disagree"
# check satisfied, so the run reaches -- and must be stopped by -- the stamp
# validation under test.  (A differing payload would stop it a step earlier and
# prove nothing about this fix.)
awk -F'\t' -v OFS='\t' -v stamp="$MALFORMED_STAMP" 'NR>1{$4=stamp} {print}' \
    "$F/manifests/base.pin" > "$F/base.pin.new" && mv "$F/base.pin.new" "$F/manifests/base.pin"
out="$(run_sync "$F" NCZ_ALLOW_SUITE_DIGESTS_CMD=1 NCZ_SUITE_DIGESTS_CMD=true)"; rc=$?
[ "$rc" != 0 ] && ok "--sync-only fails closed on a malformed snapshot stamp (rc=$rc)" \
    || bad "a malformed snapshot stamp was accepted (rc=$rc)" "$out"
[ ! -e "$MARK" ] && ok "the command in the stamp did not execute" \
    || bad "the command in the stamp was run" "$(cat "$MARK" 2>/dev/null)"
printf '%s\n' "$out" | grep -i 'not a YYYYMMDDTHHMMSSZ' >/dev/null \
    && ok "the refusal explains the required stamp format" \
    || bad "the refusal does not name the stamp format" "$out"

echo "== NCZ_SUITE_DIGESTS_CMD alone cannot replace the signed fetch =="
F="$T/override"; mk_repo "$F"
MARK2="$T/override.marker"
out="$(run_sync "$F" NCZ_SUITE_DIGESTS_CMD="touch $MARK2 --")"; rc=$?
[ "$rc" != 0 ] && ok "without the opt-in the override is refused (rc=$rc)" \
    || bad "NCZ_SUITE_DIGESTS_CMD replaced the signed fetch without an opt-in (rc=$rc)" "$out"
[ ! -e "$MARK2" ] && ok "the override command did not run" \
    || bad "the override command RAN without the test opt-in"
printf '%s\n' "$out" | grep  'NCZ_ALLOW_SUITE_DIGESTS_CMD' >/dev/null \
    && ok "the refusal names the required opt-in" \
    || bad "the refusal does not name the opt-in" "$out"

echo "== with the opt-in and a valid pin the override does run (control) =="
F="$T/control"; mk_repo "$F"
MARK3="$T/control.marker"
out="$(run_sync "$F" NCZ_ALLOW_SUITE_DIGESTS_CMD=1 NCZ_SUITE_DIGESTS_CMD="touch $MARK3 --")"
[ -e "$MARK3" ] && ok "the opted-in override runs the test stub" \
    || bad "the stub did not run even with the opt-in" "$out"

echo "== the stub still receives the snapshot as a real argument =="
# The override is now run via `bash -c ... --snapshot "$1"`, so the stamp is a
# positional argument rather than text spliced into the command.  A stub SCRIPT
# records its own argv; formatting it inline would let the outer shell expand
# "$@" before the hook ever runs, which would test nothing.
F="$T/argv"; mk_repo "$F"
ARGV="$T/argv.txt"
STUB="$T/record-argv"
cat > "$STUB" <<'STUBEOF'
#!/bin/bash
printf '%s\n' "$@" > "$ARGV_OUT"
STUBEOF
chmod +x "$STUB"
out="$(run_sync "$F" NCZ_ALLOW_SUITE_DIGESTS_CMD=1 ARGV_OUT="$ARGV" \
    NCZ_SUITE_DIGESTS_CMD="$STUB")"
if [ "$(sed -n '1p' "$ARGV" 2>/dev/null)" = "--snapshot" ] \
   && [ "$(sed -n '2p' "$ARGV" 2>/dev/null)" = "20300101T000000Z" ]; then
    ok "the stub receives (--snapshot, <stamp>) as separate argv entries"
else
    bad "the stub did not receive the snapshot as a positional argument" \
        "$(cat "$ARGV" 2>/dev/null)"
fi

echo "-- results --"
echo "  $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
exit 0
