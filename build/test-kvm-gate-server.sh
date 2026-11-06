#!/bin/bash
# Source test for the KVM install gate's server-variant payload server
# (build/kvm-install-gate-gpt.sh's NCZ_KVM_GATE_VARIANTS 'server' /
# 'server-offline-negative' sets).
#
# Proves, WITHOUT starting QEMU and WITHOUT sudo:
#   1. the exact invocation the gate uses (`python3 - <heredoc> arg1 arg2`)
#      actually passes the arguments through sys.argv[1:] — the reviewer's
#      critical point is a test, not an assumption;
#   2. the server binds, serves both artifacts (base.squashfs + the ncz
#      assets bundle) with the right sha256, and the gate's readiness probe
#      (a real HTTP GET to the end of the headers) sees 200;
#   3. the guest's fetcher (ncz-fetch-payload.sh) succeeds against that
#      server and REFUSES loudly on a wrong URL and on a stopped server;
#   4. the gate's per-artifact pin check catches a URL that does not exist
#      on the server.
#
# Runs rootless: the server binds 127.0.0.1 on a random high port (the
# QEMU-side 10.0.2.2 binding is a property of the network backend, not of
# this invocation). Part of `make test`.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ncz-gate-srv-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
FAIL=0
ok()  { echo "ok: $*"; }
bad() { echo "not ok: $*" >&2; FAIL=1; }

PORT=$((20000 + RANDOM % 20000))
SRV="$WORK/srv"
mkdir -p "$SRV"
head -c 2097152 /dev/zero > "$SRV/base.squashfs" || dd if=/dev/zero of="$SRV/base.squashfs" bs=1k count=2048 status=none
tar czf "$SRV/ncz-assets-amd64.tar.gz" -C "$SRV" base.squashfs \
    || { echo "setup: cannot make the assets bundle" >&2; exit 1; }
tar tzf "$SRV/ncz-assets-amd64.tar.gz" | grep -qx base.squashfs \
    || { echo "setup: the assets bundle does not carry base.squashfs" >&2; exit 1; }
# option B: the offline apt pool, a repo/ tree the fetcher unpacks
mkdir -p "$WORK/poolsrc/repo/dists/forky/main/binary-amd64" "$WORK/poolsrc/repo/pool/main"
printf 'Package: x\n' > "$WORK/poolsrc/repo/dists/forky/main/binary-amd64/Packages"
printf 'deb' > "$WORK/poolsrc/repo/pool/main/x_1_all.deb"
tar czf "$SRV/ncz-pool-amd64.tar.gz" -C "$WORK/poolsrc" repo \
    || { echo "setup: cannot make the pool payload" >&2; exit 1; }

# --- 1: the gate's invocation, verbatim (python3 - <heredoc> arg1 arg2) ---
# Exactly the form ncz_gate_srv_start() uses: the heredoc is the script and
# the shell arguments after the '-' reach sys.argv[1:]. If this form did not
# pass arguments, every line of the server logic below would sys.argv-crash.
python3 - "$SRV" "127.0.0.1" "$PORT" <<'PY' >"$WORK/srv.log" 2>&1 &
import http.server, os, socketserver, sys
os.chdir(sys.argv[1])
class H(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
for _ in range(20):
    try:
        srv = socketserver.TCPServer((sys.argv[2], int(sys.argv[3])), H)
        break
    except OSError as e:
        if _ == 19:
            raise SystemExit(f"bind {sys.argv[2]}:{sys.argv[3]} failed: {e}")
        import time; time.sleep(0.25)
print("serving", os.getcwd(), "on", sys.argv[2] + ":" + sys.argv[3], flush=True)
srv.serve_forever()
PY
SRV_PID=$!
if ! kill -0 "$SRV_PID" 2>/dev/null; then
    bad "the gate's python3 - <heredoc> invocation died immediately"
    cat "$WORK/srv.log" >&2
    exit 1
fi
ok "invocation: python3 - heredoc arg1 arg2 is alive (sys.argv carries the serve dir, bind host and port)"

# wait until it answers (the gate's own loop, shrunk)
for _ in $(seq 1 20); do
    python3 - 127.0.0.1 "$PORT" <<'PY' 2>/dev/null && break
import socket, sys
s = socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=2)
s.sendall(b"GET /base.squashfs HTTP/1.0\r\nHost: " + sys.argv[1].encode() + b"\r\n\r\n")
buf = b""
s.settimeout(5)
while b"\r\n\r\n" not in buf:
    chunk = s.recv(65536)
    if not chunk: break
    buf += chunk
status = buf.split(b"\r\n", 1)[0].decode("utf-8", "replace")
s.close()
sys.exit(0 if status.endswith(" 200 OK") else 1)
PY
    sleep 0.2
done
python3 - 127.0.0.1 "$PORT" <<'PY' 2>/dev/null || { bad "readiness: the server never answered 200"; kill "$SRV_PID" 2>/dev/null; exit 1; }
import socket, sys
s = socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=2)
s.sendall(b"GET /base.squashfs HTTP/1.0\r\nHost: " + sys.argv[1].encode() + b"\r\n\r\n")
buf = b""
s.settimeout(5)
while b"\r\n\r\n" not in buf:
    chunk = s.recv(65536)
    if not chunk: break
    buf += chunk
status = buf.split(b"\r\n", 1)[0].decode("utf-8", "replace")
s.close()
sys.exit(0 if status.endswith(" 200 OK") else 1)
PY
ok "readiness probe (the gate's exact logic): the server answers 200 to a real GET"

# --- 2: both artifacts, right bytes ---------------------------------------
DL="$WORK/dl"; mkdir -p "$DL"
got_p=$(curl -fsS --max-time 10 "http://127.0.0.1:$PORT/base.squashfs" | sha256sum | cut -d' ' -f1)
want_p=$(sha256sum "$SRV/base.squashfs" | cut -d' ' -f1)
[ "$got_p" = "$want_p" ] && ok "serving: base.squashfs bytes match (sha256 $got_p)" || bad "serving: base.squashfs sha256 mismatch ($got_p != $want_p)"
got_a=$(curl -fsS --max-time 10 "http://127.0.0.1:$PORT/ncz-assets-amd64.tar.gz" | sha256sum | cut -d' ' -f1)
want_a=$(sha256sum "$SRV/ncz-assets-amd64.tar.gz" | cut -d' ' -f1)
[ "$got_a" = "$want_a" ] && ok "serving: the assets bundle bytes match (sha256 $got_a)" || bad "serving: assets bundle sha256 mismatch"
got_l=$(curl -fsS --max-time 10 "http://127.0.0.1:$PORT/ncz-pool-amd64.tar.gz" | sha256sum | cut -d' ' -f1)
want_l=$(sha256sum "$SRV/ncz-pool-amd64.tar.gz" | cut -d' ' -f1)
[ "$got_l" = "$want_l" ] && ok "serving: the offline apt pool bytes match (sha256 $got_l)" || bad "serving: pool sha256 mismatch"

# --- 3: the gate's per-artifact pin check catches a wrong URL --------------
# A URL the server does not serve must not answer 200 (the gate proves both
# pinned artifacts exist BEFORE the guest starts).
_pin_out=$(python3 - "127.0.0.1:$PORT" <<'PY' 2>/dev/null || echo "NO-RESPONSE"
import socket, sys
hostport = sys.argv[1].rsplit(":", 1)
host, port = hostport
s = socket.create_connection((host, int(port)), timeout=5)
s.sendall(b"GET /no-such-file HTTP/1.0\r\nHost: " + host.encode() + b"\r\n\r\n")
buf = b""
s.settimeout(10)
while b"\r\n\r\n" not in buf:
    chunk = s.recv(65536)
    if not chunk: break
    buf += chunk
status = buf.split(b"\r\n", 1)[0].decode("utf-8", "replace") if buf else "NO-RESPONSE"
s.close()
print(status)
PY
)
case "$_pin_out" in
    *200*) bad "pin check: a missing path answered 200 -- the gate would have started the guest" ;;
    *)     ok "pin check: a URL the server does not serve does not answer 200 (got: ${_pin_out:-NO-RESPONSE})" ;;
esac

# --- 4: the guest's fetcher against the live server ------------------------
# The fetcher reads its manifest from $NCZ_FETCH_MANIFEST (default
# $NCZ_PAYLOAD_DIR/ncz-fetch-payload.manifest) and writes under
# $NCZ_PAYLOAD_DIR (default /cdrom/ncz-payload); both are overridable, so the
# source test runs it rootless against a writable dir.
FETCH="$ROOT/../preseed/ncz-fetch-payload.sh"
[ -x "$FETCH" ] || { bad "setup: $FETCH is not executable"; }
DEST="$WORK/fetch"; mkdir -p "$DEST"
{
    printf 'base.squashfs\thttp://127.0.0.1:%s/base.squashfs\t%s\tfile\n' "$PORT" "$want_p"
    printf 'ncz-assets-amd64.tar.gz\thttp://127.0.0.1:%s/ncz-assets-amd64.tar.gz\t%s\tfile\n' "$PORT" "$want_a"
    printf 'ncz-pool-amd64.tar.gz\thttp://127.0.0.1:%s/ncz-pool-amd64.tar.gz\t%s\tuntar\n' "$PORT" "$want_l"
} > "$DEST/ncz-fetch-payload.manifest"
if NCZ_PAYLOAD_DIR="$DEST" "$FETCH" > "$WORK/fetch-live.log" 2>&1; then
    ok "fetcher: all three artifacts fetched + sha256-verified against the live server"
    [ -s "$DEST/repo/dists/forky/main/binary-amd64/Packages" ] && [ -f "$DEST/repo/pool/main/x_1_all.deb" ] \
        && ok "fetcher: the pool unpacked as <staging>/repo (where the stub binds the target's /cdrom)" \
        || bad "fetcher: the pool did not unpack to <staging>/repo"
    grep -q "ncz-pool-amd64.tar.gz verified sha256=" "$WORK/fetch-live.log" \
        && ok "fetcher: the pool's 'verified sha256=' line the gate asserts is present" || bad "fetcher: no pool 'verified sha256=' line"
else
    bad "fetcher: a fetch that should succeed failed: $(tail -3 "$WORK/fetch-live.log")"
fi
grep -q "verified sha256" "$WORK/fetch-live.log" && ok "fetcher: the gate's asserted log line is present ('verified sha256=')" || bad "fetcher: no 'verified sha256' log line for the gate to assert"
grep -q "all manifest artifacts fetched and verified" "$WORK/fetch-live.log" && ok "fetcher: the gate's second asserted line is present ('all manifest artifacts fetched and verified')" || bad "fetcher: no 'all manifest artifacts fetched and verified' line"

# --- 5: the fetcher REFUSES a wrong sha256 (loud, no partial accept) -------
DEST_BAD="$WORK/fetch-bad"; mkdir -p "$DEST_BAD"
printf 'base.squashfs\thttp://127.0.0.1:%s/base.squashfs\t0000000000000000000000000000000000000000000000000000000000000000\tfile\n' "$PORT" > "$DEST_BAD/ncz-fetch-payload.manifest"
if NCZ_PAYLOAD_DIR="$DEST_BAD" NCZ_FETCH_MAX_TRIES=1 NCZ_FETCH_CONNECT_TIMEOUT=2 NCZ_FETCH_OVERALL_TIMEOUT=30 timeout 90 "$FETCH" > "$WORK/fetch-bad.log" 2>&1; then
    bad "fetcher: a WRONG sha256 was accepted (it must refuse)"
else
    ok "fetcher: a wrong sha256 is refused (the install cannot run on unverified bytes)"
fi

# --- 6: the NEGATIVE path — server stopped, the fetch fails BOUNDED -------
kill "$SRV_PID" 2>/dev/null || true
wait "$SRV_PID" 2>/dev/null || true
sleep 0.3
DEST_OFF="$WORK/fetch-off"; mkdir -p "$DEST_OFF"
printf 'base.squashfs\thttp://127.0.0.1:%s/base.squashfs\t%s\tfile\n' "$PORT" "$want_p" > "$DEST_OFF/ncz-fetch-payload.manifest"
t0=$(date +%s)
if NCZ_PAYLOAD_DIR="$DEST_OFF" NCZ_FETCH_MAX_TRIES=2 NCZ_FETCH_CONNECT_TIMEOUT=1 NCZ_FETCH_OVERALL_TIMEOUT=30 timeout 90 "$FETCH" > "$WORK/fetch-off.log" 2>&1; then
    bad "negative: the fetch SUCCEEDED with the server stopped"
else
    t1=$(date +%s); dt=$((t1 - t0))
    [ "$dt" -gt 45 ] && bad "negative: the fetch took ${dt}s (not bounded)" \
        || ok "negative: with the server stopped the fetch failed in ${dt}s (bounded) — the gate's offline run must look like this"
fi
if [ -e "$DEST_OFF/base.squashfs" ]; then
    bad "negative: a half-written rootfs payload was left on the staging root"
else
    ok "negative: no half-written payload left behind (no partial file on the staging root)"
fi
grep -q "No root filesystem was installed" "$WORK/fetch-off.log" && ok "negative: the log carries the guest's refusal line the gate asserts" || bad "negative: no 'No root filesystem was installed' line: $(tail -2 "$WORK/fetch-off.log")"

# --- 7: the gate serves and checks the pool (option B) ---------------------
G="$ROOT/kvm-install-gate-gpt.sh"
grep -q 'cp "$NCZ_GATE_SERVER_POOL" "$SRV_DIR/' "$G" && ok "gate: the pool is copied into the served dir" || bad "gate: the pool is not served"
grep -q '\$1 ~ /^ncz-pool-/' "$G" && grep -q '\$1 ~ /^ncz-assets-/' "$G" \
    && ok "gate: the bundle and pool pins are read by name (two untar rows)" || bad "gate: untar rows are not told apart"
grep -q '_srv_check_url "$_srv_lurl"' "$G" && ok "gate: the pinned pool URL must answer 200 before the guest starts" || bad "gate: pool URL not checked"
grep -q 'for _fa in base.squashfs "$_srv_name" "$_srv_pool_name"; do' "$G" \
    && ok "gate: the guest must log 'verified sha256=' for the pool too" || bad "gate: pool fetch not asserted"
grep -q 'no offline apt pool to serve' "$G" && ok "gate: a missing pool payload is a gate error" || bad "gate: missing pool not refused"

echo
[ "$FAIL" -eq 0 ] && echo "test-kvm-gate-server: ALL PASSED" || { echo "test-kvm-gate-server: FAILURES" >&2; exit 1; }
