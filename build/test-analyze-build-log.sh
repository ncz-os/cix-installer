#!/usr/bin/env bash
# Tests for build/analyze-build-log.py — the stub model server is python3 stdlib only.
#
# Spec cases (Duty-5e job 01a1ca7d-d008-75cf-9ace-a6a04a5e8c5a):
#   (a) chunks merge in order
#   (b) malformed JSON from the stub triggers exactly one retry then a recorded chunk error
#   (c) the doubled-line dedup preserves original line numbering
#   (d) a red fixture where the stub returns class C3 and the merged report carries it
#   (e) --timeout is honored: a transport timeout is a recorded chunk error and
#       is NOT retried (the ONE retry is for malformed JSON only). Justification
#       for the new case: CPU-served models prefill 9-14k-token chunks in
#       minutes (measured 2026-11-11 on the 8095 sidecar), so the hard-coded
#       120s cut every chunk off; the CLI now takes --timeout.
#   (f) only tee-pairs collapse: a run of 3 identical lines keeps TWO
#       (originals 1 and 3), not one. Justification for the new case: review
#       verdict becfef02 (high) - collapse-any-run silently deleted genuine
#       repeated lines (runs of 3+ exist in the 2026-10-29 evidence logs);
#       red-proven against the old dedup, green with pair-consumption.
#   (g) terminal merge: the chunk covering the build-abort marker decides the
#       merged class and first_error_line (fallback: last non-ok), never the
#       first non-ok chunk. Justification for the new case: the A1 accuracy
#       measurement (2026-11-11) showed first-non-ok-wins let a benign apt W:
#       warning (early chunk, class C6) hijack the merged verdict away from the
#       terminal failure (which correctly cited the ERROR abort lines).
#   (h) the SYSTEM_PROMPT carries the classification-contract clauses: apt W:
#       warnings are never failures on their own, and the taxonomy carries the
#       C1 symptom vocabulary ('an input has an unreviewed origin'). Justified
#       by the same A1 measurement; a regression dropping the clauses must fail
#       CI (prompt content is part of the spec).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ANALYZER="$REPO_ROOT/build/analyze-build-log.py"
TMP="$(mktemp -d)"
STUB_PID=""
cleanup() {
    [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- stub model server (python3 stdlib only) --------------------------------
cat >"$TMP/stub.py" <<'PYEOF'
import http.server
import json
import os
import sys
import time

STATE_DIR = os.environ["STUB_DIR"]
MODE = os.environ["STUB_MODE"]
count = 0


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        global count
        count += 1
        body = self.rfile.read(int(self.headers["Content-Length"]))
        try:
            user_text = json.loads(body)["messages"][-1]["content"]
        except (json.JSONDecodeError, KeyError, IndexError, TypeError):
            user_text = body.decode(errors="replace")
        with open(os.path.join(STATE_DIR, "lastbody"), "w") as fh:
            fh.write(user_text)
        with open(os.path.join(STATE_DIR, "count"), "w") as fh:
            fh.write(str(count))
        if MODE == "slow":
            time.sleep(3)
        if MODE == "garbage":
            content = "this is not strict JSON"
        elif MODE == "c3":
            content = json.dumps(
                {
                    "failure_class": "C3",
                    "first_error_line": 3,
                    "cause": "stub boom",
                    "evidence": [3],
                }
            )
        elif MODE == "mixed":
            # request 1 = early warning chunk, request 4 = terminal abort chunk
            if count == 1:
                content = json.dumps(
                    {
                        "failure_class": "C6",
                        "first_error_line": 2,
                        "cause": "stub early warning",
                        "evidence": [2],
                    }
                )
            elif count == 4:
                content = json.dumps(
                    {
                        "failure_class": "C3",
                        "first_error_line": 8,
                        "cause": "stub terminal abort",
                        "evidence": [8],
                    }
                )
            else:
                content = json.dumps(
                    {
                        "failure_class": "ok",
                        "first_error_line": None,
                        "cause": "chunk %d" % count,
                        "evidence": [],
                    }
                )
        else:
            content = json.dumps(
                {
                    "failure_class": "ok",
                    "first_error_line": None,
                    "cause": "chunk %d" % count,
                    "evidence": [],
                }
            )
        payload = json.dumps({"choices": [{"message": {"content": content}}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):
        pass


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(os.path.join(STATE_DIR, "port"), "w") as fh:
    fh.write(str(server.server_address[1]))
server.serve_forever()
PYEOF

start_stub() { # $1 = mode
    rm -f "$TMP/port" "$TMP/count" "$TMP/lastbody"
    STUB_DIR="$TMP" STUB_MODE="$1" python3 "$TMP/stub.py" &
    STUB_PID=$!
    for _ in $(seq 1 50); do
        [ -s "$TMP/port" ] && break
        sleep 0.1
    done
    [ -s "$TMP/port" ] || fail "stub did not publish its port"
    PORT="$(cat "$TMP/port")"
}

stop_stub() {
    kill "$STUB_PID" 2>/dev/null || true
    wait "$STUB_PID" 2>/dev/null || true
    STUB_PID=""
}

run_analyzer() { # $1 = input, $2 = out json, $3 = chunk-lines, $4 = timeout (optional)
    python3 "$ANALYZER" "$1" \
        --model-url "http://127.0.0.1:$PORT/v1/chat/completions" \
        --chunk-lines "$3" --timeout "${4:-120}" --out "$2"
}

check() { # $1 = report json, $2 = python expression over report variable `r`
    python3 - "$1" "$2" <<'PYEOF'
import json
import sys

r = json.load(open(sys.argv[1]))
sys.exit(0 if eval(sys.argv[2]) else 1)
PYEOF
}

# --- (a) chunks merge in order ---------------------------------------------
printf 'alpha\nbeta\ngamma\ndelta\nepsilon\nzeta\n' >"$TMP/log-a.out"
start_stub ok
run_analyzer "$TMP/log-a.out" "$TMP/report-a.json" 2
stop_stub
check "$TMP/report-a.json" '[c["index"] for c in r["chunks"]] == [0, 1, 2]' \
    || fail "(a) chunk indices are not 0,1,2 in order"
check "$TMP/report-a.json" 'r["chunk_errors"] == []' \
    || fail "(a) unexpected chunk errors"
check "$TMP/report-a.json" 'r["failure_class"] == "ok"' \
    || fail "(a) merged class is not ok"
echo "PASS (a): chunks merge in order"

# --- (b) malformed JSON -> exactly one retry -> recorded chunk error --------
printf 'only line\n' >"$TMP/log-b.out"
start_stub garbage
run_analyzer "$TMP/log-b.out" "$TMP/report-b.json" 100
stop_stub
[ "$(cat "$TMP/count")" = "2" ] \
    || fail "(b) expected exactly 2 requests (1 + 1 retry), got $(cat "$TMP/count")"
check "$TMP/report-b.json" 'len(r["chunk_errors"]) == 1 and r["chunks"] == []' \
    || fail "(b) chunk error not recorded"
check "$TMP/report-b.json" 'r["failure_class"] == "unknown"' \
    || fail "(b) merged class with only errors must be unknown"
echo "PASS (b): malformed JSON -> one retry -> recorded chunk error"

# --- (c) doubled-line dedup preserves original line numbering ---------------
# orig 1..6; the ERROR line sits at ORIGINAL line 3 (and its tee twin at 4).
printf 'start\nstart\nERROR: boom\nERROR: boom\nend\nend\n' >"$TMP/log-c.out"
start_stub c3
run_analyzer "$TMP/log-c.out" "$TMP/report-c.json" 100
stop_stub
grep -q '^3|ERROR: boom$' "$TMP/lastbody" \
    || fail "(c) chunk text lost original numbering for the ERROR line"
grep -q '^2|ERROR: boom$' "$TMP/lastbody" \
    && fail "(c) ERROR line was renumbered to deduped position 2"
check "$TMP/report-c.json" 'r["evidence"] == [3] and r["chunks"][0]["original_lines"] == [1, 5]' \
    || fail "(c) evidence/original_lines do not use original numbering"
echo "PASS (c): doubled-line dedup preserves original line numbering"

# --- (d) red fixture: stub returns C3, merged report carries it -------------
check "$TMP/report-c.json" 'r["failure_class"] == "C3" and r["chunks"][0]["failure_class"] == "C3"' \
    || fail "(d) merged report does not carry C3"
echo "PASS (d): red fixture C3 carried into the merged report"

# --- (e) --timeout honored: transport timeout -> chunk error, NO retry ------
printf 'one line\n' >"$TMP/log-e.out"
start_stub slow
run_analyzer "$TMP/log-e.out" "$TMP/report-e.json" 100 1
stop_stub
[ "$(cat "$TMP/count")" = "1" ] \
    || fail "(e) expected exactly 1 request on timeout (no transport retry), got $(cat "$TMP/count")"
check "$TMP/report-e.json" 'len(r["chunk_errors"]) == 1 and "timed out" in r["chunk_errors"][0]["error"]' \
    || fail "(e) timeout not recorded as a chunk error"
echo "PASS (e): --timeout honored (transport timeout recorded, not retried)"

# --- (f) only tee-pairs collapse: 3-run keeps originals 1 and 3 --------------
# originals 1,2,3 = x (a 3-run: two tee pairs plus an unpaired twin), 4 = y
printf 'x\nx\nx\ny\n' >"$TMP/log-f.out"
start_stub ok
run_analyzer "$TMP/log-f.out" "$TMP/report-f.json" 100
stop_stub
grep -q '^1|x$' "$TMP/lastbody" \
    || fail "(f) first occurrence of x lost"
grep -q '^3|x$' "$TMP/lastbody" \
    || fail "(f) second occurrence of x (original 3) lost - collapse is not pair-wise"
grep -q '^2|x$' "$TMP/lastbody" \
    && fail "(f) tee twin (original 2) not collapsed"
echo "PASS (f): only tee-pairs collapse (3-run keeps originals 1 and 3)"

# --- (g) terminal merge: the abort chunk decides, not the first non-ok ------
# 8 distinct lines, chunk-lines 2 -> chunks [1-2][3-4][5-6][7-8]; stub "mixed"
# answers C6 (warning) for chunk 0 and C3 (abort) for chunk 3.
printf 'start\nW: unsandboxed download\nfetch ok a\nfetch ok b\nfetch ok c\nfetch ok d\nERROR [provenance-inputs] FAILED\nERROR build aborted at stage (rc=1)\n' >"$TMP/log-g.out"
start_stub mixed
run_analyzer "$TMP/log-g.out" "$TMP/report-g.json" 2
stop_stub
check "$TMP/report-g.json" 'r["failure_class"] == "C3"' \
    || fail "(g) merged class is not the abort chunk's (terminal-failure semantics broken)"
check "$TMP/report-g.json" 'r["first_error_line"] == 8' \
    || fail "(g) first_error_line is not the abort chunk's"
check "$TMP/report-g.json" 'sorted(r["evidence"]) == [2, 8]' \
    || fail "(g) evidence not preserved across chunks"
echo "PASS (g): terminal/abort chunk decides the merged class"

# --- (h) prompt carries the classification-contract clauses -----------------
grep -q "never failures on their own" "$ANALYZER" \
    || fail "(h) SYSTEM_PROMPT lost the benign-warning clause"
grep -q "an input has an unreviewed origin" "$ANALYZER" \
    || fail "(h) taxonomy lost the C1 symptom vocabulary"
echo "PASS (h): prompt carries benign-warning + C1 symptom clauses"

echo "analyze-build-log tests: 8 passed, 0 failed"
