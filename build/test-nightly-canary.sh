#!/bin/bash
# test-nightly-canary.sh -- offline tests for the nightly canary orchestration:
# CLI contract, the dependency inventory, the dry-run plan, the kernel HEAD +
# patch-applicability check, the lock/disk guard, and the status/TRIAGE/retention
# machinery.  (The heavy rebuild stages are exercised live on the build hosts,
# not here.)
#
# Exit 0 all pass, 1 any FAIL.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CANARY="$ROOT/build/nightly-canary.sh"
KHC="$ROOT/build/nightly/kernel-head-check.sh"
HWS="$ROOT/build/nightly/hw-smoke.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$*"; }
S="$(mktemp -d "${TMPDIR:-/tmp}/ncz-canary.XXXXXX")"
trap 'rm -rf "$S"' EXIT

echo "== 1. CLI contract =="
expect_rc() { local want="$1" desc="$2"; shift 2; bash "$CANARY" "$@" >/dev/null 2>&1; local rc=$?; \
    if [ "$rc" = "$want" ]; then ok "$desc (rc=$rc)"; else bad "$desc (want $want got $rc)"; fi; }
expect_rc 2 "no --arch rejected" --mode nightly
expect_rc 2 "bad --arch rejected" --arch riscv
expect_rc 2 "bad --mode rejected" --arch amd64 --mode hourly
expect_rc 2 "bad --sources rejected" --arch amd64 --sources sometimes
expect_rc 2 "unknown flag rejected" --arch amd64 --frobnicate
expect_rc 0 "--help" --help

echo "== 2. inventory =="
inv="$(bash "$CANARY" --inventory 2>/dev/null)"
for c in ncz-singularity-desktop libdrm-ncz2 cix-gpu-kmd-dkms linux-arm64-sky1 ncz-screensavers; do
    grep -q "$c" <<<"$inv" && ok "inventory lists $c" || bad "inventory missing $c"
done
grep -qi 'buildable-from-head' <<<"$inv" && ok "inventory has the buildable-from-head header" || bad "inventory header missing"

echo "== 3. dry-run plan =="
p="$(bash "$CANARY" --arch both --mode weekly --dry-run 2>/dev/null)"
for s in preflight refresh-substrate resolve-heads kernel-head-check rebuild-components ledger-candidates provenance-inputs shader-gate unit-tests hw-smoke status retention; do
    grep -q "    - $s" <<<"$p" && ok "plan names stage $s" || bad "plan missing stage $s"
done
grep -q 'weekly-image' <<<"$p" && ok "weekly plan names weekly-image" || bad "weekly plan omits weekly-image"
grep -q 'NEVER' <<<"$p" && ok "plan states the never-do list" || bad "plan omits never-do list"
pn="$(bash "$CANARY" --arch amd64 --mode nightly --dry-run 2>/dev/null)"
grep -q 'weekly-image' <<<"$pn" && bad "nightly plan wrongly names weekly-image" || ok "nightly plan omits weekly-image"

echo "== 4. kernel head + patch applicability =="
git init -q "$S/tree"; git -C "$S/tree" config user.email t@t; git -C "$S/tree" config user.name t
printf 'a\nb\nc\n' > "$S/tree/f"; git -C "$S/tree" add f; git -C "$S/tree" commit -qm init
mkdir -p "$S/patches"
cp "$S/tree/f" "$S/orig"
printf 'a\nB\nc\n' > "$S/tree/f"; diff -u "$S/orig" "$S/tree/f" | sed 's#^--- .*#--- a/f#; s#^+++ .*#+++ b/f#' > "$S/patches/0001-good.patch"
git -C "$S/tree" checkout -q -- f
printf -- '--- a/nope\n+++ b/nope\n@@ -1,1 +1,1 @@\n-x\n+y\n' > "$S/patches/0002-bad.patch"
bash "$KHC" --arch amd64 --out "$S/kout" --tree-amd64 "$S/tree" --patches-amd64 "$S/patches" >/dev/null 2>&1
rc=$?; [ "$rc" = 0 ] && ok "kernel-head-check exits 0 (conflicts are reported, not fatal)" || bad "kernel-head-check rc=$rc"
grep -q '"status": "CONFLICT"' "$S/kout/kernel-head-amd64.json" && ok "conflicting patch reported" || bad "conflict not reported"
grep -q '0002-bad.patch' "$S/kout/kernel-head-amd64.json" && ok "conflicting patch named" || bad "conflict list missing the bad patch"
grep -q '"n_applied": 1' "$S/kout/kernel-head-amd64.json" && ok "good patch counted applied" || bad "good patch not counted"
# no tree, unreachable remote -> SKIPPED (never a fake pass)
bash "$KHC" --arch arm64 --out "$S/kout2" --remote-arm64 https://127.0.0.1:9/nope.git --tree-arm64 /nonexistent >/dev/null 2>&1
grep -q '"status": "HEAD-ONLY"\|"status": "SKIPPED"' "$S/kout2/kernel-head-arm64.json" \
    && ok "no-tree kernel check reports HEAD-ONLY/SKIPPED" || bad "no-tree kernel check status wrong"

echo "== 5. hw-smoke skip discipline =="
cat > "$S/reg.tsv" <<'EOF'
# host	ip	hostname	arch	gpu	kernel	ssh_user	cred_ref	role	smoke	forbidden
dead	192.0.2.1	nope	amd64	x	k	ncz	-	role	scenefx-probe	reboot
EOF
bash "$HWS" --out "$S/hw.json" --registry "$S/reg.tsv" --hosts dead --connect-timeout 2 >/dev/null 2>&1
grep -q '"status": "SKIPPED"' "$S/hw.json" && ok "unreachable host SKIPPED" || bad "unreachable host not SKIPPED"
bash "$HWS" --out "$S/hw2.json" --registry "$S/reg.tsv" --hosts ghost >/dev/null 2>&1
grep -q 'unknown host in registry' "$S/hw2.json" && ok "unknown host SKIPPED(unknown)" || bad "unknown host not flagged"

echo "== 6. lock + disk guard =="
OUT="$S/runs"; mkdir -p "$OUT/.ncz-nightly.lock"; printf '%s\n' "$$" > "$OUT/.ncz-nightly.lock/pid"
bash "$CANARY" --arch amd64 --mode nightly --unattended --only preflight --out-root "$OUT" --run-id LOCKTEST >/dev/null 2>&1
rc=$?; [ "$rc" = 2 ] && ok "live lock refuses to start (rc=$rc)" || bad "live lock did not refuse (rc=$rc)"
rm -rf "$OUT/.ncz-nightly.lock"
bash "$CANARY" --arch amd64 --mode nightly --only preflight --out-root "$OUT" --run-id DISK --max-disk-pct 0 >/dev/null 2>&1
rc=$?; [ "$rc" = 2 ] && ok "disk guard refuses at 0% limit (rc=$rc)" || bad "disk guard did not refuse (rc=$rc)"

echo "== 7. green run: status/latest/last-green =="
OUT2="$S/runs2"
bash "$CANARY" --arch amd64 --mode nightly --no-build --no-hw --no-reaper \
    --only preflight --out-root "$OUT2" --run-id GREENRUN --max-disk-pct 99 >/dev/null 2>&1
rc=$?; [ "$rc" = 0 ] && ok "green run rc=0" || bad "green run rc=$rc"
for f in status/GREENRUN.json status/latest.json status/last-green.json; do
    [ -f "$OUT2/$f" ] && ok "wrote $f" || bad "missing $f"
done
python3 - "$OUT2/status/latest.json" <<'PYEOF' && ok "latest.json is green" || bad "latest.json not green"
import json,sys
s=json.load(open(sys.argv[1])); sys.exit(0 if s["green"] and s["rc"]==0 else 1)
PYEOF
grep -q '^preflight	PASS' "$OUT2/GREENRUN/stages.tsv" && ok "preflight recorded PASS" || bad "preflight not recorded PASS"

echo "== 8. red run: status red + TRIAGE + no last-green =="
OUT3="$S/runs3"
NCZ_NIGHTLY_TEST_FAIL_STAGE=preflight bash "$CANARY" --arch amd64 --mode nightly \
    --no-build --no-hw --no-reaper --only preflight --out-root "$OUT3" --run-id REDRUN --max-disk-pct 99 >/dev/null 2>&1
rc=$?; [ "$rc" != 0 ] && ok "red run rc!=0 (rc=$rc)" || bad "red run rc=0"
[ -f "$OUT3/REDRUN/TRIAGE.md" ] && ok "TRIAGE.md written on red" || bad "TRIAGE.md missing on red"
[ -f "$OUT3/status/last-green.json" ] && bad "red run wrongly wrote last-green.json" || ok "red run did not write last-green.json"
python3 - "$OUT3/status/latest.json" <<'PYEOF' && ok "latest.json is red with first failing component" || bad "latest.json not red"
import json,sys
s=json.load(open(sys.argv[1])); sys.exit(0 if (not s["green"]) and s["first_failing_component"]=="preflight" else 1)
PYEOF

echo "== 9. retention (keep last 3 nightly) =="
OUT4="$S/runs4"; mkdir -p "$OUT4"
for d in 20000101 20010101 20020101 20030101; do mkdir -p "$OUT4/$d"; touch -t 200001010000 "$OUT4/$d"; done
bash "$CANARY" --arch amd64 --mode nightly --no-build --no-hw --no-reaper \
    --only preflight --out-root "$OUT4" --run-id RETENTION --max-disk-pct 99 >/dev/null 2>&1
n="$(ls -1d "$OUT4"/[0-9]* 2>/dev/null | wc -l | tr -d ' ')"
[ "$n" -le 3 ] && ok "retention kept <=3 numeric run dirs ($n)" || bad "retention kept $n run dirs"

printf '\n== nightly-canary tests: %d passed, %d failed ==\n' "$PASS" "$FAIL"
if [ "$FAIL" = 0 ]; then exit 0; else exit 1; fi
