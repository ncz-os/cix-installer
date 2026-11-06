#!/bin/bash
# test-substrate-ci-http.sh -- end-to-end tests for build/substrate-ci.py preflight
# over real HTTP.
#
# build/test-substrate-ci.sh covers the decision logic with an injected fetcher.
# This covers the network path itself against a local server that can be told to
# behave like the snapshot service does on a bad day: 503 on pool objects while the
# index still serves, a 200 with zero bytes, and a 404 for something genuinely absent.
#
# The three failure modes it encodes were all observed on 2026-11-06:
#   * 200 with a zero-byte body must never count as healthy (it scored a fake 63.5 %);
#   * 503/504 is "degraded", which the CI treats as a no-op with an alert, not a failure;
#   * 404 means the pin does not authorize the object, which is a hard stop.
#
# Run: bash build/test-substrate-ci-http.sh    Exit 0 = all cases pass.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
python3 -I - "$HERE/substrate-ci.py" <<'PY'
import http.server
import importlib.util
import json
import socketserver
import subprocess
import sys
import threading

spec = importlib.util.spec_from_file_location("sci", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
SCI = sys.argv[1]

ok = fail = 0


def check(cond, what):
    global ok, fail
    if cond:
        ok += 1
        print("  PASS  %s" % what)
    else:
        fail += 1
        print("  FAIL  %s" % what)


class Handler(http.server.BaseHTTPRequestHandler):
    mode = "ok"

    def do_GET(self):
        if Handler.mode == "503":
            body = b"no healthy backends"
            self.send_response(503)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if Handler.mode == "404":
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        body = b"x" * 512 if Handler.mode == "ok" else b""
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


srv = socketserver.TCPServer(("127.0.0.1", 0), Handler)
port = srv.server_address[1]
threading.Thread(target=srv.serve_forever, daemon=True).start()
base = "http://127.0.0.1:%d/archive/debian/X" % port

# --- probe verdicts over real HTTP -----------------------------------------
Handler.mode = "ok"
probes = m.probe_mirror(base, retries=(0,))
check(all(p["verdict"] == "ok" for p in probes), "HTTP 200 with a body -> ok")

Handler.mode = "empty"
probes = m.probe_mirror(base, retries=(0,))
check(all(p["verdict"] == "empty" for p in probes),
      "HTTP 200 with ZERO bytes -> empty, never healthy (the false 63.5% bug)")

Handler.mode = "503"
probes = m.probe_mirror(base, retries=(0,))
check(all(p["verdict"] == "unreachable" for p in probes), "HTTP 503 -> unreachable")

Handler.mode = "404"
probes = m.probe_mirror(base, retries=(0,))
check(all(p["verdict"] == "absent" for p in probes), "HTTP 404 -> absent, not a service failure")

# --- decisions through the real CLI ----------------------------------------
def cli_preflight(mode, extra=()):
    Handler.mode = mode
    cmd = [sys.executable, "-I", SCI, "preflight", "--base", base,
           "--pin-age-days", "3", "--no-retry", "--json"] + list(extra)
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    try:
        out = json.loads(p.stdout)
    except Exception:
        out = {}
    return p.returncode, out


rc, out = cli_preflight("ok")
check(rc == 0 and out.get("decision") == "proceed",
      "CLI: healthy mirror -> proceed, exit 0 (got %s/%s)" % (rc, out.get("decision")))

rc, out = cli_preflight("503")
check(rc == 0 and out.get("decision") == "degraded",
      "CLI: degraded mirror -> exit 0 + degraded, a no-op not a pipeline failure (got %s/%s)"
      % (rc, out.get("decision")))

rc, out = cli_preflight("empty")
check(rc == 0 and out.get("decision") == "degraded",
      "CLI: zero-byte 200 is treated as degraded, not healthy (got %s/%s)"
      % (rc, out.get("decision")))

rc, out = cli_preflight("404")
check(rc == 2 and out.get("decision") == "broken-pin",
      "CLI: 404 means the pin does not authorize its object -> hard stop, exit 2 (got %s/%s)"
      % (rc, out.get("decision")))

srv.shutdown()
print("\n%d passed, %d failed" % (ok, fail))
sys.exit(1 if fail else 0)
PY
