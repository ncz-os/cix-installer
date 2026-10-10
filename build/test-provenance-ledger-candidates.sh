#!/bin/bash
# test-provenance-ledger-candidates.sh -- unit tests for the nightly
# ledger-candidates mechanism in build/forky-provenance.py.
#
# Proves BOTH directions of the operator's design (2026-10-10):
#   * nightly mode ACCEPTS an NCZ package whose exact (name,version,arch)+sha256
#     is in the CURRENT run's ledger-candidates.tsv, but ONLY when the sha256 of
#     the bytes scanned matches the candidate's recorded sha256;
#   * a candidate whose sha256 does NOT match the bytes FAILS;
#   * release mode (the default) IGNORES candidates entirely: the same package
#     is an unknown origin and FAILS;
#   * an unknown package FAILS in BOTH modes;
#   * the CLI refuses to combine candidates with release mode or --ubuntu-only,
#     and refuses --ledger-mode nightly without a candidates file.
#
# The byte-level cases drive forky-provenance.py's classify() directly (offline,
# no snapshot index needed); the argument cases drive the real CLI.
#
# Exit 0 all pass, 1 any FAIL.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FP="$ROOT/build/forky-provenance.py"
WRAP="$ROOT/build/check-forky-provenance.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$*"; }

echo "== 1. classify(): candidate byte-match both directions =="
# Assert the classify() outcomes (the Python driver prints RESULT lines).
declare -A R
while read -r k tag v n; do
    [ "$k" = "RESULT" ] || continue
    R["$tag"]="$v:$n"
done < <(python3 -I - "$FP" <<'PYEOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("fp", sys.argv[1]); F = importlib.util.module_from_spec(spec); spec.loader.exec_module(F)
SHA_GOOD="a"*64; SHA_BAD="b"*64
def mkref(mode, candidates=None, ncz=None):
    r=F.Ref.__new__(F.Ref); r.ubuntu_only=False; r.ledger_mode=mode; r.vendor={}
    r.ncz=ncz or {}; r.ncz_candidates=candidates or {}; r.ncz_ts={}; r.receipt_ts={}
    r.idx={}; r.sid={}; r.sid_idx={}; r.trust={"architectures":"amd64 arm64"}; r.seen_kernel=set(); return r
CAND={("ncz-apt-policy","1.0.1","all"):{"sha256":{SHA_GOOD},"recipe":"build/x.sh","source_revision":"r203","source_shas":"d","run_id":"r203"}}
def run(tag, ref, *a):
    F.FAILS=[]; o=F.classify(ref,"t",*a); print("RESULT",tag,o,len(F.FAILS))
run("reviewed", mkref("release",ncz={("ncz-apt-policy","1.0.1","all"):{SHA_GOOD}}),"ncz-apt-policy","1.0.1","all","NCZ",SHA_GOOD)
run("nightly-match", mkref("nightly",candidates=CAND),"ncz-apt-policy","1.0.1","all","NCZ",SHA_GOOD)
run("nightly-mismatch", mkref("nightly",candidates=CAND),"ncz-apt-policy","1.0.1","all","NCZ",SHA_BAD)
run("release-candidate-rejected", mkref("release"),"ncz-apt-policy","1.0.1","all","NCZ",SHA_GOOD)
run("nightly-unknown", mkref("nightly",candidates=CAND),"totally-unknown","9.9","amd64","X",SHA_GOOD)
run("release-unknown", mkref("release"),"totally-unknown","9.9","amd64","X",SHA_GOOD)
F.FAILS=[]; o=F.classify_noarch(mkref("nightly",candidates=CAND),"t","ncz-apt-policy","1.0.1","NCZ"); print("RESULT","nightly-noarch",o,len(F.FAILS))
F.FAILS=[]; o=F.classify_noarch(mkref("release"),"t","ncz-apt-policy","1.0.1","NCZ"); print("RESULT","release-noarch",o,len(F.FAILS))
PYEOF
)

check() { # tag expected_origin expected_nfails
    local got="${R[$1]:-MISSING}"
    if [ "$got" = "$2:$3" ]; then ok "$1 => $got"; else bad "$1 => $got (want $2:$3)"; fi
}
check reviewed                   ncz                       0
check nightly-match              ncz-candidate             0
check nightly-mismatch           None                      1
check release-candidate-rejected None                      1
check nightly-unknown            None                      1
check release-unknown            None                      1
check nightly-noarch             ncz-candidate-identity    0
check release-noarch             None                      1

echo "== 2. CLI argument contract =="
expect_rc() { # want desc args...
    local want="$1" desc="$2"; shift 2
    bash "$WRAP" "$@" >/dev/null 2>&1; local rc=$?
    if [ "$rc" = "$want" ]; then ok "$desc (rc=$rc)"; else bad "$desc (want $want got $rc)"; fi
}
# candidates in release mode -> usage error (2)
expect_rc 2 "candidates rejected in release mode" --ledger-candidates /tmp/x.tsv --debs /tmp
# nightly without candidates -> usage error (2)
expect_rc 2 "nightly without candidates rejected" --ledger-mode nightly --debs /tmp
# nightly + candidates + missing file -> hard die (fails closed, rc=2 like every
# die() in forky-provenance.py -- never silently scans with no candidates)
expect_rc 2 "nightly missing candidates file dies (fail closed)" --ledger-mode nightly --ledger-candidates /nonexistent/c.tsv --debs /tmp --index-dir /tmp
# ubuntu-only + nightly -> usage error
expect_rc 2 "ubuntu-only + nightly rejected" --ubuntu-only --ledger-mode nightly --ledger-candidates /tmp/x.tsv

printf '\n== ledger-candidates tests: %d passed, %d failed ==\n' "$PASS" "$FAIL"
if [ "$FAIL" = 0 ]; then exit 0; else exit 1; fi
