#!/bin/bash
# test-container-ownership-audit.sh -- M10 (docs/BUILD-STABILITY.md §3, class
# C6): no container stage may leave a uid-0 file under the clone.
#
# WHY.  T item 6, 2026-10-29: "root-owned files in the clone after the
# containerised build stages made rm/cleanup fail until sudo chown -R".  The
# repo had fixed this class piecemeal three times (check-forky-provenance.sh
# strands its run dir, stage_provenance_gate's NCZ_CHOWN_BACK,
# ncz_magnetar_collect's chown -R), but ncz_container_run() -- which runs
# `make offline-mirror` and the layer/image makes as root in a container mounted
# on the clone -- had no general chown-back and nothing audited the result.
#
# M10 adds both halves, and this test pins them:
#
#   1. the audit exists, is wired into run_stage() (so EVERY stage is audited,
#      container or not) and ncz_container_run() installs the chown-back trap
#   2. POSITIVE: a stage that leaves no uid-0 file passes, and the audit
#      reports nothing
#   3. NEGATIVE (real uid 0): a stage that leaves a planted root-owned file
#      FAILS the stage, the finding names the file, and the file is chowned
#      back so the run dir stays deletable.  Runs only where root or
#      passwordless sudo is available; otherwise it is SKIPPED with a message.
#   4. NEGATIVE (no root needed): the same find/report/fail path, driven by
#      treating the build user's own uid as foreign (NCZ_OWNERSHIP_FOREIGN_UIDS,
#      a tests-only knob), so the reporting half is always proven.
#
#   build/test-container-ownership-audit.sh    exit 0 all pass, 1 any FAIL
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/build/build-image.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$*"; }
skip() { printf 'SKIP %s\n' "$*"; }

SCRATCH="${NCZ_TEST_SCRATCH:-$ROOT/build/.imgown.$$}"
rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"
trap 'rm -rf "$SCRATCH" 2>/dev/null' EXIT

# Extract exactly ONE function body, from `name() {` to the first column-0 `}`.
# The name is anchored end-to-end (so `run_stage` never matches `run_stage_foo`)
# and the opening brace may be spaced freely (`name() {`, `name(){`, tab).
# Col-0 `}` is the repo's closing-brace convention for top-level functions.
fn() {
    awk -v f="$1" '
        $0 ~ "^" f "\\(\\)[[:space:]]*\\{" { p = 1; print; next }
        p { print }
        p && /^\}[[:space:]]*$/ { exit }
    ' "$BIN"
}

# run_run <run-dir> <stage command> [extra env assignments...] -> rc
# Runs the REAL harness end to end; every stage body is the given command.
run_run() {
    local rd="$1" cmd="$2"; shift 2
    mkdir -p "$rd/logs"
    env "$@" NCZ_TEST_STAGE_CMD="$cmd" \
        bash "$BIN" --arch amd64 --full --no-publish --run-dir "$rd" >/dev/null 2>&1
}

# --- 1. the audit function exists and run_stage() calls it ----------------
echo "== 1. the ownership audit is wired into run_stage() =="
audit_fn=""
for cand in ncz_audit_stage_ownership ncz_ownership_audit ncz_audit_uid0; do
    if [ -n "$(fn "$cand")" ]; then audit_fn="$cand"; break; fi
done
[ -n "$audit_fn" ] && ok "build-image.sh defines an ownership audit ($audit_fn)" \
    || bad "build-image.sh defines no ownership-audit function"
rs="$(fn run_stage)"
if [ -n "$audit_fn" ] && grep -q "$audit_fn" <<<"$rs"; then
    ok "run_stage() calls $audit_fn (every stage is audited, container or not)"
else
    bad "run_stage() does not call the ownership audit"
fi
afn="$(fn "$audit_fn" 2>/dev/null)"
grep -q 'uid 0' <<<"$afn" && ok "the audit looks for uid 0" || bad "the audit does not test for uid 0"
grep -qE 'head (-\w+ )?20|head -20|-n 20' <<<"$afn" \
    && ok "the audit lists up to 20 paths" || bad "the audit does not cap its path list at 20"

# --- 2. POSITIVE: a clean stage passes and reports nothing ----------------
echo "== 2. a stage that leaves no uid-0 file passes =="
rd="$SCRATCH/positive"
rc="$(run_run "$rd" "mkdir -p '$rd/planted' && : > '$rd/planted/ours.txt'" ; echo $?)"
[ "$rc" = 0 ] && ok "a clean stage passes (rc=$rc)" || bad "a clean stage was failed (rc=$rc)"
if grep -rqi 'root-owned file' "$rd"/logs 2>/dev/null; then
    bad "the clean run logged an ownership finding: $(grep -rhi 'root-owned file' "$rd"/logs | head -1)"
else
    ok "the clean run reports no ownership finding"
fi

# --- 3. NEGATIVE with root: a planted uid-0 file is reported + chowned ----
echo "== 3. a planted root-owned file is reported and chowned back =="
as_root=""
if [ "$(id -u)" = 0 ]; then
    as_root="direct"; owner="0:0"
elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    as_root="sudo"; owner="$(id -u):$(id -g)"
fi
if [ -z "$as_root" ]; then
    skip "3. planted uid-0 case: no root and no passwordless sudo (M10's stated exception)"
else
    rd="$SCRATCH/negative-root"
    mkdir -p "$rd/planted"
    : > "$rd/planted/root-owned.txt"
    if [ "$as_root" = sudo ]; then sudo -n chown 0:0 "$rd/planted/root-owned.txt"
    else chown 0:0 "$rd/planted/root-owned.txt"; fi
    planted="$(stat -c '%u' "$rd/planted/root-owned.txt" 2>/dev/null)"
    [ "$planted" = 0 ] && ok "the fixture holds a real uid-0 file" \
        || bad "the fixture could not create a uid-0 file (uid=$planted)"
    if [ "$planted" = 0 ]; then
        rc="$(run_run "$rd" ":" NCZ_CHOWN_BACK="$owner" ; echo $?)"
        # M10 is "no uid-0 file may remain under the clone after a full build" --
        # it says nothing about who runs the build.  A uid-0 file is a finding
        # whether the invoker is root or not, so the audit is expected to run and
        # REPORT in both cases.  What differs is only the chown-back target: as
        # root it is a no-op (the file is already theirs).
        [ "$rc" != 0 ] && ok "a uid-0 file under the run dir fails the build (rc=$rc)" \
            || bad "a uid-0 file under the run dir did NOT fail the build (rc=$rc)"
        if ! grep -rq 'root-owned.txt' "$rd"/logs 2>/dev/null; then
            bad "the audit did not report the planted root-owned file"
        elif [ "$(id -u)" = 0 ]; then
            # as the root login the audit must still have produced the finding
            ok "as root the audit still runs and reports the uid-0 file (finding present)"
        else
            ok "the finding names the planted root-owned file"
        fi
        now="$(stat -c '%u:%g' "$rd/planted/root-owned.txt" 2>/dev/null)"
        [ "$now" = "$owner" ] && ok "the planted file was chowned back to $owner" \
            || bad "the planted file is still $now (wanted $owner)"
        # and the run dir is deletable again by the build user
        if rm -rf "$rd/planted" 2>/dev/null; then
            ok "the run dir is deletable after the audit (no sudo rm needed)"
        else
            bad "the run dir is still not deletable by the build user"
            [ "$as_root" = sudo ] && sudo -n rm -rf "$rd/planted" 2>/dev/null || true
        fi
    fi
fi

# --- 4. NEGATIVE without root: the report path always runs ----------------
echo "== 4. the audit's report/fail path (no root needed) =="
rd="$SCRATCH/negative-foreign"
rc="$(run_run "$rd" "mkdir -p '$rd/planted' && : > '$rd/planted/foreign-owned.txt'" \
      NCZ_OWNERSHIP_FOREIGN_UIDS="$(id -u)" ; echo $?)"
[ "$rc" != 0 ] && ok "a foreign-uid file under the run dir fails the stage (rc=$rc)" \
    || bad "a foreign-uid file under the run dir did NOT fail the stage"
out="$(cat "$rd"/logs/*.log 2>/dev/null)"
grep -q 'foreign-owned.txt' <<<"$out" \
    && ok "the finding names the offending path" || bad "the finding does not name the file"
grep -rqi 'root-owned file' "$rd"/logs 2>/dev/null \
    && ok "the finding reads as a root-owned-file report" \
    || bad "the finding is not reported as a root-owned-file FAIL"
awk -F'\t' '$3 ~ /^FAIL/{f=1} END{exit !f}' "$rd/stages.tsv" 2>/dev/null \
    && ok "stages.tsv records the audited stage as FAIL" \
    || bad "stages.tsv does not record the failed stage"

# --- 5. ncz_container_run() hands the clone back on every exit path -------
echo "== 5. the container helper installs the chown-back trap =="
cr="$(fn ncz_container_run)"
grep -q 'ncz_trap_chown_back\|ncz_chown_back' <<<"$cr" \
    && ok "ncz_container_run() chowns back on exit" \
    || bad "ncz_container_run() has no chown-back"
grep -q 'lib/priv.sh' "$BIN" \
    && ok "build-image.sh sources build/lib/priv.sh (the chown-back helpers)" \
    || bad "build-image.sh does not source lib/priv.sh"

printf '\n== container-ownership-audit tests: %d passed, %d failed ==\n' "$PASS" "$FAIL"
if [ "$FAIL" = 0 ]; then exit 0; else exit 1; fi
