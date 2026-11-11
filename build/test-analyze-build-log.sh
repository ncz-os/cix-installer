#!/usr/bin/env bash
# Tests for build/analyze-build-log.py — the stub model server is python3 stdlib only.
#
# Spec cases (Duty-5e job 01a1ca7d-d008-75cf-9ace-a6a04a5e8c5a):
#   (a) chunks merge in order
#   (b) malformed JSON from the stub triggers exactly one retry then a recorded chunk error
#   (c) the doubled-line dedup preserves original line numbering
#   (d) a red fixture where the stub returns class C3 and the merged report carries it
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

run_analyzer() { # $1 = input, $2 = out json, $3 = chunk-lines
    python3 "$ANALYZER" "$1" \
        --model-url "http://127.0.0.1:$PORT/v1/chat/completions" \
        --chunk-lines "$3" --out "$2"
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

echo "analyze-build-log tests: 4 passed, 0 failed"
