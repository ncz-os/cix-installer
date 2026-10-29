#!/bin/bash
# test-no-lan-urls.sh -- HARD RULE (operator, 2026-10-29): an image never
# carries a LAN URL.
#
# Why: the first real Magnetar server install (TYPHON, 2026-10-29) failed in
# the debootstrap stub -- '[FETCH] base.squashfs attempt 1..9 failed (rc=4)' --
# because the medium's manifest pinned http://10.0.2.2 (the KVM gate's host
# alias). The payload host was serving the same file at 561 MB/s. A medium
# pinned to a gate alias or a build host's LAN address installs nowhere but
# the build rack, so the writer must refuse to emit one and shipped scripts
# must not contain one either.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PASS=0; FAILS=0
ok()  { PASS=$((PASS+1)); printf 'ok   %s\n' "$*"; }
bad() { FAILS=$((FAILS+1)); printf 'FAIL %s\n' "$*"; }

# --- 1. the writer's refusal, exercised directly ---------------------------
PYOUT=$(python3 - "$ROOT" <<'PY' 2>&1
import importlib.util, sys, pathlib
root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("w", root/"build"/"iso"/"write-usb-image.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
bad_urls = ["http://10.0.2.2/base.squashfs",
            "http://192.168.207.11:8088/base.squashfs",
            "http://172.16.5.4/x", "http://127.0.0.1/x",
            "http://localhost/x", "http://buildhost.local/x"]
good_urls = ["https://payload.ncz-os.example/base.squashfs",
             "https://cdn.example.org/ncz/ncz-pool-amd64.tar.gz"]
for u in bad_urls:
    try:
        m._refuse_lan_url(u, "test")
    except RuntimeError:
        continue
    print("NOT-REFUSED", u); sys.exit(1)
for u in good_urls:
    try:
        m._refuse_lan_url(u, "test")
    except RuntimeError:
        print("WRONGLY-REFUSED", u); sys.exit(1)
print("OK")
PY
)
case "$PYOUT" in
  *OK) ok "writer refuses every LAN/loopback URL and accepts public hosts" ;;
  *)   bad "writer LAN-URL refusal: $(printf '%s' "$PYOUT" | tail -2 | tr '\n' ' ')" ;;
esac

# --- 2. shipped runtime surfaces carry no LAN URL --------------------------
# Shipped = what a target runs or reads: preseed/, post-install/, assets/.
# Comments that must quote a LAN address to explain this rule may end the line
# with the marker  lan-url-ok .
# Loopback (127.0.0.1 / localhost) is NOT a LAN pin: those are the target's
# own client calls against a service on the same box (46-ncz-cli.sh health
# checks), which never leave the machine. The rule is about addresses that
# only resolve inside the build rack.
hits=$(grep -rInE 'https?://(10\.[0-9]+\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)|https?://[a-z0-9.-]+\.local' \
        "$ROOT/preseed" "$ROOT/post-install" "$ROOT/assets" 2>/dev/null \
       | grep -v 'lan-url-ok' | grep -vE '/tests?/' || true)
if [ -z "$hits" ]; then
    ok "no LAN URL in preseed/, post-install/ or assets/"
else
    bad "LAN URL in a shipped file:"
    printf '%s\n' "$hits" | head -5 | sed 's/^/       /'
fi

# --- 3. no self-contained medium pins a URL at all -------------------------
if grep -q '_server_payload_mode' "$ROOT/build/iso/write-usb-image.py" \
   && grep -q 'NCZ_SERVER_PAYLOAD=medium' "$ROOT/build/iso/write-usb-image.py"; then
    ok "a self-contained server medium is supported (NCZ_SERVER_PAYLOAD=medium)"
else
    bad "no self-contained server path: a server medium can only be built with URLs"
fi

echo "no-lan-url tests: $PASS passed, $FAILS failed"
[ "$FAILS" = 0 ]
