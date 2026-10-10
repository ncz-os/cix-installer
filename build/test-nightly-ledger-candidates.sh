#!/bin/bash
# test-nightly-ledger-candidates.sh -- tests for the candidate EMITTER
# (build/nightly-ledger-candidates.sh) and the promotion tool
# (build/promote-ledger-candidates.sh).
#
# Proves:
#   * the emitter writes same-schema candidate rows (name/version/arch/sha256/
#     recipe/source_revision/note/resolved_source_shas/run_id/status=candidate)
#     with the sha256 of the actual deb bytes, and SKIPS a deb with no
#     provenance row (never invents a recipe/revision);
#   * promotion DRY-RUN prints a diff and changes nothing;
#   * promotion REFUSES to overwrite a reviewed identity with different bytes
#     (conflict), and refuses --apply with a conflict present;
#   * --apply requires NCZ_PROMOTE_OPERATOR=1 + --reviewer;
#   * --apply appends the new reviewed row (and only that row).
#
# Exit 0 all pass, 1 any FAIL.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EMIT="$ROOT/build/nightly-ledger-candidates.sh"
PROM="$ROOT/build/promote-ledger-candidates.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$*"; }
S="$(mktemp -d "${TMPDIR:-/tmp}/ncz-candtest.XXXXXX")"
trap 'rm -rf "$S"' EXIT
sha() { sha256sum "$1" | awk '{print $1}'; }

echo "== 1. emitter =="
mkdir -p "$S/debs"
printf 'fake deb A payload\n' > "$S/debs/ncz-apt-policy_1.0.1_all.deb"
printf 'fake deb B payload\n' > "$S/debs/ncz-screensavers_0.9.0_amd64.deb"
printf 'orphan deb, no provenance\n' > "$S/debs/mystery_1.0_amd64.deb"
printf 'ncz-apt-policy_1.0.1_all.deb\tbuild/build-ncz-apt-policy-deb.sh\tr203\tcafe\n'  > "$S/prov.tsv"
printf 'ncz-screensavers_0.9.0_amd64.deb\tscreensavers-version.env\t0.9.0-head\tbeef\n' > "$S/prov2.tsv"
cat "$S/prov.tsv" "$S/prov2.tsv" > "$S/prov-all.tsv"
bash "$EMIT" --run-id testrun --out "$S/cand.tsv" --provenance "$S/prov-all.tsv" --deb-dir "$S/debs" >"$S/emit.log" 2>&1
rc=$?
[ "$rc" = 0 ] && ok "emitter rc=0" || bad "emitter rc=$rc ($(cat "$S/emit.log"))"
grep -q 'wrote 2 candidate row' "$S/emit.log" && ok "emitter wrote 2 rows" || bad "emitter row count wrong: $(cat "$S/emit.log")"
grep -q 'SKIP mystery_1.0_amd64.deb' "$S/emit.log" && ok "emitter skipped the provenance-less deb" || bad "emitter did not skip the orphan deb"
grep -q '^mystery' "$S/cand.tsv" && bad "orphan deb leaked into candidates" || ok "orphan deb absent from candidates"

row="$(grep '^ncz-apt-policy' "$S/cand.tsv")"
[ -n "$row" ] && ok "candidate has the ncz-apt-policy row" || bad "candidate missing ncz-apt-policy"
got_sha="$(printf '%s' "$row" | cut -f4)"; want_sha="$(sha "$S/debs/ncz-apt-policy_1.0.1_all.deb")"
[ "$got_sha" = "$want_sha" ] && ok "candidate sha256 == deb bytes sha256" || bad "candidate sha mismatch ($got_sha vs $want_sha)"
[ "$(printf '%s' "$row" | cut -f5)" = "build/build-ncz-apt-policy-deb.sh" ] && ok "candidate recipe carried" || bad "candidate recipe wrong"
[ "$(printf '%s' "$row" | cut -f6)" = "r203" ] && ok "candidate source_revision carried" || bad "candidate source_revision wrong"
[ "$(printf '%s' "$row" | cut -f9)" = "testrun" ] && ok "candidate build_run_id carried" || bad "candidate run id wrong"
[ "$(printf '%s' "$row" | cut -f10)" = "candidate" ] && ok "candidate status=candidate" || bad "candidate status wrong"

echo "== 2. promotion: dry run + conflicts =="
LEDGER="$S/ncz-packages.tsv"
printf '# reviewed ledger fixture\n# name\tversion\tarch\tsha256\trecipe\tsource_revision\tnote\n' > "$LEDGER"
printf 'ncz-apt-policy\t1.0.1\tall\t%s\tbuild/build-ncz-apt-policy-deb.sh\tr203\treviewed\n' "$(sha "$S/debs/ncz-apt-policy_1.0.1_all.deb")" >> "$LEDGER"
before="$(sha "$LEDGER")"

# candidate: one NEW row (screensavers) + one identical-to-reviewed + one conflict
CAND2="$S/cand2.tsv"
{
    printf '# candidates\n'
    grep '^ncz-screensavers' "$S/cand.tsv"
    grep '^ncz-apt-policy' "$S/cand.tsv"
    printf 'ncz-apt-policy\t1.0.1\tall\t%s\tbuild/build-ncz-apt-policy-deb.sh\tr203\tconflicting bytes\t\trun\tcandidate\n' "$(printf 'a%.0s' $(seq 1 64))"
} > "$CAND2"
bash "$PROM" testrun --candidates "$CAND2" --ledger "$LEDGER" >"$S/promo.log" 2>&1; rc=$?
[ "$rc" = 1 ] && ok "dry-run with a conflict exits 1" || bad "expected rc=1 got $rc"
grep -q 'CONFLICT ncz-apt-policy' "$S/promo.log" && ok "conflict reported" || bad "conflict not reported"
grep -q 'ncz-screensavers' "$S/promo.log" && ok "dry-run diff shows the new row" || bad "diff missing new row"
[ "$(sha "$LEDGER")" = "$before" ] && ok "dry-run changed nothing" || bad "dry-run modified the ledger!"

echo "== 3. promotion: clean dry run then gated apply =="
CAND3="$S/cand3.tsv"; grep '^ncz-screensavers' "$S/cand.tsv" > "$CAND3"
bash "$PROM" testrun --candidates "$CAND3" --ledger "$LEDGER" >"$S/promo3.log" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "clean dry-run exits 0" || bad "clean dry-run rc=$rc"
[ "$(sha "$LEDGER")" = "$before" ] && ok "clean dry-run still changed nothing" || bad "clean dry-run modified the ledger"

# apply without the operator env -> refuses
bash "$PROM" testrun --candidates "$CAND3" --ledger "$LEDGER" --apply --reviewer zoder >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "--apply without NCZ_PROMOTE_OPERATOR refuses" || bad "ungated --apply rc=$rc (want 2)"
[ "$(sha "$LEDGER")" = "$before" ] && ok "refused --apply changed nothing" || bad "refused --apply modified the ledger"

# apply with conflict present -> refuses (3)
NCZ_PROMOTE_OPERATOR=1 bash "$PROM" testrun --candidates "$CAND2" --ledger "$LEDGER" --apply --reviewer zoder >/dev/null 2>&1; rc=$?
[ "$rc" = 3 ] && ok "--apply with a conflict refuses" || bad "--apply-with-conflict rc=$rc (want 3)"

# proper gated apply
NCZ_PROMOTE_OPERATOR=1 bash "$PROM" testrun --candidates "$CAND3" --ledger "$LEDGER" --apply --reviewer zoder >"$S/apply.log" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "gated --apply succeeds" || bad "gated --apply rc=$rc ($(cat "$S/apply.log"))"
grep -q '^ncz-screensavers	' "$LEDGER" && ok "ledger gained the new row" || bad "ledger missing the new row after apply"
[ "$(grep -c '^ncz-apt-policy' "$LEDGER")" = 1 ] && ok "reviewed row not duplicated" || bad "reviewed row duplicated/removed"

printf '\n== nightly-ledger-candidates tests: %d passed, %d failed ==\n' "$PASS" "$FAIL"
if [ "$FAIL" = 0 ]; then exit 0; else exit 1; fi
